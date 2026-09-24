# Muslin Linux: run inside the builder container (./muslin build), or natively
# on any musl host. Override CC / KERNEL_IMAGE / BUSYBOX_BIN to swap parts.
KERNEL_VERSION  ?= 6.12.48
BUSYBOX_VERSION ?= 1.37.0
JOBS            ?= $(shell nproc)
CC              ?= cc

B     := build
DL    := $(B)/dl
OUT   := out
KSRC  := $(B)/linux-$(KERNEL_VERSION)
BBSRC := $(B)/busybox-$(BUSYBOX_VERSION)

KERNEL_IMAGE ?= $(OUT)/bzImage
BUSYBOX_BIN  ?= $(BBSRC)/busybox
INIT_BIN     := $(OUT)/init
INITRAMFS    := $(OUT)/initramfs.cpio.gz

KERNEL_URL  := https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VERSION).tar.xz
BUSYBOX_URL := https://busybox.net/downloads/busybox-$(BUSYBOX_VERSION).tar.bz2

.PHONY: all kernel busybox init initramfs run test size clean distclean
all: kernel initramfs size

# ── fetch ───────────────────────────────────────────────────────────────
$(DL)/%:
	@mkdir -p $(DL)
	curl -fL --retry 3 -o $@.part $(if $(findstring linux,$*),$(KERNEL_URL),$(BUSYBOX_URL))
	mv $@.part $@

# ── kernel: tinyconfig + fragment ───────────────────────────────────────
kernel: $(KERNEL_IMAGE)

$(KSRC)/Makefile: $(DL)/linux-$(KERNEL_VERSION).tar.xz
	tar -xf $< -C $(B) && touch $@

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

$(BBSRC)/Makefile: $(DL)/busybox-$(BUSYBOX_VERSION).tar.bz2
	tar -xf $< -C $(B) && touch $@

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

size:
	@echo "── artifacts ──"; ls -lh $(OUT) 2>/dev/null | awk 'NR>1{print "  "$$5"\t"$$9}'
	@file $(INIT_BIN) 2>/dev/null | sed 's/^/  /' || true

clean:
	rm -rf $(OUT) $(B)/rootfs
	-$(MAKE) -C $(BBSRC) clean 2>/dev/null
	-$(MAKE) -C $(KSRC) clean 2>/dev/null

distclean:
	rm -rf $(OUT) $(B)
