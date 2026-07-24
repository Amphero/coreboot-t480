#!/usr/bin/env python3
"""
transfer-settings.py - carries the settings (UEFI variables incl. Secure Boot
keys) over from an ORIGINAL firmware (chip dump with your configured state)
onto a FRESHLY BUILT ROM - without touching the firmware itself. A NEW output
file is written; the inputs stay untouched.

  python3 scripts/transfer-settings.py <original.bin> <new.rom> [-o out.rom] [--gbe]

WHAT is transferred:
  SMMSTORE   the complete UEFI variable region: Secure Boot keys (PK/KEK/db),
             boot entries/order, menu/CFR settings, timeout, ...
             -> that is "the settings incl. Secure Boot".
  SI_GBE     only with --gbe: the GbE region = MAC/network identity of the original.

WHAT is deliberately NOT transferred:
  RW_MRC_CACHE   RAM training cache - regenerates at boot; a stale cache would be risky.
  SI_ME          Intel ME firmware - not a "setting"; the new ROM has its own (deguarded) ME.
  COREBOOT       the firmware itself - stays that of the NEW ROM (only settings move over).

FMAP-aware: locates the regions in both ROMs via their FMAP (offsets may differ
between builds); only requires equal region SIZE.

Reliability: works between builds with the same SMMSTORE config (true for
pinned/latest here - both SMMSTORE 0x40000, edk2 variable format compatible).
Verify after flashing; if Secure Boot ever doesn't take: flash the fresh ROM +
`sbctl enroll-keys -m` (the sbctl keys live on the OS disk anyway). ALWAYS take
a backup before flashing.
"""
import argparse, struct, sys
from pathlib import Path

FMAP_SIG  = b"__FMAP__"
FMAP_HDR  = "<8sBBQI32sH"      # signature, ver_major, ver_minor, base, size, name[32], nareas
FMAP_AREA = "<II32sH"          # offset, size, name[32], flags


def parse_fmap(data, label):
    """Find the FMAP in the image and return {region name: (offset, size)}."""
    idx = data.find(FMAP_SIG)
    if idx < 0:
        sys.exit(f"ERROR: {label}: no FMAP found - is this a coreboot image?")
    _sig, _vmaj, _vmin, _base, _size, _name, nareas = struct.unpack_from(FMAP_HDR, data, idx)
    areas, off = {}, idx + struct.calcsize(FMAP_HDR)
    for _ in range(nareas):
        aoff, asize, aname, _flags = struct.unpack_from(FMAP_AREA, data, off)
        areas[aname.split(b"\0")[0].decode("ascii", "replace")] = (aoff, asize)
        off += struct.calcsize(FMAP_AREA)
    return areas


def main():
    ap = argparse.ArgumentParser(
        description="Transfer settings (SMMSTORE incl. Secure Boot) from the original onto a fresh ROM",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("original", help="original firmware (16 MB chip dump with your configured state)")
    ap.add_argument("new", help="freshly built ROM (target of the settings)")
    ap.add_argument("-o", "--output", help="output file (default: <new>_migrated.rom next to the new ROM)")
    ap.add_argument("--gbe", action="store_true", help="also carry over SI_GBE (MAC/network identity)")
    ap.add_argument("--dry-run", action="store_true", help="only show what would happen")
    args = ap.parse_args()

    orig = Path(args.original).read_bytes()
    new  = Path(args.new).read_bytes()
    if len(orig) != len(new):
        sys.exit(f"ERROR: sizes differ ({len(orig)} vs {len(new)} B) - both must share the same flash layout.")

    ao = parse_fmap(orig, "original")
    an = parse_fmap(new,  "new")

    regions = ["SMMSTORE"] + (["SI_GBE"] if args.gbe else [])
    out = bytearray(new)
    print(f"Original : {args.original}\nNew      : {args.new}\n")
    for r in regions:
        if r not in ao:
            sys.exit(f"ERROR: region '{r}' missing in the original - layout incompatible.")
        if r not in an:
            sys.exit(f"ERROR: region '{r}' missing in the new ROM - layout incompatible.")
        oo, osz = ao[r]
        no, nsz = an[r]
        if osz != nsz:
            sys.exit(f"ERROR: '{r}' sizes differ (orig 0x{osz:X} vs new 0x{nsz:X}) - not transferable.")
        out[no:no + nsz] = orig[oo:oo + osz]
        extra = ""
        if r == "SMMSTORE":
            extra = "  (Secure Boot keys detected)" if b"Platform Key" in orig[oo:oo + osz] \
                    else "  (no PK signature found - original perhaps in Setup Mode?)"
        print(f"  {r:9} orig @0x{oo:06X}  ->  new @0x{no:06X}   ({nsz} B){extra}")

    # Safety net: the firmware itself (COREBOOT) must NOT have changed.
    if "COREBOOT" in an:
        cbo, cbs = an["COREBOOT"]
        if bytes(out[cbo:cbo + cbs]) != new[cbo:cbo + cbs]:
            sys.exit("ERROR: internal error: the COREBOOT region would have been modified - aborted.")
        print("  COREBOOT (the new firmware) stays unchanged")

    if args.dry_run:
        print("\n(dry run - nothing written)")
        return
    outp = Path(args.output) if args.output else Path(args.new).parent / (Path(args.new).stem + "_migrated.rom")
    outp.write_bytes(out)
    print(f"\nwritten: {outp}  ({len(out)} B)")
    print("   = firmware of the NEW ROM + settings/Secure Boot of the original.")
    print("   Take a backup before flashing. If Secure Boot doesn't take after boot,")
    print("   fallback: flash the fresh ROM and run `sbctl enroll-keys -m`.")


if __name__ == "__main__":
    main()
