# Alpine is musl-native: plain `cc` produces musl binaries, no cross toolchain.
FROM alpine:3.20
RUN apk add --no-cache \
      build-base linux-headers bc bison flex perl elfutils-dev openssl-dev \
      xz bzip2 gzip cpio curl diffutils findutils coreutils file \
      ncurses-dev qemu-system-x86_64
ENV HOME=/tmp
WORKDIR /muslin
