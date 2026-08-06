#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""
vbnv.py - read and steer the vboot non-volatile block (VBNV) of a running
machine with this firmware.

  sudo python3 scripts/vbnv.py show
  sudo python3 scripts/vbnv.py try-next A
  sudo python3 scripts/vbnv.py boot-ok

WHY: two things upstream leaves to the ChromeOS updater, which this firmware
does not have.

`try-next`: when a slot fails verification, vboot flips VB2_NV_TRY_NEXT to the
other slot and never flips it back (`fail_impl()`, 2misc.c:123). Repairing the
broken slot does not move the machine back to it.

`boot-ok`: the TPM rollback counter only moves when the *previous* boot was
reported successful - `2firmware.c:210` wants a higher version, the same slot as
last boot, and `last_fw_result == VB2_FW_RESULT_SUCCESS`. Nothing in coreboot or
vboot ever writes SUCCESS (on ChromeOS that is `crossystem fw_result`), so
without this the counter stays at 0 forever. Run it late in the boot, when
"successful" actually means something - see README.md for the systemd unit.

WHERE: CMOS index 0x34, 16 bytes. coreboot reads the block at
CONFIG_VBOOT_VBNV_OFFSET + 14 (security/vboot/vbnv_cmos.c), and this board's
VBOOT_VBNV_OFFSET is 0x26. /dev/nvram hides the first 14 RTC bytes, so the file
offset is 0x26 as well - the two numbers match by construction, not by accident.

The block carries a header signature and a CRC-8; both are checked before
anything is written back, and nothing is touched when they do not verify.

FIRST RUN: expect `Input/output error`. The kernel guards /dev/nvram with the
legacy PC CMOS checksum and refuses both reads and writes while it is stale
(pc_nvram_read()/pc_nvram_write() in drivers/char/nvram.c). coreboot only
maintains that checksum with USE_OPTION_TABLE, and this board has no
cmos.layout, so it never does. `fix-checksum` makes the kernel recompute it
once.

That is safe here: the checksum covers CMOS 16-45 and lives at 46/47, while
VBNV sits at 52-67. coreboot reads neither in this configuration - its
cmos_set_checksum() call sits inside `if (CONFIG(USE_OPTION_TABLE))`
(drivers/pc80/rtc/mc146818rtc.c). Nothing else writes CMOS 16-45 on this
machine, so it stays valid afterwards.

Changes apply on the next reboot - the firmware reads VBNV in verstage.
"""
import argparse, errno, fcntl, sys

NVRAM_DEV  = "/dev/nvram"
NVRAM_OFF  = 0x26   # = CONFIG_VBOOT_VBNV_OFFSET, see the module docstring
BLOCK_SIZE = 16     # VBOOT_VBNV_BLOCK_SIZE

NVRAM_SETCKS = 0x7041   # _IO('p', 0x41), uapi/linux/nvram.h - recompute checksum

EIO_HINT = ("the kernel refuses /dev/nvram while the legacy PC CMOS checksum is\n"
            "       stale, and this firmware never writes it. Run once:\n"
            "           sudo python3 scripts/vbnv.py fix-checksum")

# offsets inside the block - security/vboot/vbnv_layout.h, 2nvstorage_fields.h
OFFS_HEADER   = 0
OFFS_RECOVERY = 2
OFFS_BOOT2    = 7
OFFS_CRC      = 15

HEADER_MASK      = 0xc3
HEADER_SIGNATURE = 0x40

# fields in the BOOT2 byte
BOOT2_RESULT_MASK       = 0x03
BOOT2_TRIED             = 0x04
BOOT2_TRY_NEXT          = 0x08
BOOT2_PREV_RESULT_MASK  = 0x30
BOOT2_PREV_RESULT_SHIFT = 4
BOOT2_PREV_TRIED        = 0x40

RESULTS = {0: "unknown", 1: "trying", 2: "success", 3: "failure"}
RESULT_SUCCESS = 2   # VB2_FW_RESULT_SUCCESS


def crc8(data):
    """CRC-8 ITU, x^8 + x^2 + x + 1. Same routine as vboot's vb2_crc8() and
    coreboot's crc8_vbnv(); the mask to 16 bits stands in for the C code's
    implicit truncation in the final (uint8_t)(crc >> 8)."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc ^= 0x1070 << 3
            crc = (crc << 1) & 0xffff
    return crc >> 8


def slot_name(bit):
    return "B" if bit else "A"


def open_nvram(mode):
    try:
        return open(NVRAM_DEV, mode, buffering=0)
    except FileNotFoundError:
        sys.exit(f"ERROR: {NVRAM_DEV} does not exist - the kernel needs CONFIG_NVRAM.")
    except PermissionError:
        sys.exit(f"ERROR: {NVRAM_DEV} is root-only - run this as root.")


def read_block():
    with open_nvram("rb") as f:
        f.seek(NVRAM_OFF)
        try:
            blk = f.read(BLOCK_SIZE)
        except OSError as e:
            if e.errno == errno.EIO:
                sys.exit(f"ERROR: cannot read {NVRAM_DEV}: {EIO_HINT}")
            raise
    if len(blk) != BLOCK_SIZE:
        sys.exit(f"ERROR: short read from {NVRAM_DEV} ({len(blk)} of {BLOCK_SIZE} bytes).")
    return bytearray(blk)


