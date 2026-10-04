#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# build_kernel.sh
#
# Build an isolated x86_64 Linux kernel version.
#
# Usage:
#   ./build_kernel.sh 6.18.55
#
# Optional:
#   JOBS=8 ./build_kernel.sh 6.18.55
#
# Layout:
#
# kernel/
# ├── build_kernel.sh
# ├── .downloads/
# │   └── linux-6.18.55.tar.xz
# │
# └── 6.18.55/
#     ├── src/
#     │   └── linux-6.18.55/
#     ├── build/
#     ├── logs/
#     │   └── build.log
#     └── artifacts/
#         ├── bzImage
#         ├── vmlinux
#         ├── System.map
#         ├── Module.symvers
#         └── config
#
# IMPORTANT:
# Mali r56p0 is NOT copied into the kernel tree.
# It will later be built as an external module.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=""; CONFORMANT=0; CONFIG_ONLY=0

usage() {
    cat <<'USAGE'
Usage: build_kernel.sh <kernel-version> [--conformant] [--config-only]

  --conformant   Emit only the kernel config deviations the Arm GPU Bug Bounty
                 permits: CONFIG_COMPAT, the ARM64 page-size choice, CONFIG_KASAN*
                 and CONFIG_UBSAN*. Development conveniences (KCOV, DWARF5,
                 GDB_SCRIPTS, KALLSYMS_ALL, SLUB_DEBUG_ON, RANDOMIZE_BASE=off,
                 nokaslr) are NOT applied. See docs/BUG_BUNTY_COMPLIANCE.md.

                 The five Mali driver prerequisites are still applied, because
                 the external module cannot link without them. They are reported
                 separately as a known deviation pending Arm's confirmation.

  --config-only  Configure, verify and save .config, then stop. Skips the
                 compile, so a config can be validated in seconds.

Env:
  JOBS=N         Parallel compile jobs (default: nproc)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --conformant)  CONFORMANT=1; shift ;;
        --config-only) CONFIG_ONLY=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        [0-9]*.[0-9]*.[0-9]*) VERSION="$1"; shift ;;
        *) echo "[!] unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    usage
    exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[!] Invalid kernel version: $VERSION"
    echo "[!] Expected format: X.Y.Z"
    exit 2
fi

JOBS="${JOBS:-$(nproc)}"

VERSION_DIR="$SCRIPT_DIR/$VERSION"
SRC_ROOT="$VERSION_DIR/src"
LOG_DIR="$VERSION_DIR/logs"
ARTIFACT_DIR="$VERSION_DIR/artifacts"
DOWNLOAD_DIR="$SCRIPT_DIR/.downloads"

# Each mode gets its own O= directory. Changing .config invalidates
# include/generated/autoconf.h and forces a near-total rebuild, so sharing one
# build dir would mean rebuilding from scratch every time you switch between
# hunting a bug and confirming it.
#
# Note the disk cost: a compiled kernel build is ~4.3G, so holding BOTH modes
# compiled at once needs ~8.6G. --config-only is cheap (~100M), so it is
# perfectly reasonable to keep both configurations and compile one at a time.
if [[ "$CONFORMANT" -eq 1 ]]; then
    BUILD_DIR="$VERSION_DIR/build-conformant"
    ARTIFACT_DIR="$VERSION_DIR/artifacts-conformant"
else
    BUILD_DIR="$VERSION_DIR/build"
    ARTIFACT_DIR="$VERSION_DIR/artifacts"
fi

SRC_DIR="$SRC_ROOT/linux-$VERSION"
ARCHIVE="$DOWNLOAD_DIR/linux-$VERSION.tar.xz"

# Linux 6.x releases are available here.
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VERSION.tar.xz"

mkdir -p \
    "$SRC_ROOT" \
    "$BUILD_DIR" \
    "$LOG_DIR" \
    "$ARTIFACT_DIR" \
    "$DOWNLOAD_DIR"

LOG_FILE="$LOG_DIR/build.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo " Linux kernel isolated build"
echo "============================================================"
echo "Version    : $VERSION"
echo "Source     : $SRC_DIR"
echo "Build      : $BUILD_DIR"
echo "Artifacts  : $ARTIFACT_DIR"
echo "Logs       : $LOG_DIR"
echo "Jobs       : $JOBS"
echo "============================================================"
echo

