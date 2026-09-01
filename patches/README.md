# Patches

Everything in this directory diverges from upstream and lives only in this
repo. This file documents what each patch does, why it exists, and how to
maintain it when upstream moves.

There are four groups with different lifetimes:

| Directory | Applied to | Applied when | Ends up in |
|-----------|------------|--------------|------------|
| `base/` | coreboot | while building the **base image** (`Dockerfile.offline`, stage 2) | **every** ROM built from this repo |
| `edk2/` | the MrChromebox EDK2 payload | same stage, right after `base/` | **every** ROM built from this repo |
| `tpm-reset/` | coreboot | only in the per-variant step of `build-firmware.py --tpm-reset` | **only** the `..._tpmreset.rom` |
| `regression/` | nothing | never | nothing |

`regression/` is a graveyard: patches that were built, measured and found to
make things worse. Nothing globs it, `config_hash()` does not cover it. They
stay because the measurement behind them is worth keeping, and because the
next person to have the same idea should find the answer before spending a
day on it. Move one back into `base/` only with a new measurement.

`base/` and `edk2/` patches are applied in lexical order, each with a
mandatory `git apply --check` first. If upstream changes one of the patched
files, the build **aborts with a clear error** instead of silently producing
a ROM without the change - that is deliberate (this repo once used two
`sed -i` calls for the same job, and `sed` exits 0 even when its pattern no
longer matches). After changing anything here, rebuild with `--rebuild-base`;
`config_hash()` covers both directories, so an edited patch is noticed.

Generate a new patch against the tree with the earlier ones already applied,
not against pristine coreboot. Several of these touch the same files - 0033
and 0036 both edit `ec/lenovo/h8/cfr.h` a few lines apart - and a patch cut
from the untouched tree carries context that no longer exists by the time it
runs. `git worktree add` on `sources/coreboot`, apply everything up to the
new patch, edit there, diff.

The two are separate because they track different upstreams on different
release cycles. `edk2/` applies to the tree at
`payloads/external/edk2/workspace/mrchromebox`, which is the clone named in
`config/versions.lock`, not coreboot's. Patches against EDK2 submodules do
not work this way - `git apply` there would have to run inside the submodule,
and nothing does that.

Either directory may be absent - git does not track empty ones - and
the loop skips it.

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

Three properties are load-bearing; keep them when touching this file:

1. **Level 4 rests at HFSP `0x80` (EC automatic), never `0x00`.** Writing a
   manual level disables the EC's own fan curve; `0x00` would mean "fan off
   and no safety net". `0x80` keeps the EC curve alive as a fallback while
   ACPI is at rest.
2. **`FNP4._OFF` is a deliberate no-op.** ACPI requires that `_STA` can
   reach 0 after `_OFF`; level 4 is the lowest state, there is nothing
   below it. Linux forgives a violation - Windows disables the whole
   thermal zone.
