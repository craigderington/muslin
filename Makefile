# Muslin Linux: run inside the builder container (./muslin build), or natively
# on any musl host. Override CC / KERNEL_IMAGE / BUSYBOX_BIN to swap parts.
KERNEL_VERSION  ?= 6.12.48
BUSYBOX_VERSION ?= 1.37.0
JOBS            ?= $(shell nproc)
CC              ?= cc
SOURCE_DATE_EPOCH ?= 1727395200
BOOT_BUDGET_MS    ?= 500

B     := build
DL    := $(B)/dl
OUT   := out
KSRC  := $(B)/linux-$(KERNEL_VERSION)
BBSRC := $(B)/busybox-$(BUSYBOX_VERSION)

KERNEL_IMAGE ?= $(OUT)/bzImage
BUSYBOX_BIN  ?= $(BBSRC)/busybox
INIT_BIN     := $(OUT)/init
INITRAMFS    := $(OUT)/initramfs.cpio.gz

KERNEL_SIZE_MAX    ?= 1572864
INITRAMFS_SIZE_MAX ?= 1048576

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

.PHONY: all verify-sources kernel busybox init initramfs run test boot-budget profile size reproducible clean distclean
all: kernel initramfs size

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

$(KSRC)/.config: $(KSRC)/Makefile config/kernel.fragment
	$(MAKE) -C $(KSRC) tinyconfig
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

$(BBSRC)/.config: $(BBSRC)/Makefile
	$(MAKE) -C $(BBSRC) defconfig
	sed -i -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
	       -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
	       -e 's/^CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/' \
	       -e 's/^CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' $@

$(BBSRC)/busybox: $(BBSRC)/.config
	$(MAKE) -C $(BBSRC) -j$(JOBS) CC="$(CC)"

# ── init: our PID 1 ─────────────────────────────────────────────────────
init: $(INIT_BIN)

$(INIT_BIN): src/init/init.c
	@mkdir -p $(OUT)
	$(CC) -static -Os -Wall -Wextra -Werror -o $@ $<
	strip $@

# ── initramfs ───────────────────────────────────────────────────────────
initramfs: $(INITRAMFS)

$(INITRAMFS): $(BUSYBOX_BIN) $(INIT_BIN) scripts/mkinitramfs.sh $(shell find rootfs -type f)
	scripts/mkinitramfs.sh $(B)/rootfs $(BUSYBOX_BIN) $(INIT_BIN) rootfs $@

# ── run / test ──────────────────────────────────────────────────────────
run: $(KERNEL_IMAGE) $(INITRAMFS)
	scripts/run-qemu.sh $(KERNEL_IMAGE) $(INITRAMFS)

test: $(KERNEL_IMAGE) $(INITRAMFS)
	scripts/selftest.sh $(KERNEL_IMAGE) $(INITRAMFS)

boot-budget: $(KERNEL_IMAGE) $(INITRAMFS)
	REQUIRE_KVM=1 BOOT_BUDGET_MS=$(BOOT_BUDGET_MS) scripts/selftest.sh $(KERNEL_IMAGE) $(INITRAMFS)

profile: $(KERNEL_IMAGE) $(INITRAMFS)
	scripts/profile-boot.sh $(KERNEL_IMAGE) $(INITRAMFS)

size: $(KERNEL_IMAGE) $(INITRAMFS)
	@echo "── artifacts ──"; ls -lh $(OUT) 2>/dev/null | awk 'NR>1{print "  "$$5"\t"$$9}'
	@file $(INIT_BIN) 2>/dev/null | sed 's/^/  /' || true
	@set -eu; \
		kernel_size=$$(stat -c %s $(KERNEL_IMAGE)); \
		initramfs_size=$$(stat -c %s $(INITRAMFS)); \
		test $$kernel_size -lt $(KERNEL_SIZE_MAX) || { \
			echo "kernel size budget exceeded: $$kernel_size >= $(KERNEL_SIZE_MAX) bytes"; exit 1; \
		}; \
		test $$initramfs_size -lt $(INITRAMFS_SIZE_MAX) || { \
			echo "initramfs size budget exceeded: $$initramfs_size >= $(INITRAMFS_SIZE_MAX) bytes"; exit 1; \
		}; \
		echo "  size budgets: PASS"

reproducible:
	@set -eu; hashes=$$(mktemp); trap 'rm -f "$$hashes"' EXIT; \
		$(MAKE) clean >/dev/null; $(MAKE) all >/dev/null; \
		sha256sum $(KERNEL_IMAGE) $(INIT_BIN) $(INITRAMFS) > "$$hashes"; \
		$(MAKE) clean >/dev/null; $(MAKE) all >/dev/null; \
		sha256sum -c "$$hashes"; \
		echo "reproducible build: PASS"

clean:
	rm -rf $(OUT) $(B)/rootfs
	-$(MAKE) -C $(BBSRC) clean 2>/dev/null
	-$(MAKE) -C $(KSRC) clean 2>/dev/null

distclean:
	rm -rf $(OUT) $(B)
