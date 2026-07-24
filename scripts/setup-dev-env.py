#!/usr/bin/env python3
"""
setup-dev-env.py  -  convenient front-end for PHASE 1 (FETCH).

Checks the host requirements (only podman) and then runs ./fetch.sh, which
builds the build-environment image and downloads ALL sources completely into
sources/<mode>/ (coreboot incl. submodules + crossgcc tarballs, MrChromebox
EDK2, libreboot tarball, lbmk with a populated cache). PHASE 2 then builds offline.

  python3 scripts/setup-dev-env.py                 # BUILD_MODE=pinned (HW-tested)
  python3 scripts/setup-dev-env.py --mode latest   # newest stable versions
  python3 scripts/setup-dev-env.py --mode latest --refresh

Next:  python3 scripts/build-firmware.py --mode <pinned|latest>
"""
import argparse, subprocess, sys, shutil, getpass
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
FETCH   = PROJECT / "fetch.sh"


def check_tools():
    print("[1/2] checking host requirements ...")
    if not shutil.which("podman"):
        sys.exit("   podman is missing. Install:  sudo pacman -S podman\n"
                 "   (rootless needs /etc/subuid + /etc/subgid entries for your user)")
    user = getpass.getuser()
    subuid = Path("/etc/subuid")
    if subuid.exists() and user not in subuid.read_text():
        print(f"   note: no /etc/subuid entry for '{user}' - rootless podman may need:")
        print(f"     sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 {user}")
    if not FETCH.exists():
        sys.exit(f"   {FETCH} is missing?!")
    print("   ok: podman present (everything else runs in the container)")


def run_fetch(mode, refresh):
    print(f"[2/2] starting PHASE 1 (FETCH):  ./fetch.sh {mode}{' --refresh' if refresh else ''}")
    cmd = ["bash", str(FETCH), mode] + (["--refresh"] if refresh else [])
    r = subprocess.run(cmd, cwd=PROJECT)
    if r.returncode != 0:
        sys.exit("   ERROR: fetch failed - see output above.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Prepare the dev environment + PHASE 1 fetch",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--mode", default="pinned", choices=["pinned", "latest"])
    ap.add_argument("--refresh", action="store_true", help="re-resolve the 'latest' versions")
    args = ap.parse_args()

    print(f"Project: {PROJECT}\n")
    check_tools()
    run_fetch(args.mode, args.refresh)
    print(f"\ndev environment + sources/{args.mode} ready.")
    print(f"   Next:  python3 scripts/build-firmware.py --mode {args.mode} --help")