def check(blk):
    """The two checks coreboot's verify_vbnv() makes. Returns None when good."""
    if (blk[OFFS_HEADER] & HEADER_MASK) != HEADER_SIGNATURE:
        return (f"header signature {blk[OFFS_HEADER] & HEADER_MASK:#04x}, "
                f"expected {HEADER_SIGNATURE:#04x}")
    want = crc8(blk[:OFFS_CRC])
    if blk[OFFS_CRC] != want:
        return f"CRC {blk[OFFS_CRC]:#04x}, computed {want:#04x}"
    return None


def write_block(blk):
    blk[OFFS_CRC] = crc8(blk[:OFFS_CRC])
    with open_nvram("r+b") as f:
        f.seek(NVRAM_OFF)
        try:
            f.write(bytes(blk))
        except OSError as e:
            if e.errno == errno.EIO:
                sys.exit(f"ERROR: cannot write {NVRAM_DEV}: {EIO_HINT}")
            raise


def cmd_boot_ok(_args):
    """Report this boot as successful, so the next one can roll the TPM
    rollback counter forward (2firmware.c:210)."""
    blk = read_block()
    bad = check(blk)
    if bad:
        sys.exit(f"ERROR: the VBNV block does not verify ({bad}) - refusing to write.\n"
                 f"       Reboot once so the firmware rewrites it, then try again.")

    if (blk[OFFS_BOOT2] & BOOT2_RESULT_MASK) == RESULT_SUCCESS:
        print("this boot is already marked successful - nothing written")
        return 0

    blk[OFFS_BOOT2] = (blk[OFFS_BOOT2] & ~BOOT2_RESULT_MASK & 0xff) | RESULT_SUCCESS
    write_block(blk)

    back = read_block()
    if check(back) or (back[OFFS_BOOT2] & BOOT2_RESULT_MASK) != RESULT_SUCCESS:
        sys.exit("ERROR: the write did not stick.")
    print(f"boot marked successful (slot {slot_name(back[OFFS_BOOT2] & BOOT2_TRIED)})")
    return 0


def cmd_fix_checksum(_args):
    """Have the kernel recompute the legacy PC CMOS checksum. Writes CMOS 46/47
    and nothing else; the VBNV block at 52-67 is not touched."""
    with open_nvram("r+b") as f:
        try:
            fcntl.ioctl(f, NVRAM_SETCKS)
        except OSError as e:
            sys.exit(f"ERROR: NVRAM_SETCKS failed: {e}")
    print("CMOS checksum recomputed - /dev/nvram is readable now")
    return cmd_show(None)


def cmd_show(_args):
    blk = read_block()
    bad = check(blk)
    boot2 = blk[OFFS_BOOT2]
    prev_result = (boot2 & BOOT2_PREV_RESULT_MASK) >> BOOT2_PREV_RESULT_SHIFT
    print(f"raw               {blk.hex(' ')}")
    print(f"integrity         {'ok' if bad is None else 'BAD - ' + bad}")
    print(f"running slot      {slot_name(boot2 & BOOT2_TRIED)}")
    print(f"result so far     {RESULTS[boot2 & BOOT2_RESULT_MASK]}")
    print(f"previous slot     {slot_name(boot2 & BOOT2_PREV_TRIED)}")
    print(f"previous result   {RESULTS[prev_result]}")
    print(f"next boot         slot {slot_name(boot2 & BOOT2_TRY_NEXT)}")
    print(f"recovery request  {blk[OFFS_RECOVERY]:#04x}")
    return 1 if bad else 0


def cmd_try_next(args):
    slot = args.slot.upper()
    blk = read_block()
    bad = check(blk)
    if bad:
        sys.exit(f"ERROR: the VBNV block does not verify ({bad}) - refusing to write.\n"
                 f"       Reboot once so the firmware rewrites it, then try again.")

    before = blk[OFFS_BOOT2]
    if slot == "B":
        blk[OFFS_BOOT2] |= BOOT2_TRY_NEXT
    else:
        blk[OFFS_BOOT2] &= ~BOOT2_TRY_NEXT & 0xff
    if blk[OFFS_BOOT2] == before:
        print(f"next boot already selects slot {slot} - nothing written")
        return 0

    write_block(blk)

    back = read_block()
    bad = check(back)
    if bad:
        sys.exit(f"ERROR: the block does not verify after writing ({bad}).\n"
                 f"       Reboot; a bad block makes the firmware fall back to the\n"
                 f"       copy in RW_NVRAM, so this is recoverable.")
    if not bool(back[OFFS_BOOT2] & BOOT2_TRY_NEXT) == (slot == "B"):
        sys.exit("ERROR: the write did not stick - CMOS may be write-protected.")
    print(f"next boot selects slot {slot} - reboot to apply")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="Read and steer the vboot NV block (VBNV) in CMOS",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)

    sub.add_parser("show", help="decode the block: which slot runs, which one is next")

    p = sub.add_parser("try-next", help="pick the slot the next boot selects")
    p.add_argument("slot", choices=["A", "B", "a", "b"], help="slot to boot next")

    sub.add_parser("boot-ok", help="report this boot as successful (rollback counter)")

    sub.add_parser("fix-checksum",
                   help="recompute the legacy CMOS checksum so /dev/nvram opens up")

    args = ap.parse_args()
    return {"show": cmd_show,
            "try-next": cmd_try_next,
            "boot-ok": cmd_boot_ok,
            "fix-checksum": cmd_fix_checksum}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
