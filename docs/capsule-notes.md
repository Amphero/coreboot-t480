# Capsule notes

State of the slot-only capsule work on branch `capsule-slot-only`. Findings
that were measured rather than assumed, and the things that would otherwise
have to be re-derived.

## Where it stands

The chain from `fwupdmgr`/`efi_capsule_loader` down to `FmpDxe` works. The
`EFI_ABORTED` on apply is diagnosed and fixed in the patches; the fix has not
been on hardware yet.

Measured 2026-08-16, firmware from `roms/coreboot_t480_dualslot.rom` in slot B,
capsule built from the same ROM:

- the kernel accepts it: `efi: Successfully uploaded capsule file with reboot
  type 'RESET_WARM'`
- the firmware processes it and records a result: `Capsule0000`, `CapsuleLast`
  and `CapsuleMax` appear under GUID `39b68c46-…`
- `Capsule0000` carries our FMP capsule GUID `6dcbd5ed-…` and
  `CapsuleStatus = 0x8000000000000015`, i.e. `EFI_ABORTED`, payload index 1
- slot A is byte-identical to what was in it before, so nothing was written

## The abort, found by reading

`SmmStoreLib` keeps its state per linked driver: `mSmmStoreInfo` is a module
global and stays NULL until `SmmStoreLibInitialize()` runs in that driver.
`FmpDeviceSlotLib` never called it - the reference `FmpDeviceSmmLib` does it
from its constructor (`FmpDeviceSmmLib.c:1141`), which is exactly the kind of
per-copy setup a library user forgets. So every store call in FmpDxe's copy
returned `EFI_NO_MEDIA`, `FmpDeviceCheckImageWithStatus` hit its
block-size branch and marked the image invalid, and `SetTheImage` turned
"not valid for update" into `EFI_ABORTED` (`FmpDxe.c:1288`). That accounts for
everything measured: overall status `EFI_ABORTED`, nothing written, and no
usable detail. Patch 0003 now has the same constructor.

## Why no detail reached the OS, both halves fixed

`FmpDxe` only passes a device library's `LastAttemptStatus` through if it falls
in the range reserved for device libraries, `0x1800` upwards
(`FmpDevicePkg/Include/LastAttemptStatus.h:73`). Outside that it replaces the
value with a flat `LAST_ATTEMPT_STATUS_ERROR_UNSUCCESSFUL`. The library used
the standard codes, all below the range; it now has one code per failure site,
`0x1800` up (patch 0003).

The other half: the ESRT the OS reads was the static one from `BlSupportDxe`,
which never carries a `LastAttemptStatus` at all. Patch 0004 adds
`EsrtFmpDxe`, which rebuilds the table from the FMP instances on ReadyToBoot
and installs nothing when it finds none - so firmware built without capsule
support keeps the static table.

## Debug output does not fit

`USE_CBMEM_FOR_CONSOLE=TRUE` routes the payload's `DEBUG()` to coreboot's CBMEM
console, readable from `/sys/firmware/log`, and suppresses `-DMDEPKG_NDEBUG` so
the calls survive a RELEASE build. Both were confirmed to work.

It does not fit: `GenFv` fails on `PLDFV`. In RELEASE the fdf sets
`FD_SIZE = 0x0900000` (9 MiB) and the payload already uses 0x857000, leaving
about 676 KB for every module's debug strings. `TARGET=DEBUG` raises `FD_SIZE`
to 0x0A00000, so `CONFIG_EDK2_DEBUG=y` together with `USE_CBMEM_FOR_CONSOLE`
should give both the space and readable output. Not tried yet.

## A slot image is not interchangeable

`FSP_M_XIP` is selected unconditionally by `src/soc/intel/skylake/Kconfig:19`
and cannot be turned off - FSP-M is what brings memory up, so there is no RAM to
copy it into. It is therefore bound to its flash address, and romstage carries
references to it.

Measured on a built ROM: of the twelve CBFS files in `FW_MAIN`,
`fallback/romstage` and `fspm.bin` differ between the two slots. The other ten
are byte-identical.

