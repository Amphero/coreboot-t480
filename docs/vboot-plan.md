# vboot port plan

Goal: Google verified boot on the T480 port. The RO section verifies the
signature of a RW slot before jumping into it, falls back A -> B -> RO on
verification failure, and enforces anti-rollback through version counters
in TPM2 NV space. The EDK2 payload, SMMSTORE/Secure Boot and measured
boot all stay as they are.

Non-goals: ChromeOS EC features (the T480 EC is not a Chrome EC),
depthcharge, Boot Guard (deliberately disabled by deguard - vboot's root
of trust is the RO section, protected at most by SPI write protection).

Everything below marked *verified* was checked against the coreboot 26.06
tree in `sources/latest/coreboot`; the rest is design to be validated by
the milestones.

## Facts (verified)

- `soc/intel/skylake` supports vboot: selects `VBOOT_STARTS_IN_BOOTBLOCK`,
  `VBOOT_VBNV_CMOS` (+ `_BACKUP_TO_FLASH`), `VBOOT_MUST_REQUEST_DISPLAY`.
- `sklkbl_thinkpad` has zero vboot wiring: no fmd, no hooks, no GBB.
- All board hooks have weak defaults (`security/vboot/bootmode.c`):
  `get_recovery_mode_switch`, `get_write_protect_state`,
  `clear_recovery_mode_switch`, `fill_lb_gpios` - a first bring-up needs
  no board code at all.
- Keys come from `VBOOT_ROOT_KEY`, `VBOOT_RECOVERY_KEY`,
  `VBOOT_FIRMWARE_PRIVKEY`, `VBOOT_KEYBLOCK`; the defaults point at the
  devkeys in `3rdparty/vboot/tests/devkeys` - usable for bring-up,
  replaced in M3. Signing happens inside `make`; futility is built as
  part of the coreboot build (`util/futility`).
- Custom flash layout via `CONFIG_FMDFILE` (the file is run through the
  C preprocessor with the build's config.h, so it may use CONFIG
  macros). The in-tree chromeos.fmd default exists only `if CHROMEOS`,
  so we set `CONFIG_FMDFILE` explicitly in the vboot defconfig. With
  FMDFILE set, `CONFIG_CBFS_SIZE` no longer shapes the layout (it only
  feeds the generated default FMAP) - drop it there to avoid confusion.
  Reference layout: `mainboard/google/glados/chromeos.fmd` (same SoC
  generation, 16 MB).
