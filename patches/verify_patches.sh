#!/usr/bin/env bash
# ============================================================
# verify_patches.sh
#
# Presence + provenance check for both patch sets. This does NOT
# test applicability -- use verify_against_kbase.sh for that.
#
#   patches/        Arm's six VP patches, verbatim (r54p0 reference)
#   patches/r56p0/  derived port actually applied for r56p0
# ============================================================
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$ROOT/patches"
R56="$P/r56p0"
ARCHIVE="$ROOT/driver/AX504X08X-SW-99002-r56p0-18eac0.tar.gz"

fail=0
note() { printf '%s\n' "$*"; }
bad()  { echo "[FAIL] $*"; fail=1; }

# ---- Set 1: Arm's six, verbatim -------------------------------------------
note '[+] Arm VP patch set (verbatim, r54p0 reference):'
arm_count="$(find "$P" -maxdepth 1 -name '*.patch' | wc -l)"
if [[ "$arm_count" -eq 6 ]]; then
    find "$P" -maxdepth 1 -name '*.patch' -printf '  %f\n' | sort
else
    bad "expected 6 Arm patches in $P, found $arm_count"
fi

# ---- Set 2: the r56p0 port -------------------------------------------------
note ''
note '[+] r56p0 port set (applied by build_driver.sh by default):'
r56_count="$(find "$R56" -maxdepth 1 -name '*.patch' 2>/dev/null | wc -l)"
if [[ "$r56_count" -eq 3 ]]; then
    find "$R56" -maxdepth 1 -name '*.patch' -printf '  %f\n' | sort
else
    bad "expected 3 patches in $R56, found $r56_count"
fi

# ---- Provenance: the port must stay traceable to Arm ----------------------
note ''
note '[+] Provenance:'
SRC_PATCH="$P/0004-Workaround-no-definition-of-dmb-in-non-Arm-platforms.patch"
DST_PATCH="$R56/0002-Fix-no-definition-of-dmb-in-non-Arm-platforms.patch"
if [[ -f "$SRC_PATCH" && -f "$DST_PATCH" ]]; then
    if cmp -s "$SRC_PATCH" "$DST_PATCH"; then
        note '  dmb shim is byte-identical to Arm 0004 (cmp OK)'
    else
        bad 'r56p0 dmb patch has diverged from Arm 0004 (cmp differs)'
    fi
else
    bad 'dmb patch missing from one of the two sets'
fi

note '  r56p0 arch_timer patch is locally authored; see its header for scope'

# ---- Archive fingerprint --------------------------------------------------
if [[ -f "$ARCHIVE" ]]; then
    note ''
    note '[+] Source archive:'
    sha256sum "$ARCHIVE" | sed 's/^/  /'
else
    bad "r56p0 archive missing: $ARCHIVE"
fi

note ''
if [[ "$fail" -ne 0 ]]; then
    echo '[!] Patch set verification FAILED.'
    exit 1
fi

note '[+] Both patch sets present and provenance intact.'
note '[!] Applicability is checked by patches/verify_against_kbase.sh (fast, no'
note '    kernel build) and gated by build_driver.sh (dry-run, then apply).'
note '[!] Patches are never force-applied or silently ported.'