# ------------------------------------------------------------
# Download source
# ------------------------------------------------------------

if [[ ! -f "$ARCHIVE" ]]; then
    echo "[+] Downloading:"
    echo "    $KERNEL_URL"

    wget \
        --continue \
        -O "$ARCHIVE.tmp" \
        "$KERNEL_URL"

    mv "$ARCHIVE.tmp" "$ARCHIVE"
else
    echo "[+] Archive already exists:"
    echo "    $ARCHIVE"
fi

# ------------------------------------------------------------
# Extract source
# ------------------------------------------------------------

if [[ ! -d "$SRC_DIR" ]]; then
    echo "[+] Extracting source..."

    tar \
        -xf "$ARCHIVE" \
        -C "$SRC_ROOT"
else
    echo "[+] Source already extracted."
fi

# ------------------------------------------------------------
# Verify source version
# ------------------------------------------------------------

cd "$SRC_DIR"

ACTUAL_VERSION="$(make -s kernelversion)"

if [[ "$ACTUAL_VERSION" != "$VERSION" ]]; then
    echo
    echo "[!] Kernel source version mismatch!"
    echo "    requested: $VERSION"
    echo "    actual:    $ACTUAL_VERSION"
    exit 1
fi

echo "[+] Kernel version verified: $ACTUAL_VERSION"

# ------------------------------------------------------------
# Create x86_64 base configuration
# ------------------------------------------------------------

echo
echo "[+] Creating x86_64 defconfig..."

make \
    O="$BUILD_DIR" \
    ARCH=x86_64 \
    defconfig

CONFIG="$BUILD_DIR/.config"

# ------------------------------------------------------------
# Permitted by the Arm GPU Bug Bounty: CONFIG_COMPAT, the ARM64 page-size
# choice, CONFIG_KASAN* and CONFIG_UBSAN*. 64BIT/X86_64/MODULES/DEVTMPFS are
# structural for this kit rather than research choices. The rest of what Arm
# permits is applied further down, split by mode.
# ------------------------------------------------------------

echo
echo "[+] Configuring research kernel..."

scripts/config \
    --file "$CONFIG" \
    --enable CONFIG_64BIT \
    --enable CONFIG_X86_64 \
    --enable CONFIG_MODULES \
    --enable CONFIG_MODULE_UNLOAD \
    --enable CONFIG_DEVTMPFS \
    --enable CONFIG_KASAN \
    --enable CONFIG_KASAN_GENERIC \
    --enable CONFIG_UBSAN

# ------------------------------------------------------------
# Mali driver prerequisites
# ------------------------------------------------------------
#
# The Mali driver is built out-of-tree by driver/build_driver.sh, but it links
# against the exports of THIS kernel. modpost therefore fails unless every
# symbol it imports is already built into vmlinux. The r56p0 Kbase needs these
# four subsystems; without them mali_kbase.ko reports 16 undefined symbols and
# cannot link (measured, not theoretical):
#
#   CONFIG_COMMON_CLK            __clk_is_enabled                    drivers/clk/clk.c
#   CONFIG_PM_DEVFREQ            devfreq_add_device, devfreq_suspend_device,
#                                devfreq_resume_device,
#                                devfreq_register_opp_notifier,
#                                devfreq_unregister_opp_notifier,
#                                devfreq_recommended_opp,
#                                devfreq_remove_device               drivers/devfreq/devfreq.c
#   CONFIG_PM_OPP                dev_pm_opp_find_freq_{ceil,exact,floor},
#                                dev_pm_opp_get_opp_count,
#                                dev_pm_opp_get_voltage,
#                                dev_pm_opp_put                      drivers/opp/core.c
#   CONFIG_DEVFREQ_THERMAL       devfreq_cooling_em_register,
#                                devfreq_cooling_unregister          drivers/thermal/devfreq_cooling.c
#
# Notes:
#   * The devfreq symbol is PM_DEVFREQ, not DEVFREQ. It was renamed in 6.13;
#     setting the old name silently does nothing.
#   * PM_DEVFREQ is a menuconfig that `select PM_OPP`, so PM_OPP is pulled in
#     automatically. It is set explicitly anyway to keep the intent readable.
#   * DEVFREQ_THERMAL depends on PM_DEVFREQ && PM_OPP. Its object is added by
#     drivers/thermal/Makefile as thermal_sys-$(CONFIG_DEVFREQ_THERMAL).
#   * DEVFREQ_GOV_SIMPLE_ONDEMAND is what midgard/Kconfig selects for the
#     coarse_demand power policy, which the research plan exercises.
#   * ARM Mali itself is deliberately NOT enabled here. The driver is an external
#     module; enabling it in-tree would defeat the purpose of the kit.

