# Alpine is musl-native: plain `cc` produces musl binaries, no cross toolchain.
FROM alpine:3.20
RUN apk add --no-cache \
      build-base linux-headers bc bison flex perl elfutils-dev openssl-dev \
      xz bzip2 gzip cpio tar curl diffutils findutils coreutils file \
      ncurses-dev gnupg qemu-system-x86_64 rustup go e2fsprogs e2fsprogs-extra zstd python3
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
ENV PATH=/opt/cargo/bin:$PATH
RUN rustup-init -y --profile minimal --default-toolchain 1.78.0 \
      --default-host x86_64-unknown-linux-musl
ENV HOME=/tmp
WORKDIR /muslin
