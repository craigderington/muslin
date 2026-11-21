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
HELPER_CC=${CC:-cc}
CC=$HELPER_CC
STRIP=${STRIP:-strip}
LDFLAGS=-Wl,--build-id=none
export CC STRIP
set --
if [ "${GUEST_ARCH:-x86_64}" = aarch64 ]; then
    CC="clang --target=aarch64-alpine-linux-musl --sysroot=$GUEST_SYSROOT --gcc-toolchain=$GUEST_SYSROOT/usr"
    LDFLAGS="$LDFLAGS -fuse-ld=lld"
    # The configure probe skips runtime linker checks when cross-compiling.
    set -- --build=x86_64-linux-musl --host=aarch64-linux-musl \
        --with-system-tzdata=/usr/share/zoneinfo LDFLAGS_EX_BE=-Wl,--export-dynamic
fi
"$WORK/source-$VERSION/configure" "$@" --prefix=/usr/pgsql \
    --disable-nls --without-icu --without-readline --without-zlib \
    --without-lz4 --without-zstd --without-libxml --without-libxslt \
    --without-openssl --without-systemd --without-liburing --disable-rpath \
    CFLAGS="-Os -ffile-prefix-map=$WORK=/build/postgresql" LDFLAGS="$LDFLAGS"
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
"$HELPER_CC" -static -Os -Wall -Wextra -Werror -o "$ROOT/usr/bin/postgres-user" "$REPO/src/postgres-user/main.c"
"$STRIP" "$ROOT/usr/bin/postgres-user"
if [ "${GUEST_ARCH:-x86_64}" = aarch64 ]; then
    mkdir -p "$ROOT/usr/share"
    cp -RL "$GUEST_SYSROOT/usr/share/zoneinfo" "$ROOT/usr/share/"
    readelf -l "$ROOT/usr/pgsql/bin/postgres" | grep -Fq 'interpreter: /lib/ld-musl-aarch64.so.1]'
fi
cp -a "$REPO/packages/postgresql/root"/. "$ROOT"/
# Fail rather than silently ship a library dependency that the guest lacks.
for bin in "$ROOT"/usr/pgsql/bin/* "$ROOT"/usr/pgsql/lib/*; do
    readelf -d "$bin" | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' |
        while read -r lib; do
            case "${GUEST_ARCH:-x86_64}:$lib" in
                *:libpq.so.5|x86_64:libc.musl-x86_64.so.1|aarch64:libc.musl-aarch64.so.1) ;;
                *) echo "unexpected PostgreSQL runtime dependency: $lib ($bin)" >&2; exit 1;;
            esac
        done
done
cd "$REPO"
scripts/mkpackage.sh postgresql "$VERSION" "$ROOT" "$OUT"
echo "PostgreSQL payload bytes: $(du -sb "$ROOT" | cut -f1)"
