#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/workspace.env" 2>/dev/null || true
KVER=""; JOBS="${JOBS:-$(nproc)}"; SKIP=0; CLEAN=0; PATCH_SET=r56p0
usage(){ echo "Usage: $0 --kernel X.Y.Z [--jobs N] [--patch-set r56p0|arm] [--skip-patches] [--clean]"; echo "  --patch-set  r56p0 (default) derived port for r56p0; arm = Arm's six verbatim patches"; }
while [[ $# -gt 0 ]]; do case "$1" in --kernel) KVER="$2"; shift 2;; --jobs) JOBS="$2"; shift 2;; --patch-set) PATCH_SET="$2"; shift 2;; --skip-patches) SKIP=1; shift;; --clean) CLEAN=1; shift;; -h|--help) usage; exit 0;; *) echo "[!] unknown: $1"; usage; exit 2;; esac; done
[[ "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { usage; exit 2; }
case "$PATCH_SET" in r56p0) PATCH_DIR="$PATCH_ROOT/r56p0"; PATCH_COUNT=2;; arm) PATCH_DIR="$PATCH_ROOT"; PATCH_COUNT=6;; *) echo "[!] unknown patch set: $PATCH_SET (expected r56p0 | arm)"; usage; exit 2;; esac
KERNEL_SRC="$KERNEL_ROOT/$KVER/src/linux-$KVER"; KERNEL_BUILD="$KERNEL_ROOT/$KVER/build"
ARCHIVE="$DRIVER_ROOT/AX504X08X-SW-99002-r56p0-18eac0.tar.gz"
WORK="$DRIVER_ROOT/work/$KVER"; OUT="$DRIVER_ROOT/artifacts/r56p0-18eac0/linux-$KVER"; LOG="$DRIVER_ROOT/logs/$KVER"
[[ -f "$KERNEL_SRC/Makefile" && -f "$KERNEL_BUILD/.config" && -f "$ARCHIVE" ]] || { echo '[!] kernel source/build or r56p0 archive missing'; exit 1; }
mkdir -p "$LOG"; exec > >(tee -a "$LOG/build.log") 2>&1
[[ "$(make -s -C "$KERNEL_SRC" kernelversion)" == "$KVER" ]] || { echo '[!] kernel version mismatch'; exit 1; }
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
tar -xzf "$ARCHIVE" -C "$WORK"
SRC="$(find "$WORK" -type d -path '*/driver/product/kernel' -print -quit)"; [[ -n "$SRC" ]] || { echo '[!] r56p0 kernel tree not found'; exit 1; }
KB="$SRC/drivers/gpu/arm/midgard/Kbuild"; grep -q r56p0 "$KB" || { echo '[!] not r56p0'; exit 1; }
KDIR="$WORK/kdir"; KOUT="$WORK/kout"; cp -a "$KERNEL_SRC" "$KDIR"; mkdir -p "$KOUT"; cp "$KERNEL_BUILD/.config" "$KOUT/.config"; cp -a "$SRC/." "$KDIR/"
grep -Fxq 'obj-$(CONFIG_MALI_MIDGARD) += arm/' "$KDIR/drivers/gpu/Makefile" || echo 'obj-$(CONFIG_MALI_MIDGARD) += arm/' >> "$KDIR/drivers/gpu/Makefile"
grep -Fxq 'source "drivers/gpu/arm/Kconfig"' "$KDIR/drivers/video/Kconfig" || echo 'source "drivers/gpu/arm/Kconfig"' >> "$KDIR/drivers/video/Kconfig"
SC="$KDIR/scripts/config"; chmod +x "$SC"; "$SC" --file "$KOUT/.config" --module CONFIG_MALI_MIDGARD; "$SC" --file "$KOUT/.config" --enable CONFIG_MALI_CSF_SUPPORT; "$SC" --file "$KOUT/.config" --enable CONFIG_MALI_EXPERT; "$SC" --file "$KOUT/.config" --enable CONFIG_MALI_NO_MALI; "$SC" --file "$KOUT/.config" --disable CONFIG_MALI_REAL_HW; "$SC" --file "$KOUT/.config" --set-str CONFIG_MALI_NO_MALI_DEFAULT_GPU tKRx; "$SC" --file "$KOUT/.config" --set-str CONFIG_MALI_PLATFORM_NAME vexpress
make -C "$KDIR" O="$KOUT" olddefconfig
PATCHES=("$PATCH_DIR"/*.patch); [[ ${#PATCHES[@]} -eq $PATCH_COUNT ]] || { echo "[!] expected exactly $PATCH_COUNT patch(es) in set '$PATCH_SET' ($PATCH_DIR), found ${#PATCHES[@]}"; exit 1; }; echo "[+] Patch set: $PATCH_SET ($PATCH_COUNT patch(es)) from $PATCH_DIR"
if [[ "$SKIP" -eq 0 ]]; then for p in "${PATCHES[@]}"; do echo "===== DRY RUN $(basename "$p") ====="; patch --dry-run --batch -p3 -d "$KDIR" -i "$p"; done; for p in "${PATCHES[@]}"; do patch --batch -p3 -d "$KDIR" -i "$p"; done; else echo '[!] VP patches skipped'; fi
make -C "$KDIR" O="$KOUT" olddefconfig
make -C "$KDIR" O="$KOUT" modules_prepare
if grep -q '^CONFIG_MODVERSIONS=y' "$KOUT/.config" && [[ ! -f "$KOUT/Module.symvers" ]]; then echo '[!] Module.symvers missing for CONFIG_MODVERSIONS=y; complete the kernel build first'; exit 1; fi
make -C "$KDIR" O="$KOUT" M="$KDIR/drivers/gpu/arm/midgard" -j"$JOBS" modules
KO="$KOUT/drivers/gpu/arm/midgard/mali_kbase.ko"; [[ -f "$KO" ]] || { echo '[!] mali_kbase.ko missing'; exit 1; }
cp "$KO" "$OUT/mali_kbase.ko"; cp "$KOUT/.config" "$OUT/kernel-config"; grep -n MALI_RELEASE_NAME "$KDIR/drivers/gpu/arm/midgard/Kbuild" > "$OUT/mali-release.txt" || true
cat > "$OUT/build-info.txt" <<INFO
driver_release=r56p0-18eac0
linux_version=$KVER
arch=x86_64
platform=vexpress
mali_csf_support=y
mali_no_mali=y
vp_patches_skipped=$([[ $SKIP -eq 1 ]] && echo yes || echo no)
patch_set=$PATCH_SET
patch_count=$PATCH_COUNT
patch_dir=$PATCH_DIR
kernel_source=$KERNEL_SRC
kernel_build=$KERNEL_BUILD
integration_source=$KDIR
integration_build=$KOUT
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
INFO
sha256sum "$OUT"/* "$ARCHIVE" "$PATCH_DIR"/*.patch > "$OUT/SHA256SUMS"
file "$OUT/mali_kbase.ko"; echo "[+] SUCCESS: $OUT/mali_kbase.ko"