3. **`_INI` sets `\FLVL` and nothing else.** It runs before the OS
   attaches its EmbeddedControl handler, so an EC access there aborts the
   method (`AE_NOT_EXIST` at every boot, issue #1). The write would be a
   no-op anyway: the ramstage leaves the fan register at `0x80`
   (`H8_FAN_CONTROL_AUTO`, `h8.c`) on every boot, which is level 4.

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

| Level | HFSP | on at | off at | measured RPM | audible |
|-------|------|-------|--------|--------------|---------|
| 4 | `0x80` | - | - | 0 cold, ~2870 after load | EC automatic, mostly silent |
| 3 | `0x02` | 54 C | 46 C | 2866 | soft hum |
| 2 | `0x04` | 64 C | 56 C | 3155 | audible |
| 1 | `0x05` | 72 C | 64 C | 3573 | clearly audible |
| 0 | `0x07` | 80 C | 72 C | 3994 | loud, but still regulated |

`\TPSV` (90 C, passive throttling) is untouched. `\TCRT` moves from 100
to 110: 100 is exactly the CPU's throttle point, so while thermal
management works the EC sensor cannot exceed it - the trip did nothing
until a sustained all-core build outran the fan escalation (the zone is
polled every 10 s, and the top step used to engage at 85 C only), and
then it answered a temperature the silicon handles by throttling with a
hardware-protection poweroff (2026-08-26). At 110 it fires only when
throttling itself has failed, which is what `_CRT` is for. The ON
thresholds moved down 5-7 K for the same incident: the top step has to
be at full speed before the passive trip, not racing it.

**Tuning:** edit the values in the `thermal.h` hunk of this patch, rebuild
with `--rebuild-base`, reflash. Keep each ON above its OFF (hysteresis),
keep the order monotonic, and keep everything well below `\TPSV`.

**Why level 1 is `0x05` and not `0x06`.** All eight HFSP levels were measured
on a 20L5 - each held 60 s at idle through `thinkpad_acpi fan_control=1`,
settled RPM taken as the median of the last 20 s:

| HFSP | `0x00` | `0x01` | `0x02` | `0x03` | `0x04` | `0x05` | `0x06` | `0x07` |
|------|------|------|------|------|------|------|------|------|
| RPM | 0 | 2665 | 2866 | 3018 | 3155 | 3573 | 3989 | 3994 |

`0x06` and `0x07` are the same speed - 5 RPM apart, 0.13 %. With level 1 on
`0x06` the `_AC0` trip at 85 C therefore escalated to a fan speed that was
already running since 76 C: a dead step. At the same time levels 2 and 1 were
834 RPM apart, by far the largest jump and the one that is actually audible.
`0x05` closes that hole - the four steps now sit at 2866 / 3155 / 3573 / 3994
RPM, i.e. 289 / 418 / 421 RPM apart, and `_AC0` becomes a real escalation.
The trade-off is deliberate: between 72 and 80 C the machine now runs quieter
and correspondingly warmer.

Verified on a 20L5: the hysteresis steps back down cleanly after the load ends
and the old unregulated "disengaged" mode no longer occurs at all. Where
sustained full load settles is **not** reproducible, though: two 10-minute
`stress-ng --cpu 8` runs ended at 76-77 C on level 1 and at 84-86 C on level 0,
with the same measured fan speed (3987 / 3981 RPM) both times. Identical
cooling with a 9 K different equilibrium means the difference comes from the
heat input or the ambient, not from the curve - do not try to paper over it
with thresholds.

## base/0020-cfr-fan-profile-option.patch

**Files:** `src/mainboard/lenovo/sklkbl_thinkpad/cfr.c`, `.../ramstage.c`,
`.../variants/t480/include/variant/thermal.h`,
`src/ec/lenovo/h8/acpi/thermal.asl`

Makes the fan curve switchable in the EDK2 setup menu ("Embedded
Controller" form) without rebuilding. Four profiles:

| # | Profile | Idea | _AC0.._AC3 ON thresholds |
|---|---------|------|--------------------------|
| 0 | Quiet | quieter, runs hotter | 88 / 80 / 72 / 64 C |
| 1 | Balanced (default) | the curve from 0012 | 80 / 72 / 64 / 54 C |
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
   just below the CPU's throttle point (100 C): in practice the EC curve
   rules alone (the mode for `thinkfan`/`zcfan` users), but if the EC
   curve ever fails there is still an ACPI escalation before throttling
   and the critical trip (`\TCRT`, 110). Setting the trips above `_CRT`
   or removing them would delete that last net - don't.

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

## base/0031-h8-no-master-wireless-switch.patch

**Files:** `src/ec/lenovo/h8/Kconfig`, `.../h8/acpi/thinkpad.asl`,
`src/mainboard/lenovo/sklkbl_thinkpad/Kconfig`

Fixes bluetooth/WWAN being **hard-blocked** in rfkill. The `WLSW` ACPI
method reports the master wireless kill switch by reading EC bit
0x48.1 (`GSTS`) - a relic of the sliders on X220-era ThinkPads. The
T480 has no such switch and its EC reads 0 there (measured via
`ec_sys`), so `thinkpad_acpi` believed the radio master switch was off
and hard-blocked both radios. Behind the new opt-in
`H8_NO_MASTER_WIRELESS_SWITCH` (selected for the T480 only), the
`WLSW` method is **omitted entirely**.

Omitted, not stubbed: a first version returned a constant 1 instead.
That un-does the hard-block, but any `WLSW` makes `thinkpad_acpi`
register a `SW_RFKILL_ALL` master switch, and the kernel's
`rfkill-input` handler answers "switch is on" by unblocking **every**
radio at each boot (`net/rfkill/input.c`, handler connect) - which
also defeated patch 0033. The board has no slider, so it reports none.

## base/0032-h8-extended-hotkeys.patch

**Files:** `src/ec/lenovo/h8/Kconfig`, `.../h8/acpi/thinkpad.asl`,
`.../h8/acpi/ec.asl`, `src/mainboard/lenovo/sklkbl_thinkpad/Kconfig`

Makes the Fn+F9..F12 functions emit the key events matching what is
printed on the T480 keycaps. The EC delivers these keys fine, but the
legacy hotkey numbers the shared H8 code assigned (X220-era positions)
land on keymap slots the kernel maps to `KEY_UNKNOWN` ("unhandled HKEY
event 0x100d/e/f" in dmesg) or the useless generic `KEY_FN_F10`.
2017+ ThinkPads use Lenovo's *adaptive/extended* hotkey codes
(0x11xx/0x13xx), which the kernel maps unconditionally (verified in
the 7.1 source, `hotkey_notify_hotkey` and the keymap table):

| Key | Keycap symbol | Old event | New event | Kernel key |
|-----|---------------|-----------|-----------|------------|
| Fn+F9 | settings gear | 0x100a | 0x110e | KEY_CONFIG |
| Fn+F10 | bluetooth | 0x100e | 0x1314 | KEY_BLUETOOTH |
| Fn+F11 | keyboard | 0x100f | 0x1315 | KEY_KEYBOARD |
| Fn+F12 | star / favorites | 0x100d | 0x1311 | KEY_BOOKMARKS |

A new `REK` method reports these codes through the existing `MHKP`
queue; everything sits behind the opt-in `H8_EXTENDED_HOTKEYS`,
selected for the T480 only - older H8 boards keep their correct
legacy codes.

## base/0033-h8-remember-bluetooth-state.patch

**Files:** `src/ec/lenovo/h8/Kconfig`, `.../h8/h8.h`, `.../h8/h8.c`,
`.../h8/bluetooth.c`, `.../h8/cfr.h`,
`src/mainboard/lenovo/sklkbl_thinkpad/Kconfig`

Stops bluetooth from coming back on after every reboot. `h8_enable()`
writes EC register 0x3a bit 4 on every boot from the `bluetooth` setup
option, and `thinkpad_acpi` reads its rfkill state from exactly that bit
(`HKEY.GBDC`), so whatever the OS wrote through `HKEY.SBDC` before the
reboot was overwritten before the OS ever looked.

Behind the new opt-in `H8_BLUETOOTH_KEEP_STATE` (selected for the T480
only), the option becomes an enum with a third value, `Last state` (2),
and that is the default. On that value `h8_enable()` skips the write
entirely; the EC keeps the bit across the reset, so "off" stays off. The
two old values keep forcing the radio on or off at every boot.

Notes:

- Other H8 boards see no change - without the symbol `cfr.h` declares
  the same `SM_DECLARE_BOOL` as upstream.
- The EC's memory is standby-powered. Removing battery *and* charger
  resets it and the radio comes back on.
- WWAN sits in the same register, bit 6, and gets the same treatment in
  patch 0034.

## base/0034-h8-remember-wwan-state.patch

**Files:** `src/ec/lenovo/h8/Kconfig`, `.../h8/h8.h`, `.../h8/h8.c`,
`.../h8/wwan.c`, `.../h8/cfr.h`,
`src/mainboard/lenovo/sklkbl_thinkpad/Kconfig`

The same thing 0033 does for bluetooth, for WWAN: `h8_enable()` writes
EC register 0x3a **bit 6** on every boot from the `wwan` setup option,
which overwrites whatever the OS left there through `HKEY.SWAN`. Behind
`H8_WWAN_KEEP_STATE` the option gains a third value, `Last state` (2),
which is the default and makes `h8_enable()` skip the write.

Mechanically it is a mirror of 0033 - same register, same option style,
the `wwan` object already sits in the board's "Embedded Controller" form
(`sklkbl_thinkpad/cfr.c`), so nothing about the menu changes except the
value list.

Notes:

- The board does not select `H8_HAS_WWAN_GPIO_DETECTION`, so
  `h8_has_wwan()` always returns true ("Assuming WWAN installed") and
  bit 6 is written on every boot today. With `Last state` it keeps
  whatever value it already has.
- **The WWAN half is untested.** There is no WWAN card in the machine
  this repo is built for. What was verified: the option shows up, the
  build is clean, and bit 6 survives a reboot (readable through
  `ec_sys`, see "EC debugging" in GUIDE.md). What was not:
  that a real modem actually stays off. The mechanism itself is the one
  0033 relies on and that one is verified on hardware.
- Same cold-start caveat as 0033: pulling battery *and* charger clears
  the EC and the radio comes back on.

## base/0035-h8-acpi-radio-state-save-stubs.patch

**Files:** `src/ec/lenovo/h8/Kconfig`, `.../h8/acpi/ec.asl`,
`src/mainboard/lenovo/sklkbl_thinkpad/Kconfig`

Silences two errors `thinkpad_acpi` logs on **every shutdown**:

```
thinkpad_acpi: acpi_evalf(\WGSV, vd, ...) failed: AE_NOT_FOUND
thinkpad_acpi: acpi_evalf(\BLTH, vd, ...) failed: AE_NOT_FOUND
```

For every radio rfkill switch it registers, the driver installs a
`.shutdown` handler that calls a root-scope ACPI method to have the
firmware save the radio state for S4/S5 - `\BLTH(5)` for bluetooth,
`\WGSV(4)` for WWAN. Lenovo's DSDT has both; coreboot has neither, and
`acpi_evalf()` reports the miss at `KERN_ERR`. They are visible even
with `quiet loglevel=1` because `systemd-shutdown` raises the console
loglevel to 5 just before the kernel goes down.

Behind `H8_ACPI_RADIO_SAVE_STUBS` the EC ASL gains two empty methods in
the root scope. `acpi_evalf(..., "vd", ...)` only checks for `AE_OK`, so
an empty body is enough and the success path is a `vdbg_printk`, i.e.
silent.

Why an empty body is correct here: the state *is* preserved, just not the
way Lenovo's firmware does it. The EC keeps register 0x3a across the
reset and coreboot no longer overwrites it - that is patches 0033 and
0034. Without those two the stubs would be claiming something that is
not true, so do not select this symbol on its own.

The kernel calls `\BLTH`/`\WGSV` nowhere else - only from
`bluetooth_shutdown()`/`wan_shutdown()` and the `*_exit()` paths that
reuse them (checked in the 7.1 tree). That also gives a way to test
without rebooting: `modprobe -r thinkpad_acpi` runs the same code.

## base/0036-h8-keyboard-backlight-three-states.patch

**Files:** `src/ec/lenovo/h8/h8.h`, `src/ec/lenovo/h8/cfr.h`,
`src/ec/lenovo/h8/ssdt.c`, `src/ec/lenovo/h8/h8.c`

Turns the Keyboard Backlight setup option from a bool into three states
and gates `HKBL` on the third.

```
Disabled        dark at boot, the OS can still switch it on
Enabled         on at boot
Not installed   not published to the OS at all
```

`thinkpad_acpi` asks `MLCG` for the capability. That returns bit `0x200`
whenever `HKBL` is set, `ssdt.c` writes `HKBL` from
`has_keyboard_backlight`, and the T480 devicetree sets that to 1 in the
shared baseboard with no variant override. So the kernel creates
`tpacpi::kbd_backlight` on every machine and GNOME draws a brightness
slider for hardware that may not be there. Issue #12.

This started as a second, separate option for presence. Two booleans side
by side, both reading "Disabled" and meaning different things, is a menu
nobody can parse - and the obvious reading of "Keyboard Backlight:
Disabled" is that the thing is gone, which it was not. One option with
three states says what it means.

`KBL_ABSENT` is ours and never reaches the EC; `h8.c` maps it back to
`KBL_OFF` before touching `H8_CONFIG1`. `KBL_OFF` and `KBL_ON` keep the
values the bool had, so settings already in SMMSTORE survive.

The T480 ships with and without a backlit keyboard, so this cannot live
in the devicetree - it has to be per machine, which is why it is a setup
option and not a Kconfig.

Takes effect after a reboot: the option lives in SMMSTORE and the SSDT is
generated at boot.

## base/0040-t480-vboot-fmd.patch

**Files:** `src/mainboard/lenovo/sklkbl_thinkpad/vboot.fmd` (new)

Flash layout for the vboot port (see `docs/vboot-notes.md`): two signed
4 MB slots `RW_SECTION_A/B`, `WP_RO` (FMAP, GBB, RO CBFS) at the top of
the chip, `RW_MRC_CACHE` and `SMMSTORE` at their current absolute
offsets so existing installs keep their settings across the migration.
Inert on its own - the file only takes effect when `CONFIG_FMDFILE`
points at it, which only the vboot defconfig does. Layout validated
with `fmaptool` (offsets tile `BIOS` exactly, three CBFSes recognized).

## base/0041-t480-vboot-kconfig.patch

**Files:** `src/mainboard/lenovo/sklkbl_thinkpad/Kconfig`

Adds the board's `config VBOOT` select block (`VBOOT_SLOTS_RW_AB`),
same pattern as google/glados, inside the existing
`if BOARD_LENOVO_SKLKBL_THINKPAD_COMMON` guard so it stays scoped to
this board. No effect until `CONFIG_VBOOT=y` is set.

## base/0042-cfr-bios-lock-option.patch

**File:** `src/mainboard/lenovo/sklkbl_thinkpad/cfr.c`

Adds `&bios_lock` to the "System" form of the setup menu. Same shape as
0001: the object already exists upstream in `intelblocks/cfr.h`,
complete with a callback that hides the entry unless
`BOOTMEDIA_SMM_BWP_RUNTIME_OPTION` is set - so the patch is inert until
the defconfig enables SMM BIOS write protection. The option is the
documented way to flash internally with that protection on: toggle
"BIOS Lock" off, reboot, flash, toggle it back.

Maintenance note: this patch touches the same `obj_list` as 0001, so it
is generated against the tree with 0001 (and 0020) already applied.
When rebasing, keep that order.

## base/0043-lockdown-protect-descriptor-and-gbe.patch

**Files:** `src/security/lockdown/Kconfig`,
`src/security/lockdown/lockdown.c`

Adds `BOOTMEDIA_LOCK_DESCRIPTOR_GBE` (default off, depends on
`BOOTMEDIA_LOCK_CONTROLLER`) and, when set, programs a second Flash
Protected Range over `SI_DESC` + `SI_GBE` from
`boot_device_security_lockdown()` - same function, same boot state and
so the same FLOCKDN/DLOCK as the `WP_RO` range. Write protection only
(`CTRLR_WP`), deliberately not the choice's `lock_type`: with
`BOOTMEDIA_LOCK_WHOLE_NO_ACCESS` that would be `CTRLR_RWP` and take the
descriptor out of a full-chip backup too.

Closes the hole issue #5 left: `BIOS_CONTROL` (BIOSWE/EISS) gates the
BIOS region and the first range covers `WP_RO`, so nothing protected
offset 0. The descriptor is what grants the region permissions in the
first place, and the GbE NVM holds the MAC. Both were writable from the
OS whenever the SPI controller was visible.

Protected ranges apply to the accesses of the master that programs
them, not globally (datasheet 332690-004EN 32.7.1.4.2), so the ME and
the GbE controller still reach their own regions. Ranges may cross
region boundaries, and `SI_DESC` (0x0, 4 KB) and `SI_GBE` (0x1000, 8 KB)
are adjacent, so one register covers 0x0-0x2fff. The code checks that
adjacency and bails out with a log line instead of guessing.

Changing the MAC with `nvmutil`, or the descriptor with `ifdtool`, then
needs the external programmer.

On success the log carries `BM-LOCKDOWN: Enabled protection for
SI_DESC + SI_GBE` and a second `FPR` line next to the `WP_RO` one. Every
failure path prints at `BIOS_ERR`; `No SPI FPR free!` from the FPR code
means all five registers were taken and the range did not happen.

## regression/0050-t480-hda-verbs-from-stock-bios.patch

**Files:**
`src/mainboard/lenovo/sklkbl_thinkpad/variants/t480/hda_verb.c`

In `regression/`, so it is not built. Measured 2026-08-29 against the
previous firmware in the other slot, same machine and stimulus: with the
stock table the speakers click once at signal onset and once at offset,
and the tone is audibly worse. Upstream's table does neither. Details and
the ruled-out causes are in `docs/hda-notes.md`.

Replaces the ALC257 entry with the one the stock Lenovo BIOS uses. The
table sits uncompressed at `0xda2c80` in a 16 MB dump, in a different
encoding than coreboot's (`ec 10 57 02` for the header, coefficients as
`0x500`/`0x4xx` pairs rather than finished dwords). Byte-identical in
`n24ur39w`, in this board's pre-coreboot dump and in a foreign NM-B501
image, so it is neither BIOS-version nor board specific.

Upstream's pin configs were already right - all ten match. The codec
coefficients were not: the stock BIOS issues 49 writes, upstream 14, and
only three agree. Coef 0x38, the register upstream's own comment labels
"ClassD 2W", is 0x7900 then 0x7901 in the stock BIOS against upstream's
0x8981; 0x3c and 0x09 differ too, and the speaker EQ/DRC block on nodes
0x53 and 0x54 - 32 writes - is absent upstream. Upstream in turn writes
coef 0x37 (silence threshold), 0x30, 0x0a, 0x1a and node 0x58, which the
stock BIOS never touches.

The jack count goes 18 -> 38 and the pin macros give way to raw dwords
because the block is a verbatim copy; keeping half of it in macro form
would hide which parts are ours.

Written for issue #10, where a whine tracking cpu load is audible in the
setup menu. It is not a proven fix - the board this repo is built on runs
the upstream table without any whine - it is the A/B half that makes the
class-D theory testable.

## base/0060-t480-acoustic-noise-mitigation.patch

**Files:** `src/mainboard/lenovo/sklkbl_thinkpad/devicetree.cb`

Sets the Skylake acoustic noise UPDs, which the board leaves at their FSP
defaults: fast VR slew rates and fast package-C ramping. Both make the
rails audible under changing load, which is the symptom in issue #10 - a
whine that tracks cpu load and is there in the setup menu, so before any
OS driver.

`AcousticNoiseMitigation` gates the rest (`chip.h:441`, passed through in
`chip.c:475`). Only `SlowSlewRateForIa` is raised, to Fast/16. The whine
follows cpu load, so IA is the suspect.

The first version of this patch took GT and SA to Fast/16 as well and
disabled fast package-C ramping on all three. It was built, installed and
measured on 2026-08-29: the screen flickered badly enough to be hard to
read. GT feeds the iGPU, and slowing its rail that far is not something
the reported symptom asks for. See `docs/hda-notes.md`.

Installed here in slot A since 2026-08-29, no flicker and no audio fault
in the boots since. That says nothing about the whine itself - it was
never audible on this machine. #10 waits on the reporter.

Watch out for one thing when trimming this further: the registers left
unset are **not** left alone. Once `AcousticNoiseMitigation` is on they go
to FSP as 0, which is `Fast/2` - a value, not the pre-mitigation default.
There is no way to enable the mitigation for one rail only.

Upstream sets none of this on `sklkbl_thinkpad`; other boards do, e.g.
`acer/aspire_vn7_572g` and `clevo/cml-u`.

Inserts above `# Generate ACPI P-State table` and leaves the
`device ref hda on end` anchor alone - `apply-devicetree.sh` runs after
the patches and needs it.

`IslVrCmd` sits right above these in `chip.c` and is another VR C-state
workaround, also unset. Not touched: whether this board has an Intersil
VR is unknown.

## edk2/0001-fmpdxe-slot-capsule-scaffolding.patch

**Files:** `UefiPayloadPkg/UefiPayloadPkg.dsc`,
`UefiPayloadPkg/UefiPayloadPkg.fdf`

Adds `SLOT_CAPSULE_SUPPORT` (default FALSE) next to upstream's
`CAPSULE_SUPPORT`, and with it a second arrangement of `FmpDxe`.

Upstream builds `FmpDxe` embedded into the capsule or, since
`uefipayload_2608` (`CAPSULE_EMBED_FMP_DXE`), in the firmware - either
way it runs `FmpDeviceSmmLib` and updates the whole flash chip, which
its own header says needs every flash protection lifted. That is the
opposite of this build. `SLOT_CAPSULE_SUPPORT` puts `FmpDxe` into the firmware
instead (fdf) and points its `FmpDeviceLib` at `FmpDeviceSlotLib`, which
writes only the inactive vboot slot. Nothing has to be unlocked for
that: the protected ranges are programmed at `BS_DEV_RESOURCES`, long
before capsules are parsed at `BS_DEV_INIT`, and they leave the BIOS
region writable while sealing `WP_RO`, `SI_DESC` and `SI_GBE`.

The two defines are mutually exclusive and the dsc raises `!error` if
both are set - they disagree about where `FmpDxe` lives and what it may
touch.

Also widens the `CAPSULE_SUPPORT` library block (`CapsuleLib`,
`FmpAuthenticationLib`, the `FmpDependency*` set, `FmpPayloadHeaderLib`)
and forces `PcdCapsuleFmpSupport` and `PcdSupportUpdateCapsuleReset`
true, because `FmpDxe` needs all of it either way.

**Inert on its own, and not yet switchable.** With the define at FALSE
the build is byte-identical to before. Setting it TRUE fails until
`FmpDeviceSlotLib` exists - the dsc names an `.inf` that no patch
provides yet.

Open decision, deliberately not taken here: whether to add `EsrtFmpDxe`
alongside. It is not a conflict question - `BlSupportDxe` installs its
static entry at its entry point, both ESRT drivers install theirs on
ReadyToBoot, and `InstallConfigurationTable` replaces an entry of the
same GUID, so the later one simply wins. `EsrtFmpDxe` also bails out
without installing when it finds no FMP instance, so it cannot blank a
working table.

The reason to add it is `LastAttemptStatus`. `BlSupportDxe` never sets
that field, so it stays 0 and fwupd can never tell whether an update
worked. `EsrtFmpDxe` fills it from the FMP instance.

## edk2/0002-expose-flash-layout-to-the-payload.patch

**Files:** `UefiPayloadPkg/Include/Coreboot.h`,
`UefiPayloadPkg/Include/Guid/FlashLayoutInfoGuid.h` (new),
`UefiPayloadPkg/Include/Library/BlParseLib.h`,
`UefiPayloadPkg/Library/CbParseLib/CbParseLib.c`,
`UefiPayloadPkg/Library/SblParseLib/SblParseLib.c`,
`UefiPayloadPkg/UefiPayloadEntry/UefiPayloadEntry.c` + `.inf`,
`UefiPayloadPkg/UefiPayloadPkg.dec`

A DXE driver cannot reach `BlParseLib` - that one runs in the payload
entry phase. So the coreboot table is read there and handed on as a HOB,
the same way `gEfiFirmwareInfoHobGuid` already works, and
`FmpDeviceSlotLib` will pick it up with `GetFirstGuidHob`.

`FLASH_LAYOUT_INFO` carries two things a writer needs:

- `FmapAddress`, coreboot's in-memory copy of the flash map. It keeps one
  in CBMEM unconditionally (`fmap_setup_cbmem_cache`, a `CBMEM_READY_HOOK`)
  and points at it with `CB_TAG_FMAP`. Nothing has to search the flash or
  hardcode an offset, and the map describes the firmware that is running.
  `FmapOffset` and `BootMediaSize` come along for the case where the copy
  is missing.
- `CbfsOffset`, the CBFS coreboot actually booted from. Under verified
  boot that is `FW_MAIN_A` or `FW_MAIN_B`, so it identifies the running
  slot. The alternative was `CB_TAG_VBOOT_WORKBUF`, which means parsing
  `vb2_shared_data` - vboot's internal state, not a stable interface.

`SblParseLib` gets a stub returning `RETURN_NOT_FOUND`. Every function of
the class is implemented by both bootloader backends; without it the Slim
Bootloader build would fail to link.

Applies unconditionally - unlike 0001 there is no define. That also means
a plain build exercises it.

Maintenance note: the new header is CRLF like every other file in that
tree, so `git apply` reports whitespace warnings for it. Expected, not a
defect.

## tpm-reset/tpm2-clear-on-boot.patch

Adds a ramstage hook that clears the discrete TPM 2.0 via `TPM2_Clear`
(platform hierarchy) **on every boot**. Only ever applied to the separate
`..._tpmreset.rom` built by `--tpm-reset`; the normal ROM never contains
it, which the build verifies (`nm`/`strings`). Usage and warnings: see
"TPM reset" in GUIDE.md.

## When upstream breaks a patch

The base-image build stops with `ERROR: <patch> does not apply`. To rebase:

```bash
./fetch.sh                                   # fresh tree in sources/coreboot
cd sources/coreboot
for p in ../../patches/base/*.patch; do git apply --check "$p" && git apply "$p" || echo "FAILS: $p"; done
# fix the failing change by hand, then re-export it:
git diff -- <files of that patch> > ../../patches/base/<same-name>.patch
```

Keep the numbering (0001/0002 = setup menu, 0010-0012 = stepped fan,
0020 = fan profiles, 0030-0035 = OS compatibility, 0040-0047 = vboot,
lockdown, capsules, TPM) - the patches are applied in lexical order and
later ones build on the context of earlier ones (0012 on 0002's Kconfig,
0020 on 0011/0012, 0030 on 0020's ramstage.c, 0033 on 0031/0032's
Kconfig hunks, 0034/0035 on 0033's).