scripts/config \
    --file "$CONFIG" \
    --enable CONFIG_COMMON_CLK \
    --enable CONFIG_PM_OPP \
    --enable CONFIG_PM_DEVFREQ \
    --enable CONFIG_DEVFREQ_THERMAL \
    --enable CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND

# ------------------------------------------------------------
# Development-only conveniences  (NOT applied with --conformant)
# ------------------------------------------------------------
#
# Every option below is outside the set the Arm GPU Bug Bounty permits to deviate
# from the default kernel config. They are excellent for finding and debugging
# bugs, and useless -- or counterproductive -- in a configuration you intend to
# validate a finding in. RANDOMIZE_BASE=off and nokaslr in particular REMOVE
# hardening, so a bug demonstrated on such a build may not reproduce on the
# device a report has to be demonstrated on.
#
#   KCOV                 coverage instrumentation; Arm's KASAN/UBSAN are the
#                        sanctioned instrumentation and are applied above
#   DEBUG_INFO_DWARF5    larger kernel, and a config that is not the default
#   GDB_SCRIPTS          debugging convenience
#   KALLSYMS_ALL         debugging convenience
#   STACKTRACE           debugging convenience
#   DEBUG_FS             debugging convenience
#   MAGIC_SYSRQ          host-side debugging
#   SLUB_DEBUG_ON        alters allocator behaviour
#   DEVTMPFS_MOUNT       alters early boot
#   RANDOMIZE_BASE=off   removes KASLR
#   FRAME_POINTER        no-op on x86_64 anyway (needs ARCH_WANT_FRAME_POINTERS)
#
# So: use them to find bugs. Rebuild with --conformant before you claim one.

if [[ "$CONFORMANT" -eq 0 ]]; then
    scripts/config \
        --file "$CONFIG" \
        --enable CONFIG_KCOV \
        --enable CONFIG_DEBUG_INFO \
        --enable CONFIG_DEBUG_INFO_DWARF5 \
        --enable CONFIG_GDB_SCRIPTS \
        --enable CONFIG_FRAME_POINTER \
        --enable CONFIG_KALLSYMS \
        --enable CONFIG_KALLSYMS_ALL \
        --enable CONFIG_DEBUG_KERNEL \
        --enable CONFIG_DEBUG_FS \
        --enable CONFIG_MAGIC_SYSRQ \
        --enable CONFIG_STACKTRACE \
        --enable CONFIG_SLUB_DEBUG \
        --enable CONFIG_SLUB_DEBUG_ON \
        --disable CONFIG_RANDOMIZE_BASE
else
    echo "[+] --conformant: skipping all non-permitted config deviations."
    echo "    Debugging aids (KCOV, DWARF5, GDB_SCRIPTS, KALLSYMS_ALL,"
    echo "    SLUB_DEBUG_ON, RANDOMIZE_BASE=off, ...) are NOT applied."
fi

# ------------------------------------------------------------
# Normalize configuration
# ------------------------------------------------------------

echo
echo "[+] Normalizing .config..."

make \
    O="$BUILD_DIR" \
    ARCH=x86_64 \
    olddefconfig

# ------------------------------------------------------------
# Assert the Mali driver prerequisites survived olddefconfig
# ------------------------------------------------------------
#
# scripts/config only edits .config text. If a symbol does not exist in this
# kernel, or its dependencies are unmet, olddefconfig silently discards the
# request and the driver then fails to link much later with a wall of
# "undefined symbol" errors. Fail here instead, with the actual value.

echo
echo "[+] Verifying Mali driver prerequisites in .config..."

