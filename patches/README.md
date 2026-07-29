# Patches

Everything in this directory diverges from upstream and lives only in this
repo. This file documents what each patch does, why it exists, and how to
maintain it when upstream moves.

There are two groups with different lifetimes:

| Directory | Applied when | Ends up in |
|-----------|--------------|------------|
| `base/` | while building the **base image** (`Dockerfile.offline`, stage 2) | **every** ROM built from this repo |
| `tpm-reset/` | only in the per-variant step of `build-firmware.py --tpm-reset` | **only** the `..._tpmreset.rom` |

`base/` patches are applied to the coreboot tree in lexical order, each with
a mandatory `git apply --check` first. If upstream changes one of the patched
files, the build **aborts with a clear error** instead of silently producing
a ROM without the change - that is deliberate (this repo once used two
`sed -i` calls for the same job, and `sed` exits 0 even when its pattern no
longer matches). After changing anything here, rebuild with `--rebuild-base`.

## base/0001-cfr-expose-power-on-after-fail.patch

**File:** `src/mainboard/lenovo/sklkbl_thinkpad/cfr.c`

Adds `&power_on_after_fail` to the "System" form of the CFR setup menu, so
"Restore AC power after loss" becomes configurable in the EDK2 setup UI.
The option itself already exists upstream in `intelblocks/cfr.h`; the board
just never put it into its menu.

Maintenance note: `intelblocks/cfr.h` declares **two** objects with the same
`opt_name` (`power_on_after_fail` as an enum, `power_on_after_fail_bool` as
a bool) and says "use this option or the one below, but not both". This
patch uses the enum variant; never add the bool variant as well.

## base/0002-t480-default-me-disabled.patch

**File:** `src/mainboard/lenovo/sklkbl_thinkpad/Kconfig`

Adds `select CSE_DEFAULT_CFR_OPTION_STATE_DISABLED` to `BOARD_LENOVO_T480`,
so the Intel ME defaults to *disabled* in the CFR setup menu (the user can
still enable it there).

This replaces an earlier sed that hardcoded `.default_value = 1` in the
shared SoC header `intelblocks/cfr.h`. That was fragile twice over: it
edited a header shared by every Intel SoC board, and the `1` was a magic
number in an enum that upstream defines *inverted* (`{ "Disabled", 1 },
{ "Enabled", 0 }`) - a future re-ordering would have silently flipped the
default to "ME enabled". The Kconfig select is the mechanism the option's
help text itself prescribes, and it would be acceptable upstream.

## base/0010-h8-acpi-stepped-fan-hfsp-field.patch

**Files:** `src/ec/lenovo/h8/Kconfig`, `src/ec/lenovo/h8/acpi/ec.asl`

First of three patches for **stepped fan control**. The EC fan register
(offset 0x2f, "HFSP") supports more than upstream's ASL exposes:

```
 bit  7   EC automatic mode   (0x80 = the EC follows its own fan curve)
 bit  6   disengage           (0x40 = unregulated full speed, no limiter)
 bits 0-2 manual level 0-7    (0 = fan OFF, 7 = fastest regulated level)
```

Upstream maps only bits 6 and 7 (`FAND`/`FANA`), which makes ACPI fan
control binary: EC automatic below the trip point, screaming unregulated
`0x40` above it. This patch adds an opt-in Kconfig symbol `H8_FAN_STEPPED`
(default n) and, behind it:

- a second ASL `Field` over the same byte, mapping it whole as `HFSP`
  (several Fields on one OperationRegion are legal ASL),
- `FANE(1)` now selects level 7 - the fastest **regulated** speed - instead
  of disengage,
- a new method `FANL(level)` to set any level (`0x00`-`0x07`, or `0x80` to
  hand control back to the EC).

Without the symbol the generated ASL is **byte-identical** to upstream
(verified by diffing decompiled DSDTs), so all other H8 ThinkPads
(X220, T430, T60, ...) are untouched.

## base/0011-h8-acpi-stepped-active-cooling.patch

**File:** `src/ec/lenovo/h8/acpi/thermal.asl`

Second fan patch: replaces the one-fan/one-trip-point active cooling of
thermal zone THM0 with a five-level state machine, entirely behind
`#if CONFIG(H8_FAN_STEPPED)` (the old code remains unchanged in the
`#else` branch). It follows the pattern documented in
<https://doc.coreboot.org/drivers/acpi_fan_control.html> and implemented
in `mainboard/samsung/stumpy`:

- `FAN0`..`FAN4` are five `PNP0C0B` fan devices - one physical fan
  presented as five speeds. Each has a PowerResource `FNP0`..`FNP4`.
- `\FLVL` holds the current level; a **lower number means a faster fan**.
- `_AC0`.._AC3` are the trip points with built-in hysteresis: the returned
  temperature depends on whether the level is already active (ON threshold
  to enter, lower OFF threshold to leave).
- `_INI` starts at level 4, the resting state.

Two properties are load-bearing; keep them when touching this file:

1. **Level 4 rests at HFSP `0x80` (EC automatic), never `0x00`.** Writing a
   manual level disables the EC's own fan curve; `0x00` would mean "fan off
   and no safety net". `0x80` keeps the EC curve alive as a fallback while
   ACPI is at rest.
2. **`FNP4._OFF` is a deliberate no-op.** ACPI requires that `_STA` can
   reach 0 after `_OFF`; level 4 is the lowest state, there is nothing
   below it. Linux forgives a violation - Windows disables the whole
   thermal zone.

The `FANx_HFSP`/`FANx_THRESHOLD_*` values come from the selecting board's
`<variant/thermal.h>` (patch 0012); the `#ifndef` fallbacks in the file
only keep it compilable on its own.

## base/0012-t480-stepped-fan-thresholds.patch

