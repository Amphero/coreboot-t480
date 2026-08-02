# vboot notes

Findings from porting Google verified boot to this board, kept because
they explain non-obvious configuration and would otherwise have to be
re-derived. Everything here was checked against the coreboot 26.06 tree
and, where it says so, on hardware. Open work lives in the issue tracker.

## Layout

`RW_MRC_CACHE` and `SMMSTORE` keep the absolute offsets they had before
vboot, so existing installs survive the migration and old backups stay
compatible. `WP_RO` sits at the top of the chip as one contiguous range,
which is what makes a controller-level write protection possible at all
(see the issue about it).

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

`vb2_select_fw_slot()` takes the slot from `VB2_NV_TRY_NEXT`, and the
fallback writes that field permanently (`2misc.c:408`). Restoring the
broken slot does not move the machine back to it, and nothing in the
firmware ever does - upstream leaves that to the ChromeOS updater
(`crossystem fw_try_next`). Harmless while both slots carry the same
image.

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
version, but the TPM counter never advances: the roll-forward in
`2firmware.c:210` requires `last_fw_result == VB2_FW_RESULT_SUCCESS`, and
nothing sets SUCCESS. vboot only ever writes FAILURE, TRYING and UNKNOWN;
the code that reports success is in `2load_kernel.c`, which coreboot does
not call. secdata stays at 0 and no image is refused as too old.

## Generating keys

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
