#!/usr/bin/env bash
# ============================================================
# collect_artifacts.sh -- assemble a self-contained deliverable
#                        bundle in artifacts/.
#
# Usage:
#   ./tools/collect_artifacts.sh [kernel-version]
#   ./tools/collect_artifacts.sh 6.18.55 --no-vmlinux
#
# The kit writes its outputs into two separate trees while you work:
#
#   kernel/<ver>/artifacts/              bzImage, vmlinux, System.map, ...
#   driver/artifacts/<rel>/linux-<ver>/  mali_kbase.ko, kernel-config, ...
#
# That split is right for a build tree and wrong for anything you want to hand
# over, archive, or attach to a report. This script collects the pieces into one
# directory with a flat, obvious layout and a single verifiable checksum file.
#
#   artifacts/
#   ├── README.txt              what this is, how to verify and reproduce
#   ├── MANIFEST.sha256         sha256 of every other file in the bundle
#   ├── build-info.txt          driver build provenance
#   ├── kernel/                 bzImage, vmlinux, System.map, Module.symvers, config
#   ├── driver/                 mali_kbase.ko, kernel-config, mali-release.txt
#   ├── boot/initramfs.cpio.gz  boots the module without host tooling
#   ├── patches/r56p0/          the patch set actually applied
#   ├── provenance/             upstream archive hash, driver SHA256SUMS
#   └── docs/                   PATCHES.md, BUG_BUNTY_COMPLIANCE.md
#
# Arm's proprietary Kbase source archive is NOT copied -- only its SHA256 is
# recorded. Redistributing it in a bundle is not ours to do; obtain it from
# https://developer.arm.com/downloads/-/mali-drivers/5th-gen-gpu-architecture-kernel
# and check it against provenance/source-archive.sha256.
#
# vmlinux is 500M+ of the bundle and is only needed for GDB symbolication, so
# --no-vmlinux omits it. MANIFEST.sha256 records what was actually included.
# ============================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/workspace.env" 2>/dev/null || true

VERSION=""; WANT_VMLINUX=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-vmlinux) WANT_VMLINUX=0; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        [0-9]*.[0-9]*.[0-9]*) VERSION="$1"; shift ;;
        *) echo "[!] unknown argument: $1" >&2; exit 2 ;;
    esac
done
VERSION="${VERSION:-6.18.55}"

DRIVER_REL="r56p0-18eac0"
K_SRC="$ROOT/kernel/$VERSION/artifacts"
D_SRC="$ROOT/driver/artifacts/$DRIVER_REL/linux-$VERSION"
K_CFG="$ROOT/kernel/$VERSION/build-conformant/.config"
ARCHIVE="$ROOT/driver/AX504X08X-SW-99002-r56p0-18eac0.tar.gz"
OUT="$ROOT/artifacts"

# ------------------------------------------------------------
# Refuse to build an incomplete bundle silently
# ------------------------------------------------------------

missing=0
for f in "$K_SRC/bzImage" "$K_SRC/config" "$K_SRC/System.map" \
         "$K_SRC/Module.symvers" \
         "$D_SRC/mali_kbase.ko" "$D_SRC/kernel-config" \
         "$D_SRC/build-info.txt" "$D_SRC/mali-release.txt"; do
    if [[ ! -f "$f" ]]; then
        echo "[!] missing: ${f#$ROOT/}" >&2
        missing=$((missing + 1))
    fi
done
if [[ "$WANT_VMLINUX" -eq 1 && ! -f "$K_SRC/vmlinux" ]]; then
    echo "[!] missing: ${K_SRC#$ROOT/}/vmlinux  (use --no-vmlinux to skip)" >&2
    missing=$((missing + 1))
fi
if [[ "$missing" -ne 0 ]]; then
    echo >&2
    echo "[!] $missing required file(s) absent. Build them first:" >&2
    echo "    kernel/build_kernel.sh $VERSION" >&2
    echo "    driver/build_driver.sh --kernel $VERSION" >&2
    exit 1
fi

