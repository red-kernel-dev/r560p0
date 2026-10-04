# Patch sets

Two sets live here. They are not alternatives to each other — one is the
upstream reference, the other is what actually gets applied.

## Set 1 — `patches/` (Arm's six, verbatim)

Byte-for-byte from Arm's `patches_for_virtual_device.zip`, kept unmodified as
the provenance record. Arm documents this set as clean for **r54p0**.

```
0001-mali-fix-build-error-for-CONFIG_OF-n-for-4.1-kernels.patch
0002-Fix-x86-build-error-for-missing-asm-arch_timer.h.patch
0003-Workaround-arch_timer-funcs-undefined-for-NO_MALI.patch
0004-Workaround-no-definition-of-dmb-in-non-Arm-platforms.patch
0005-Fix-unused-function-warnings.patch
0006-Fix-make-clean-when-no-arbitration-code-present.patch
```

These are **not** applied to r56p0. See the table below.

## Set 2 — `patches/r56p0/` (derived port, applied by default)

```
0001-r56p0-guard-arch_timer-for-non-Arm.patch              locally authored
0002-Fix-no-definition-of-dmb-in-non-Arm-platforms.patch  Arm 0004, byte-identical
```

## Why the port exists

Measured against `AX504X08X-SW-99002-r56p0-18eac0.tar.gz`
(`MALI_RELEASE_NAME ?= '"r56p0-18eac0"'`, `Kbuild:75`), Arm's six score
**1 clean / 5 failed** at `patch -p3 --dry-run --batch`. Reproduce with:

```bash
./patches/verify_against_kbase.sh arm     # exits 1, shows per-patch failures
```

Each failure has a specific reason, and only one of them means real work:

| Arm patch | Status on r56p0 | Reason | Action |
|---|---|---|---|
| 0001 `CONFIG_OF=n` | already fixed upstream | r56p0 added `&& defined(CONFIG_OF)` beneath the same `KERNEL_VERSION(4,15,0)` guard (`version_compat_defs.h:566`), so the conflicting definition cannot occur when `CONFIG_OF=n` | dropped |
| 0002 `asm/arch_timer.h` | partly needed | 4 of 6 files fine; `mali_kbase_time.c:31` is genuinely unguarded and fails only on blank-line context drift | ported |
| 0003 `arch_timer` funcs | partly needed | `mali_hw_access.h` hunk applies at offset −2; `clk_rate_trace.c` was refactored to `kbase_arch_timer_get_cntfrq(kbdev)` and gained an `xlnx,versal` check | ported |
| 0004 `dmb()` | clean | `dmb(osh)` still present at `mali_kbase_csf.c:875,917,3641` | kept verbatim |
| 0005 unused functions | already applied | guards already present at `mali_kbase_devfreq.c:350/536` and `mali_kbase_device.c:130/204` | dropped |
| 0006 `make clean` | moot | r56p0's `Kbuild` contains no `arbitration` reference at all | dropped |

The `arch_timer` port touches only the three files actually compiled under
`CONFIG_MALI_PLATFORM_NAME="vexpress"` + `CONFIG_MALI_NO_MALI=y` +
`CONFIG_MALI_CSF_SUPPORT=y`:

| File | Compiled? | Why |
|---|---|---|
| `include/linux/mali_hw_access.h` | yes | include + `mali_arch_timer_get_cntfrq()` macro |
| `backend/gpu/mali_kbase_time.c` | yes | unguarded include |
| `csf/mali_kbase_csf_firmware_no_mali.c` | yes | `csf/Kbuild:51`, the `NO_MALI` branch |
| `csf/mali_kbase_csf_firmware.c` | no | `csf/Kbuild:54`, the real-HW branch |
| `platform/devicetree/mali_kbase_clk_rate_trace.c` | no | `Kbuild:204` includes `platform/$(MALI_PLATFORM_DIR)/Kbuild`; `platform/vexpress/Kbuild` builds only `mali_kbase_config_vexpress.o` and `mali_kbase_platform_fake.o` |
| `backend/gpu/mali_kbase_model_dummy.c` | yes | but already `#ifdef CONFIG_ARM64` in r56p0 |

The port also includes `<linux/time64.h>` explicitly for `USEC_PER_SEC`, which
Arm's 0003 relied on getting transitively — only ever tested against r54p0.

Note the substituted frequency is a fiction on x86: there is no Arm system
timer, and under `NO_MALI` + vexpress no real clock is registered at all
(Arm's own expected `dmesg` reads *"Clock not available for devfreq"*). The
value only feeds devfreq / `GPU_ACTIVE` normalisation arithmetic. It is not a
bug.

## Verifying

```bash
./patches/verify_patches.sh              # presence + provenance, both sets
./patches/verify_against_kbase.sh        # dry-run r56p0 set, seconds, no kernel
./patches/verify_against_kbase.sh arm    # dry-run Arm's six (expected: 1/6)
```

`build_driver.sh` then gates the real build: it dry-runs every patch in the
selected set, and **stops** if any fails. It never forces and never silently
ports a patch.

```bash
./driver/build_driver.sh --kernel 6.18.55                  # r56p0 set
./driver/build_driver.sh --kernel 6.18.55 --patch-set arm  # Arm's six
```

The chosen set is recorded in `build-info.txt` and covered by `SHA256SUMS`.