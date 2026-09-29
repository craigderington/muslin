#!/usr/bin/env python3
"""Install PostgreSQL, commit rows, reboot with an active transaction, verify durability."""
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
KERNEL, INITRD, BASE = [Path(p).resolve() for p in sys.argv[1:4]]
TIMEOUT = int(os.environ.get('POSTGRES_TEST_TIMEOUT', '180'))


def boot(disk, commands, log_path):
    import select
    import time
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = dict(os.environ, DISK_IMAGE=str(disk), MEM='256M', HOST_HTTP_PORT=str(port),
               APPEND_EXTRA='muslin.root=/dev/vda muslin.postgres muslin.acceptance')
    process = subprocess.Popen([str(HERE/'run-qemu.sh'), str(KERNEL), str(INITRD)],
                               env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)
    output = bytearray()
    sent = False
    end = time.monotonic() + TIMEOUT
    try:
        while time.monotonic() < end:
            if select.select([process.stdout], [], [], .1)[0]:
                data = os.read(process.stdout.fileno(), 65536)
                if not data:
                    break
                output.extend(data)
                log_path.write_bytes(output)
            if not sent and b'root@muslin' in output and b'MUSLIN_POSTGRES_READY' in output:
                process.stdin.write(commands.encode())
                process.stdin.flush()
                sent = True
        process.wait(timeout=1)
        assert process.returncode == 0 and sent, 'guest failed startup or shutdown'
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        log_path.write_bytes(output)
    log = output.decode(errors='replace').replace('\r', '')
    for bad in ('Kernel panic', 'MUSLIN_BOOT_FAILED', 'shutdown hook failed', 'shutdown hook timed out'):
        assert bad not in log, log
    assert '\nMUSLIN_POSTGRES_STOPPED\n' in log, 'missing clean PostgreSQL shutdown: '+log
    return log


work = Path(tempfile.mkdtemp(prefix='postgres-test-', dir=BASE.parent))
disk = work/'disk.ext4'
subprocess.run(['cp', '--sparse=always', str(BASE), str(disk)], check=True)
first = '''/etc/init.d/postgresql sql -At -c "CREATE TABLE muslin_probe (id integer PRIMARY KEY, payload text NOT NULL); INSERT INTO muslin_probe SELECT i, md5(i::text) FROM generate_series(1,1000) i; SELECT 'MUSLIN_PG_WRITE_OK' FROM muslin_probe HAVING count(*)=1000 AND sum(id)=500500 AND bool_and(payload=md5(id::text));"
/etc/init.d/postgresql sql -At -c "SELECT 'MUSLIN_PG_DURABILITY_OK' WHERE current_user='postgres' AND current_setting('fsync')='on' AND current_setting('full_page_writes')='on' AND current_setting('synchronous_commit')='on';"
/etc/init.d/postgresql sql -c "DO 'BEGIN IF 1+1 <> 2 THEN RAISE EXCEPTION ''PL/pgSQL failed''; END IF; END;';"
read -r pgpid < /var/lib/postgresql/data/postmaster.pid
cat /proc/$pgpid/status
PGAPPNAME=muslin_shutdown_probe postgres-user psql -X -v ON_ERROR_STOP=1 -c 'BEGIN; INSERT INTO muslin_probe VALUES (9999, md5(9999::text)); SELECT pg_sleep(60); COMMIT;' >/var/lib/postgresql/held-client.log 2>&1 &
for tries in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    active=$(/etc/init.d/postgresql sql -At -c "SELECT 1 FROM pg_stat_activity WHERE application_name='muslin_shutdown_probe' AND wait_event='PgSleep';")
    if [ "$active" = 1 ]; then echo MUSLIN_PG_HELD_READY; break; fi
    sleep 1
done
reboot
'''
second = '''/etc/init.d/postgresql sql -At -c "SELECT 'MUSLIN_PG_READ_OK' FROM muslin_probe HAVING count(*)=1000 AND sum(id)=500500 AND bool_and(payload=md5(id::text));"
/etc/init.d/postgresql sql -At -c "SELECT 'MUSLIN_PG_ROLLBACK_OK' WHERE NOT EXISTS (SELECT 1 FROM muslin_probe WHERE id=9999);"
/etc/init.d/postgresql sql -At -c "SELECT 'MUSLIN_PG_LOCAL_ONLY' WHERE current_setting('listen_addresses')='';"
if grep -q 'automatic recovery in progress' /var/lib/postgresql/server.log; then echo MUSLIN_PG_UNCLEAN; fi
poweroff
'''
try:
    log1 = boot(disk, first, work/'first.log')
    assert 'mpkg: installed postgresql ' in log1, log1
    for marker in ('MUSLIN_PG_WRITE_OK', 'MUSLIN_PG_DURABILITY_OK', 'MUSLIN_PG_HELD_READY'):
        assert '\n'+marker+'\n' in log1, log1
    assert re.search(r'^Uid:\s+70\s+70\s+70\s+70$', log1, re.M), log1
    assert re.search(r'^Gid:\s+70\s+70\s+70\s+70$', log1, re.M), log1
    assert '\nERROR:' not in log1 and '\nDO\n' in log1, log1
    assert 'reboot: stopping processes' in log1, log1
    log2 = boot(disk, second, work/'second.log')
    for marker in ('MUSLIN_PG_READ_OK', 'MUSLIN_PG_ROLLBACK_OK', 'MUSLIN_PG_LOCAL_ONLY'):
        assert '\n'+marker+'\n' in log2, log2
    assert 'mpkg: installed postgresql ' not in log2, 'package was unexpectedly reinstalled'
    assert '\nMUSLIN_PG_UNCLEAN\n' not in log2, log2
    assert 'poweroff: stopping processes' in log2, log2
except BaseException:
    for log in sorted(work.glob('*.log')):
        print(log.read_text(errors='replace')[-12000:])
    print(f'PostgreSQL test failed; guest disk and logs retained at {work}', file=sys.stderr)
    raise
else:
    print('PostgreSQL: PASS (mpkg install; UID/GID 70; PL/pgSQL; 1000 committed rows survive reboot; active transaction rolled back; clean reboot/poweroff)')
    shutil.rmtree(work)
