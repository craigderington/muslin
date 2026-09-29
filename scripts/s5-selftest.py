#!/usr/bin/env python3
"""Guest regressions for package validation, durable install, root failures and shutdown."""
import hashlib
import io
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time

HERE = Path(__file__).resolve().parent
KERNEL, INITRD, BASE = map(lambda p: Path(p).resolve(), sys.argv[1:4])


def debugfs(disk, command):
    result = subprocess.run(['debugfs', '-w', '-R', command, str(disk)], capture_output=True, text=True, check=True)
    if any(word in result.stderr for word in ('File not found', 'not found by', 'Could not', 'Usage:')):
        raise RuntimeError(result.stderr)
    return result.stdout


def environment(disk, cmdline):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = dict(os.environ, HOST_HTTP_PORT=str(port), APPEND_EXTRA=cmdline)
    if disk is not None:
        env['DISK_IMAGE'] = str(disk)
    else:
        env.pop('DISK_IMAGE', None)
    return env


def boot(disk, cmdline, commands=None):
    process = subprocess.Popen([str(HERE/'run-qemu.sh'), str(KERNEL), str(INITRD)],
                               env=environment(disk, cmdline), stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = bytearray()
    deadline = time.monotonic() + 30
    sent = False
    try:
        while time.monotonic() < deadline:
            if select.select([process.stdout], [], [], .1)[0]:
                data = os.read(process.stdout.fileno(), 65536)
                if not data:
                    break
                output.extend(data)
            if commands is not None and not sent and b'root@muslin' in output:
                process.stdin.write(commands.encode())
                process.stdin.flush()
                sent = True
        process.wait(timeout=1)
        assert process.returncode == 0, f'QEMU exited {process.returncode}'
        assert commands is None or sent, 'guest never reached the interactive shell'
    except BaseException:
        process.terminate()
        process.wait(timeout=5)
        print(output.decode(errors='replace'))
        raise
    log = output.decode(errors='replace').replace('\r', '')
    assert 'Kernel panic' not in log, log
    return log


def package(work, name, files, members):
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for path, data, kind in [('manifest', f'name={name}\nversion=1\n'.encode(), tarfile.REGTYPE),
                                 ('files', files.encode(), tarfile.REGTYPE), *members]:
            entry = tarfile.TarInfo(path)
            entry.type = kind
            entry.mode = 0o644
            entry.size = len(data) if kind == tarfile.REGTYPE else 0
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                entry.linkname = '/etc/hostname'
            tar.addfile(entry, io.BytesIO(data) if entry.size else None)
    path = work/(name+'.mpkg')
    path.write_bytes(subprocess.check_output(['zstd', '-q', '-c'], input=archive.getvalue()))
    path.with_suffix('.mpkg.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name+'\n')
    return path


with tempfile.TemporaryDirectory(prefix='muslin-s5-') as temporary:
    work = Path(temporary)
    disk = work/'disk.ext4'
    shutil.copyfile(BASE, disk)
    cases = {
        'alpha': ('/usr/bin/s5-owned\n', [('root/usr/bin/s5-owned', b'ALPHA\n', tarfile.REGTYPE)]),
        'conflict': ('/usr/bin/s5-owned\n', [('root/usr/bin/s5-owned', b'BAD\n', tarfile.REGTYPE)]),
        'omitted': ('', [('root/usr/bin/s5-owned', b'BAD\n', tarfile.REGTYPE)]),
        'traversal': ('/usr/bin/s5-owned\n', [('root/usr/../etc/hostname', b'BAD\n', tarfile.REGTYPE)]),
        'absolute': ('/usr/bin/s5-owned\n', [('/etc/hostname', b'BAD\n', tarfile.REGTYPE)]),
        'symlink': ('/usr/bin/s5-link\n', [('root/usr/bin/s5-link', b'', tarfile.SYMTYPE)]),
        'hardlink': ('/usr/bin/s5-link\n', [('root/usr/bin/s5-link', b'', tarfile.LNKTYPE)]),
        'basefile': ('/etc/hostname\n', [('root/etc/hostname', b'BAD\n', tarfile.REGTYPE)]),
        'checksum': ('/usr/bin/s5-checksum\n', [('root/usr/bin/s5-checksum', b'BAD\n', tarfile.REGTYPE)]),
    }
    for name, (files, members) in cases.items():
        path = package(work, name, files, members)
        checksum = path.with_suffix('.mpkg.sha256')
        if name == 'checksum':
            checksum.write_text('0'*64+'\n')
        for source in (path, checksum):
            debugfs(disk, f'write {source} /var/lib/muslin/{source.name}')
    commands = 'mpkg install /var/lib/muslin/alpha.mpkg\n'
    for name in [*list(cases)[1:], 'alpha']:
        commands += (f'if mpkg install /var/lib/muslin/{name}.mpkg; then echo S5_UNEXPECTED_{name}; '
                     f'else echo S5_REJECTED_{name}; fi\n')
    commands += ('[ "$(cat /usr/bin/s5-owned)" = ALPHA ] && '
                 '[ "$(cat /etc/hostname)" = muslin ] && echo S5_CONTENT_OK\n'
                 'poweroff\n')
    log = boot(disk, 'muslin.root=/dev/vda muslin.acceptance', commands)
    assert 'MUSLIN_BOOT_FAILED' not in log and 'mpkg: installed alpha 1' in log, log
    assert '\nS5_CONTENT_OK\n' in log and 'poweroff: stopping processes' in log, log
    for name in [*list(cases)[1:], 'alpha']:
        assert f'\nS5_REJECTED_{name}\n' in log and f'\nS5_UNEXPECTED_{name}\n' not in log, log
    log = boot(disk, 'muslin.root=/dev/vda muslin.acceptance',
               '[ "$(cat /usr/bin/s5-owned)" = ALPHA ] && '
               '[ -f /var/lib/mpkg/alpha/manifest ] && echo S5_RETAINED\nreboot\n')
    assert '\nS5_RETAINED\n' in log and 'reboot: stopping processes' in log, log
    print('S5 packages: malformed/conflicting/checksum/upgrade rejection, durable install, poweroff and reboot PASS', flush=True)

    for failure in ('missing-device', 'missing-init', 'mount-target'):
        shutil.copyfile(BASE, disk)
        if failure == 'missing-init':
            debugfs(disk, 'rm /sbin/init')
        if failure == 'mount-target':
            debugfs(disk, 'rmdir /proc')
            marker = work/'marker'
            marker.write_text('not a directory\n')
            debugfs(disk, f'write {marker} /proc')
        device = '/dev/vdz' if failure == 'missing-device' else '/dev/vda'
        log = boot(disk, 'muslin.root='+device)
        assert 'MUSLIN_BOOT_FAILED' in log and 'userspace ready' not in log, log
    print('S5 disk-root failures: missing disk, missing init, partial mount-move failure PASS', flush=True)
