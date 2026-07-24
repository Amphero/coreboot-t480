#!/usr/bin/env python3
"""
archive-build.py  —  offline resilience: save the finished build container image.

The offline build image 'coreboot-t480-<mode>' (pinned/latest) ALREADY contains
everything built (coreboot sources, MrChromebox EDK2, crossgcc toolchain, blobs).
With it archived, the firmware can be rebuilt at any time **without network** —
even if GitHub / review.coreboot.org / the libreboot mirrors disappear.

  python3 scripts/archive-build.py --mode pinned   # or --mode latest

Produces:  podman-image/coreboot-t480-<mode>.tar.zst   (~4-5 GB)

Restore on any machine with podman:
    zstd -dc coreboot-t480-<mode>.tar.zst | podman load
    # then variants as usual:  python3 scripts/build-firmware.py --mode <mode>

Note: the real safety net is sources/<mode>/ anyway (all sources +
versions.lock, see ./fetch.sh) — this image is the *maximum* redundancy.
"""
import argparse, subprocess, sys, shutil
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
OUTDIR  = PROJECT / "podman-image"


def main():
    ap = argparse.ArgumentParser(description="Archive the finished offline build image (per mode)")
    ap.add_argument("--mode", default="pinned", choices=["pinned", "latest"],
                    help="which image to archive: coreboot-t480-<mode> (default pinned)")
    args = ap.parse_args()
    IMAGE = f"coreboot-t480-{args.mode}"

    if subprocess.run(["podman", "image", "exists", IMAGE]).returncode != 0:
        sys.exit(f"Image '{IMAGE}' does not exist — run  python3 scripts/build-firmware.py --mode {args.mode}  first.")

    comp, ext = ("zstd", "zst") if shutil.which("zstd") else ("xz", "xz")
    OUTDIR.mkdir(parents=True, exist_ok=True)
    dest = OUTDIR / f"{IMAGE}.tar.{ext}"

    print(f"Archiving podman image '{IMAGE}'  ->  {dest}")
    print(f"Compression: {comp}. This takes a few minutes (8 GB -> ~2-3 GB) …")

    # pipe podman save (uncompressed) through the compressor
    save = subprocess.Popen(["podman", "save", IMAGE], stdout=subprocess.PIPE)
    cargs = ["zstd", "-T0", "-19", "-o", str(dest)] if comp == "zstd" else ["xz", "-T0", "-c"]
    if comp == "zstd":
        subprocess.run(cargs, stdin=save.stdout, check=True)
    else:
        with open(dest, "wb") as f:
            subprocess.run(cargs, stdin=save.stdout, stdout=f, check=True)
    save.wait()

    size_gb = dest.stat().st_size / 1e9
    print(f"\n✅ Done: {dest}  ({size_gb:.1f} GB)")
    print("   Restore:  "
          + (f"zstd -dc {dest.name} | podman load" if comp == "zstd"
             else f"xz -dc {dest.name} | podman load"))


if __name__ == "__main__":
    main()
