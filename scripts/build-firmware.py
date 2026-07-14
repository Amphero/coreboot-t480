#!/usr/bin/env python3
"""
build-firmware.py  —  T480 coreboot+EDK2-Firmware bauen (PHASE 2, OFFLINE).

Zwei-Phasen-Ablauf:
  PHASE 1  ./fetch.sh [pinned|latest]        (einmalig, mit Netz -> sources/<mode>/)
  PHASE 2  python3 scripts/build-firmware.py --mode <pinned|latest>   (OHNE Netz)

Dieses Skript baut ausschließlich aus sources/<mode>/ und betreibt sowohl den
Image-Build als auch die Varianten-Läufe mit **--network=none** (verifizierbar
offline). Fertige ROMs + die verwendete versions.lock landen in roms/.
Flashen: extern per CH341A — siehe README.md.

Beispiele:
  python3 scripts/build-firmware.py                         # pinned: TPM + Setup Mode + RNG (finale Firmware)
  python3 scripts/build-firmware.py --mode latest           # aus sources/latest/
  python3 scripts/build-firmware.py --tpm-reset             # zusätzlich ein Reset-ROM (TPM2_Clear) — siehe README.md
  python3 scripts/build-firmware.py --no-tpm               # TPM deaktivieren (OS sieht kein TPM)
  python3 scripts/build-firmware.py --auto-enroll           # MS-Keys automatisch (kein Setup Mode)
  python3 scripts/build-firmware.py --no-rng                # EFI_RNG_PROTOCOL (RDRAND) weglassen
  python3 scripts/build-firmware.py --plain                 # nur die rohe Image-ROM
  python3 scripts/build-firmware.py --mac AA:BB:CC:DD:EE:FF
  python3 scripts/build-firmware.py --rebuild-base          # Offline-Image von Grund auf neu

Danach Secure Boot mit sbctl einrichten (README.md) — WICHTIG:
CMOS-Batterie angeschlossen + korrekte Uhrzeit, sonst scheitert das Key-Enrollen!
"""
import argparse, subprocess, sys, hashlib, shutil, datetime, re
from pathlib import Path

PROJECT    = Path(__file__).resolve().parent.parent
BUILD      = PROJECT / "build"         # Build-Rezepte: Dockerfile.offline/.deps, apply-devicetree.sh
CONFIG     = PROJECT / "config"        # Board-Konfig + Boot-Logo: defconfig, splash.bmp
ROMS       = PROJECT / "roms"
SOURCES    = PROJECT / "sources"
PATCHDIR   = PROJECT / "patches" / "tpm-reset"   # Clear-Patch für das optionale --tpm-reset
IMAGE_PREFIX = "coreboot-t480"       # Offline-Image PRO MODUS: coreboot-t480-pinned / -latest
DEPS_IMAGE = "coreboot-t480-deps"

FDF ="/opt/coreboot/payloads/external/edk2/workspace/mrchromebox/UefiPayloadPkg/UefiPayloadPkg.fdf"