# ------------------------------------------------------------
# Assemble
# ------------------------------------------------------------

# Only ever remove paths this script owns, so a stray collect cannot eat
# anything else that happens to live under artifacts/.
echo "[+] Assembling $OUT"
rm -rf "$OUT"/kernel "$OUT"/driver "$OUT"/boot "$OUT"/patches \
       "$OUT"/provenance "$OUT"/docs
rm -f "$OUT/README.txt" "$OUT/MANIFEST.sha256" "$OUT/build-info.txt"
mkdir -p "$OUT"/{kernel,driver,boot,patches/r56p0,provenance,docs}

for f in bzImage System.map Module.symvers config; do
    cp "$K_SRC/$f" "$OUT/kernel/$f"
done
if [[ "$WANT_VMLINUX" -eq 1 ]]; then
    cp "$K_SRC/vmlinux" "$OUT/kernel/vmlinux"
else
    echo "[+] vmlinux omitted by request (--no-vmlinux)"
fi

for f in mali_kbase.ko kernel-config mali-release.txt; do
    cp "$D_SRC/$f" "$OUT/driver/$f"
done
cp "$D_SRC/build-info.txt" "$OUT/build-info.txt"
[[ -f "$D_SRC/SHA256SUMS" ]] && cp "$D_SRC/SHA256SUMS" "$OUT/provenance/driver-SHA256SUMS"

# The bootable rootfs already embeds mali_kbase.ko, so the bundle boots as-is.
if [[ -f "$ROOT/rootfs/initramfs.cpio.gz" ]]; then
    cp "$ROOT/rootfs/initramfs.cpio.gz" "$OUT/boot/"
else
    echo "[!] no initramfs -- run rootfs/build_rootfs.sh $VERSION to make the" >&2
    echo "    bundle directly bootable" >&2
fi