Consequence, and the reason the capsule carries both slots: writing slot A's
image into slot B would **pass verification and then fail to boot**. vboot
checks that VBLOCK and FW_MAIN agree with each other, which they would, and has
nothing to say about the address FSP-M was linked for. Do not "simplify" this
into a single slot image.

## What the design rests on, all verified

- The flash map reaches the payload in memory. coreboot keeps a copy in CBMEM
  unconditionally (`fmap_setup_cbmem_cache`, a `CBMEM_READY_HOOK`) and points at
  it with `CB_TAG_FMAP`. Confirmed on hardware: `cbmem-464d4150` exists, and the
  payload reported `fmap@AA0000 (mem 7ABDC000)`, the same address coreboot's own
  CBMEM table lists.
- The running slot comes from `CbfsOffset` in the same hob - `0x6B0000` on a
  slot B boot, which is `FW_MAIN_B`. No need to parse `vb2_shared_data`, which
  is internal and not an interface.
- `CbfsSize` is the size recorded in the CBFS, not the region size (0x30E7C0 vs
  0x3F0800). A writer has to take its bounds from the flash map.
- Writing goes through `SmmStoreLib*AnyBlock`, which sets
  `SMMSTORE_CMD_USE_FULL_FLASH`. coreboot only honours that when it found a
  capsule this boot: `has_capsules` is latched once from `uefi_capsule_count` at
  `BS_POST_DEVICE` (`drivers/efi/capsules.c`). Outside a capsule boot every
  block call returns unsupported, which is the intended flow, not a defect.
- Nothing has to be unlocked. The protected ranges are programmed at
  `BS_DEV_RESOURCES` and sealed there, before capsules are parsed at
  `BS_DEV_INIT`, and they leave the BIOS region writable while sealing `WP_RO`,
  `SI_DESC` and `SI_GBE`.
- Slot offsets are 64 KiB aligned: `RW_SECTION_A` at 0x2A0000 is block 42,
  `RW_SECTION_B` at 0x6A0000 is block 106, 64 blocks each.

## Build system, things that cost time

- EDK2 builds with `-q` (`payloads/external/edk2/Makefile:45`), which swallows
  compiler and linker errors - a failing module reports only "Failed to execute
  command". `CONFIG_EDK2_CUSTOM_BUILD_PARAMS` is appended after it, so a `-v`
  there brings them back.
- A new coreboot Kconfig symbol does not reach the edk2 sub-make on its own.
  `payloads/external/Makefile.mk` enumerates what it forwards, in two separate
  lists: `EDK2_CAPSULE_ARGS` for capsule generation and the recipe of
  `$(obj)/UEFIPAYLOAD.fd` for the payload build. A symbol needed at build time
  belongs in the second.
- A dsc component with a `FILE_GUID` override needs the same override on the
  fdf side (`INF FILE_GUID = … path`), or the module is built and silently not
  placed in the volume. Check `Build/…/FV/DXEFV.inf` for the GUID, not the build
  log.
- Changing anything under `sources/coreboot` invalidates the crossgcc layer and
  costs half an hour. Changing only `sources/edk2` does not.

## Next

1. Flash the rebuilt ROM, apply a capsule built from it, and check three
   things: the inactive slot carries the new content, VBNV has the trial boot
   armed, and `/sys/firmware/efi/esrt` shows the FMP-built entry. On failure
   the entry's `last_attempt_status` now names the failed check.
2. The capsule is signed with EDK2's published test certificates, which is what
   the stock `FMP_DEVICE_PKCS7_PCD_INC` trusts and what makes `FmpDxe` print
   "Warning test key is used". Replace it with an own key before this is used
   for anything - `CONFIG_DRIVERS_EFI_CAPSULE_TRUSTED_PUBLIC_CERT` and the
   `--signer-cert` options of `scripts/make-capsule.py`. Costs a build and a
   flash, so it is worth doing once the mechanism works.

## Machine state as this was written

Both slots hold test builds, not the release image. Slot A has the earlier
single-half library build, slot B the two-half one; both boot. BIOS Lock is off
for development, so flashing needs no setup menu visit. The rollback counter and
both preambles are at version 4.
