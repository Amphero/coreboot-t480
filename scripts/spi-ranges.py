#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""
spi-ranges.py - read the PCH Flash Protected Range registers of a running
machine with this firmware.

  sudo python3 scripts/spi-ranges.py

WHY: the ranges are the boundary that neither BIOS Lock nor root can lift
(README.md, "What the write protections allow"), and nothing in userspace
reports them. `flashrom --flash-name` used to print them, but with
DT_DEVICE_FAST_SPI=y it opens /dev/mtd0 and takes the MTD path, which prints
no BIOS Control, FREG or PR lines at all. BIOS Control is PCI config space and
`setpci -s 00:1f.5 dc.b` still reads it; the FPRs are not, they sit in SPIBAR.

The coreboot log covers the normal case - `grep -a "FPR " /sys/firmware/log`
shows what was programmed at boot. This reads the hardware instead, which is
the thing that actually decides, and is the way to check after a coreboot or
FSP update that FSP did not take the registers first.

WHERE: SPIBAR is BAR0 of the Fast SPI controller at 00:1f.5, and the five FPR
registers start at offset 0x84 (SPI_FPR_SHIFT = 12, so 4 KB granularity).
Needs iomem=relaxed on the kernel command line, otherwise /dev/mem refuses the
mapping.

Expected on this firmware: FPR0 over WP_RO, FPR1 over SI_DESC + SI_GBE, both
WPE=1 RPE=0 - write-protected, still readable, so a full-chip backup works.
"""

import mmap, os, sys

DEV_PATH = "/sys/bus/pci/devices/0000:00:1f.5"
FPR_BASE = 0x84
FPR_COUNT = 5
FPR_SHIFT = 12
WPE = 1 << 31
RPE = 1 << 15


def spibar():
    """BAR0 of the Fast SPI controller, from sysfs rather than hardcoded."""
    try:
        with open(f"{DEV_PATH}/resource") as f:
            start = int(f.readline().split()[0], 16)
    except FileNotFoundError:
        sys.exit(f"ERROR: {DEV_PATH} does not exist.\n"
                 f"   The SPI controller is hidden from the OS - that is\n"
                 f"   DT_DEVICE_FAST_SPI=n in config/board.conf. Read the\n"
                 f"   ranges from the coreboot log instead:\n"
                 f"       grep -a 'FPR ' /sys/firmware/log")
    if not start:
        sys.exit("ERROR: BAR0 of 00:1f.5 reads as 0 - no SPIBAR to map.")
    return start


def main():
    base = spibar()
    page = base & ~(mmap.PAGESIZE - 1)
    off = base - page

    try:
        fd = os.open("/dev/mem", os.O_RDONLY)
    except PermissionError:
        sys.exit("ERROR: /dev/mem is root-only - run this as root.")
    except FileNotFoundError:
        sys.exit("ERROR: /dev/mem does not exist - the kernel needs CONFIG_DEVMEM.")

    try:
        m = mmap.mmap(fd, off + 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
    except OSError as e:
        os.close(fd)
        sys.exit(f"ERROR: cannot map SPIBAR at 0x{base:08x}: {e}\n"
                 f"   The kernel blocks /dev/mem over PCI MMIO unless the\n"
                 f"   command line carries iomem=relaxed.")

    print(f"SPIBAR 0x{base:08x}, FPR0-{FPR_COUNT - 1} at +0x{FPR_BASE:02x}")
    locked = 0
    for i in range(FPR_COUNT):
        pos = off + FPR_BASE + i * 4
        v = int.from_bytes(m[pos:pos + 4], "little")
        if v == 0:
            print(f"  FPR{i}  0x{v:08x}  free")
            continue
        locked += 1
        start = (v & 0x7fff) << FPR_SHIFT
        end = (((v >> 16) & 0x7fff) << FPR_SHIFT) | ((1 << FPR_SHIFT) - 1)
        print(f"  FPR{i}  0x{v:08x}  0x{start:08x}-0x{end:08x}"
              f"  writes={'blocked' if v & WPE else 'ALLOWED'}"
              f"  reads={'blocked' if v & RPE else 'allowed'}")

    m.close()
    os.close(fd)

    if not locked:
        sys.exit("\nERROR: no protected range is programmed at all.")


if __name__ == "__main__":
    main()