mali_prereq_ok=1
for sym in COMMON_CLK PM_OPP PM_DEVFREQ DEVFREQ_THERMAL DEVFREQ_GOV_SIMPLE_ONDEMAND; do
    if grep -qx "CONFIG_${sym}=y" "$CONFIG"; then
        printf '    %-36s y\n' "CONFIG_${sym}"
    else
        printf '    %-36s %s  <-- NOT BUILT IN\n' \
            "CONFIG_${sym}" \
            "$(grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} )" "$CONFIG" || echo absent)"
        mali_prereq_ok=0
    fi
done

if [[ "$mali_prereq_ok" -ne 1 ]]; then
    echo
    echo "[!] One or more Mali driver prerequisites did not survive olddefconfig."
    echo "    driver/build_driver.sh will fail at modpost with undefined symbols."
    exit 1
fi

# ------------------------------------------------------------
# Arm Bug Bounty compliance checks
# ------------------------------------------------------------
#
# From the Device Configuration Guidelines (document version 20250623-1.0):
#
#   "Where possible, the default Kernel configuration should be used. Only the
#    following Kernel Build KConfig options may be changed ... CONFIG_COMPAT,
#    [ARM64_4K_PAGES|ARM64_16K_PAGES], CONFIG_KASAN* ... CONFIG_UBSAN*"
#
#   "Any of the CONFIG_KASAN* options may be set to y or n, except for the
#    following: CONFIG_KASAN_*_TEST, must be set to n"
#   "Any of the CONFIG_UBSAN* options may be set to y or n, except for the
#    following: CONFIG_TEST_UBSAN, must be set to n"
#   "the Arm Mali Kernel Driver only supports 64-bit kernels"
#
# These are checked rather than assumed, because a silently-satisfied constraint
# is indistinguishable from an unnoticed violation once a report depends on it.

echo
if [[ "$CONFORMANT" -eq 1 ]]; then
    echo "[+] Arm Bug Bounty compliance checks (--conformant)"
else
    echo "[+] Arm Bug Bounty compliance checks (development build)"
fi

compliance_ok=1

# 1. Hard prohibitions: the *_TEST options Arm requires to be off.
for sym in KASAN_UNIT_TEST KASAN_KUNIT_TEST KASAN_MODULE_TEST KASAN_KUNIT_TEST_MODULE TEST_UBSAN; do
    if grep -qx "CONFIG_${sym}=y" "$CONFIG"; then
        printf '    %-34s y   <-- VIOLATION: Arm requires n\n' "CONFIG_${sym}"
        compliance_ok=0
    else
        printf '    %-34s n    ok\n' "CONFIG_${sym}"
    fi
done

# 2. 64-bit only.
if grep -qx "CONFIG_64BIT=y" "$CONFIG"; then
    printf '    %-34s y    ok (64-bit required)\n' "CONFIG_64BIT"
else
    printf '    %-34s %s  <-- VIOLATION: Kbase requires a 64-bit kernel\n' \
        "CONFIG_64BIT" "$(grep -E '^(CONFIG_64BIT=|# CONFIG_64BIT )' "$CONFIG" || echo absent)"
    compliance_ok=0
fi

