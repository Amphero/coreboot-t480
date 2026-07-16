#!/usr/bin/env python3
"""
archive-build.py  —  Offline-Resilienz: das fertig gebaute Container-Image sichern.

Das Offline-Build-Image 'coreboot-t480-<mode>' (pinned/latest) enthält BEREITS alles
Gebaute (coreboot-Quellen, MrChromebox-EDK2, crossgcc-Toolchain, Blobs). Wird es
gesichert, lässt sich die Firmware jederzeit **ohne Netz** neu erzeugen — auch wenn
GitHub / review.coreboot.org / die libreboot-Mirrors verschwinden.

  python3 scripts/archive-build.py --mode pinned   # bzw. --mode latest

Erzeugt:  podman-image/coreboot-t480-<mode>.tar.zst   (~4-5 GB)

Wiederherstellen auf beliebiger Maschine mit podman:
    zstd -dc coreboot-t480-<mode>.tar.zst | podman load
    # danach Varianten ganz normal:  python3 scripts/build-firmware.py --mode <mode>

Hinweis: Die eigentliche Absicherung ist ohnehin sources/<mode>/ (alle Quellen +
versions.lock, siehe ./fetch.sh) — dieses Image ist die *maximale* Redundanz.
"""
import argparse, subprocess, sys, shutil
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
OUTDIR  = PROJECT / "podman-image"


def main():
    ap = argparse.ArgumentParser(description="Fertiges Offline-Build-Image sichern (pro Modus)")
    ap.add_argument("--mode", default="pinned", choices=["pinned", "latest"],
                    help="welches Image sichern: coreboot-t480-<mode> (Default pinned)")
    args = ap.parse_args()
    IMAGE = f"coreboot-t480-{args.mode}"

    if subprocess.run(["podman", "image", "exists", IMAGE]).returncode != 0:
        sys.exit(f"Image '{IMAGE}' existiert nicht — erst  python3 scripts/build-firmware.py --mode {args.mode}  ausführen.")

    comp, ext = ("zstd", "zst") if shutil.which("zstd") else ("xz", "xz")
    OUTDIR.mkdir(parents=True, exist_ok=True)
    dest = OUTDIR / f"{IMAGE}.tar.{ext}"

    print(f"Sichere podman-Image '{IMAGE}'  ->  {dest}")
    print(f"Komprimierung: {comp}. Das dauert ein paar Minuten (8 GB -> ~2-3 GB) …")

    # podman save (unkomprimiert) durch den Kompressor pipen
    save = subprocess.Popen(["podman", "save", IMAGE], stdout=subprocess.PIPE)
    cargs = ["zstd", "-T0", "-19", "-o", str(dest)] if comp == "zstd" else ["xz", "-T0", "-c"]
    if comp == "zstd":
        subprocess.run(cargs, stdin=save.stdout, check=True)
    else:
        with open(dest, "wb") as f:
            subprocess.run(cargs, stdin=save.stdout, stdout=f, check=True)
    save.wait()

    size_gb = dest.stat().st_size / 1e9
    print(f"\n✅ Fertig: {dest}  ({size_gb:.1f} GB)")
    print("   Wiederherstellen:  "
          + (f"zstd -dc {dest.name} | podman load" if comp == "zstd"
             else f"xz -dc {dest.name} | podman load"))


if __name__ == "__main__":
    main()
