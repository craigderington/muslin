#!/bin/sh
# Build a deliberately small musl PostgreSQL package from verified upstream source.
set -eu
ARCHIVE=$(realpath "${1:?archive}")
HASH=${2:?sha256}
VERSION=${3:?version}
WORK=${4:?build directory}
OUT=$(realpath -m "${5:?package output}")
REPO=$PWD
printf '%s  %s\n' "$HASH" "$ARCHIVE" | sha256sum -c -
mkdir -p "$WORK"
WORK=$(realpath "$WORK")
# Keep versioned source and compiler objects separate from the package staging tree.
if [ ! -f "$WORK/source-$VERSION/configure" ]; then
    mkdir -p "$WORK/source-$VERSION"
    tar -xf "$ARCHIVE" -C "$WORK/source-$VERSION" --strip-components=1
fi
mkdir -p "$WORK/build-$VERSION"
cd "$WORK/build-$VERSION"
"$WORK/source-$VERSION/configure" --prefix=/usr/pgsql \
    --disable-nls --without-icu --without-readline --without-zlib \
    --without-lz4 --without-zstd --without-libxml --without-libxslt \
    --without-openssl --without-systemd --without-liburing --disable-rpath \
    CFLAGS="-Os -ffile-prefix-map=$WORK=/build/postgresql" LDFLAGS='-Wl,--build-id=none'
env MAKELEVEL=0 make -j"${JOBS:-2}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM
env MAKELEVEL=0 make DESTDIR="$STAGE/install" install-strip
ROOT=$STAGE/root
mkdir -p "$ROOT/usr/pgsql/bin" "$ROOT/usr/pgsql/lib" "$ROOT/usr/bin"
for bin in postgres initdb pg_ctl psql pg_isready pg_controldata; do
    cp "$STAGE/install/usr/pgsql/bin/$bin" "$ROOT/usr/pgsql/bin/"
done
cp -L "$STAGE/install/usr/pgsql/lib/libpq.so.5" "$ROOT/usr/pgsql/lib/libpq.so.5"
for lib in plpgsql.so dict_snowball.so; do
    cp "$STAGE/install/usr/pgsql/lib/$lib" "$ROOT/usr/pgsql/lib/"
done
cp -a "$STAGE/install/usr/pgsql/share" "$ROOT/usr/pgsql/"
cp "$WORK/source-$VERSION/COPYRIGHT" "$ROOT/usr/pgsql/share/COPYRIGHT"
cc -static -Os -Wall -Wextra -Werror -o "$ROOT/usr/bin/postgres-user" "$REPO/src/postgres-user/main.c"
strip "$ROOT/usr/bin/postgres-user"
cp -a "$REPO/packages/postgresql/root"/. "$ROOT"/
# Fail rather than silently ship a library dependency that the guest lacks.
for bin in "$ROOT"/usr/pgsql/bin/* "$ROOT"/usr/pgsql/lib/*; do
    readelf -d "$bin" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' |
        while read -r lib; do
            case "$lib" in libc.musl-x86_64.so.1|libpq.so.5) ;;
                *) echo "unexpected PostgreSQL runtime dependency: $lib ($bin)" >&2; exit 1;;
            esac
        done
done
cd "$REPO"
scripts/mkpackage.sh postgresql "$VERSION" "$ROOT" "$OUT"
echo "PostgreSQL payload bytes: $(du -sb "$ROOT" | cut -f1)"
