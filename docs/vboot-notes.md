# vboot notes

Findings from porting Google verified boot to this board, kept because
they explain non-obvious configuration and would otherwise have to be
re-derived. Everything here was checked against the coreboot 26.06 tree
and, where it says so, on hardware. Open work lives in the issue tracker.

## Layout

`RW_MRC_CACHE` and `SMMSTORE` keep the absolute offsets they had before
vboot, so existing installs survive the migration and old backups stay
compatible. `WP_RO` sits at the top of the chip as one contiguous range,
which is what makes the controller-level write protection possible
(see "The WP_RO lock" below).

SMMSTORE is found at runtime by coreboot's SMM driver through an FMAP
lookup (`drivers/smmstore/store.c`), not by a hardcoded offset - keeping
the offset is about preserving contents, not about function.

## Why `VBOOT_CLEAR_RECOVERY_IN_RAMSTAGE=y`

Without it a single recovery event pins the machine to RO boots forever.
`vb2api_clear_recovery()` is called from `2kernel.c` - the depthcharge
path this payload never runs - and from `bootmode.c:61`, which is only
compiled with this option. The request stays in VBNV, so every boot
re-enters recovery.

coreboot's own help text names the case: "platforms without
vboot-integrated payloads, to avoid being stuck in the recovery mode".

Verified on hardware: the first boot after flashing still runs recovery
and clears the request, the second selects a slot again.

## Why `VBOOT_ALWAYS_ENABLE_DISPLAY=y`

The SoC selects `VBOOT_MUST_REQUEST_DISPLAY`, which skips display init on
normal verified boots - no splash, dark until the kernel takes over. The
decision is taken in verstage, so shipping a fix needs a `WP_RO` write,
not just a slot update.

## Telling a recovery boot apart

`MRC: failed to locate region type 0` appears if and only if the boot is
a recovery boot. `lookup_region_type()` asks for `RECOVERY_FLAG` in that
case; `normal_training` carries `NORMAL_FLAG` only (because vboot starts
in the bootblock) and there is no recovery MRC region here, so nothing
matches. A recovery boot therefore also retrains memory - a minute or two
of black screen.

Use `cbmem -1` to look at the current boot; the console buffer holds
several, and `/sys/firmware/log` is truncated when the pre-CBMEM buffer
overflows.

## Slot selection is sticky

`vb2_select_fw_slot()` takes the slot from `VB2_NV_TRY_NEXT`, and a
failing slot flips that field permanently: `fail_impl()` writes
`1 - fw_slot` at `2misc.c:123`, reached through `vb2api_fail()` from
`vb2_load_fw_keyblock()` and `vb2_load_fw_preamble()`. Restoring the
broken slot does not move the machine back to it, and nothing in the
firmware ever does - upstream leaves that to the ChromeOS updater
(`crossystem fw_try_next`). Harmless while both slots carry the same
image.

The second fallback, the one inside `vb2_select_fw_slot()` itself
(`2misc.c:394`), is dead code here. It needs
`last_fw_result == VB2_FW_RESULT_TRYING`, which is only written when
`VB2_NV_TRY_COUNT` is non-zero, and neither coreboot nor this repo ever
sets that field. Do not cite it as the reason for the sticky slot.

## TPM

The first boot after enabling vboot clears the TPM:
`factory_initialize_tpm2()` starts with `tlcl_force_clear()` before
setting up the NV spaces (`security/vboot/secdata_tpm2.c`). Everything
sealed to the TPM is invalidated once - LUKS falls back to the passphrase
and needs re-enrolling. It happens once; the spaces persist, and later
key or firmware changes do not repeat it.

vboot, the EDK2 Tcg2 stack and measured boot coexist on the one TPM.
vboot measures the boot mode and GBB HWID into PCR 1 and the firmware
version into PCR 10; measured boot keeps using PCR 2.

## Rollback protection does not work here