def run(cmd, **kw):
    print("   $", " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, check=True, **kw)


def config_mac():
    """MAC-Default aus config/defconfig lesen (Marker-Zeile '# MAC=AA:BB:..')."""
    for line in (CONFIG / "defconfig").read_text().splitlines():
        m = re.match(r"\s*#\s*MAC\s*=\s*([0-9A-Fa-f:]{17})\b", line)
        if m:
            return m.group(1).lower()
    return None


def image_exists(name):
    return subprocess.run(["podman", "image", "exists", name]).returncode == 0


# ---------------------------------------------------------------- PHASE 1 checks
def require_sources(mode):
    """Die sources/<mode>/ müssen aus PHASE 1 vorhanden sein — kein stiller Fallback."""
    src = SOURCES / mode
    lock = src / "versions.lock"
    if not lock.exists():
        sys.exit(f"❌ sources/{mode}/ fehlt (keine versions.lock).\n"
                 f"   Erst PHASE 1 ausführen:  ./fetch.sh {mode}")
    for need in ("coreboot", "edk2/mrchromebox", "lbmk", "defconfig"):
        if not (src / need).exists():
            sys.exit(f"❌ sources/{mode}/{need} fehlt — PHASE-1-Fetch unvollständig.\n"
                     f"   Neu holen:  ./fetch.sh {mode} --refresh")
    if not image_exists(DEPS_IMAGE):
        sys.exit(f"❌ Build-Umgebungs-Image '{DEPS_IMAGE}' fehlt.\n"
                 f"   Wird von PHASE 1 gebaut:  ./fetch.sh {mode}")
    return src


def verify_checksums(src):
    """sha256sums.txt aus PHASE 1 prüfen (harte Integritätskontrolle vor dem Build)."""
    sums = src / "sha256sums.txt"
    if not sums.exists():
        sys.exit(f"❌ {sums} fehlt — PHASE 1 unvollständig. ./fetch.sh <mode> --refresh")
    print(f"[integrität] sha256sum -c {sums.relative_to(PROJECT)}")
    r = subprocess.run(["sha256sum", "-c", "sha256sums.txt"], cwd=src)
    if r.returncode != 0:
        sys.exit("❌ SHA256-Prüfung fehlgeschlagen — Quellen korrupt. ./fetch.sh <mode> --refresh")
    print("   SHA256: OK ✓")


def sync_build_config(src):
    """Aktuelles config/defconfig (+splash.bmp) in sources/<mode>/ spiegeln.
    So greifen lokale defconfig-Tweaks beim Offline-Build (Context = sources/<mode>/),
    ohne dass PHASE 1 neu laufen muss. Wirkt sich erst mit --rebuild-base aus."""
    shutil.copy2(CONFIG / "defconfig", src / "defconfig")
    shutil.copy2(BUILD / "apply-devicetree.sh", src / "apply-devicetree.sh")  # config-driven devicetree toggles
    sp = CONFIG / "splash.bmp"
    if sp.exists():
        shutil.copy2(sp, src / "splash.bmp")
    else:
        (src / "splash.bmp").unlink(missing_ok=True)
    print(f"[config] defconfig + apply-devicetree.sh{' + splash.bmp' if sp.exists() else ''}  ->  sources/{src.name}/")


def log_versions(src):
    """Verwendete Versionen loggen und als versions_<mode>.lock ins roms/ kopieren
    (pro Modus getrennt, damit pinned/latest sich nicht gegenseitig überschreiben)."""
    lock = src / "versions.lock"
    print("\n=== verwendete Versionen (versions.lock) ===")
    print("\n".join("   " + l for l in lock.read_text().splitlines() if l and not l.startswith("#")))
    ROMS.mkdir(parents=True, exist_ok=True)
    dest = ROMS / f"versions_{src.name}.lock"
    shutil.copy2(lock, dest)
    print(f"   -> kopiert nach {dest.relative_to(PROJECT)}")


# ---------------------------------------------------------------- PHASE 2 build
def lock_get(src, key):
    """Wert aus sources/<mode>/versions.lock lesen (leer, wenn nicht vorhanden)."""
    for line in (src / "versions.lock").read_text().splitlines():
        if line.startswith(f"{key}=") and not line.startswith("#"):
            return line.split("=", 1)[1].strip()
    return ""


def build_base(src, image, mac, force):
    """Offline-Image bauen: Context = sources/<mode>/, --network=none."""
    if image_exists(image) and not force:
        print(f"[base] Image '{image}' vorhanden — überspringe (--rebuild-base zum Neubau).")
        return
    print(f"[base] OFFLINE-Build '{image}' (MAC={mac}, --network=none) — erster Lauf ~30-60 min (crossgcc) …")
    cmd = ["podman", "build", "--network=none", "--build-arg", f"MAC_ADDRESS={mac}"]
    # EDK2-Branch aus versions.lock an coreboot durchreichen (CONFIG_EDK2_TAG_OR_REV),
    # damit der vorplatzierte Klon genutzt wird statt coreboots evtl. anderem Default.
    edk2_branch = lock_get(src, "EDK2_BRANCH")
    if edk2_branch:
        cmd += ["--build-arg", f"EDK2_BRANCH={edk2_branch}"]
    cmd += ["-f", str(BUILD / "Dockerfile.offline"), "-t", image, str(src)]
    run(cmd)


def container_build(image, no_tpm, setup_mode, enable_rng, outname, reset_patch=None):
    """Variante im vorhandenen Image erzeugen (schnell, crossgcc wird wiederverwendet). OFFLINE.

    reset_patch: optionaler Clear-Patch (patches/tpm-reset/…). Ist er gesetzt, wird er vor
    `make` angewandt -> Reset-ROM, das das TPM 2.0 bei JEDEM Boot per TPM2_Clear zurücksetzt;
    danach wird am Ramstage nachgewiesen, dass der Hook wirklich drin ist."""
    steps = ['set -e', 'git config --global --add safe.directory "*"']
    if setup_mode:
        # EnrollDefaultKeys-DXE auskommentieren -> Firmware startet im Setup Mode.
        # dirty tree -> coreboots edk2-Makefile ueberspringt 'git checkout -f', Patch ueberlebt.
        steps.append(rf'sed -i "/EnrollDefaultKeys\/EnrollDefaultKeys\.inf/ s/^/#/" {FDF}')
    steps.append('cd /opt/coreboot')
    config_changed = False
    if no_tpm:
        steps += [
            r'sed -i "s/^CONFIG_TPM2=y/# CONFIG_TPM2 is not set/" .config',
            'grep -q "^CONFIG_EDK2_DISABLE_TPM=y" .config || echo "CONFIG_EDK2_DISABLE_TPM=y" >> .config',
        ]
        config_changed = True
    if enable_rng:
        # EFI_RNG_PROTOCOL (RDRAND): RngDxe+Hash2 haengen an NETWORK_DRIVER_ENABLE, der schwere
        # TCP/IP-Stack an NETWORK_ENABLE (bleibt aus) -> nur ~2,5 KB, kein Netzwerk-Stack.
        steps.append(
            r'''grep -q 'NETWORK_DRIVER_ENABLE=TRUE' .config || sed -i 's|^CONFIG_EDK2_CUSTOM_BUILD_PARAMS="\(.*\)"|CONFIG_EDK2_CUSTOM_BUILD_PARAMS="\1 -D NETWORK_DRIVER_ENABLE=TRUE"|' .config'''
        )
        config_changed = True
    if config_changed:
        steps.append('make olddefconfig')
    if reset_patch:
        # Clear-Patch NUR fuer das Reset-ROM; muss sauber passen, sonst Abbruch.
        steps += [
            f'echo "[tpm-reset] wende Clear-Patch an: {reset_patch.name}"',
            f'git apply --check /reset/{reset_patch.name} || {{ echo "FEHLER: Clear-Patch {reset_patch.name} passt nicht auf diese Basis (API-Drift?)"; exit 1; }}',
            f'git apply /reset/{reset_patch.name}',
        ]
    steps += ['make -j"$(nproc)"']
    if reset_patch:
        # nachweisen, dass der Clear-Hook wirklich im Ramstage steckt (sonst waere das
        # "Reset"-ROM ein stilles No-Op).
        steps += [
            'RD=build/cbfs/fallback/ramstage.debug; [ -f "$RD" ] || RD="$(find build -name ramstage.debug -print -quit)"',
            'test -n "$RD" || { echo "FEHLER: ramstage.debug nicht gefunden"; exit 1; }',
            'nm "$RD" 2>/dev/null | grep -q tpm_reset_clear || { echo "FEHLER: Hook-Symbol tpm_reset_clear fehlt im Reset-Ramstage"; exit 1; }',
            'strings "$RD" | grep -q "TPM-RESET:" || { echo "FEHLER: TPM-RESET-Logstrings fehlen im Reset-Ramstage"; exit 1; }',
            'echo "[tpm-reset] Reset-ROM: Hook nachweislich enthalten (nm + strings)"',
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
    print(f"  Größe : {len(data)} Bytes  {'(16 MB ✓)' if ok else '✗ NICHT 16 MB!'}")
    print(f"  MD5   : {hashlib.md5(data).hexdigest()}")
    print(f"  MAC   : {mac}")
    print(f"  Pfad  : {rom}")
    if not ok:
        sys.exit("  ✗ Größe falsch — Build fehlgeschlagen?")


def main():
    ap = argparse.ArgumentParser(description="T480 coreboot+EDK2 Firmware bauen (Phase 2, offline)",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--mode", default="pinned", choices=["pinned", "latest"],
                    help="welche sources/<mode>/ verwenden (Default pinned = HW-getestet)")
    ap.add_argument("--mac", help="MAC überschreiben (Default: Marker '# MAC=' aus config/defconfig)")
    ap.add_argument("--no-tpm", action="store_true",
                    help="TPM deaktivieren (OS sieht kein TPM). Default: TPM ist AN (der T480-TPM ist repariert)")
    ap.add_argument("--tpm-reset", action="store_true",
                    help="ZUSÄTZLICH ein Reset-ROM erzeugen (…_tpmreset.rom): cleart das TPM 2.0 bei JEDEM "
                         "Boot per TPM2_Clear. Ablauf: Reset-ROM flashen, einmal booten, dann das normale "
                         "ROM flashen. Details/Warnungen: README.md. (Nicht mit --no-tpm/--plain kombinierbar.)")
    ap.add_argument("--auto-enroll", action="store_true", help="MS-Keys automatisch (kein Setup Mode)")
    ap.add_argument("--no-rng", action="store_true",
                    help="EFI_RNG_PROTOCOL (RDRAND) NICHT einbauen (Default: RNG ist drin, ~2,5 KB, KEIN Netzwerk-Stack)")
    ap.add_argument("--plain", action="store_true", help="nur rohe Image-ROM (SB, TPM, Auto-Enroll)")
    ap.add_argument("--rebuild-base", action="store_true", help="Offline-Image von Grund auf neu bauen")
    ap.add_argument("--version", help="Versionsstring für den ROM-Namen "
                    "(Default: pinned -> 'pinned' (eingefroren); latest -> Datum JJJJMMTT, z.B. 20260709)")
    ap.add_argument("--output", help="Ausgabedateiname komplett überschreiben (Default: coreboot_t480_<version>[…].rom)")
    args = ap.parse_args()

    mac = (args.mac or config_mac() or "").lower()
    if not re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
        sys.exit("❌ Ungültige/fehlende MAC ('%s'). In config/defconfig als '# MAC=AA:BB:CC:DD:EE:FF' "
                 "hinterlegen oder --mac AA:BB:.. angeben." % mac)

    # --tpm-reset braucht ein aktives TPM (es cleart es ja) und den Varianten-Pfad.
    if args.tpm_reset and args.no_tpm:
        sys.exit("❌ --tpm-reset cleart das TPM und braucht es daher aktiv — nicht mit --no-tpm kombinierbar.")
    if args.tpm_reset and args.plain:
        sys.exit("❌ --tpm-reset ist nicht mit --plain kombinierbar (plain = rohe Basis-ROM ohne Variante).")
    reset_patch = None
    if args.tpm_reset:
        reset_patch = PATCHDIR / f"tpm2-clear-on-boot_{args.mode}.patch"
        if not reset_patch.exists():
            reset_patch = PATCHDIR / "tpm2-clear-on-boot.patch"
        if not reset_patch.exists():
            sys.exit(f"❌ Reset-Patch fehlt in {PATCHDIR}/ (tpm2-clear-on-boot[_{args.mode}].patch)")

    # PHASE 1 muss gelaufen sein — kein stilles Zurückfallen auf Online/anderen Modus.
    src = require_sources(args.mode)
    verify_checksums(src)
    sync_build_config(src)
    log_versions(src)

    image = f"{IMAGE_PREFIX}-{args.mode}"          # coreboot-t480-pinned / coreboot-t480-latest
    build_base(src, image, mac, args.rebuild_base)

    # Namens-„Version": pinned ist eingefroren (wird nicht aktueller) -> fester Name 'pinned';
    # latest entwickelt sich weiter -> Datum (JJJJMMTT). Beides via --version überschreibbar.
    ver = args.version or ("pinned" if args.mode == "pinned"
                           else datetime.date.today().strftime("%Y%m%d"))
    if args.plain:
        out = args.output or f"coreboot_t480_{ver}_plain.rom"
        extract_plain(image, out)
    else:
        no_tpm = args.no_tpm      # Default: TPM AN (der reparierte T480-TPM ist jetzt Standard)
        setup_mode = not args.auto_enroll
        enable_rng = not args.no_rng          # RNG ist jetzt Default (mit --no-rng abschaltbar)
        if args.output:
            out = args.output
        else:
            # Default = TPM + Setup Mode + RNG -> nur das Datum. Nur ABWEICHUNGEN
            # vom Default landen als Tag im Namen (sonst wäre der Default-Name „verrauscht").
            dev = (("_no-tpm"  if no_tpm         else "")   # TPM deaktiviert (Default ist AN)
                   + ("_msenroll" if not setup_mode else "")  # MS-Keys auto statt Setup Mode
                   + ("_no-rng"   if not enable_rng else ""))  # RNG weggelassen
            out = f"coreboot_t480_{ver}{dev}.rom"
        print(f"[variante] mode={args.mode}  version={ver}  no_tpm={no_tpm}  setup_mode={setup_mode}  enable_rng={enable_rng}  ->  {out}")
        container_build(image, no_tpm, setup_mode, enable_rng, out)

    verify(ROMS / out)

    # Optional: zusätzlich ein Reset-ROM (gleiche Konfig + Clear-Patch) aus DEMSELBEN Image.
    reset_out = None
    if reset_patch and not args.plain:
        reset_out = f"{out[:-4]}_tpmreset.rom"
        print(f"\n[tpm-reset] erzeuge zusätzlich Reset-ROM (Clear bei JEDEM Boot): {reset_out}")
        container_build(image, no_tpm, setup_mode, enable_rng, reset_out, reset_patch=reset_patch)
        verify(ROMS / reset_out)

    print("\n✅ Fertig (offline gebaut aus sources/%s). Flashen extern per CH341A — siehe README.md." % args.mode)
    print("   Danach Secure Boot per sbctl — CMOS-Batterie an + korrekte Uhrzeit!")
    if reset_out:
        print(f"\n⚠️  TPM-RESET (Details: README.md): erst {reset_out} flashen + EINMAL booten")
        print(f"    (cleart das TPM bei jedem Boot!), verifizieren, DANN {out} flashen.")


if __name__ == "__main__":
    main()
