#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""
build-firmware.py  -  build the T480 coreboot+EDK2 firmware (PHASE 2, OFFLINE).

Two-phase flow:
  PHASE 1  ./fetch.sh [pinned|latest]        (once, with network -> sources/<mode>/)
  PHASE 2  python3 scripts/build-firmware.py --mode <pinned|latest>   (NO network)

This script builds exclusively from sources/<mode>/ and runs both the image
build and the variant passes with **--network=none** (verifiably offline).
Finished ROMs + the versions.lock that was used end up in roms/.
Flashing: externally via CH341A - see README.md.

Examples:
  python3 scripts/build-firmware.py                         # pinned: TPM + Setup Mode + RNG (final firmware)
  python3 scripts/build-firmware.py --mode latest           # from sources/latest/
  python3 scripts/build-firmware.py --tpm-reset             # additionally a reset ROM (TPM2_Clear) - see README.md
  python3 scripts/build-firmware.py --no-tpm               # disable the TPM (OS sees no TPM)
  python3 scripts/build-firmware.py --auto-enroll           # MS keys automatically (no Setup Mode)
  python3 scripts/build-firmware.py --no-rng                # leave out EFI_RNG_PROTOCOL (RDRAND)
  python3 scripts/build-firmware.py --plain                 # just the raw image ROM
  python3 scripts/build-firmware.py --mac AA:BB:CC:DD:EE:FF
  python3 scripts/build-firmware.py --rebuild-base          # rebuild the offline image from scratch

Afterwards set up Secure Boot with sbctl (README.md) - IMPORTANT:
CMOS battery connected + correct clock, otherwise key enrolling fails!
"""
import argparse, os, subprocess, sys, hashlib, shutil, datetime, re
from pathlib import Path

PROJECT    = Path(__file__).resolve().parent.parent
BUILD      = PROJECT / "build"         # build recipes: Dockerfile.offline/.deps, apply-devicetree.sh
CONFIG     = PROJECT / "config"        # board config + boot logo: defconfig, splash.bmp
ROMS       = PROJECT / "roms"
SOURCES    = PROJECT / "sources"
PATCHDIR   = PROJECT / "patches" / "tpm-reset"   # clear patch for the optional --tpm-reset
IMAGE_PREFIX = "coreboot-t480"       # offline image PER MODE: coreboot-t480-pinned / -latest
DEPS_IMAGE = "coreboot-t480-deps"

FDF ="/opt/coreboot/payloads/external/edk2/workspace/mrchromebox/UefiPayloadPkg/UefiPayloadPkg.fdf"


def run(cmd, **kw):
    print("   $", " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, check=True, **kw)


def board_conf():
    """Parse config/board.conf: plain KEY=value lines, '#' comments ignored.
    Deliberately NOT sourced as shell - both consumers (this script and
    build/apply-devicetree.sh) parse the same ^KEY=value shape."""
    vals = {}
    f = CONFIG / "board.conf"
    if f.exists():
        for line in f.read_text().splitlines():
            if line.lstrip().startswith("#"):
                continue
            m = re.match(r"\s*([A-Za-z0-9_]+)\s*=\s*(\S+)", line)
            if m:
                vals[m.group(1)] = m.group(2)
    return vals


def image_exists(name):
    return subprocess.run(["podman", "image", "exists", name]).returncode == 0


# ---------------------------------------------------------------- PHASE 1 checks
def require_sources(mode):
    """sources/<mode>/ from PHASE 1 must be present - no silent fallback."""
    src = SOURCES / mode
    lock = src / "versions.lock"
    if not lock.exists():
        sys.exit(f"ERROR: sources/{mode}/ is missing (no versions.lock).\n"
                 f"   Run PHASE 1 first:  ./fetch.sh {mode}")
    for need in ("coreboot", "edk2/mrchromebox", "lbmk", "defconfig"):
        if not (src / need).exists():
            sys.exit(f"ERROR: sources/{mode}/{need} is missing - PHASE 1 fetch incomplete.\n"
                     f"   Re-fetch:  ./fetch.sh {mode} --refresh")
    if not image_exists(DEPS_IMAGE):
        sys.exit(f"ERROR: build-environment image '{DEPS_IMAGE}' is missing.\n"
                 f"   PHASE 1 builds it:  ./fetch.sh {mode}")
    return src


def verify_checksums(src):
    """Verify PHASE 1's sha256sums.txt (hard integrity check before the build)."""
    sums = src / "sha256sums.txt"
    if not sums.exists():
        sys.exit(f"ERROR: {sums} is missing - PHASE 1 incomplete. ./fetch.sh <mode> --refresh")
    print(f"[integrity] sha256sum -c {sums.relative_to(PROJECT)}")
    r = subprocess.run(["sha256sum", "-c", "sha256sums.txt"], cwd=src)
    if r.returncode != 0:
        sys.exit("ERROR: SHA256 check failed - sources corrupt. ./fetch.sh <mode> --refresh")
    print("   SHA256: OK")