cp "$ROOT"/patches/r56p0/*.patch "$OUT/patches/r56p0/"

# Arm's archive: hash only, never redistributed.
sha256sum "$ARCHIVE" | sed "s|$ARCHIVE|AX504X08X-SW-99002-r56p0-18eac0.tar.gz|" \
    > "$OUT/provenance/source-archive.sha256"

for d in PATCHES.md BUG_BUNTY_COMPLIANCE.md; do
    [[ -f "$ROOT/patches/$d" ]] && cp "$ROOT/patches/$d" "$OUT/docs/$d"
    [[ -f "$ROOT/docs/$d" ]] && cp "$ROOT/docs/$d" "$OUT/docs/$d"
done
cp "$ROOT/docs/BUG_BUNTY_COMPLIANCE.md" "$OUT/docs/" 2>/dev/null || true

# Record whether a conformant kernel config exists, so the bundle says plainly
# which kind of build it is rather than leaving that to be guessed.
{
    echo "# Which kernel configuration this bundle was built against."
    if [[ -f "$K_CFG" ]]; then
        echo "# A --conformant config was found at:"
        echo "#   kernel/$VERSION/build-conformant/.config"
        echo "# NOTE: the kernel binaries here are from the DEVELOPMENT build."
        echo "# Read docs/BUG_BUNTY_COMPLIANCE.md before using this bundle to"
        echo "# substantiate a submission."
    else
        echo "# DEVELOPMENT build only. No --conformant config found."
        echo "# See docs/BUG_BUNTY_COMPLIANCE.md."
    fi
} > "$OUT/provenance/kernel-config-kind.txt"

# ------------------------------------------------------------
# README
# ------------------------------------------------------------

VF="kernel/vmlinux (present)"
[[ "$WANT_VMLINUX" -eq 0 ]] && VF="kernel/vmlinux (OMITTED -- no GDB symbols)"

cat > "$OUT/README.txt" <<EOF
Mali r56p0 x86_64 research kit -- artifact bundle
================================================
Assembled $(date -u '+%Y-%m-%dT%H:%M:%SZ')

Contents
--------
kernel/bzImage            bootable kernel
$VF
kernel/System.map         kernel symbol addresses
kernel/Module.symvers     exported symbols, for out-of-tree modules
kernel/config             exact .config used

driver/mali_kbase.ko      the built module (unstripped, DWARF5, KASAN-instrumented)
driver/kernel-config      .config the driver was compiled against
driver/mali-release.txt   MALI_RELEASE_NAME from the Kbase Kbuild

boot/initramfs.cpio.gz    BusyBox initramfs with mali_kbase.ko embedded at /mali_kbase.ko

patches/r56p0/            the 3-patch set actually applied to r56p0-18eac0
provenance/source-archive.sha256   SHA256 of Arm's Kbase tarball (not redistributed)
provenance/driver-SHA256SUMS        checksums recorded at driver build time
provenance/kernel-config-kind.txt   which kernel config this is
docs/PATCHES.md                      per-patch rationale, and the port decisions
docs/BUG_BUNTY_COMPLIANCE.md         Arm bounty scope and config compliance

Verify
------
  cd artifacts && sha256sum -c MANIFEST.sha256

Boot and load the module
------------------------
  qemu-system-x86_64 -machine pc -m 6144 -smp 2 \\
    -kernel kernel/bzImage -initrd boot/initramfs.cpio.gz \\
    -append 'console=ttyS0 nokaslr' -nographic -no-reboot -monitor none

The init script insmods /mali_kbase.ko and prints the result.

Debug with GDB
---------------
The driver is an EXTERNAL module, so its symbols are in mali_kbase.ko, not in
vmlinux. Loading vmlinux alone will not resolve any kbase_* symbol -- there are
1366 of them in the module and zero in the kernel image. Load both:

  gdb kernel/vmlinux
  (gdb) add-symbol-file driver/mali_kbase.ko
  (gdb) target remote :1234
  (gdb) break kbase_driver_init

kbase_driver_init is the static function passed to module_init() at
mali_kbase_core_linux.c:5005. The module's exported entry point is init_module.

Note that at this point the module is not loaded yet, so add-symbol-file leaves
it unrelocated and kbase_driver_init sits at its link-time offset (0x10). To
break inside the driver, either:
  * boot with --serial, insmod by hand, then re-add at the runtime base shown in
    /proc/modules:
        add-symbol-file driver/mali_kbase.ko 0xffffffffa0000000
  * or break kernel-side first (do_init_module), then add the symbols once the
    module is placed.

Caveats -- read before drawing conclusions
------------------------------------------
* The dummy model (CONFIG_MALI_NO_MALI=y) does not execute GPU firmware. CSFFW
  is out of scope for this bundle, and GPU/firmware memory-access bugs cannot be
  tested with it. No /dev/mali* node is registered.
* This is a DEVELOPMENT build unless provenance/kernel-config-kind.txt says
  otherwise. It deviates from the config set the Arm Bug Bounty permits.
* Verify the Kbase tarball against provenance/source-archive.sha256 before
  reproducing. Obtain it from Arm's developer site; it is not bundled.
EOF

# ------------------------------------------------------------
# Manifest -- written last, covers everything else
# ------------------------------------------------------------

echo "[+] Checksumming"
( cd "$OUT" && find . -type f ! -name MANIFEST.sha256 -print0 \
    | sort -z | xargs -0 -r sha256sum > MANIFEST.sha256 )

# ------------------------------------------------------------
# Verify what we just wrote, rather than assuming
# ------------------------------------------------------------

echo "[+] Verifying bundle"
if ( cd "$OUT" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1 ); then
    echo "[+] OK: every file matches MANIFEST.sha256"
else
    echo "[!] manifest verification FAILED" >&2
    ( cd "$OUT" && sha256sum -c MANIFEST.sha256 2>&1 | grep -v ': OK$' >&2 )
    exit 1
fi

echo
echo "[+] Bundle: $OUT"
du -sh "$OUT" | sed 's/^/    size: /'
find "$OUT" -type f | wc -l | sed 's/^/    files: /'
echo
echo "    $OUT/README.txt"
echo "    verify with: cd $OUT && sha256sum -c MANIFEST.sha256"