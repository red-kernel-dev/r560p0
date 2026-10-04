#!/usr/bin/env bash
# ============================================================
# build_rootfs.sh -- build a BusyBox initramfs for the research
#                   kernel, with the Mali module embedded.
#
# Usage: ./build_rootfs.sh [kernel-version]
#
# The module is embedded at /mali_kbase.ko so the guest can insmod
# it with no host tooling and no second disk image. If the module has
# not been built yet the initramfs is still produced, and the init
# script says so instead of failing the boot.
#
# The init script mounts /proc, /sys and /dev, prints the running
# kernel and command line, attempts to load the module, and then
# reports what happened. It deliberately ends in a shell rather than
# powering off, so a serial session or a GDB attach can continue from
# there. qemu/boot_kernel_gdb.sh --verify runs the same initramfs
# non-interactively.
# ============================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/workspace.env" 2>/dev/null || true

V="${1:-6.18.55}"
DRIVER_REL="r56p0-18eac0"
KO_SRC="$ROOT/driver/artifacts/$DRIVER_REL/linux-$V/mali_kbase.ko"

O="$ROOT/rootfs/initramfs"
rm -rf "$O"
mkdir -p "$O"/{bin,sbin,proc,sys,dev,tmp,etc,root}

# ------------------------------------------------------------
# BusyBox + applet symlinks
# ------------------------------------------------------------

BB="$(command -v busybox)" || { echo "[!] busybox not found; install it first" >&2; exit 1; }
cp "$BB" "$O/bin/busybox"

# insmod/rmmod/lsmod matter for this kit; keep them. shellcheck disable=SC2086
for a in sh mount umount cat echo ls mkdir mknod insmod rmmod lsmod modinfo \
         dmesg uname sleep grep wc head tail sync poweroff; do
    ln -sf /bin/busybox "$O/bin/$a"
done

# ------------------------------------------------------------
# Embed the driver module
# ------------------------------------------------------------

if [[ -f "$KO_SRC" ]]; then
    cp "$KO_SRC" "$O/mali_kbase.ko"
    echo "[+] embedded $KO_SRC ($(du -h "$O/mali_kbase.ko" | cut -f1))"
else
    echo "[!] module not found at $KO_SRC" >&2
    echo "    run driver/build_driver.sh --kernel $V first; the initramfs" >&2
    echo "    will build without it and the guest will report it as absent." >&2
fi

# ------------------------------------------------------------
# init
# ------------------------------------------------------------

cat > "$O/init" <<'INIT'
#!/bin/sh
# BusyBox init for the Mali r56p0 research kernel.
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev 2>/dev/null || true

echo "===== kernel ====="
uname -a
echo "cmdline: $(cat /proc/cmdline)"

# KASAN is built in, not a module, so it has no /sys/module entry.
# dmesg is the reliable way to confirm the sanitiser came up.
if dmesg | grep -q "KernelAddressSanitizer initialized"; then
    echo "KASAN: active"
else
    echo "KASAN: NOT initialised (unexpected -- check CONFIG_KASAN)"
fi

echo "===== insmod mali_kbase.ko ====="
if [ ! -f /mali_kbase.ko ]; then
    echo "RESULT: SKIP -- /mali_kbase.ko was not embedded in this initramfs"
    echo "        (build the driver first: driver/build_driver.sh --kernel <ver>)"
else
    insmod /mali_kbase.ko
    rc=$?
    echo "insmod exit=$rc"
    if [ "$rc" -eq 0 ]; then
        echo "RESULT: LOADED"
        echo "----- lsmod -----"
        lsmod
        echo "----- /proc/modules -----"
        cat /proc/modules
        echo "----- driver messages -----"
        dmesg | grep -iE "mali|kbase|devfreq|opp" | tail -40
    else
        echo "RESULT: FAILED (rc=$rc)"
        echo "----- last 30 dmesg lines -----"
        dmesg | tail -30
    fi
fi
echo "===== end of checks ====="

# qemu/boot_kernel_gdb.sh --verify adds rp.verify to the kernel command line so
# the guest powers itself off once the checks finish. Driving this through the
# command line rather than through stdin is deliberate: piping poweroff into the
# serial console races the shell prompt and loses characters.
if grep -q 'rp\.verify' /proc/cmdline 2>/dev/null; then
    echo "rp.verify set -- powering off"
    sync
    poweroff -f
    # Should not be reached; do not fall through into a shell.
    while :; do sleep 5; done
fi

exec /bin/sh
INIT
chmod +x "$O/init"

# ------------------------------------------------------------
# Pack
# ------------------------------------------------------------

(cd "$O" && find . -print0 | cpio --null -o --format=newc 2>/dev/null) \
    | gzip -9 > "$ROOT/rootfs/initramfs.cpio.gz"

echo "[+] $ROOT/rootfs/initramfs.cpio.gz ($(du -h "$ROOT/rootfs/initramfs.cpio.gz" | cut -f1))"