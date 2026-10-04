#!/usr/bin/env bash
# ============================================================
# verify_against_kbase.sh
#
# Dry-run a patch set against the real r56p0 Kbase tree WITHOUT
# building a kernel, then verify the patched tree is actually
# configurable. This is the fast feedback loop.
#
# Usage:
#   ./verify_against_kbase.sh [patch-set] [archive]
#
#   patch-set: r56p0 (default) | arm
#   archive:   path to AX504X08X-SW-99002-r56p0-18eac0.tar.gz
#
# Why this exists: "all patches apply cleanly" is NOT sufficient.
# r56p0 ships drivers/gpu/arm/Kconfig that unconditionally sources an
# arbitration/Kconfig which does not exist in the release. Every patch
# still applies to that tree, yet olddefconfig dies before any patching
# is reached. So this script also checks that every kbuild Kconfig
# source resolves AFTER the set has been applied.
#
# Exits non-zero if the release is not r56p0, if the patch count is
# wrong, if any patch fails to dry-run, or if the patched tree still
# has an unresolvable Kconfig source. Never modifies the repository
# or the archive; extraction happens in a temp dir removed on exit.
# ============================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_ROOT="$ROOT/patches"

SET="${1:-r56p0}"
ARCHIVE="${2:-$ROOT/driver/AX504X08X-SW-99002-r56p0-18eac0.tar.gz}"

case "$SET" in
    r56p0) DIR="$PATCH_ROOT/r56p0"; EXPECT=3 ;;
    arm)   DIR="$PATCH_ROOT";        EXPECT=6 ;;
    *) echo "[!] unknown patch set: $SET (expected: r56p0 | arm)" >&2; exit 2 ;;
esac

for t in patch tar grep find sort; do
    command -v "$t" >/dev/null 2>&1 || { echo "[!] $t required" >&2; exit 1; }
done

[[ -f "$ARCHIVE" ]] || { echo "[!] archive missing: $ARCHIVE" >&2; exit 1; }
[[ -d "$DIR" ]]      || { echo "[!] patch set dir missing: $DIR" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/r56p0-patchcheck.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "============================================================"
echo " Patch verification against r56p0 Kbase"
echo "============================================================"
echo "Set      : $SET ($DIR)"
echo "Archive  : $ARCHIVE"
echo "Expected : $EXPECT patch(es)"
echo "============================================================"
echo

tar -xzf "$ARCHIVE" -C "$WORK"
SRC="$(find "$WORK" -type d -path '*/driver/product/kernel' -print -quit)"
[[ -n "$SRC" ]] || { echo '[!] r56p0 kernel tree not found in archive' >&2; exit 1; }

KBUILD="$SRC/drivers/gpu/arm/midgard/Kbuild"
[[ -f "$KBUILD" ]] || { echo '[!] Kbase Kbuild missing' >&2; exit 1; }

REL="$(grep -m1 'MALI_RELEASE_NAME' "$KBUILD" | sed 's/.*"\(r[0-9]*p[0-9]*\).*/\1/')"
echo "Detected MALI_RELEASE_NAME : ${REL:-<unknown>}"
[[ "$REL" == r56p0 ]] || { echo "[!] expected r56p0, found '${REL:-unknown}'" >&2; exit 1; }
echo

PATCHES=("$DIR"/*.patch)
if [[ "${#PATCHES[@]}" -ne "$EXPECT" ]]; then
    echo "[FAIL] expected exactly $EXPECT patch(es) in $DIR, found ${#PATCHES[@]}" >&2
    exit 1
fi
echo "Patch count OK: ${#PATCHES[@]}"
echo

# --- 1. dry-run every patch -------------------------------------------------
echo "Dry run:"
dry_bad=0
for p in "${PATCHES[@]}"; do
    name="$(basename "$p")"
    printf '  %-58s ' "$name"
    if out="$(patch --dry-run --batch -p3 -d "$SRC" -i "$p" 2>&1)"; then
        if grep -qiE 'offset|fuzz' <<<"$out"; then
            echo "CLEAN (offset/fuzz)"
            grep -iE 'offset|fuzz' <<<"$out" | sed 's/^/        /'
        else
            echo "CLEAN"
        fi
    else
        echo "FAIL"
        sed 's/^/        /' <<<"$out"
        dry_bad=$((dry_bad + 1))
    fi
done
echo

if [[ "$dry_bad" -ne 0 ]]; then
    echo "[FAIL] $dry_bad patch(es) do not apply to $REL."
    echo "       Do NOT force or silently port. See patches/PATCHES.md."
    exit 1
fi

# --- 2. apply, so the tree can be inspected post-patch ----------------------
for p in "${PATCHES[@]}"; do
    patch --batch -p3 -d "$SRC" -i "$p" >/dev/null 2>&1 \
        || { echo "[!] apply failed unexpectedly: $(basename "$p")" >&2; exit 1; }
done
echo "Applied ${#PATCHES[@]} patch(es) to scratch tree."
echo

# --- 3. kbuild Kconfig source integrity, AFTER patching ---------------------
#
# Model kconfig's real behaviour, which is counter-intuitive: kconfig includes a
# sourced file EVEN INSIDE a false "#if 0" block. Only a "#" comment actually
# disables a source line. (Verified against 6.18.55 -- an "#if 0"-wrapped source
# still fails olddefconfig.) So drop plain comment lines and treat every
# remaining source statement as live, exactly as kconfig does.
kconfig_active() {
    find "$SRC/drivers/gpu" -name 'Kconfig' -type f -print0 2>/dev/null \
        | xargs -0 -r grep -hvE '^[[:space:]]*#' \
        | grep -vE '^[[:space:]]*$'
}

echo "Kconfig source integrity after patching:"
echo "  (kbuild reads Kconfig; Mconfig is meson-only and unused here)"
kcfg_bad=0
while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    rel="${ref#\$(MALI_KCONFIG_EXT_PREFIX)}"
    if [[ -f "$SRC/$rel" ]]; then
        printf '    %-60s OK\n' "$rel"
    else
        printf '    %-60s MISSING\n' "$rel"
        kcfg_bad=$((kcfg_bad + 1))
    fi
done < <(kconfig_active \
         | grep -oE '^[[:space:]]*(source|rsource)[[:space:]]+"[^"]*Kconfig"' \
         | grep -oE '"[^"]+"' | tr -d '"' | sort -u)

while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    rel="${ref#\$(MALI_KCONFIG_EXT_PREFIX)}"; rel="${rel#kernel/}"
    [[ -f "$SRC/$rel" ]] || printf '    %-60s MISSING (meson only, ignored)\n' "$rel"
done < <(find "$SRC/drivers/gpu" -name 'Mconfig' -type f -print0 2>/dev/null \
         | xargs -0 -r grep -hvE '^[[:space:]]*#' \
         | grep -oE '(source|rsource)[[:space:]]+"[^"]*Mconfig"' \
         | grep -oE '"[^"]+"' | tr -d '"' | sort -u)
echo

echo "------------------------------------------------------------"
if [[ "$kcfg_bad" -ne 0 ]]; then
    echo "Result: patches apply, but $kcfg_bad Kconfig source(s) still unresolved"
    echo "------------------------------------------------------------"
    echo
    echo "[FAIL] The patched tree would still fail olddefconfig."
    echo "       A patch in this set must guard the stale source line."
    exit 1
fi

echo "Result: ${#PATCHES[@]} clean, 0 Kconfig gaps (set=$SET, release=$REL)"
echo "------------------------------------------------------------"
echo
echo "[+] Patch set '$SET' applies cleanly to $REL and leaves a"
echo "    configurable tree. build_driver.sh can proceed."