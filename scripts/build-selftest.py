#!/usr/bin/env python3
"""Build regressions: reproducible disk metadata, variant identity and state isolation."""
import gzip
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
OUT = Path(sys.argv[1]).resolve()


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, text=True, capture_output=True, **kwargs).stdout


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


with tempfile.TemporaryDirectory(prefix='muslin-build-test-') as temporary:
    work = Path(temporary)
    for variant in ('c', 'rs'):
        initrd = OUT/f'initramfs-{variant}.cpio.gz'
        a, b = work/f'{variant}-a.ext4', work/f'{variant}-b.ext4'
        run(HERE/'mkrootfs.sh', initrd, OUT/'mpkg', a, '32')
        time.sleep(1.1)  # Catch host ctime leaking into the second image.
        run(HERE/'mkrootfs.sh', initrd, OUT/'mpkg', b, '32')
        assert sha(a) == sha(b), f'{variant}: ext4 not reproducible'
        stage = work/variant
        stage.mkdir()
        subprocess.run(['cpio', '-id', '--quiet', '--no-preserve-owner'], input=gzip.decompress(initrd.read_bytes()), cwd=stage, check=True)
        extracted = work/f'init-{variant}'
        run('debugfs', '-R', f'dump /sbin/init {extracted}', a)
        assert sha(extracted) == sha(stage/'sbin/init') == sha(OUT/f'init-{variant}'), 'wrong disk init variant'
        for path in ('/', '/etc/passwd', '/sbin/init', '/bin/sh', '/usr/bin/mpkg', '/usr/bin/zstd', '/var/lib/muslin'):
            stat = run('debugfs', '-R', f'stat {path}', a)
            assert 'User:     0   Group:     0' in stat, stat
            epoch = int(os.environ.get('SOURCE_DATE_EPOCH', '1'))
            assert f'ctime: 0x{epoch:08x}:00000000' in stat, stat
        run('e2fsck', '-fn', a)
    print('S5 build: reproducible C/Rust disks, matching init, root ownership, timestamps and fsck PASS', flush=True)

    # Exercise the actual Make targets in a disposable project, with rebuildable fixtures.
    sandbox = work/'project'
    sandbox.mkdir()
    shutil.copytree(HERE, sandbox/'scripts', ignore=shutil.ignore_patterns('__pycache__'))
    (sandbox/'out').mkdir()
    (sandbox/'out/rootfs-c.ext4').write_bytes(b'legacy user state')
    (sandbox/'out/base-c.ext4').write_bytes(b'base version one')
    shutil.copyfile(REPO/'Makefile', sandbox/'Makefile')
    run('make', 'preserve-state', cwd=sandbox)
    runtime = sandbox/'state/rootfs-c.ext4'
    assert runtime.read_bytes() == b'legacy user state'
    assert (sandbox/'state/legacy-c.ext4').read_bytes() == b'legacy user state'
    runtime.write_bytes(b'guest changed state')
    (sandbox/'out/base-c.ext4').write_bytes(b'rebuilt version two')
    run(HERE/'prepare-runtime.sh', sandbox/'out/base-c.ext4', runtime)
    assert runtime.read_bytes() == b'guest changed state'
    run('make', 'clean', cwd=sandbox)
    assert not (sandbox/'out').exists()
    assert runtime.read_bytes() == b'guest changed state'
    (sandbox/'out').mkdir()
    (sandbox/'out/base-c.ext4').write_bytes(b'rebuilt after clean')
    run(HERE/'prepare-runtime.sh', sandbox/'out/base-c.ext4', runtime)
    run('make', 'distclean', cwd=sandbox)
    assert runtime.read_bytes() == b'guest changed state'
    assert (sandbox/'state/legacy-c.ext4').read_bytes() == b'legacy user state'
    print('S5 state: legacy migration, base rebuild, clean and distclean preserve runtime data PASS', flush=True)

    package_out = work/'packages'
    run('make', 'package', f'OUT={package_out}', cwd=REPO)
    package = package_out/'hello-1.0.0.mpkg'
    checksum = package.with_suffix('.mpkg.sha256')
    original = sha(package)
    checksum.unlink()
    run('make', 'package', f'OUT={package_out}', cwd=REPO)
    assert checksum.read_text().split()[0] == original == sha(package)
    print('S5 package build: missing checksum regenerated, package bytes reproduce PASS', flush=True)

    # A success marker must not hide a QEMU failure or timeout.
    harness = work/'harness'
    harness.mkdir()
    shutil.copyfile(HERE/'selftest.sh', harness/'selftest.sh')
    for ending in ('exit 1', 'sleep 5'):
        runner = harness/'run-qemu.sh'
        runner.write_text('#!/bin/sh\necho MUSLIN_USERLAND_OK\necho MUSLIN_SELFTEST_OK uptime=0.001s\n'+ending+'\n')
        runner.chmod(0o755)
        result = subprocess.run(['sh', str(harness/'selftest.sh'), 'kernel', 'initrd'],
                                env=dict(os.environ, TIMEOUT='1'), capture_output=True, text=True)
        assert result.returncode != 0, result.stdout
    print('S5 harness: markers followed by failure or timeout are rejected PASS', flush=True)