def sync_build_config(src):
    """Mirror the current config/defconfig (+splash.bmp) and patches/ into sources/<mode>/.
    That way local defconfig/patch tweaks reach the offline build (context = sources/<mode>/)
    without re-running PHASE 1. Takes effect only with --rebuild-base."""
    shutil.copy2(CONFIG / "defconfig", src / "defconfig")
    shutil.copy2(CONFIG / "board.conf", src / "board.conf")      # MAC marker + DT_DEVICE toggles
    shutil.copy2(BUILD / "apply-devicetree.sh", src / "apply-devicetree.sh")  # config-driven devicetree toggles
    sp = CONFIG / "splash.bmp"
    if sp.exists():
        shutil.copy2(sp, src / "splash.bmp")
    else:
        (src / "splash.bmp").unlink(missing_ok=True)
    dst = src / "patches"
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(PROJECT / "patches", dst)                    # base patches (Dockerfile.offline) + tpm-reset
    print(f"[config] defconfig + board.conf + apply-devicetree.sh + patches/{' + splash.bmp' if sp.exists() else ''}  ->  sources/{src.name}/")


def log_versions(src):
    """Log the versions in use and copy them to roms/ as versions_<mode>.lock
    (separate per mode so pinned/latest don't overwrite each other)."""
    lock = src / "versions.lock"
    print("\n=== versions in use (versions.lock) ===")
    print("\n".join("   " + l for l in lock.read_text().splitlines() if l and not l.startswith("#")))
    ROMS.mkdir(parents=True, exist_ok=True)
    dest = ROMS / f"versions_{src.name}.lock"
    shutil.copy2(lock, dest)
    print(f"   -> copied to {dest.relative_to(PROJECT)}")


# ---------------------------------------------------------------- PHASE 2 build
def lock_get(src, key):
    """Read a value from sources/<mode>/versions.lock (empty if absent)."""
    for line in (src / "versions.lock").read_text().splitlines():
        if line.startswith(f"{key}=") and not line.startswith("#"):
            return line.split("=", 1)[1].strip()
    return ""


def config_hash(src, mac):
    """Fingerprint of everything that gets baked into the base image: the MAC,
    versions.lock, defconfig, board.conf, apply-devicetree.sh, splash.bmp and
    every patches/base/*.patch. Stored as an image label so a later run can
    tell whether the existing image still matches the working tree."""
    h = hashlib.sha256()
    h.update(mac.encode() + b"\0")
    for name in ("versions.lock", "defconfig", "board.conf",
                 "apply-devicetree.sh", "splash.bmp"):
        f = src / name
        if f.exists():
            h.update(name.encode() + b"\0" + f.read_bytes() + b"\0")
    for p in sorted((src / "patches" / "base").glob("*.patch")):
        h.update(p.name.encode() + b"\0" + p.read_bytes() + b"\0")
    return h.hexdigest()


def build_base(src, image, mac, force):
    """Build the offline image: context = sources/<mode>/, --network=none."""
    chash = config_hash(src, mac)
    if image_exists(image) and not force:
        r = subprocess.run(["podman", "image", "inspect", "-f",
                            '{{index .Config.Labels "t480.confighash"}}', image],
                           capture_output=True, text=True)
        have = r.stdout.strip()
        if have == chash:
            print(f"[base] image '{image}' exists and matches config/patches/MAC - skipping.")
            return
        if have in ("", "<no value>"):
            print(f"[base] WARNING: image '{image}' predates the staleness check - cannot verify "
                  f"it matches the current config/patches. --rebuild-base to be certain.")
            return
        sys.exit(f"ERROR: image '{image}' was built from DIFFERENT config/patches/MAC than the "
                 f"working tree.\n   Your changes are NOT in that image. Rebuild:  --rebuild-base"
                 f"\n   (or revert the local changes to build the old state)")
    print(f"[base] OFFLINE build '{image}' (MAC={mac}, --network=none) - first run ~30-60 min (crossgcc) ...")
    cmd = ["podman", "build", "--network=none", "--build-arg", f"MAC_ADDRESS={mac}",
           "--label", f"t480.confighash={chash}"]
    # Pass the EDK2 branch/commit from versions.lock through to coreboot
    # (CONFIG_EDK2_TAG_OR_REV) so the exact pre-placed checkout is used.
    edk2_branch = lock_get(src, "EDK2_BRANCH")
    if edk2_branch:
        cmd += ["--build-arg", f"EDK2_BRANCH={edk2_branch}"]
    edk2_commit = lock_get(src, "EDK2_COMMIT")
    if edk2_commit:
        cmd += ["--build-arg", f"EDK2_COMMIT={edk2_commit}"]
    cmd += ["-f", str(BUILD / "Dockerfile.offline"), "-t", image, str(src)]
    run(cmd)