- flashrom's `--fmap` reads the FMAP **from the chip**, not from the
  image (man page: "The on-chip fmap will be read and used to generate
  the layout"). Consequences below in the flash flow.
- Space: the current image uses ~2.9 MB CBFS (payload 1.55 MB), 11 MB
  free -> two 4 MB RW slots plus a full RO CBFS fit comfortably.
- The board has no cmos.layout/option table, so the VBNV area at
  `VBOOT_VBNV_OFFSET` has no option-table collision (verify in M1 that
  nothing else scribbles over it).

## Target layout (draft)

RW_MRC_CACHE and SMMSTORE keep their current absolute offsets, so
existing installs keep their settings and `transfer-settings.py` keeps
working unchanged. SI regions stay exactly as the IFD defines them.

```
FLASH 0x1000000
  SI_ALL@0x0 0x240000
    SI_DESC@0x0      0x1000
    SI_GBE@0x1000    0x2000
    SI_ME@0x3000     0x111000
  SI_BIOS@0x240000 0xdc0000
    RW_MRC_CACHE@0x0            0x10000     # abs 0x240000 (unchanged)
    SMMSTORE(PRESERVE)@0x10000  0x40000     # abs 0x250000 (unchanged)
    RW_ELOG(PRESERVE)@0x50000   0x4000      # abs 0x290000
    RW_NVRAM(PRESERVE)@0x54000  0x6000      # vboot nvdata flash backup
    RW_UNUSED@0x5a000           0x6000
    RW_SECTION_A@0x60000 0x400000           # abs 0x2a0000
      VBLOCK_A@0x0        0x10000
      FW_MAIN_A(CBFS)@0x10000 0x3effc0
      RW_FWID_A@0x3fffc0  0x40
    RW_SECTION_B@0x460000 0x400000          # abs 0x6a0000, mirror of A
    WP_RO@0x860000 0x560000                 # abs 0xaa0000..0xffffff
      FMAP@0x0        0x800
      RO_FRID@0x800   0x40
      RO_FRID_PAD@0x840 0x7c0
      GBB@0x1000      0xf000
      COREBOOT(CBFS)@0x10000 0x550000
```

All offsets/sizes verified to tile SI_BIOS exactly (0xdc0000, no gaps,
no overlap). WP_RO sits at the top of the chip so a single SPI protected
range can cover it later. The FMAP moves; our tools find it by
signature.

## Patches (patches/base/, 0040-0049 reserved for vboot)

- **0040-vboot-fmd.patch** - add
  `src/mainboard/lenovo/sklkbl_thinkpad/vboot.fmd` with the layout above.
  Inert until FMDFILE points at it; must not change the default build.
- **0041-vboot-kconfig.patch** - board Kconfig: `config VBOOT` block
  (glados pattern, verified) selecting `VBOOT_SLOTS_RW_AB`. FMDFILE is
  NOT set here - it goes into the vboot defconfig (see facts).
  Everything stays behind `CONFIG_VBOOT=y`, which only the vboot
  defconfig sets.
- **0042-vboot-hooks.patch** (optional, M2+) - board hooks where the weak
  defaults are not enough: `get_write_protect_state` reading the actual
  SPI WP status, recovery-request plumbing. Skipped for bring-up.

Config/build changes outside the patch series:

- `config/defconfig.vboot` (or a commented block): `CONFIG_VBOOT=y`,
  `CONFIG_FMDFILE`, key paths; `CONFIG_CBFS_SIZE` dropped. The normal
  defconfig stays vboot-free until the port is hardware-proven.
- `scripts/build-firmware.py`: NO extra signing step needed - verified:
  every variant is a full rebuild (sed on the EDK2 .fdf, then
  `make olddefconfig` + `make`), and with vboot enabled `make` signs the
  slots itself with the configured keys. The only change is getting the
  key files into the offline build context (fetch.sh copies them like
  board.conf; devkeys need nothing, they are in the tree).
- `scripts/gen-vboot-keys.sh` (M3): generate an own keyset with
  `futility`; private keys never enter the repo - the repo carries only
  the public keys/keyblocks and paths.
- Flash flow. Migration to the new layout can stay internal: the OLD
  on-chip FMAP's `FMAP` + `COREBOOT` regions cover exactly the byte
  range the new layout changes (0x290000-0xffffff), while RW_MRC_CACHE
  and SMMSTORE are skipped and thereby preserved:
  `flashrom -p internal --fmap -i FMAP -i COREBOOT -w <new>.rom`.
  Needs its own checked script (the regular one refuses on FMAP
  mismatch, correctly) and the external programmer at hand. AFTER
  migration, updates write RW_SECTION_A only - `--fmap` then reads the
  new chip FMAP, which matches the image again.

## Milestones with acceptance criteria

- **M1 bring-up (devkeys):** image builds with 0040+0041 and
  `CONFIG_VBOOT=y`; boots slot A. Check: cbmem console shows the vb2
  verification lines, `cbmem -L` gains the GBB/FMAP measurements and the
  FW_MAIN_A paths (the eventlog format we verified for measured boot
  already prints them). Fallback intact: settings survive because
  SMMSTORE stayed put.
- **M2 fallback:** corrupt VBLOCK_A on the chip -> next boot runs slot B;
  corrupt both -> RO recovery boot (which for us simply means the RO
  copy of coreboot+EDK2 starts). Both restorable internally.
- **M3 own keys + rollback:** replace devkeys, bump
  `VBOOT_KEYBLOCK_VERSION`, verify the TPM2 secdata counters advance and
  an older signed image is refused.
- **M4 integration:** update flow + README, decision on SPI write
  protection for WP_RO (see open questions), rebase onto main.

## Open questions / risks

1. **TPM interplay:** vboot does TPM2 startup early and owns secdata;
   EDK2's Tcg2 stack starts the TPM again (benign INVALID_POSTINIT seen
   today) and measured boot extends PCRs. All three must coexist -
   M1 explicitly checks eventlog + PCRs + Secure Boot afterwards.
2. **VBNV in CMOS:** no option table, offset looks free (verified), but
   confirm nothing else in the port touches those RTC bytes.
3. **SPI write protection for WP_RO:** W25Q128 SRP/WP# wiring on the
   T480 is unknown; without it, vboot's RO is only as trustworthy as the
   last flash. Investigate flashrom's WP commands on the internal
   programmer in M4 - until then this is tamper-evidence, not tamper-proof
   (same honest limit as measured boot).
4. **Recovery UX:** no Chrome EC, so no keyboard combo. Recovery request
   works via VBNV flag from the OS; document how, or wire a key in 0042.
5. **SMMSTORE access:** the runtime store is coreboot's SMM driver, and
   it locates the region via FMAP lookup at runtime
   (`drivers/smmstore/store.c: fmap_locate_area`) - so it would even
   tolerate a moved SMMSTORE. Keeping the offset is about preserving
   the *contents* through migration and staying compatible with old
   backups. M1 must confirm UEFI vars and Secure Boot still function
   from a slot boot.
6. **Boot time:** verification adds hashing of FW_MAIN_A on every boot;
   measure with `cbmem -t` before/after (ties into the boot-profiling
   item from the improvement list).
