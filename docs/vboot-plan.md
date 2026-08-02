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
  mismatch) and the external programmer at hand. AFTER
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

## M1 findings (hardware, 2026-08-02)

- Migration flash over the old FMAP+COREBOOT regions worked; slot A
  boots verified (cbmem: "Slot A is selected", VB2 digests up to the
  payload). Secure Boot enabled, SMMSTORE and settings intact.
- First boot factory-initializes the TPM secdata spaces and starts with
  `tlcl_force_clear()` (`security/vboot/secdata_tpm2.c`): every
  TPM-sealed secret is invalidated once - LUKS falls back to the
  passphrase and needs a re-enroll (wipe-slot=tpm2, delete
  `/var/lib/systemd/tpm2-srk-public-key.*`, enroll again). Goes into
  the README when this merges.
- No splash: `VBOOT_MUST_REQUEST_DISPLAY` (selected by the SoC) skips
  display init on normal verified boots. Fixed with
  `VBOOT_ALWAYS_ENABLE_DISPLAY=y`; the decision is taken in verstage
  (RO), so shipping the fix needs a WP_RO write, not just a slot update.
- vboot measurements landed in PCR 1 (GBB HWID), PCR 2 changed with the
  new measurement paths; PCR 0/3 unchanged. vboot additionally measures
  the firmware version into PCR 10.

## M2 findings (hardware, 2026-08-02)

- Slot fallback works: with VBLOCK_A zeroed the next boot logs "Slot B
  is selected" and comes up complete (Secure Boot enabled, payload from
  the B slot). No user-visible difference - both slots hold the same
  image. Tooling: `scripts/vboot-slots.sh`.
- RO recovery works: with both VBLOCKs zeroed the machine still boots -
  WP_RO carries a complete image including the EDK2 payload, Secure Boot
  stays enabled and the system is fully usable, so the RW slots can be
  rewritten from the running system. Proof: both VBLOCKs read back as
  wiped while the machine was up. The recovery boot skips the MRC cache
  ("MRC: failed to locate region type 0"), so it costs a full memory
  training - a minute or two of black screen.
- **Recovery is a one-way street without `VBOOT_CLEAR_RECOVERY_IN_RAMSTAGE`.**
  After the recovery test the machine kept booting recovery even with both
  slots restored. `vb2api_clear_recovery()` is only called from
  `2kernel.c` (the depthcharge path we never run) and from
  `bootmode.c:61`, which is compiled only under
  `VBOOT_CLEAR_RECOVERY_IN_RAMSTAGE` - coreboot's own help text names the
  case exactly: "platforms without vboot-integrated payloads, to avoid
  being stuck in the recovery mode". The request stays in VBNV, so every
  boot re-enters recovery: RO code, no MRC cache, full memory training.
  Fix: `CONFIG_VBOOT_CLEAR_RECOVERY_IN_RAMSTAGE=y`. Until then the
  request can be cleared by hand in CMOS (VBNV lives at
  `CONFIG_VBOOT_VBNV_OFFSET + 14` = 0x34, byte 2 is the request, byte 15
  the CRC8).
  Diagnosing it: "MRC: failed to locate region type 0" appears if and
  only if the boot is a recovery boot - `normal_training` carries
  NORMAL_FLAG only (vboot starts in the bootblock) and there is no
  recovery MRC region, so the lookup finds nothing. Use `cbmem -1` to
  isolate the current boot; the console buffer holds several.
- Slot selection is sticky. `vb2_select_fw_slot()` takes the slot from
  `VB2_NV_TRY_NEXT` and the fallback writes that field permanently
  (2misc.c:408) - restoring VBLOCK_A does not move the machine back to
  slot A, and nothing in the firmware ever does. Upstream expects the
  OS updater to steer it (`crossystem fw_try_next`). Harmless while both
  slots carry the same image, but M4 needs an answer: build crossystem
  (needs libflashrom headers in the deps image), write the VBNV bytes
  directly (CMOS offset 0x26, CRC8 over the record), or document that
  clearing CMOS resets the choice to A.

## Open questions / risks

1. **TPM interplay:** resolved in M1, see findings - the three users
   coexist; the one-time cost is the factory-init TPM clear.
2. **VBNV in CMOS:** no option table, offset looks free (verified), but
   confirm nothing else in the port touches those RTC bytes.
3. **SPI write protection for WP_RO:** W25Q128 SRP/WP# wiring on the
   T480 is unknown; without it, vboot's RO is only as trustworthy as the
   last flash. Investigate flashrom's WP commands on the internal
   programmer in M4 - until then this is tamper-evidence, not tamper-proof
   (same limit as measured boot).
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