`--version $(CONFIG_VBOOT_KEYBLOCK_VERSION)` does set the preamble
version, but the TPM counter never advances. Two things stop it, and
either one alone would be enough.

The roll-forward at `2firmware.c:210` needs all three of: a version above
secdata, the same slot as the last boot, and `last_fw_result ==
VB2_FW_RESULT_SUCCESS`. Nothing ever writes SUCCESS - not in coreboot,
and not in vboot either outside its own unit tests. vboot writes only
FAILURE, TRYING and UNKNOWN; on ChromeOS the success report comes from
userspace (`crossystem fw_result`), which is the piece a coreboot-only
integration does not have.

And `CONFIG_VBOOT_KEYBLOCK_VERSION` is not set in `config/defconfig`, so
it keeps its default of 1 and every build carries the same version. Even
with SUCCESS in place, `fw_version > fw_version_secdata` could be true at
most once.

secdata therefore stays at 0 and no image is refused as too old.

## The WP_RO lock

`BOOTMEDIA_LOCK_CONTROLLER` + `BOOTMEDIA_LOCK_WPRO_VBOOT_RO`: in
ramstage, `boot_device_security_lockdown()` writes one Flash Protected
Range register covering `WP_RO` (0xaa0000-0xffffff). The FPRs work at
4 KB granularity (`SPI_FPR_SHIFT = 12`, five registers), so the region
is covered exactly; the FMAP offsets are flash-absolute because
`boot_device_ro()` spans `CONFIG_ROM_SIZE`, not the BIOS region. The
chipset lockdown then sets FLOCKDN and DLOCK, sealing the register until
the next reset - and the next boot re-arms it before the payload runs.

Consequences, measured and structural:

- Every host write into the range is dropped by the controller - OS, SMM
  and the `bios_lock` toggle make no difference. The two mechanisms are
  independent: EISS gates the regions outside, the FPR seals `WP_RO`.
- The MRC cache is written at `BS_DEV_ENUMERATE/ON_EXIT`, the FPR set at
  `BS_DEV_RESOURCES/ON_ENTRY`, FLOCKDN at `BS_DEV_RESOURCES/ON_EXIT` -
  no ordering conflict, and everything writable lies outside the range
  anyway. `BOOTMEDIA_LOCK_IN_VERSTAGE` is therefore not needed here.
- `GBB_FLAG_DISABLE_FW_ROLLBACK_CHECK` (the rollback-protection
  escape hatch) sits in the GBB inside `WP_RO`: external-only from now
  on. Same for replacing the keyset.
- A successful lock prints `BM-LOCKDOWN: Enabled bootmedia protection`
  plus an FPR line with the range; `No SPI FPR free!` would mean FSP
  occupied all five registers and the lock silently did not happen -
  check the log after any coreboot or FSP update.

`scripts/keygeneration/create_new_keys.sh` is unusable here - it insists
on ChromeOS AP-RO keys. `scripts/gen-vboot-keys.sh` calls the helpers in
`common.sh` directly and works around two gaps: `dumpRSAPublicKey` has to
be compiled by hand (the vboot Makefile wants libflashrom), and
`vbutil_key`/`vbutil_keyblock` exist only as futility subcommands while
`common.sh` calls them as programs.

Build futility outside the fetched tree (`BUILD=/tmp/vbuild`). That tree
is the offline build context, and writing into it invalidates the
crossgcc layer cache - a config change then costs an hour instead of a
quarter of one.

## Hardware test results

- Slot fallback: with `VBLOCK_A` zeroed the next boot selects slot B and
  comes up complete.
- RO recovery: with both VBLOCKs zeroed the machine still boots. `WP_RO`
  carries a complete image including the payload, so the slots can be
  rewritten from the running system.
- Foreign keys: an image signed with a different keyset, written into the
  slot the machine actually boots, is refused and the other slot is
  selected. Writing it into the other slot proves nothing - vboot never
  looks at it.
