# Muslin Linux: run inside the builder container (./muslin build), or natively
# on any musl host. Override CC / KERNEL_IMAGE / BUSYBOX_BIN to swap parts.
KERNEL_VERSION  ?= 6.12.48
BUSYBOX_VERSION ?= 1.37.0
JOBS            ?= $(shell nproc)
CC              ?= cc
SOURCE_DATE_EPOCH ?= 1727395200
BOOT_BUDGET_MS    ?= 500
INIT_IMPL         ?= c

B     := build
DL    := $(B)/dl
OUT   := out
KSRC  := $(B)/linux-$(KERNEL_VERSION)
BBSRC := $(B)/busybox-$(BUSYBOX_VERSION)

KERNEL_IMAGE ?= $(OUT)/bzImage
BUSYBOX_BIN  ?= $(BBSRC)/busybox
INIT_C_BIN   := $(OUT)/init-c
INIT_RS_BIN  := $(OUT)/init-rs
TOOLS_BIN    := $(OUT)/muslin-tools
GO_BIN       := $(OUT)/muslin-go
MPKG_BIN     := $(OUT)/mpkg
INIT_BIN     := $(OUT)/init-$(INIT_IMPL)
INITRAMFS    := $(OUT)/initramfs-$(INIT_IMPL).cpio.gz
ROOTFS_IMAGE := $(OUT)/base-$(INIT_IMPL).ext4
RUNTIME_DISK := state/rootfs-$(INIT_IMPL).ext4
ROOTFS_SIZE_MB ?= 32
HELLO_PACKAGE := $(OUT)/hello-1.0.0.mpkg

POSTGRES_VERSION := 18.6
POSTGRES_SHA256 := 555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f
POSTGRES_ARCHIVE := $(DL)/postgresql-$(POSTGRES_VERSION).tar.bz2
POSTGRES_PACKAGE := $(OUT)/postgresql-$(POSTGRES_VERSION).mpkg
POSTGRES_KERNEL := $(OUT)/bzImage-postgres
POSTGRES_KSRC := $(B)/linux-$(KERNEL_VERSION)-postgres
POSTGRES_BASE := $(OUT)/postgres-$(INIT_IMPL).ext4
POSTGRES_RUNTIME := state/postgres-$(INIT_IMPL).ext4
POSTGRES_KERNEL_SIZE_MAX := 2097152
POSTGRES_DISK_SIZE_MB := 256

KERNEL_SIZE_MAX    ?= 1835008
INITRAMFS_SIZE_MAX ?= 1048576
ROOTFS_SIZE_MAX    ?= 33554432

KERNEL_URL  := https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VERSION).tar.xz
BUSYBOX_URL := https://busybox.net/downloads/busybox-$(BUSYBOX_VERSION).tar.bz2
KERNEL_SIG_URL  := https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VERSION).tar.sign
BUSYBOX_SIG_URL := $(BUSYBOX_URL).sig

KERNEL_SHA256  := 5bf9eb676751bf48978e38363c772298b41a75336d5038ed6d37012399471db2
BUSYBOX_SHA256 := 3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
KERNEL_SIGNER  := 647F28654894E3BD457199BE38DBBDC86092693E
BUSYBOX_SIGNER := C9E9416F76E610DBD09D040F47B70C55ACC9965B

export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP := @$(SOURCE_DATE_EPOCH)
export KBUILD_BUILD_USER := muslin
export KBUILD_BUILD_HOST := muslin
export KBUILD_BUILD_VERSION := 1
.DELETE_ON_ERROR:

.PHONY: all verify-sources kernel busybox init init-c init-rs tools go-tool initramfs rootfs-image package \
        run runtime-disk preserve-state test test-c test-rs test-all test-network test-persistence test-package test-s5 test-mpkg boot-budget profile size reproducible clean distclean
all: kernel initramfs rootfs-image package size

.PHONY: postgres postgres-package postgres-kernel run-postgres test-postgres test-postgres-all postgres-size
postgres: postgres-kernel $(POSTGRES_BASE) postgres-size
postgres-package: $(POSTGRES_PACKAGE) $(POSTGRES_PACKAGE).sha256
postgres-kernel: $(POSTGRES_KERNEL)