**Files:** `src/mainboard/lenovo/sklkbl_thinkpad/Kconfig`,
`.../acpi/ec.asl`,
`.../variants/t480/include/variant/thermal.h` (new)

Third fan patch: `select H8_FAN_STEPPED` for the **T480 only** (T470s,
T480s, T580, X280 stay on upstream behaviour - they are untested) and the
actual fan curve:

| Level | HFSP | on at | off at | audible |
|-------|------|-------|--------|---------|
| 4 | `0x80` | - | - | EC automatic, mostly silent |
| 3 | `0x02` | 58 C | 50 C | soft hum |
| 2 | `0x04` | 68 C | 60 C | audible |
| 1 | `0x06` | 76 C | 68 C | clearly audible |
| 0 | `0x07` | 85 C | 77 C | loud, but still regulated |

`\TPSV` (90 C, passive throttling) and `\TCRT` (100 C, critical shutdown)
are untouched - they are the safety net above the curve, not part of it.

**Tuning:** edit the values in the `thermal.h` hunk of this patch, rebuild
with `--rebuild-base`, reflash. Keep each ON above its OFF (hysteresis),
keep the order monotonic, and keep everything well below `\TCRT`.

Verified on a 20L5: full CPU load levels out at 75-78 C on level 1,
the hysteresis steps back down cleanly after the load ends, and the old
unregulated "disengaged" mode no longer occurs at all.

## base/0020-cfr-fan-profile-option.patch

**Files:** `src/mainboard/lenovo/sklkbl_thinkpad/cfr.c`, `.../ramstage.c`,
`.../variants/t480/include/variant/thermal.h`,
`src/ec/lenovo/h8/acpi/thermal.asl`

Makes the fan curve switchable in the EDK2 setup menu ("Embedded
Controller" form) without rebuilding. Four profiles:

| # | Profile | Idea | _AC0.._AC3 ON thresholds |
|---|---------|------|--------------------------|
| 0 | Quiet | quieter, runs hotter | 88 / 80 / 72 / 64 C |
| 1 | Balanced (default) | the verified curve from 0012 | 85 / 76 / 68 / 58 C |
| 2 | Performance | louder, runs cooler | 78 / 68 / 58 / 48 C |
| 3 | EC only | firmware keeps its hands off the fan | 96 / 95 / 94 / 93 C |

The chain: the setup menu stores `fan_profile` in the SMMSTORE; on boot
the ramstage reads it (`get_uint_option`) and publishes it as `\FPRO` in
an SSDT; the thermal zone's `_ACx` methods look their trip points up in a
per-profile package (`FTBL`) indexed by `\FPRO`, with the same 8 K
hysteresis as before. Because the SSDT is generated at boot, **a profile
change applies on the next reboot** - which is how leaving a firmware
setup menu works anyway.

Three details that must survive future edits:

1. **The SSDT hook is chained.** `mainboard_enable()` used to assign
   `ssdt_add_dgpu` directly; the new `mainboard_fill_ssdt()` calls it
   *and* writes `\FPRO`. Assigning either one directly again would
   silently drop the other (no dGPU in ACPI, or a dead profile option).
2. **`\FPRO` is double-guarded:** clamped to 0..3 in C, and in ASL
   `CondRefOf` covers a missing SSDT entry while a `> 3` check covers
   garbage - an out-of-range `Index()` into the package would hang the
   thermal zone.
3. **"EC only" does not disable the trips.** All four sit 1 K staggered
   just below `\TCRT` (100 C): in practice the EC curve rules alone
   (the mode for `thinkfan`/`zcfan` users), but if the EC curve ever
   fails there is still an ACPI escalation before the critical shutdown.
   Setting the trips above `_CRT` or removing them would delete that
   last net - don't.

## base/0030-t480-lenovo-bios-version-for-thinkpad_acpi.patch

**File:** `src/mainboard/lenovo/sklkbl_thinkpad/ramstage.c`

Makes `thinkpad_acpi` load without `force_load=1`. The driver's probe
(`tpacpi_parse_fw_id`) requires the SMBIOS **BIOS version** to parse as a
Lenovo firmware ID (`xxxyTkkW`, e.g. `N24ET65W`) and gives up before even
reading the product version - coreboot's build id (`5cbf8afc-dirty`)
fails that at the first lowercase letter. The board now reports
`N24ET99W (1.99 )` for the T480: the stock scheme with a release above
every real one, so no tool ever flags the firmware as outdated. coreboot
stays identifiable through the SMBIOS BIOS *vendor* string.

Note: `CONFIG_MAINBOARD_VERSION="ThinkPad T480"` in `config/defconfig` is
the second half of this fix (the driver checks the product version right
after the firmware ID) - keep both.

## tpm-reset/tpm2-clear-on-boot.patch

Adds a ramstage hook that clears the discrete TPM 2.0 via `TPM2_Clear`
(platform hierarchy) **on every boot**. Only ever applied to the separate
`..._tpmreset.rom` built by `--tpm-reset`; the normal ROM never contains
it, which the build verifies (`nm`/`strings`). Usage and warnings: see
"TPM reset" in the top-level README.

## When upstream breaks a patch

The base-image build stops with `ERROR: <patch> does not apply`. To rebase:

```bash
./fetch.sh <mode>                            # fresh tree in sources/<mode>/coreboot
cd sources/<mode>/coreboot
for p in ../../../patches/base/*.patch; do git apply --check "$p" && git apply "$p" || echo "FAILS: $p"; done
# fix the failing change by hand, then re-export it:
git diff -- <files of that patch> > ../../../patches/base/<same-name>.patch
```

Keep the numbering (0001/0002 = setup menu, 0010+ = fan) - the patches are
applied in lexical order and 0012 builds on top of 0002's Kconfig context.