def container_build(image, no_tpm, setup_mode, enable_rng, outname, reset_patch=None):
    """Produce a variant inside the existing image (fast, crossgcc is reused). OFFLINE.

    reset_patch: optional clear patch (patches/tpm-reset/...). If set, it is applied before
    `make` -> a reset ROM that clears the TPM 2.0 via TPM2_Clear on EVERY boot; afterwards
    the ramstage is checked to prove the hook is really in there."""
    # Every sed below is followed by a grep that PROVES the edit took. sed
    # exits 0 when its pattern matches nothing (the same failure mode that got
    # the base patches moved from sed to git apply --check) - and a silently
    # skipped setup-mode edit would auto-enroll Microsoft keys instead of
    # starting in Setup Mode.
    steps = ['set -e', 'git config --global --add safe.directory "*"']
    if setup_mode:
        # Comment out the EnrollDefaultKeys DXE -> firmware starts in Setup Mode.
        # dirty tree -> coreboot's edk2 Makefile skips 'git checkout -f', the patch survives.
        steps += [
            rf'sed -i "/EnrollDefaultKeys\/EnrollDefaultKeys\.inf/ s/^/#/" {FDF}',
            rf'grep -q "^#.*EnrollDefaultKeys\.inf" {FDF} || {{ echo "ERROR: EnrollDefaultKeys not commented out in UefiPayloadPkg.fdf (EDK2 layout changed?) - would auto-enroll MS keys"; exit 1; }}',
        ]
    steps.append('cd /opt/coreboot')
    config_changed = False
    if no_tpm:
        steps += [
            r'sed -i "s/^CONFIG_TPM2=y/# CONFIG_TPM2 is not set/" .config',
            r'! grep -q "^CONFIG_TPM2=y" .config || { echo "ERROR: CONFIG_TPM2 still enabled after edit"; exit 1; }',
            'grep -q "^CONFIG_EDK2_DISABLE_TPM=y" .config || echo "CONFIG_EDK2_DISABLE_TPM=y" >> .config',
        ]
        config_changed = True
    if enable_rng:
        # EFI_RNG_PROTOCOL (RDRAND): RngDxe+Hash2 hang off NETWORK_DRIVER_ENABLE, the heavy
        # TCP/IP stack off NETWORK_ENABLE (stays off) -> only ~2.5 KB, no network stack.
        steps += [
            r'''grep -q 'NETWORK_DRIVER_ENABLE=TRUE' .config || sed -i 's|^CONFIG_EDK2_CUSTOM_BUILD_PARAMS="\(.*\)"|CONFIG_EDK2_CUSTOM_BUILD_PARAMS="\1 -D NETWORK_DRIVER_ENABLE=TRUE"|' .config''',
            r'''grep -q 'NETWORK_DRIVER_ENABLE=TRUE' .config || { echo "ERROR: could not add NETWORK_DRIVER_ENABLE to CONFIG_EDK2_CUSTOM_BUILD_PARAMS"; exit 1; }''',
        ]
        config_changed = True
    if config_changed:
        steps.append('make olddefconfig')
        # olddefconfig re-evaluates defaults/selects - re-check what must survive it.
        if no_tpm:
            steps.append(r'! grep -q "^CONFIG_TPM2=y" .config || { echo "ERROR: olddefconfig re-enabled CONFIG_TPM2"; exit 1; }')
        if enable_rng:
            steps.append(r'''grep -q 'NETWORK_DRIVER_ENABLE=TRUE' .config || { echo "ERROR: olddefconfig dropped NETWORK_DRIVER_ENABLE"; exit 1; }''')
    if reset_patch:
        # Clear patch ONLY for the reset ROM; must apply cleanly, otherwise abort.
        steps += [
            f'echo "[tpm-reset] applying clear patch: {reset_patch.name}"',
            f'git apply --check /reset/{reset_patch.name} || {{ echo "ERROR: clear patch {reset_patch.name} does not apply to this base (API drift?)"; exit 1; }}',
            f'git apply /reset/{reset_patch.name}',
        ]
    steps += ['make -j"$(nproc)"']
    if reset_patch:
        # prove the clear hook really is in the ramstage (otherwise the "reset"
        # ROM would be a silent no-op).
        steps += [
            'RD=build/cbfs/fallback/ramstage.debug; [ -f "$RD" ] || RD="$(find build -name ramstage.debug -print -quit)"',
            'test -n "$RD" || { echo "ERROR: ramstage.debug not found"; exit 1; }',
            'nm "$RD" 2>/dev/null | grep -q tpm_reset_clear || { echo "ERROR: hook symbol tpm_reset_clear missing from reset ramstage"; exit 1; }',
            'strings "$RD" | grep -q "TPM-RESET:" || { echo "ERROR: TPM-RESET log strings missing from reset ramstage"; exit 1; }',
            'echo "[tpm-reset] reset ROM: hook verifiably present (nm + strings)"',
        ]
    steps += [f'cp build/coreboot.rom /out/{outname}', f'echo BUILT {outname}']
    script = "\n".join(steps)
    ROMS.mkdir(parents=True, exist_ok=True)
    mounts = ["-v", f"{ROMS}:/out:z"]
    if reset_patch:
        mounts += ["-v", f"{reset_patch.parent}:/reset:ro,z"]
    run(["podman", "run", "--rm", "--network=none", *mounts, "--user", "root",
         image, "bash", "-c", script])


