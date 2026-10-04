# Mali r56p0 x86_64 external-driver research kit

Canonical workspace:
`/workspaces/x86_kernel/mali-r56p0-x86-full`

This kit separates Linux kernel builds from the Mali r56p0 Kbase build.

## Start

```bash
./init_.sh
source ./workspace.env
./kernel/build_kernel.sh 6.18.55
./patches/verify_patches.sh
./patches/verify_against_kbase.sh
./driver/build_driver.sh --kernel 6.18.55
```

## Driver builder

`driver/build_driver.sh` extracts the exact included `AX504X08X-SW-99002-r56p0-18eac0.tar.gz`, verifies r56p0, creates a private integration copy of the selected Linux source, configures the x86 Simulated Platform/No-Mali/CSF settings, then dry-runs every patch in the selected set. It **stops** if any patch fails to apply; it does not force or silently port a patch.

## Patch sets

Two sets, not alternatives:

- `patches/` — Arm's six VP patches, byte-for-byte verbatim, kept as the provenance record. Arm documents these as clean for r54p0. They do **not** apply to r56p0 (1 of 6 dry-runs clean).
- `patches/r56p0/` — the derived port actually applied, 3 patches. Applied by default.

Select with `--patch-set r56p0|arm`. The choice is recorded in `build-info.txt` and covered by `SHA256SUMS`.

`patches/verify_against_kbase.sh` checks a set against the real r56p0 tree in seconds, with no kernel build — the fast feedback loop. It dry-runs every patch, then re-scans the patched tree's Kconfig `source` statements, because "applies cleanly" does not imply "configurable": r56p0 ships a `Kconfig` that sources an `arbitration/` directory absent from the release, which kills `olddefconfig` even when every patch applies. See `patches/PATCHES.md` for why each patch is or is not in the r56p0 set.

The original kernel source under `kernel/<version>/src/` is never modified by the driver builder.

## Output

```text
driver/artifacts/r56p0-18eac0/linux-6.18.55/
├── mali_kbase.ko
├── kernel-config
├── mali-release.txt
├── build-info.txt
└── SHA256SUMS
```

## QEMU/GDB

```bash
./rootfs/build_rootfs.sh
./qemu/boot_kernel_gdb.sh 6.18.55
```

In another terminal:

```bash
gdb kernel/6.18.55/artifacts/vmlinux
target remote :1234
```

## Important

The included six VP patches are the supplied Arm patch set. Existing research notes identify them as clean for r54p0 and explicitly caution that applicability is not automatic for other Kbase releases. This kit therefore treats successful r56p0 dry-run as a required gate.

That caution has now been measured: on r56p0-18eac0 only 1 of Arm's six dry-runs clean. Five are redundant (already fixed upstream), moot, or target files this configuration never compiles. Separately, r56p0 itself has a bug Arm's set does not address: `drivers/gpu/arm/Kconfig` sources an `arbitration/Kconfig` that the release does not ship, which breaks `olddefconfig` regardless of patching. The reduction, that bug, and the justification for each patch are recorded in `patches/PATCHES.md`, and the gate still refuses to proceed on any failure.

Because the driver is an external module, the kernel must also export every symbol the driver imports — so `build_kernel.sh` enables the driver's prerequisites (`CONFIG_COMMON_CLK`, `CONFIG_PM_OPP`, `CONFIG_PM_DEVFREQ`, `CONFIG_DEVFREQ_THERMAL`) without enabling Mali itself, then asserts they survived `olddefconfig`. Note the devfreq option is `PM_DEVFREQ`, not `DEVFREQ`; it was renamed in 6.13. The full symbol-to-option mapping, and the fact that modpost reads `Module.symvers` from the kernel build tree rather than the module directory, are documented in `patches/PATCHES.md`.
