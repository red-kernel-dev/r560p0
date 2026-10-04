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
0003-r56p0-drop-stale-arbitration-Kconfig-source.patch     locally authored
```

### 0003 — an upstream r56p0 Kconfig bug

`drivers/gpu/arm/Kconfig:25` unconditionally sources
`$(MALI_KCONFIG_EXT_PREFIX)drivers/gpu/arm/arbitration/Kconfig`, but
`drivers/gpu/arm/` contains only `midgard/` — there is no `arbitration/`
directory anywhere in the release, and `CONFIG_MALI_HAS_VIRTUALIZATION` is
referenced neither in any Kbuild nor in any Kconfig.
`MALI_KCONFIG_EXT_PREFIX` is never assigned in this release, so it expands to
nothing. The result is a hard failure at the *first* `olddefconfig`, before any
patching is reached:

```
drivers/gpu/arm/Kconfig:25: can't open file "drivers/gpu/arm/arbitration/Kconfig"
make[3]: *** [.../scripts/kconfig/Makefile:85: olddefconfig] Error 1
```

Arm's 0006 does **not** help here, for two independent reasons: the r56p0 Kbuild
contains no arbitration reference for it to guard, and 0006 never touched the
Kconfig — which is the thing that actually breaks.

Guarding the `source` line is safe because nothing in the release defines or
consumes the arbitration symbols. Arm's own Virtual Platform How-To Guide
(Troubleshooting) confirms the arbitration reference code is optional: *"in most
cases the Arbitration code is not required, such as in testing systems where only
a single Guest OS is using the GPU."*

`midgard/Mconfig:338` has the same stale reference, but Mconfig is meson-only
and this kit builds with kbuild, so it is left alone and reported as ignored.

**Consequence for ordering:** because this bug lives in a Kconfig file, the
driver builder applies patches *before* resolving the kernel config. Applying
them afterwards cannot work — `olddefconfig` never gets to run.

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

`verify_against_kbase.sh` does more than dry-run. "All patches apply cleanly" is
**not** sufficient — patch 0003 exists precisely because the whole set applied
cleanly to a tree that could not be configured. So after applying the set to a
scratch copy it re-scans every `source` statement in the kbuild Kconfig files
and fails if any referenced file is still missing. Stale `Mconfig` references are
reported as informational, since this kit uses kbuild.

That scan deliberately models a counter-intuitive kconfig behaviour: a sourced
file is included **even inside a false `#if 0` block**. Only a `#` comment
actually disables a `source` line. Confirmed empirically against 6.18.55, where
the `#if 0` variant of patch 0003 still failed with the original error. So the
check drops comment lines and treats every remaining `source` as live.

`build_driver.sh` then gates the real build: it applies the selected set
**before** the first `olddefconfig`, and **stops** if any patch fails. It never
forces and never silently ports a patch.

```bash
./driver/build_driver.sh --kernel 6.18.55                  # r56p0 set
./driver/build_driver.sh --kernel 6.18.55 --patch-set arm  # Arm's six
```

The chosen set is recorded in `build-info.txt` and covered by `SHA256SUMS`.

## The kernel must export the driver's symbols

The driver is an **external module**, but it links against the exports of the
kernel that `build_kernel.sh` produced. `modules_prepare` compiles it; it does
not link it. So every symbol the driver imports must already be built into
`vmlinux`, and three consequences follow — all three were hit in practice.

**1. The kernel needs the driver's prerequisites even though the driver is
absent from it.** The first complete compile of r56p0 failed at MODPOST with 16
undefined symbols, from four subsystems that kernel had never been built with:

| Symbol(s) | Defined in | Required kernel option |
|---|---|---|
| `__clk_is_enabled` | `drivers/clk/clk.c` | `CONFIG_COMMON_CLK` |
| `devfreq_add_device`, `devfreq_suspend_device`, `devfreq_resume_device`, `devfreq_register_opp_notifier`, `devfreq_unregister_opp_notifier`, `devfreq_recommended_opp`, `devfreq_remove_device` | `drivers/devfreq/devfreq.c` | `CONFIG_PM_DEVFREQ` |
| `dev_pm_opp_find_freq_ceil`, `dev_pm_opp_find_freq_exact`, `dev_pm_opp_find_freq_floor`, `dev_pm_opp_get_opp_count`, `dev_pm_opp_get_voltage`, `dev_pm_opp_put` | `drivers/opp/core.c` | `CONFIG_PM_OPP` |
| `devfreq_cooling_em_register`, `devfreq_cooling_unregister` | `drivers/thermal/devfreq_cooling.c` | `CONFIG_DEVFREQ_THERMAL` |

Two naming traps. The devfreq option is **`PM_DEVFREQ`**, not `DEVFREQ` — it was
renamed in 6.13, and the old name is silently ignored. And `DEVFREQ_THERMAL` is
gated by `thermal_sys-$(CONFIG_DEVFREQ_THERMAL)` in `drivers/thermal/Makefile`;
there is no `DEVFREQ_COOLING` symbol any more. `PM_DEVFREQ` is a `menuconfig`
that `select`s `PM_OPP`, and `DEVFREQ_THERMAL` depends on both.

`build_kernel.sh` enables all four and then **asserts** they survived
`olddefconfig`, because `scripts/config` only edits text: a request for a
symbol that does not exist, or whose dependencies are unmet, is discarded
without complaint, and the cost of learning that is a failed driver link hours
later. Enabling these four does not weaken the debug configuration — KASAN,
KASAN_GENERIC, UBSAN, KCOV, DWARF5, `RANDOMIZE_BASE=n` and `MODVERSIONS=n` are
all unaffected, so Arm's deviation rules still hold.

**2. `Module.symvers` must be placed where modpost looks for it.** For an
external module the kernel Makefile sets `objtree` to the *kernel* build tree
(Makefile:186) and `scripts/Makefile.modpost` reads
`$(objtree)/Module.symvers` from there — not from the module's own directory.
`modules_prepare` never produces it, so modpost loads no exported-symbol table
at all and reports even core symbols — `jiffies_to_msecs`, `current_task`,
`_raw_spin_trylock` — as undefined. `build_driver.sh` copies in the one the
completed kernel build produced. This is needed whether or not
`CONFIG_MODVERSIONS=y`: MODVERSIONS only adds CRCs, the symbol table itself is
always required.

**3. Patches must be applied before the first `olddefconfig`.** Arm's ordering
configures the kernel first and applies patches afterwards. That cannot work
here, because the r56p0 Kconfig bug in patch 0003 kills `olddefconfig` outright
— the builder never reaches the patch stage. The builder now applies the set
before resolving the config, matching the order in Arm's own guide.