$(POSTGRES_ARCHIVE):
	$(call download,https://ftp.postgresql.org/pub/source/v$(POSTGRES_VERSION)/postgresql-$(POSTGRES_VERSION).tar.bz2)

# Verification happens on every recipe invocation, before extraction/build.
$(POSTGRES_PACKAGE) $(POSTGRES_PACKAGE).sha256 &: $(POSTGRES_ARCHIVE) Makefile scripts/build-postgres.sh scripts/mkpackage.sh src/postgres-user/main.c $(shell find packages/postgresql/root)
	@mkdir -p $(OUT)
	JOBS=$(JOBS) scripts/build-postgres.sh $(POSTGRES_ARCHIVE) $(POSTGRES_SHA256) $(POSTGRES_VERSION) $(B)/postgres $(POSTGRES_PACKAGE)

# A separate source/build tree keeps the tiny base kernel untouched.
$(POSTGRES_KSRC)/Makefile: $(DL)/linux-$(KERNEL_VERSION).verified
	@mkdir -p $(POSTGRES_KSRC)
	tar -xf $(DL)/linux-$(KERNEL_VERSION).tar.xz -C $(POSTGRES_KSRC) --strip-components=1
	@touch $@

$(POSTGRES_KSRC)/.config: $(POSTGRES_KSRC)/Makefile config/kernel.fragment config/postgres-kernel.fragment
	$(MAKE) -C $(POSTGRES_KSRC) tinyconfig
	cd $(POSTGRES_KSRC) && ./scripts/kconfig/merge_config.sh -m .config $(CURDIR)/config/kernel.fragment $(CURDIR)/config/postgres-kernel.fragment
	$(MAKE) -C $(POSTGRES_KSRC) olddefconfig
	cd $(POSTGRES_KSRC) && ./scripts/kconfig/merge_config.sh -m .config $(CURDIR)/config/kernel.fragment $(CURDIR)/config/postgres-kernel.fragment
	$(MAKE) -C $(POSTGRES_KSRC) olddefconfig

$(POSTGRES_KERNEL): $(POSTGRES_KSRC)/.config
	@mkdir -p $(OUT)
	$(MAKE) -C $(POSTGRES_KSRC) -j$(JOBS) bzImage
	cp $(POSTGRES_KSRC)/arch/x86/boot/bzImage $@

$(POSTGRES_BASE): $(INITRAMFS) $(MPKG_BIN) $(POSTGRES_PACKAGE) $(POSTGRES_PACKAGE).sha256 scripts/mkrootfs.sh scripts/normalize-ext4.py
	@set -eu; overlay=$$(mktemp -d); trap 'rm -rf "$$overlay"' EXIT; \
		mkdir -p "$$overlay/var/lib/muslin"; \
		cp $(POSTGRES_PACKAGE) "$$overlay/var/lib/muslin/postgresql.mpkg"; \
		cp $(POSTGRES_PACKAGE).sha256 "$$overlay/var/lib/muslin/postgresql.mpkg.sha256"; \
		scripts/mkrootfs.sh $(INITRAMFS) $(MPKG_BIN) $@ $(POSTGRES_DISK_SIZE_MB) "$$overlay"

postgres-size: $(POSTGRES_KERNEL) $(POSTGRES_BASE)
	@test $$(stat -c %s $(POSTGRES_KERNEL)) -lt $(POSTGRES_KERNEL_SIZE_MAX)
	@test $$(stat -c %s $(POSTGRES_BASE)) -le $$(( $(POSTGRES_DISK_SIZE_MB) * 1048576 ))
	@echo 'PostgreSQL profile size budgets: PASS'

run-postgres: postgres
	@scripts/prepare-runtime.sh $(POSTGRES_BASE) $(POSTGRES_RUNTIME)
	DISK_IMAGE=$(POSTGRES_RUNTIME) MEM=256M APPEND_EXTRA="muslin.root=/dev/vda muslin.postgres" \
		scripts/run-qemu.sh $(POSTGRES_KERNEL) $(INITRAMFS)

test-postgres: postgres
	python3 scripts/postgres-selftest.py $(POSTGRES_KERNEL) $(INITRAMFS) $(POSTGRES_BASE)

test-postgres-all:
	$(MAKE) test-postgres INIT_IMPL=c
	$(MAKE) test-postgres INIT_IMPL=rs

# ── fetch ───────────────────────────────────────────────────────────────
define download
	@mkdir -p $(DL)
	curl -fL --retry 3 -o $@.part $(1)
	mv $@.part $@
endef

$(DL)/linux-$(KERNEL_VERSION).tar.xz:
	$(call download,$(KERNEL_URL))

$(DL)/linux-$(KERNEL_VERSION).tar.sign:
	$(call download,$(KERNEL_SIG_URL))

$(DL)/busybox-$(BUSYBOX_VERSION).tar.bz2:
	$(call download,$(BUSYBOX_URL))

$(DL)/busybox-$(BUSYBOX_VERSION).tar.bz2.sig:
	$(call download,$(BUSYBOX_SIG_URL))

$(DL)/linux-$(KERNEL_VERSION).verified: $(DL)/linux-$(KERNEL_VERSION).tar.xz $(DL)/linux-$(KERNEL_VERSION).tar.sign scripts/verify-source.sh
	scripts/verify-source.sh kernel $< $(word 2,$^) $(KERNEL_SHA256) $(KERNEL_SIGNER)
	@touch $@

$(DL)/busybox-$(BUSYBOX_VERSION).verified: $(DL)/busybox-$(BUSYBOX_VERSION).tar.bz2 $(DL)/busybox-$(BUSYBOX_VERSION).tar.bz2.sig scripts/verify-source.sh
	scripts/verify-source.sh busybox $< $(word 2,$^) $(BUSYBOX_SHA256) $(BUSYBOX_SIGNER)
	@touch $@

verify-sources: $(DL)/linux-$(KERNEL_VERSION).tar.xz $(DL)/linux-$(KERNEL_VERSION).tar.sign \
                $(DL)/busybox-$(BUSYBOX_VERSION).tar.bz2 $(DL)/busybox-$(BUSYBOX_VERSION).tar.bz2.sig
	scripts/verify-source.sh kernel $(word 1,$^) $(word 2,$^) $(KERNEL_SHA256) $(KERNEL_SIGNER)
	scripts/verify-source.sh busybox $(word 3,$^) $(word 4,$^) $(BUSYBOX_SHA256) $(BUSYBOX_SIGNER)

# ── kernel: tinyconfig + fragment ───────────────────────────────────────
kernel: $(KERNEL_IMAGE)

$(KSRC)/Makefile: $(DL)/linux-$(KERNEL_VERSION).verified
	tar -xf $(DL)/linux-$(KERNEL_VERSION).tar.xz -C $(B) && touch $@

$(KSRC)/.config: $(KSRC)/Makefile config/kernel.fragment Makefile
	$(MAKE) -C $(KSRC) tinyconfig
	cd $(KSRC) && ./scripts/kconfig/merge_config.sh -m .config $(CURDIR)/config/kernel.fragment
	$(MAKE) -C $(KSRC) olddefconfig
	# A second pass applies settings whose menus only become visible after the
	# first pass enables their parent subsystem (notably networking).
	cd $(KSRC) && ./scripts/kconfig/merge_config.sh -m .config $(CURDIR)/config/kernel.fragment
	$(MAKE) -C $(KSRC) olddefconfig

$(OUT)/bzImage: $(KSRC)/.config
	@mkdir -p $(OUT)
	$(MAKE) -C $(KSRC) -j$(JOBS) bzImage
	cp $(KSRC)/arch/x86/boot/bzImage $@

# ── busybox: static, musl ───────────────────────────────────────────────
busybox: $(BUSYBOX_BIN)

$(BBSRC)/Makefile: $(DL)/busybox-$(BUSYBOX_VERSION).verified
	tar -xf $(DL)/busybox-$(BUSYBOX_VERSION).tar.bz2 -C $(B) && touch $@

$(BBSRC)/.config: $(BBSRC)/Makefile config/busybox.fragment scripts/merge-busybox-config.sh
	$(MAKE) -C $(BBSRC) allnoconfig
	scripts/merge-busybox-config.sh $@ config/busybox.fragment
	yes '' | $(MAKE) -C $(BBSRC) oldconfig

$(BBSRC)/busybox: $(BBSRC)/.config
	$(MAKE) -C $(BBSRC) -j$(JOBS) CC="$(CC)"

# ── init: our PID 1 ─────────────────────────────────────────────────────
init: $(INIT_BIN)
init-c: $(INIT_C_BIN)
init-rs: $(INIT_RS_BIN)
tools: $(TOOLS_BIN)
go-tool: $(GO_BIN)

$(INIT_C_BIN): src/init/init.c
	@mkdir -p $(OUT)
	$(CC) -static -Os -Wall -Wextra -Werror -o $@ $<
	strip $@

$(INIT_RS_BIN): src/init-rs/main.rs
	@mkdir -p $(OUT)
	rustc --target x86_64-unknown-linux-musl --edition 2021 \
		-C opt-level=z -C panic=abort -C lto=fat -C codegen-units=1 -C relocation-model=static \
		-C strip=symbols -o $@ $<

$(TOOLS_BIN): src/tools/main.rs
	@mkdir -p $(OUT)
	rustc --target x86_64-unknown-linux-musl --edition 2021 \
		-C opt-level=z -C panic=abort -C lto=fat -C codegen-units=1 -C relocation-model=static \
		-C strip=symbols -o $@ $<

$(MPKG_BIN): src/mpkg/main.rs
	@mkdir -p $(OUT)
	rustc --target x86_64-unknown-linux-musl --edition 2021 \
		-C opt-level=z -C panic=abort -C lto=fat -C codegen-units=1 -C relocation-model=static \
		-C strip=symbols -o $@ $<

test-mpkg:
	@mkdir -p $(OUT)
	rustc --edition 2021 --test src/mpkg/main.rs -o $(OUT)/mpkg-tests
	$(OUT)/mpkg-tests

$(GO_BIN): src/go-proof/main.go
	@mkdir -p $(OUT)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
		-ldflags='-s -w -buildid=' -o $@ $<

# ── initramfs ───────────────────────────────────────────────────────────
initramfs: $(INITRAMFS)
rootfs-image: $(ROOTFS_IMAGE)
package: $(HELLO_PACKAGE) $(HELLO_PACKAGE).sha256

$(INITRAMFS): $(BUSYBOX_BIN) $(INIT_BIN) $(TOOLS_BIN) $(GO_BIN) scripts/mkinitramfs.sh $(shell find rootfs)
	scripts/mkinitramfs.sh $(B)/rootfs-$(INIT_IMPL) $(BUSYBOX_BIN) $(INIT_BIN) $(TOOLS_BIN) $(GO_BIN) rootfs $@

$(ROOTFS_IMAGE): $(INITRAMFS) $(MPKG_BIN) scripts/mkrootfs.sh scripts/normalize-ext4.py
	scripts/mkrootfs.sh $(INITRAMFS) $(MPKG_BIN) $@ $(ROOTFS_SIZE_MB)

$(HELLO_PACKAGE) $(HELLO_PACKAGE).sha256 &: $(shell find packages/hello/root) scripts/mkpackage.sh
	@mkdir -p $(OUT)
	scripts/mkpackage.sh hello 1.0.0 packages/hello/root $(HELLO_PACKAGE)

# ── run / test ──────────────────────────────────────────────────────────
preserve-state:
	@scripts/preserve-state.sh $(OUT)

runtime-disk: preserve-state $(ROOTFS_IMAGE)
	@scripts/prepare-runtime.sh $(ROOTFS_IMAGE) $(RUNTIME_DISK)

run: $(KERNEL_IMAGE) $(INITRAMFS) runtime-disk
	DISK_IMAGE=$(RUNTIME_DISK) APPEND_EXTRA="muslin.root=/dev/vda $(APPEND_EXTRA)" \
		scripts/run-qemu.sh $(KERNEL_IMAGE) $(INITRAMFS)

test: $(KERNEL_IMAGE) $(INITRAMFS)
	scripts/selftest.sh $(KERNEL_IMAGE) $(INITRAMFS)

test-c:
	$(MAKE) test INIT_IMPL=c

test-rs:
	$(MAKE) test INIT_IMPL=rs

test-all:
	$(MAKE) test INIT_IMPL=c
	$(MAKE) test INIT_IMPL=rs

test-network: $(KERNEL_IMAGE) $(INITRAMFS)
	scripts/network-selftest.sh $(KERNEL_IMAGE) $(INITRAMFS)

test-persistence: $(KERNEL_IMAGE) $(INITRAMFS) $(ROOTFS_IMAGE)
	scripts/persistence-selftest.sh $(KERNEL_IMAGE) $(INITRAMFS) $(ROOTFS_IMAGE)

test-package: $(KERNEL_IMAGE) $(INITRAMFS) $(ROOTFS_IMAGE) package
	scripts/package-selftest.sh $(KERNEL_IMAGE) $(INITRAMFS) $(ROOTFS_IMAGE) $(HELLO_PACKAGE)

# Keep recursive builds sequential: the shared kernel/BusyBox build trees are
# not independent jobs. Each initramfs and base disk has its own inputs.
test-s5: test-mpkg
	$(MAKE) kernel initramfs rootfs-image package INIT_IMPL=c
	$(MAKE) initramfs rootfs-image INIT_IMPL=rs
	python3 scripts/build-selftest.py $(OUT)
	$(MAKE) -j1 test test-network test-persistence test-package size INIT_IMPL=c
	python3 scripts/s5-selftest.py $(KERNEL_IMAGE) $(OUT)/initramfs-c.cpio.gz $(OUT)/base-c.ext4
	$(MAKE) -j1 test test-network test-persistence test-package INIT_IMPL=rs
	python3 scripts/s5-selftest.py $(KERNEL_IMAGE) $(OUT)/initramfs-rs.cpio.gz $(OUT)/base-rs.ext4

boot-budget: $(KERNEL_IMAGE) $(INITRAMFS)
	REQUIRE_KVM=1 BOOT_BUDGET_MS=$(BOOT_BUDGET_MS) scripts/selftest.sh $(KERNEL_IMAGE) $(INITRAMFS)

profile: $(KERNEL_IMAGE) $(INITRAMFS)
	scripts/profile-boot.sh $(KERNEL_IMAGE) $(INITRAMFS)

size: $(KERNEL_IMAGE) $(INITRAMFS) $(ROOTFS_IMAGE)
	@echo "── artifacts ──"; ls -lh $(OUT) 2>/dev/null | awk 'NR>1{print "  "$$5"\t"$$9}'
	@file $(INIT_BIN) 2>/dev/null | sed 's/^/  /' || true
	@set -eu; \
		kernel_size=$$(stat -c %s $(KERNEL_IMAGE)); \
		initramfs_size=$$(stat -c %s $(INITRAMFS)); \
		rootfs_size=$$(stat -c %s $(ROOTFS_IMAGE)); \
		test $$kernel_size -lt $(KERNEL_SIZE_MAX) || { \
			echo "kernel size budget exceeded: $$kernel_size >= $(KERNEL_SIZE_MAX) bytes"; exit 1; \
		}; \
		test $$initramfs_size -lt $(INITRAMFS_SIZE_MAX) || { \
			echo "initramfs size budget exceeded: $$initramfs_size >= $(INITRAMFS_SIZE_MAX) bytes"; exit 1; \
		}; \
		test $$rootfs_size -le $(ROOTFS_SIZE_MAX) || { \
			echo "rootfs size budget exceeded: $$rootfs_size > $(ROOTFS_SIZE_MAX) bytes"; exit 1; \
		}; \
		echo "  size budgets: PASS"

reproducible:
	@set -eu; hashes=$$(mktemp); trap 'rm -f "$$hashes"' EXIT; \
		$(MAKE) clean >/dev/null; $(MAKE) all >/dev/null; \
		sha256sum $(KERNEL_IMAGE) $(INIT_BIN) $(TOOLS_BIN) $(GO_BIN) $(INITRAMFS) $(ROOTFS_IMAGE) $(HELLO_PACKAGE) > "$$hashes"; \
		$(MAKE) clean >/dev/null; $(MAKE) all >/dev/null; \
		sha256sum -c "$$hashes"; \
		echo "reproducible build: PASS"

clean: preserve-state
	rm -rf $(OUT) $(B)/rootfs $(B)/rootfs-c $(B)/rootfs-rs
	-$(MAKE) -C $(BBSRC) clean 2>/dev/null
	-$(MAKE) -C $(KSRC) clean 2>/dev/null

distclean: preserve-state
	rm -rf $(OUT) $(B)
