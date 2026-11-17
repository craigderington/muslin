#!/usr/bin/env python3
"""Check the interactive ARM console, job control, and PSCI poweroff."""
import os
import selectors
import subprocess
import sys
import time

process = subprocess.Popen(
    ['scripts/run-qemu-arm64.sh', *sys.argv[1:]],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
)
output = b''
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
deadline = time.monotonic() + 90
sent = False
try:
    while time.monotonic() < deadline:
        if not selector.select(timeout=1):
            if process.poll() is not None:
                break
            continue
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk:
            break
        output += chunk
        if not sent and b'userspace ready' in output:
            # Let ash acquire the console before sending the command.
            process.stdin.write(b"sleep 1; printf 'MUSLIN_CONSOLE_%s\\n' OK; poweroff\n")
            process.stdin.flush()
            sent = True
    process.wait(timeout=max(1, deadline - time.monotonic()))
    assert process.returncode == 0, f'QEMU exited {process.returncode}'
    assert b'(aarch64)' in output, 'wrong guest architecture'
    assert b'MUSLIN_CONSOLE_OK' in output, 'shell command did not run'
    assert b'Power down' in output or b'poweroff' in output, 'missing shutdown'
    assert b'job control turned off' not in output, 'no controlling terminal'
    assert b'Kernel panic' not in output and b'MUSLIN_BOOT_FAILED' not in output
    print('ARM64 console, job control, and poweroff: PASS')
except BaseException:
    print(output.decode(errors='replace'), file=sys.stderr)
    raise
finally:
    selector.close()
    if process.poll() is None:
        process.kill()
    process.wait()
