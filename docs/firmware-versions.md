# Firmware versions

`CONFIG_VBOOT_KEYBLOCK_VERSION` in `config/defconfig` is the rollback version.
futility writes it into the preamble of both slots; vboot refuses any slot whose
version is *below* the counter in the TPM. This file is the record of which
value meant what; `scripts/build-firmware.py` refuses to build a version that
is not listed here.

A version can outlive several builds. The number only has to move when an
older image should stop booting.

| Version | Introduced | coreboot | What it locks out |
|---------|------------|----------|-------------------|
| 1 | 2026-08-07 | 26.06 | Nothing yet; the vboot port itself, with SMM BWP and the `WP_RO` lock. |
| 2 | 2026-08-07 | 26.06 | Images without the descriptor and ME lock. |
| 3 | 2026-08-07 | 26.06 | Images with `CONFIG_GBB_FLAG_DISABLE_FW_ROLLBACK_CHECK` set, where the counter advances but refuses nothing. |
| 4 | 2026-08-16 | 26.06 | Images without the second protected range over `SI_DESC` and `SI_GBE`. |
| 5 | 2026-08-17 | 26.09 | Images that accept capsules signed with EDK2's published test certificates. This build carries an own trust anchor. |

Which firmware version each release carries is in its release notes. The log
of what ran on which machine is not kept in this repo.

Checking what is on a chip: verify the firmware regions, not the whole
image. `RW_MRC_CACHE`, `SMMSTORE` and `RW_NVRAM` hold runtime state and diverge
from any ROM the moment the machine boots, and the ME writes a few bytes of its
own into `SI_ME`. A full-chip verify therefore always fails once the firmware
has run; it says nothing.

```bash
sudo flashrom -p internal --fmap -i WP_RO -i RW_SECTION_A -i RW_SECTION_B \
    -v roms/<rom>
```

## Rules

**Raise by one** for a release that should lock out its predecessor. A fixed
verstage bug, a leaked key, anything where booting the old image again would be
a problem. Cosmetic changes do not need a new version; several builds may share
one. The counter cannot move at all while the number stays the same.

**The range is 16 bits, 1 to 65535.** A larger value fails verification outright
(`VB2_ERROR_FW_PREAMBLE_VERSION_RANGE`, `2firmware.c:184`): both slots are
refused and the machine lands in a recovery boot. Dates like `20260807` do not
fit. That is why this is a counter.

**The counter follows on the first boot of the new image, not the second.**
The roll-forward wants a success report from the previous boot and the same
slot. It does not check that the report was about the same *image*. Flash a
raised version while the running one has already reported success, and verstage
advances the counter on the very next boot, before the new firmware has run a
single instruction. Measured going from version 2 to 3.

That is worth knowing because it cuts both ways: a broken update advances the
counter too. To hold the counter back until the new image has proven itself,
disable `vboot-boot-ok.service` before flashing and re-enable it after the new
firmware has booted a few times. ChromeOS solves this with `VB2_NV_TRY_COUNT`,
which this firmware does not use. Nothing ever sets that field.

**Once it has followed, every older image stops booting**, including the ROMs in
`roms/` and any backup. That is the mechanism working as intended, not a
failure. See "Rollback protection" in GUIDE.md for the ways back.

**That only holds with `CONFIG_GBB_FLAG_DISABLE_FW_ROLLBACK_CHECK` off.**
coreboot sets it by default, and it makes vboot skip the comparison while the
counter keeps advancing, so the number moves and stops nobody. The flag sits in
the GBB inside `WP_RO`, so clearing it takes the external programmer. Check a
built image before trusting the protection:

```bash
python3 - <<'EOF'
import struct
r = open("roms/<rom>", "rb").read()
print(hex(struct.unpack_from("<I", r, 0xaa1000 + 12)[0]))   # GBB flags, want 0x10 or 0x00
EOF
```

## When the counter runs out

The value in the TPM is `(key_version << 16) | firmware_version`. With
`firmware_version` at 65535, raise the **key version** instead: repack the same
public firmware key with `vbutil_key --version 2`, rebuild the keyblock with the
same root key, re-sign. `0x0001ffff` -> `0x00020001` is an increase and buys
another 65535 versions. The root key in the GBB does not change, so this stays a
slot update. No programmer, despite the `WP_RO` lock.

That gives 65535 x 65535 steps in total. At one release a month the lower half
alone lasts longer than the machine will.
