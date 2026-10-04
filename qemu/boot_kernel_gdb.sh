#!/usr/bin/env bash
# ============================================================
# boot_kernel_gdb.sh -- boot the research kernel under QEMU.
#
# Usage:
#   ./boot_kernel_gdb.sh [version]                    # paused, waiting for GDB on :1234
#   ./boot_kernel_gdb.sh [version] --verify           # boot, run checks, power off
#   ./boot_kernel_gdb.sh [version] --serial           # boot straight to a serial shell
#   ./boot_kernel_gdb.sh [version] --conformant [...]  # boot the --conformant kernel
#
# GDB on the host:
#   gdb -ex 'target remote :1234' -ex 'break kbase_init' vmlinux
#
# Notes:
#   * The initramfs built by rootfs/build_rootfs.sh is attached with
#     initrd=, and it carries /mali_kbase.ko so the guest can insmod it.
#     It is optional: without it the kernel still boots.
#   * Without --serial the machine starts halted (-S) so a debugger can
#     attach before the first instruction. --verify and --serial omit -S.
#   * KVM is used when /dev/kvm is readable, otherwise QEMU falls back to
#     TCG, which is much slower but needs no privileges.
#   * nokaslr is deliberate: the research config disables
#     CONFIG_RANDOMIZE_BASE, and a fixed layout makes addresses reproducible
#     between runs.
# ============================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

V=""
MODE=gdb
CONFORMANT=0
for a in "$@"; do
    case "$a" in
        --verify) MODE=verify ;;
        --serial) MODE=serial ;;
        --conformant) CONFORMANT=1 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        [0-9]*.[0-9]*.[0-9]*) V="$a" ;;
        *) echo "[!] unknown argument: $a" >&2; exit 2 ;;
    esac
done
V="${V:-6.18.55}"

if [[ "$CONFORMANT" -eq 1 ]]; then
    # Booted kernel produced by: build_kernel.sh <ver> --conformant
    K="$ROOT/kernel/$V/artifacts-conformant/bzImage"
    # nokaslr MUST NOT be used here. Arm's Device Configuration Guidelines permit
    # only CONFIG_COMPAT, the ARM64 page-size choice, CONFIG_KASAN* and
    # CONFIG_UBSAN* to differ from the default kernel config, and the conformant
    # build leaves CONFIG_RANDOMIZE_BASE at its default (y). Disabling KASLR at
    # runtime would reintroduce exactly the deviation -- and the removed
    # hardening -- that --conformant exists to avoid.
    CMDLINE='console=ttyS0 panic=-1'
else
    K="$ROOT/kernel/$V/artifacts/bzImage"
    CMDLINE='console=ttyS0 nokaslr panic=-1'
fi

[[ -f "$K" ]] || { echo "[!] missing $K -- run kernel/build_kernel.sh $V${CONFORMANT:+ --conformant}" >&2; exit 1; }

INITRD="$ROOT/rootfs/initramfs.cpio.gz"
[[ -f "$INITRD" ]] || echo "[!] no initramfs at $INITRD; boot without one" >&2

ACCEL=tcg
[[ -r /dev/kvm ]] && ACCEL=kvm

case "$MODE" in
    gdb)
        # Halted at reset, waiting for a debugger on tcp::1234.
        exec qemu-system-x86_64 \
            -accel "$ACCEL" -machine pc -m 6144 -smp 2 \
            -kernel "$K" \
            ${INITRD:+-initrd "$INITRD"} \
            -append "$CMDLINE" \
            -nographic -no-reboot -monitor none \
            -gdb tcp::1234 -S
        ;;
    serial)
        exec qemu-system-x86_64 \
            -accel "$ACCEL" -machine pc -m 6144 -smp 2 \
            -kernel "$K" \
            ${INITRD:+-initrd "$INITRD"} \
            -append "$CMDLINE" \
            -nographic -no-reboot -monitor none
        ;;
    verify)
        # One-shot: rp.verify makes the guest run its checks and power itself
        # off. The cmdline flag is used rather than piping poweroff down the
        # serial console, which races the shell prompt and loses characters.
        qemu-system-x86_64 \
            -accel "$ACCEL" -machine pc -m 6144 -smp 2 \
            -kernel "$K" \
            ${INITRD:+-initrd "$INITRD"} \
            -append "$CMDLINE rp.verify" \
            -nographic -no-reboot -monitor none
        ;;
esac