# Firmware versions

`CONFIG_VBOOT_KEYBLOCK_VERSION` in `config/defconfig` is the rollback version.
futility writes it into the preamble of both slots; vboot refuses any slot whose
version is *below* the counter in the TPM. This file is the record of which
value meant what - `scripts/build-firmware.py` refuses to build a version that
is not listed here.

A version can outlive several builds - the number only has to move when an
older image should stop booting. The ROM column names the build that is
**deployed**; earlier builds of the same version are listed under it.

| Version | Introduced | coreboot | Deployed ROM | SHA256 | Note |
|---------|------------|----------|--------------|--------|------|
| 1 | 2026-08-07 | 26.06 (5cbf8afc) | `coreboot_t480_20260807.rom` | `d6cc79e8` | vboot port, SMM BWP, WP_RO lock. Superseded. |
| 2 | 2026-08-07 | 26.06 (5cbf8afc) | `coreboot_t480_20260807-ifdlock-nospi.rom` | `8c5b191e` | The TPM counter stands here. Raised once deliberately to exercise the path end to end - build guard, roll-forward, external flash of the RO copy. |

Checking what is on the chip: verify the firmware regions, not the whole
image. `RW_MRC_CACHE`, `SMMSTORE` and `RW_NVRAM` hold runtime state and diverge
from any ROM the moment the machine boots, and the ME writes a few bytes of its
own into `SI_ME`. A full-chip verify therefore always fails once the firmware
has run; it says nothing.

```bash
sudo flashrom -p internal --fmap -i WP_RO -i RW_SECTION_A -i RW_SECTION_B \
    -v roms/<rom>
```

Builds of version 2, in order:

| ROM | SHA256 | What changed |
|-----|--------|--------------|
| `coreboot_t480_20260807-fw2.rom` | `702843b2` | Identical firmware to version 1, version raised to 2. |
| `coreboot_t480_20260807-ifdlock.rom` | `7b8732ec` | Flash descriptor and ME region locked against the host. Built, never flashed. |
| `coreboot_t480_20260807-ifdlock-nospi.rom` | `8c5b191e` | Same, plus `DT_DEVICE_FAST_SPI=n` - no MTD device for the OS. Currently on the chip. |

## Rules

**Raise by one** for a release that should lock out its predecessor - a fixed
verstage bug, a leaked key, anything where booting the old image again would be
a problem. Cosmetic changes do not need a new version; several builds may share
one. The counter cannot move at all while the number stays the same.

**The range is 16 bits, 1 to 65535.** A larger value fails verification outright
(`VB2_ERROR_FW_PREAMBLE_VERSION_RANGE`, `2firmware.c:184`): both slots are
refused and the machine lands in a recovery boot. Dates like `20260807` do not
fit - that is why this is a counter.

**Nothing happens until the counter follows.** The TPM value only advances on
the boot *after* a successful one was reported (`vbnv boot-ok`), and only when
the same slot booted twice in a row. Until then the raised version is just a
number in the image.

**Once it has followed, every older image stops booting**, including the ROMs in
`roms/` and any backup. That is the mechanism working as intended, not a
failure - see "Rollback protection" in the README for the two ways back.

## When the counter runs out

The value in the TPM is `(key_version << 16) | firmware_version`. With
`firmware_version` at 65535, raise the **key version** instead: repack the same
public firmware key with `vbutil_key --version 2`, rebuild the keyblock with the
same root key, re-sign. `0x0001ffff` -> `0x00020001` is an increase and buys
another 65535 versions. The root key in the GBB does not change, so this stays a
slot update - no programmer, despite the `WP_RO` lock.

That gives 65535 x 65535 steps in total. At one release a month the lower half
alone lasts longer than the machine will.