# 3. In --conformant mode the development aids must be at their defaults. Report
#    rather than assert, because several are already on in x86_64_defconfig and
#    their presence is then not something this script introduced.
if [[ "$CONFORMANT" -eq 1 ]]; then
    echo
    echo "    Auditing against the resolved default kernel config..."
    # Measure, do not reason. Comparing against arch/x86/configs/x86_64_defconfig
    # *text* is misleading: options such as DEBUG_FS, STACKTRACE and SLUB_DEBUG do
    # not appear in it literally but ARE in the resolved default, because
    # olddefconfig pulls them in as dependencies. So resolve a real default here
    # and diff against that.
    #
    # Configs are normalised to symbol=value so that "not set" and "=n" compare
    # equal, otherwise every unset symbol looks like a difference.
    audit_dir="$(mktemp -d "${TMPDIR:-/tmp}/config-audit.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$audit_dir'" EXIT
    normalise() {
        sed -n -e 's/^\(CONFIG_[A-Za-z0-9_]*\)=\(.*\)$/\1=\2/p' \
               -e 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1=n/p' "$1" | sort -u
    }
    if make -s O="$audit_dir" ARCH=x86_64 defconfig >/dev/null 2>&1 \
       && [[ -f "$audit_dir/.config" ]]; then
        normalise "$audit_dir/.config" > "$audit_dir/base"
        normalise "$CONFIG"            > "$audit_dir/ours"
        added=$(comm -13 "$audit_dir/base" "$audit_dir/ours" | wc -l | tr -d ' ')
        removed=$(comm -23 "$audit_dir/base" "$audit_dir/ours" | wc -l | tr -d ' ')
        # A raw comm diff is mostly noise: enabling COMMON_CLK and PM_DEVFREQ makes
        # their sub-options *visible*, so dozens of symbols go from absent to an
        # explicit "=n" without anything actually changing. The real deviation
        # surface is the set that went from not-enabled to y or m.
        newly_on=$(comm -13 "$audit_dir/base" "$audit_dir/ours" \
                   | grep -cE '=(y|m)$' || true)
        printf '    %-34s %s newly enabled, %s newly visible-but-off, %s cleared\n' \
            "vs resolved defconfig" "$newly_on" "$((added - newly_on))" "$removed"

        # Classify what was newly enabled. Anything that is neither a permitted
        # option nor one of the declared driver prerequisites is a dependency
        # that the permitted options pulled in -- legitimate under Arm's
        # "compatible with each other", but shown so it can be reviewed rather
        # than assumed.
        echo
        echo "    Newly enabled, and NOT in the permitted set:"
        unaccounted=0
        while IFS= read -r line; do
            sym="${line%%=*}"
            case "$sym" in
                CONFIG_KASAN*|CONFIG_UBSAN*|CONFIG_COMPAT|\
                CONFIG_ARM64_4K_PAGES|CONFIG_ARM64_16K_PAGES|\
                CONFIG_COMMON_CLK|CONFIG_PM_OPP|CONFIG_PM_DEVFREQ|\
                CONFIG_DEVFREQ_THERMAL|CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND)
                    continue ;;
            esac
            unaccounted=$((unaccounted + 1))
            if [[ "$unaccounted" -le 25 ]]; then
                printf '      %-30s %s\n' "$sym" "${line#*=}"
            fi
        done < <(comm -13 "$audit_dir/base" "$audit_dir/ours" | grep -E '=(y|m)$')
        if [[ "$unaccounted" -gt 25 ]]; then
            printf '      ... and %s more\n' "$((unaccounted - 25))"
        fi
        if [[ "$unaccounted" -eq 0 ]]; then
            echo "      (none)"
        else
            echo
            echo "      Expected: these are dependencies pulled in by the permitted"
            echo "      KASAN/UBSAN options and by the declared driver prerequisites."
            echo "      Arm allows the permitted options to be used together, so these"
            echo "      are reviewable rather than violations -- but they are shown"
            echo "      because 'it is only a dependency' is a claim worth checking."
        fi
    else
        echo "    [!] could not resolve the default config for comparison;"
        echo "        skipping the diff audit (the hard checks above still ran)"
    fi
    echo
    echo "    Do NOT pass 'nokaslr' to QEMU in --conformant mode."
fi

if [[ "$compliance_ok" -ne 1 ]]; then
    echo
    echo "[!] Arm Bug Bounty compliance check FAILED. Do not use this build to"
    echo "    substantiate a submission until the violations above are resolved."
    exit 1
fi

# 4. Report, without failing: the Mali prerequisites are a deviation from the
#    permitted set, but an unavoidable one -- the external module cannot link
#    without them, so no finding is reachable without them.
echo
echo "    Known deviation from the permitted set (unavoidable here):"
printf '      %-28s %s\n' "driver prerequisites" "COMMON_CLK, PM_OPP, PM_DEVFREQ, DEVFREQ_THERMAL, DEVFREQ_GOV_SIMPLE_ONDEMAND"
echo "      The driver is an external module linking against this kernel's"
echo "      exports; without these it fails at modpost with 16 undefined"
echo "      symbols. Pending Arm's confirmation -- see docs/BUG_BUNTY_COMPLIANCE.md"

# Save exact configuration used.
cp \
    "$CONFIG" \
    "$ARTIFACT_DIR/config"

