#!/bin/sh
# mkpackage.sh NAME VERSION ROOT OUT
set -eu

NAME=${1:?name}
VERSION=${2:?version}
ROOT=${3:?root}
OUT=${4:?output}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/root"
cp -a "$ROOT"/. "$WORK/root"/
find "$WORK/root" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-0}" {} +
python3 - "$NAME" "$VERSION" "$WORK/root" >"$WORK/files" <<'PY'
import pathlib, re, sys
name, version, source = sys.argv[1:]
if not all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,63}', v) for v in (name, version)):
    raise SystemExit('invalid package name/version')
root = pathlib.Path(source)
for path in sorted(root.rglob('*')):
    relative = path.relative_to(root).as_posix()
    if (path.is_symlink() or not (path.is_file() or path.is_dir())
            or path.stat().st_mode & 0o7000
            or not relative.isascii() or any(not 33 <= ord(c) <= 126 or c == '\\' for c in relative)
            or relative.split('/')[0] not in ('usr', 'opt', 'etc', 'var', 'bin', 'sbin', 'lib')
            or relative == 'var/lib/mpkg' or relative.startswith('var/lib/mpkg/')):
        raise SystemExit(f'unsupported package entry: {relative}')
    if path.is_file():
        print('/' + relative)
PY
{
  echo "name=$NAME"
  echo "version=$VERSION"
} >"$WORK/manifest"
touch -d "@${SOURCE_DATE_EPOCH:-0}" "$WORK/manifest" "$WORK/files"

tar --format=ustar --hard-dereference --sort=name --mtime="@${SOURCE_DATE_EPOCH:-0}" --owner=0 --group=0 \
    --numeric-owner -cf "$WORK/package.tar" -C "$WORK" manifest files root
zstd -q -19 -T1 -f "$WORK/package.tar" -o "$OUT"
sha256sum "$OUT" | sed 's|  .*/|  |' >"$OUT.sha256"
echo "package: $OUT"
