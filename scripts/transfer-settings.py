#!/usr/bin/env python3
"""
transfer-settings.py — Übernimmt die Einstellungen (UEFI-Variablen inkl.
Secure-Boot-Keys) von einer ORIGINAL-Firmware (Chip-Dump mit deinem
eingerichteten Zustand) auf eine FRISCH GEBAUTE ROM — ohne die Firmware selbst
zu ändern. Es wird eine NEUE Ausgabedatei geschrieben; die Eingaben bleiben unangetastet.

  python3 scripts/transfer-settings.py <original.bin> <neu.rom> [-o out.rom] [--gbe]

WAS übertragen wird:
  SMMSTORE   die komplette UEFI-Variablen-Region: Secure-Boot-Keys (PK/KEK/db),
             Boot-Einträge/-Reihenfolge, Menü-/CFR-Einstellungen, Timeout, …
             -> das sind „die Einstellungen inkl. Secure Boot".
  SI_GBE     nur mit --gbe: die GbE-Region = MAC/Netzwerk-Identität des Originals.

WAS BEWUSST NICHT übertragen wird:
  RW_MRC_CACHE   RAM-Training-Cache — regeneriert beim Boot; alter Cache wäre riskant.
  SI_ME          Intel-ME-Firmware — kein „Setting"; die neue ROM hat ihre (deguardete) ME.
  COREBOOT       die eigentliche Firmware — bleibt die der NEUEN ROM (nur Settings kommen rüber).

FMAP-bewusst: findet die Regionen in beiden ROMs über deren FMAP (Offsets dürfen sich
zwischen Builds unterscheiden); verlangt nur gleiche Region-GRÖSSE.

Zuverlässigkeit: klappt zwischen Builds mit gleicher SMMSTORE-Konfig (gilt für pinned/latest
hier — beide SMMSTORE 0x40000, edk2-Variablenformat kompatibel). Nach dem Flashen prüfen;
falls Secure Boot mal nicht greift: frische ROM flashen + `sbctl enroll-keys -m` (die sbctl-Keys
liegen ohnehin auf der OS-Platte). VOR dem Flashen immer ein Backup ziehen.
"""
import argparse, struct, sys
from pathlib import Path

FMAP_SIG  = b"__FMAP__"
FMAP_HDR  = "<8sBBQI32sH"      # signature, ver_major, ver_minor, base, size, name[32], nareas
FMAP_AREA = "<II32sH"          # offset, size, name[32], flags


def parse_fmap(data, label):
    """FMAP im Image finden und {Regionsname: (offset, size)} zurückgeben."""
    idx = data.find(FMAP_SIG)
    if idx < 0:
        sys.exit(f"❌ {label}: keine FMAP gefunden — ist das ein coreboot-Image?")
    _sig, _vmaj, _vmin, _base, _size, _name, nareas = struct.unpack_from(FMAP_HDR, data, idx)
    areas, off = {}, idx + struct.calcsize(FMAP_HDR)
    for _ in range(nareas):
        aoff, asize, aname, _flags = struct.unpack_from(FMAP_AREA, data, off)
        areas[aname.split(b"\0")[0].decode("ascii", "replace")] = (aoff, asize)
        off += struct.calcsize(FMAP_AREA)
    return areas


def main():
    ap = argparse.ArgumentParser(
        description="Einstellungen (SMMSTORE inkl. Secure Boot) von Original auf frische ROM übertragen",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("original", help="Original-Firmware (16-MB-Chip-Dump mit deinem eingerichteten Zustand)")
    ap.add_argument("new", help="frisch gebaute ROM (Ziel der Einstellungen)")
    ap.add_argument("-o", "--output", help="Ausgabedatei (Default: <neu>_migrated.rom neben der neuen ROM)")
    ap.add_argument("--gbe", action="store_true", help="zusätzlich SI_GBE (MAC/Netzwerk-Identität) übernehmen")
    ap.add_argument("--dry-run", action="store_true", help="nur anzeigen, was passieren würde")
    args = ap.parse_args()

    orig = Path(args.original).read_bytes()
    new  = Path(args.new).read_bytes()
    if len(orig) != len(new):
        sys.exit(f"❌ Größen verschieden ({len(orig)} vs {len(new)} B) — beide müssen dasselbe Flash-Layout sein.")

    ao = parse_fmap(orig, "original")
    an = parse_fmap(new,  "neu")

    regions = ["SMMSTORE"] + (["SI_GBE"] if args.gbe else [])
    out = bytearray(new)
    print(f"Original : {args.original}\nNeu      : {args.new}\n")
    for r in regions:
        if r not in ao:
            sys.exit(f"❌ Region '{r}' fehlt im Original — Layout inkompatibel.")
        if r not in an:
            sys.exit(f"❌ Region '{r}' fehlt in der neuen ROM — Layout inkompatibel.")
        oo, osz = ao[r]
        no, nsz = an[r]
        if osz != nsz:
            sys.exit(f"❌ '{r}' Größe verschieden (orig 0x{osz:X} vs neu 0x{nsz:X}) — nicht übertragbar.")
        out[no:no + nsz] = orig[oo:oo + osz]
        extra = ""
        if r == "SMMSTORE":
            extra = "  (Secure-Boot-Keys erkannt)" if b"Platform Key" in orig[oo:oo + osz] \
                    else "  (keine PK-Signatur gefunden — Original evtl. im Setup Mode?)"
        print(f"  ✓ {r:9} orig @0x{oo:06X}  ->  neu @0x{no:06X}   ({nsz} B){extra}")

    # Sicherheitsnetz: die eigentliche Firmware (COREBOOT) darf sich NICHT geändert haben.
    if "COREBOOT" in an:
        cbo, cbs = an["COREBOOT"]
        if bytes(out[cbo:cbo + cbs]) != new[cbo:cbo + cbs]:
            sys.exit("❌ interner Fehler: COREBOOT-Region wäre verändert worden — abgebrochen.")
        print("  · COREBOOT (die neue Firmware) bleibt unverändert ✓")

    if args.dry_run:
        print("\n(dry-run — nichts geschrieben)")
        return
    outp = Path(args.output) if args.output else Path(args.new).parent / (Path(args.new).stem + "_migrated.rom")
    outp.write_bytes(out)
    print(f"\n✅ geschrieben: {outp}  ({len(out)} B)")
    print("   = Firmware der NEUEN ROM + Einstellungen/Secure Boot des Originals.")
    print("   Vor dem Flashen Backup ziehen. Greift Secure Boot nach dem Boot nicht,")
    print("   Fallback: die frische ROM flashen und `sbctl enroll-keys -m`.")


if __name__ == "__main__":
    main()