# ------------------------------------------------------------
# Display important options
# ------------------------------------------------------------

echo
echo "[+] Important configuration:"

grep -E \
    '^CONFIG_(64BIT|X86_64|MODULES|MODULE_UNLOAD|DEVTMPFS|DEVTMPFS_MOUNT|KCOV|KASAN|KASAN_GENERIC|UBSAN|DEBUG_INFO|DEBUG_INFO_DWARF5|GDB_SCRIPTS|FRAME_POINTER|KALLSYMS|KALLSYMS_ALL|DEBUG_KERNEL|DEBUG_FS|MAGIC_SYSRQ|STACKTRACE|SLUB_DEBUG|SLUB_DEBUG_ON|RANDOMIZE_BASE|COMMON_CLK|PM_OPP|PM_DEVFREQ|DEVFREQ_THERMAL|DEVFREQ_GOV_SIMPLE_ONDEMAND)=' \
    "$CONFIG" || true

# ------------------------------------------------------------
# Build
# ------------------------------------------------------------

if [[ "$CONFIG_ONLY" -eq 1 ]]; then
    echo
    echo "[+] --config-only: configuration written to $CONFIG"
    echo "[+] Not compiling. Re-run without --config-only to build."
    exit 0
fi

echo
echo "[+] Building Linux $VERSION..."
echo "[+] Parallel jobs: $JOBS"
echo

make \
    O="$BUILD_DIR" \
    ARCH=x86_64 \
    -j"$JOBS"

# ------------------------------------------------------------
# Verify build artifacts
# ------------------------------------------------------------

echo
echo "[+] Verifying build artifacts..."

REQUIRED_FILES=(
    "$BUILD_DIR/vmlinux"
    "$BUILD_DIR/arch/x86/boot/bzImage"
    "$BUILD_DIR/Module.symvers"
    "$BUILD_DIR/System.map"
)

for FILE in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$FILE" ]]; then
        echo "[!] Missing required artifact:"
        echo "    $FILE"
        exit 1
    fi
done

# ------------------------------------------------------------
# Copy stable artifacts
# ------------------------------------------------------------

echo "[+] Copying stable artifacts..."

cp \
    "$BUILD_DIR/vmlinux" \
    "$ARTIFACT_DIR/vmlinux"

cp \
    "$BUILD_DIR/arch/x86/boot/bzImage" \
    "$ARTIFACT_DIR/bzImage"

cp \
    "$BUILD_DIR/Module.symvers" \
    "$ARTIFACT_DIR/Module.symvers"

cp \
    "$BUILD_DIR/System.map" \
    "$ARTIFACT_DIR/System.map"

# ------------------------------------------------------------
# Basic validation
# ------------------------------------------------------------

echo
echo "[+] Validating vmlinux..."

file "$ARTIFACT_DIR/vmlinux"

echo
echo "[+] Validating bzImage..."

file "$ARTIFACT_DIR/bzImage"

echo
echo "[+] Checking DWARF debug sections..."

if readelf -S "$ARTIFACT_DIR/vmlinux" 2>/dev/null | grep -q '\.debug_info'; then
    echo "    [OK] DWARF debug information present"
else
    echo "    [WARN] .debug_info not found"
fi

echo
echo "============================================================"
echo " BUILD SUCCESS"
echo "============================================================"
echo
echo "Kernel version:"
echo "  $VERSION"
echo
echo "Source:"
echo "  $SRC_DIR"
echo
echo "Build directory:"
echo "  $BUILD_DIR"
echo
echo "bzImage:"
echo "  $ARTIFACT_DIR/bzImage"
echo
echo "vmlinux:"
echo "  $ARTIFACT_DIR/vmlinux"
echo
echo "Module.symvers:"
echo "  $ARTIFACT_DIR/Module.symvers"
echo
echo "Kernel config:"
echo "  $ARTIFACT_DIR/config"
echo
echo "Build log:"
echo "  $LOG_FILE"
echo
echo "============================================================"
echo
echo "External Mali driver should later use:"
echo
echo "  KERNEL_SRC=$SRC_DIR"
echo "  KERNEL_BUILD=$BUILD_DIR"
echo
echo "============================================================"
