#!/usr/bin/env python3
"""
setup-dev-env.py  —  PHASE 1 (FETCH) bequem anstoßen.

Prüft die Host-Voraussetzungen (nur podman) und ruft dann ./fetch.sh auf, das
das Build-Umgebungs-Image baut und ALLE Quellen vollständig nach
sources/<mode>/ lädt (coreboot inkl. Submodule + crossgcc-Tarballs, MrChromebox-
EDK2, libreboot-Tarball, lbmk mit populiertem Cache). Danach baut PHASE 2 offline.

  python3 scripts/setup-dev-env.py                 # BUILD_MODE=pinned (HW-getestet)
  python3 scripts/setup-dev-env.py --mode latest   # neueste stabile Stände
  python3 scripts/setup-dev-env.py --mode latest --refresh

Weiter:  python3 scripts/build-firmware.py --mode <pinned|latest>
"""
import argparse, subprocess, sys, shutil, getpass
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
FETCH   = PROJECT / "fetch.sh"


def check_tools():
    print("[1/2] Host-Voraussetzungen prüfen …")
    if not shutil.which("podman"):
        sys.exit("   podman fehlt. Installieren:  sudo pacman -S podman\n"
                 "   (rootless braucht /etc/subuid + /etc/subgid Einträge für deinen User)")
    user = getpass.getuser()
    subuid = Path("/etc/subuid")
    if subuid.exists() and user not in subuid.read_text():
        print(f"   ⚠ Hinweis: kein /etc/subuid-Eintrag für '{user}' — rootless podman evtl. nötig:")
        print(f"     sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 {user}")
    if not FETCH.exists():
        sys.exit(f"   {FETCH} fehlt?!")
    print("   ok: podman vorhanden (alles Weitere läuft im Container)")


def run_fetch(mode, refresh):
    print(f"[2/2] PHASE 1 (FETCH) starten:  ./fetch.sh {mode}{' --refresh' if refresh else ''}")
    cmd = ["bash", str(FETCH), mode] + (["--refresh"] if refresh else [])
    r = subprocess.run(cmd, cwd=PROJECT)
    if r.returncode != 0:
        sys.exit("   ❌ Fetch fehlgeschlagen — siehe Ausgabe oben.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Dev-Umgebung vorbereiten + PHASE-1-Fetch",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--mode", default="pinned", choices=["pinned", "latest"])
    ap.add_argument("--refresh", action="store_true", help="'latest'-Versionen neu auflösen")
    args = ap.parse_args()

    print(f"Projekt: {PROJECT}\n")
    check_tools()
    run_fetch(args.mode, args.refresh)
    print(f"\n✅ Dev-Umgebung + sources/{args.mode} bereit.")
    print(f"   Weiter:  python3 scripts/build-firmware.py --mode {args.mode} --help")