def extract_plain(image, outname):
    ROMS.mkdir(parents=True, exist_ok=True)
    run(["podman", "run", "--rm", "--network=none", "-v", f"{ROMS}:/out:z", "--user", "root", image,
         "bash", "-c", f"cp /opt/coreboot/build/coreboot.rom /out/{outname}"])


def verify(rom):
    data = rom.read_bytes()
    mac = ":".join(f"{b:02x}" for b in data[0x1000:0x1006])
    ok = len(data) == 16 * 1024 * 1024
    print(f"\n=== {rom.name} ===")
    print(f"  size  : {len(data)} bytes  {'(16 MB, ok)' if ok else 'NOT 16 MB!'}")
    print(f"  MD5   : {hashlib.md5(data).hexdigest()}")
    print(f"  MAC   : {mac}")
    print(f"  path  : {rom}")
    if not ok:
        sys.exit("  wrong size - build failed?")


def main():
    ap = argparse.ArgumentParser(description="Build the T480 coreboot+EDK2 firmware (phase 2, offline)",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--mode", default="pinned", choices=["pinned", "latest"],
                    help="which sources/<mode>/ to use (default pinned = HW-tested)")
    ap.add_argument("--mac", help="override the MAC (default: marker '# MAC=' in config/defconfig)")
    ap.add_argument("--no-tpm", action="store_true",
                    help="disable the TPM (OS sees no TPM). Default: TPM is ON")
    ap.add_argument("--tpm-reset", action="store_true",
                    help="ADDITIONALLY produce a reset ROM (..._tpmreset.rom): clears the TPM 2.0 on EVERY "
                         "boot via TPM2_Clear. Flow: flash the reset ROM, boot once, then flash the normal "
                         "ROM. Details/warnings: README.md. (Not combinable with --no-tpm/--plain.)")
    ap.add_argument("--auto-enroll", action="store_true", help="MS keys automatically (no Setup Mode)")
    ap.add_argument("--no-rng", action="store_true",
                    help="do NOT include EFI_RNG_PROTOCOL (RDRAND) (default: RNG is in, ~2.5 KB, NO network stack)")
    ap.add_argument("--plain", action="store_true", help="just the raw image ROM (SB, TPM, auto-enroll)")
    ap.add_argument("--rebuild-base", action="store_true", help="rebuild the offline image from scratch")
    ap.add_argument("--version", help="version string for the ROM name "
                    "(default: pinned -> 'pinned' (frozen); latest -> date YYYYMMDD, e.g. 20260709)")
    ap.add_argument("--output", help="override the output file name entirely (default: coreboot_t480_<version>[...].rom)")
    args = ap.parse_args()

    # Precedence: --mac > environment MAC= > config/board.conf. The board.conf
    # entry ships commented out on purpose - the file is tracked in git and a
    # MAC is machine identity.
    mac = (args.mac or os.environ.get("MAC") or board_conf().get("MAC") or "").lower()
    if not re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
        sys.exit("ERROR: no valid MAC ('%s'). Pass it per build (preferred, nothing lands in a "
                 "tracked file):\n"
                 "   MAC=AA:BB:CC:DD:EE:FF python3 scripts/build-firmware.py ...\n"
                 "   or:  --mac AA:BB:CC:DD:EE:FF\n"
                 "   or uncomment the MAC= line in config/board.conf (that file is tracked in git).\n"
                 "   Read yours:  ip link show enp0s31f6 | grep ether" % mac)

    # --tpm-reset needs an active TPM (it clears it, after all) and the variant path.
    if args.tpm_reset and args.no_tpm:
        sys.exit("ERROR: --tpm-reset clears the TPM and therefore needs it active - not combinable with --no-tpm.")
    if args.tpm_reset and args.plain:
        sys.exit("ERROR: --tpm-reset is not combinable with --plain (plain = raw base ROM without a variant).")
    reset_patch = None
    if args.tpm_reset:
        reset_patch = PATCHDIR / f"tpm2-clear-on-boot_{args.mode}.patch"
        if not reset_patch.exists():
            reset_patch = PATCHDIR / "tpm2-clear-on-boot.patch"
        if not reset_patch.exists():
            sys.exit(f"ERROR: reset patch missing in {PATCHDIR}/ (tpm2-clear-on-boot[_{args.mode}].patch)")

    # PHASE 1 must have run - no silent fallback to online/another mode.
    src = require_sources(args.mode)
    verify_checksums(src)
    sync_build_config(src)
    log_versions(src)

    image = f"{IMAGE_PREFIX}-{args.mode}"          # coreboot-t480-pinned / coreboot-t480-latest
    build_base(src, image, mac, args.rebuild_base)

    # Name "version": pinned is frozen (never gets newer) -> fixed name 'pinned';
    # latest keeps evolving -> date (YYYYMMDD). Both overridable via --version.
    ver = args.version or ("pinned" if args.mode == "pinned"
                           else datetime.date.today().strftime("%Y%m%d"))
    if args.plain:
        out = args.output or f"coreboot_t480_{ver}_plain.rom"
        extract_plain(image, out)
    else:
        no_tpm = args.no_tpm      # default: TPM ON
        setup_mode = not args.auto_enroll
        enable_rng = not args.no_rng          # RNG is the default (disable with --no-rng)
        if args.output:
            out = args.output
        else:
            # Default = TPM + Setup Mode + RNG -> just the date. Only DEVIATIONS
            # from the default end up as tags in the name (else the default name gets noisy).
            dev = (("_no-tpm"  if no_tpm         else "")   # TPM disabled (default is ON)
                   + ("_msenroll" if not setup_mode else "")  # MS keys auto instead of Setup Mode
                   + ("_no-rng"   if not enable_rng else ""))  # RNG left out
            out = f"coreboot_t480_{ver}{dev}.rom"
        print(f"[variant] mode={args.mode}  version={ver}  no_tpm={no_tpm}  setup_mode={setup_mode}  enable_rng={enable_rng}  ->  {out}")
        container_build(image, no_tpm, setup_mode, enable_rng, out)

    verify(ROMS / out)

    # Optional: additionally a reset ROM (same config + clear patch) from the SAME image.
    reset_out = None
    if reset_patch and not args.plain:
        reset_out = f"{out[:-4]}_tpmreset.rom"
        print(f"\n[tpm-reset] additionally building the reset ROM (clear on EVERY boot): {reset_out}")
        container_build(image, no_tpm, setup_mode, enable_rng, reset_out, reset_patch=reset_patch)
        verify(ROMS / reset_out)

    print("\nDone (built offline from sources/%s). Flash externally via CH341A - see README.md." % args.mode)
    print("   Then set up Secure Boot via sbctl - CMOS battery connected + correct clock!")
    if reset_out:
        print(f"\nNOTE: TPM-RESET (details: README.md): flash {reset_out} first + boot ONCE")
        print(f"    (it clears the TPM on every boot!), verify, THEN flash {out}.")


if __name__ == "__main__":
    main()
