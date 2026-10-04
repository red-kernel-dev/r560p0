#!/usr/bin/env bash
# ============================================================
# verify_against_kbase.sh
#
# Dry-run a patch set against the real r56p0 Kbase tree WITHOUT
# building a kernel. This is the fast feedback loop: it answers
# "does this patch set still apply?" in seconds instead of hours.
#
# Usage:
#   ./verify_against_kbase.sh [patch-set] [archive]
#
#   patch-set: r56p0 (default) | arm
#   archive:   path to AX504X08X-SW-99002-r56p0-18eac0.tar.gz
#              (default: ../driver/AX504X08X-SW-99002-r56p0-18eac0.tar.gz)
#
# Exits non-zero if the release is not r56p0, if the patch count is
# wrong, or if ANY patch fails to dry-run. Never modifies the
# repository or the archive; extraction happens in a temp dir that
# is removed on exit.
# ============================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_ROOT="$ROOT/patches"

SET="${1:-r56p0}"
ARCHIVE="${2:-$ROOT/driver/AX504X08X-SW-99002-r56p0-18eac0.tar.gz}"

case "$SET" in
    r56p0) DIR="$PATCH_ROOT/r56p0"; EXPECT=2 ;;
    arm)   DIR="$PATCH_ROOT";        EXPECT=6 ;;
    *) echo "[!] unknown patch set: $SET (expected: r56p0 | arm)" >&2; exit 2 ;;
esac

command -v patch    >/dev/null 2>&1 || { echo '[!] patch(1) required'   >&2; exit 1; }
command -v tar      >/dev/null 2>&1 || { echo '[!] tar required'       >&2; exit 1; }
command -v sha256sum>/dev/null 2>&1 || { echo '[!] sha256sum required' >&2; exit 1; }

[[ -f "$ARCHIVE" ]] || { echo "[!] archive missing: $ARCHIVE" >&2; exit 1; }
[[ -d "$DIR" ]]      || { echo "[!] patch set dir missing: $DIR" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/r56p0-patchcheck.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "============================================================"
echo " Patch dry-run against r56p0 Kbase"
echo "============================================================"
echo "Set      : $SET ($DIR)"
echo "Archive  : $ARCHIVE"
echo "Expected : $EXPECT patch(es)"
echo "Scratch  : $WORK"
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
COUNT="${#PATCHES[@]}"
if [[ "$COUNT" -ne "$EXPECT" ]]; then
    echo "[FAIL] expected exactly $EXPECT patch(es) in $DIR, found $COUNT" >&2
    exit 1
fi
echo "Patch count OK: $COUNT"
echo

pass=0
fail=0
for p in "${PATCHES[@]}"; do
    name="$(basename "$p")"
    printf '  %-58s ' "$name"
    if out="$(patch --dry-run --batch -p3 -d "$SRC" -i "$p" 2>&1)"; then
        # A hunk applied at an offset or with fuzz still counts as CLEAN here,
        # but surface it so silent drift does not go unnoticed.
        if grep -qiE 'offset|fuzz' <<<"$out"; then
            echo "CLEAN (with offset/fuzz)"
            grep -iE 'offset|fuzz' <<<"$out" | sed 's/^/        /'
        else
            echo "CLEAN"
        fi
        pass=$((pass + 1))
    else
        echo "FAIL"
        sed 's/^/        /' <<<"$out"
        fail=$((fail + 1))
    fi
done

echo
echo "------------------------------------------------------------"
echo "Result: $pass clean, $fail failed (set=$SET, release=$REL)"
echo "------------------------------------------------------------"

if [[ "$fail" -ne 0 ]]; then
    echo
    echo "A failing patch means the Kbase source has drifted from what this"
    echo "set was authored against. Do NOT force or silently port it."
    echo "See patches/PATCHES.md for why each patch is in the set."
    exit 1
fi

echo
echo "[+] All patches in set '$SET' apply cleanly to r56p0."