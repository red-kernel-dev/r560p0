# Arm GPU Bug Bounty — configuration compliance

How this kit relates to the [Arm GPU Bug Bounty program](https://app.intigriti.com/programs/arm/arm/detail),
what it can and cannot test, and how `build_kernel.sh --conformant` implements Arm's
configuration rules.

Sources, all shipped in `bounty_programe/`:

| Document | Version | Used for |
|---|---|---|
| Device Configuration Guidelines | 20250623-1.0 | the config rules below |
| GPU Bug Bounty FAQ | 20250623-1.0 | scope limits of the dummy model |
| GPU Bug Bounty How-To Guide | — | reporting expectations |
| GPU Virtual Platform How-To Guide | — | the virtual-platform setup |

## Scope

The programme covers two things:

- **Firmware:** Mali Command Stream Frontend (CSF) Firmware, `CSFFW`
- **Software:** Mali GPU Kernel Driver, `Kbase`

Bounty range $500–$20,000 USD.

## What this kit is, and what it is not

This kit builds Kbase as an **external module** on a **Virtual Platform** using the
**dummy model** (`CONFIG_MALI_NO_MALI=y`) on **x86_64**.

That approach is explicitly sanctioned. The Virtual Platform How-To Guide states:

> The "Simulated Platform Device" configuration can be used for Workstation Virtual
> Platforms (which include x86 systems), where there is no "Device Tree" present.

and points x86 users at `patches_for_virtual_device.zip` — the very patch set ported
in `patches/r56p0/`. The dummy model is Arm's own "No Mali" configuration for this
purpose. The programme also recommends a virtual environment for new setups:

> If you are configuring a new virtual environment for testing, we recommend you
> always use the latest Android Common Kernel or the latest Linux Kernel stable or
> longterm release before testing.

### What the dummy model cannot reach

From the FAQ:

> The limitation is that it cannot be used to test the system where a vulnerability
> involves the GPU or GPU Firmware making reads, writes, or executing instructions.

From the Virtual Platform guide:

> "dummy model" configuration does not attempt to request or execute the GPU Firmware,
> therefore testing against a Virtual Platform is limited to the GPU driver
> ("GPUSoftware") and you will be unable to test against the Firmware or Hardware.

Consequences, both hard limits:

1. **CSFFW cannot be tested at all here.** Half the programme's scope is unreachable.
2. **GPU and firmware memory-access bugs cannot be tested here.** The dummy model
   replaces real register access with instantaneous no-ops against a model, and the
   GPU firmware is never executed.

No `/dev/mali*` node is registered under the dummy model, so there is also no
userspace ioctl surface to exercise without additional work.

**So: use this kit to find candidate bugs in Kbase driver logic. Do not treat a
finding here as a report.**

## The configuration rules

The Device Configuration Guidelines say:

> Where possible, the default Kernel configuration should be used. Only the following
> Kernel Build KConfig options may be changed, providing it still results in a valid
> kernel config and the options are compatible with each other

| Permitted | Constraint |
|---|---|
| `CONFIG_COMPAT` | may be set `y` |
| `CONFIG_ARM64_4K_PAGES` **or** `CONFIG_ARM64_16K_PAGES` | exactly one `y`, the other `n` |
| any `CONFIG_KASAN*` | `y` or `n`, except `CONFIG_KASAN_*_TEST` must be `n` |
| any `CONFIG_UBSAN*` | `y` or `n`, except `CONFIG_TEST_UBSAN` must be `n` |

Plus:

> the Arm Mali Kernel Driver only supports 64-bit kernels

Two further points from the guidelines worth noting, since they constrain what a
report may claim:

> Vulnerabilities due to missing backports/patches or vendor-specific customizations
> are not in scope for Arm's bug bounty program.

> Arm strongly recommends you report these to the relevant OEM instead.

## Two build modes

`build_kernel.sh` has two modes. They exist because the needs conflict: finding a
bug wants instrumentation and reproducibility; confirming one wants the plainest
possible configuration.

| | development (default) | `--conformant` |
|---|---|---|
| KASAN / UBSAN | on | on — **permitted** |
| `KCOV` | on | off |
| `DEBUG_INFO_DWARF5` | on | off (`DEBUG_INFO_NONE`) |
| `GDB_SCRIPTS`, `KALLSYMS_ALL` | on | off |
| `SLUB_DEBUG_ON` | on | off |
| `RANDOMIZE_BASE` | **off** | **on** (default) |
| QEMU `nokaslr` | used | **must not** be used |
| purpose | find and debug bugs | substantiate a finding |

```bash
./kernel/build_kernel.sh 6.18.55 --conformant            # submission-shaped kernel
./kernel/build_kernel.sh 6.18.55 --config-only           # validate a config in seconds
./kernel/build_kernel.sh 6.18.55 --conformant --config-only
```

Each mode uses its own `O=` directory (`build/` vs `build-conformant/`) so the two
configs coexist. Changing `.config` invalidates `include/generated/autoconf.h` and
forces a near-total rebuild, so sharing one directory would mean rebuilding from
scratch on every switch.

**Disk:** a compiled build is ~4.3G, so holding *both* compiled needs ~8.6G. A
`--config-only` run costs ~1.4M, so keeping both configs and compiling one at a time
is cheap.

**Trade-off:** `--conformant` sets `DEBUG_INFO_NONE`, so the conformant `vmlinux`
has no debug info and cannot be symbolicated in GDB. That is deliberate — it is the
point of the mode. Debug with the development build, confirm with the conformant one.

## What the compliance check actually verifies

`--conformant` does not merely skip the development options; it **audits the result
by measurement**:

1. **Hard prohibitions** — `CONFIG_KASAN_*_TEST` and `CONFIG_TEST_UBSAN` must be `n`.
   Violations fail the build.
2. **64-bit** — `CONFIG_64BIT=y` must hold. Violation fails the build.
3. **Diff against the resolved default** — it generates a real default config and
   compares, rather than trusting reasoning about which options a defconfig implies.

Point 3 matters more than it looks. Two traps that a hand-written list gets wrong:

- Comparing against `arch/x86/configs/x86_64_defconfig` **as text** is misleading.
  `DEBUG_FS`, `STACKTRACE` and `SLUB_DEBUG` never appear in it literally, yet they
  are in the *resolved* default because `olddefconfig` pulls them in as dependencies.
  Concluding they "leaked in" from a text grep is wrong.
- A raw diff is mostly noise. Enabling `COMMON_CLK` and `PM_DEVFREQ` makes their
  sub-options *visible*, so ~27 symbols go from absent to an explicit `=n` with
  nothing actually changing. The audit therefore counts only symbols that became
  **enabled** (`=y`/`=m`).

Measured result for this kit:

```
vs resolved defconfig     23 newly enabled, 27 newly visible-but-off, 8 cleared
```

Of the 23, all are accounted for: `KASAN*`/`UBSAN*`/`COMPAT` (permitted), the five
driver prerequisites (declared below), and nine that are genuine dependencies:

| Symbol | Pulled in by |
|---|---|
| `CC_HAS_KASAN_MEMINTRINSIC_PREFIX`, `CC_HAS_UBSAN_BOUNDS_STRICT` | implied by KASAN/UBSAN |
| `CONSTRUCTORS`, `SLUB_RCU_DEBUG`, `STACKDEPOT_ALWAYS_INIT` | `select`ed by `lib/Kconfig.kasan` |
| `HAVE_CLK`, `HAVE_CLK_PREPARE`, `PM_CLK`, `GENERIC_CSUM` | the driver prerequisites |

These are reviewable rather than violations — Arm permits the listed options to be
used together — but they are printed because *"it is only a dependency"* is a claim
worth checking rather than assuming.

## Declared deviation: the driver prerequisites

Five options are applied in **both** modes, and are a genuine deviation:

`CONFIG_COMMON_CLK`, `CONFIG_PM_OPP`, `CONFIG_PM_DEVFREQ`, `CONFIG_DEVFREQ_THERMAL`,
`CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND`

They are unavoidable in this architecture. The driver is an external module that
links against this kernel's exports, so every symbol it imports must be built into
`vmlinux`. Without these five it compiles and then fails at MODPOST with 16
undefined symbols, which means no finding is reachable at all. See
`patches/PATCHES.md` for the full symbol-to-option mapping.

## Open questions for Arm

Two points where the documents are in tension, or silent. Both are worth confirming
before relying on this setup for a submission.

1. **Can a Virtual Platform device satisfy "a device that conforms to the
   configuration guidelines"?** The permitted-deviation list only enumerates ARM64
   page-size options, which raises doubt about an x86_64 host at all. If a VP device
   can conform, what is the conformant x86 base config?
2. **Are findings from the dummy model accepted for driver-only bugs?** The VP guide
   is bounty-supplied, implying yes, but it also states outright that testing against
   a VP is limited to `GPUSoftware`. The Configuration Guidelines are stricter than
   the VP guide on this point.

## Before submitting anything

1. Find the bug on the development build, with KASAN/UBSAN and debug info.
2. Rebuild with `--conformant` and boot it **without** `nokaslr`.
3. Reproduce the finding on that kernel. If it does not reproduce, the finding was an
   artefact of the development configuration — most likely of `RANDOMIZE_BASE=off` or
   `SLUB_DEBUG_ON`.
4. Re-verify on an arm64 device with a conformant config if the bug involves GPU or
   firmware memory access, since the dummy model cannot reach those paths.
5. Check the finding is not merely a missing backport or a vendor customization —
   both are explicitly out of scope.
6. Confirm the Kbase version matches a current release; vulnerabilities in
   unsupported or unpatched-down versions may be rejected.