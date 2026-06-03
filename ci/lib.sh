#!/bin/sh -efu
# SPDX-License-Identifier: GPL-2.0-or-later
# shellcheck enable=all disable=SC2250,SC3043

: "${ARCH:?}"

PROG="${PROG:-${0##*/}}"

CI_TOP="$(realpath -m -- "${0%/*}")"
export CI_TOP

STRACE_SRC="${STRACE_SRC:-$PWD/strace}"
STRACE_SRC="$(realpath -m -- "$STRACE_SRC")"

BUILDROOT_SRC="${BUILDROOT_SRC:-$PWD/buildroot}"
BUILDROOT_SRC="$(realpath -m -- "$BUILDROOT_SRC")"

OUTPUT_BASE="${OUTPUT_BASE:-$HOME/.cache/strace-cross}/$ARCH"
OUTPUT_BASE="$(realpath -m -- "$OUTPUT_BASE")"

STRACE_BUILD="$STRACE_SRC/build-$ARCH"

read -r BR_VERSION < "$CI_TOP/buildroot-version"

fatal() {
	echo >&2 "$*"
	exit 1
}

unknown_arch() {
	fatal "$PROG: unknown architecture: $ARCH"
}

# Per-arch QEMU/guest settings, resolved once from $ARCH:
#   QEMU_MACHINE  -M value (empty = QEMU default machine)
#   QEMU_BIN      emulator binary name under host/bin
#   QEMU_MEM      -m value
#   QEMU_SMP      vCPU count (env override honored); guest runs make check -j with it
#   KERNEL_IMAGE  kernel image relative to the buildroot output dir
#   NINEP_DEVICE  virtio-9p -device model
#   NINEP_BUS     PCI bus to attach the 9p devices to (empty = QEMU default bus)
#   CONSOLE       serial console tty for the kernel cmdline
QEMU_MACHINE=
NINEP_BUS=
case "$ARCH" in
m68k)
	QEMU_MACHINE=virt
	QEMU_BIN=qemu-system-m68k
	QEMU_MEM=3399672K
	QEMU_SMP=1
	KERNEL_IMAGE=images/vmlinux
	NINEP_DEVICE=virtio-9p-device
	CONSOLE=ttyGF0
	;;
s390x)
	QEMU_BIN=qemu-system-s390x
	QEMU_MEM=4G
	QEMU_SMP="${QEMU_SMP:-1}"
	KERNEL_IMAGE=images/bzImage
	NINEP_DEVICE=virtio-9p-ccw
	CONSOLE=ttysclp0
	;;
sparc64)
	QEMU_MACHINE=sun4u
	QEMU_BIN=qemu-system-sparc64
	QEMU_MEM=2G
	QEMU_SMP=1
	KERNEL_IMAGE=images/vmlinux
	NINEP_DEVICE=virtio-9p-pci
	NINEP_BUS=pciB
	CONSOLE=ttyS0
	;;
mips64el)
	QEMU_MACHINE=malta
	QEMU_BIN=qemu-system-mips64el
	QEMU_MEM=2G
	QEMU_SMP=1
	KERNEL_IMAGE=images/vmlinux
	NINEP_DEVICE=virtio-9p-pci
	CONSOLE=ttyS0
	;;
*)
	unknown_arch
	;;
esac

# virtio-blk device model mirrors the per-arch 9p transport (device/ccw/pci).
BLK_DEVICE="virtio-blk-${NINEP_DEVICE##*-}"

# The strace build tree is served to the guest on an ext2 image over virtio-blk
# (a real local filesystem, far cheaper per-op than the 9p protocol), mounted
# over the build dir; the source tree still comes via the 9p share.
STRACE_IMAGE="$OUTPUT_BASE/strace-build.ext2"

export BR_VERSION QEMU_MACHINE QEMU_BIN QEMU_MEM QEMU_SMP \
	KERNEL_IMAGE NINEP_DEVICE NINEP_BUS BLK_DEVICE CONSOLE STRACE_IMAGE \
	STRACE_SRC BUILDROOT_SRC OUTPUT_BASE STRACE_BUILD

config_version() {
	_cv_cfg="$CI_TOP/buildroot-config-$1"
	if [ ! -f "$_cv_cfg" ]; then
		fatal "no config for architecture: $1"
	fi
	_cv_ver=$(sed -n 's/^# *CONFIG_VERSION: *//p' "$_cv_cfg" | head -n1)
	if [ -z "$_cv_ver" ]; then
		fatal "no CONFIG_VERSION in $_cv_cfg"
	fi
	printf '%s\n' "$_cv_ver"
}

cache_key() {
	local _ck_ver
	_ck_ver=$(config_version "$1")
	printf '%s-%s-cfg%s\n' "$BR_VERSION" "$1" "$_ck_ver"
}

strace_test_dirs() {
	# shellcheck disable=SC2016  # $(SUBDIRS) is Make syntax, not shell
	make -C "$STRACE_BUILD" --no-print-directory \
		--eval='_strace_subdirs:;@printf "%s\n" $(SUBDIRS)' \
		_strace_subdirs 2>/dev/null | tr ' ' '\n' | sed -n '/^tests/p'
}
