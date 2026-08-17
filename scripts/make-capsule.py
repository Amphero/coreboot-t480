#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""
make-capsule.py - build a UEFI update capsule from a ROM built by this repo.

  python3 scripts/make-capsule.py roms/coreboot_t480_<version>.rom

WHAT goes in: both RW slots, A first then B, and nothing else. Not the whole
ROM. Two reasons, and the second is the one that decides it.

  A slot image is not interchangeable between the slots. FSP-M is
  execute-in-place on this SoC and bound to its flash address, and romstage
  carries references to it, so fallback/romstage and fspm.bin differ between
  RW_SECTION_A and RW_SECTION_B while the other ten CBFS files are identical.
  The builder cannot know which slot will be inactive on the machine that
  applies the capsule, so both have to travel.

  The rest of the chip has no business in a capsule. WP_RO is sealed by a
  protected range and cannot be written from the payload at all, and shipping
  SI_ME would mean handing on the Intel blob with it.

WHAT the firmware does with it: FmpDeviceSlotLib picks the half matching the
inactive slot, writes it, and arms a trial boot. See
patches/edk2/0003-fmp-device-slot-lib.patch.

SIGNING: with no arguments this uses the certificate set from keys/capsule/
(scripts/gen-capsule-certs.sh), the same root the firmware embeds through
CONFIG_DRIVERS_EFI_CAPSULE_TRUSTED_PUBLIC_CERT in config/defconfig. The
--signer-cert/--other-cert/--trusted-cert options override it. Only when
neither exists does this fall back to EDK2's published test certificates -
the ones that make FmpDxe print "Warning test key is used" and that anyone
can sign with. Fine for checking that the mechanism works, useless as a
boundary.

The GUID and the versions are read from config/defconfig, so they cannot drift
away from the firmware that has to accept the result.
"""

import argparse
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
DEFCONFIG = PROJECT / "config" / "defconfig"
IMAGE = "coreboot-t480"

# Inside the build image.
EDK2 = "/opt/coreboot/payloads/external/edk2/workspace/mrchromebox"
TESTCERTS = f"{EDK2}/BaseTools/Source/Python/Pkcs7Sign"

FMAP_SIGNATURE = b"__FMAP__"
FMAP_NAMELEN = 32


def defconfig_value(key):
    """Read one CONFIG_ value out of config/defconfig."""
    text = DEFCONFIG.read_text()
    m = re.search(rf"^{key}=(.*)$", text, re.M)
    if not m:
        sys.exit(f"ERROR: {key} is not set in config/defconfig.")
    return m.group(1).strip().strip('"')


def parse_fmap_at(rom, pos):
    """Parse a flash map at pos, or return None if it is not one.

    The signature also occurs in coreboot's own log strings, which are in the
    image - eight matches in a normal ROM, one of them the map. So a candidate
    has to prove itself: a version this code understands, a plausible area
    count, and an area named FMAP that points back at where the candidate was
    found. Nothing else in the image satisfies the last one.
    """
    head = 8 + 1 + 1 + 8 + 4 + FMAP_NAMELEN + 2
    if pos + head > len(rom):
        return None

    ver_major, ver_minor = rom[pos + 8], rom[pos + 9]
    if ver_major != 1:
        return None

    nareas = struct.unpack_from("<H", rom, pos + head - 2)[0]
    if not 1 <= nareas <= 64 or pos + head + nareas * 42 > len(rom):
        return None

    areas = {}
    for i in range(nareas):
        off, size, name, _flags = struct.unpack_from(
            f"<II{FMAP_NAMELEN}sH", rom, pos + head + i * 42)
        try:
            areas[name.rstrip(b"\0").decode("ascii")] = (off, size)
        except UnicodeDecodeError:
            return None

    if areas.get("FMAP", (None,))[0] != pos:
        return None
    return areas


def find_fmap(rom):
    """Locate the flash map and return its areas as {name: (offset, size)}.

    Searched for rather than read from a fixed offset: the layout is allowed to
    move between builds, and a capsule built against the wrong offsets would be
    accepted by the firmware and write the wrong bytes.
    """
    found, pos = [], 0
    while True:
        pos = rom.find(FMAP_SIGNATURE, pos)
        if pos < 0:
            break
        areas = parse_fmap_at(rom, pos)
        if areas is not None:
            found.append((pos, areas))
        pos += 1

    if not found:
        sys.exit("ERROR: no flash map in this image - is it a coreboot ROM?")
    if len(found) > 1:
        sys.exit("ERROR: several valid flash maps at "
                 + ", ".join(hex(p) for p, _ in found) + " - refusing to guess.")
    return found[0][1]


METAINFO = """\
<?xml version="1.0" encoding="UTF-8"?>
<component type="firmware">
  <id>com.github.amphero.coreboot-t480.firmware</id>
  <name>coreboot T480</name>
  <summary>coreboot with EDK2 payload for the ThinkPad T480</summary>
  <description>
    <p>
      Slot-only firmware update. The capsule carries both verified-boot
      slots; the firmware writes the inactive one and arms a trial boot,
      so a bad update falls back to the running slot on its own.
    </p>
  </description>
  <provides>
    <firmware type="flashed">{guid}</firmware>
  </provides>
  <url type="homepage">https://github.com/Amphero/custom-coreboot-t480</url>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>GPL-3.0-only</project_license>
  <categories>
    <category>X-System</category>
  </categories>
  <releases>
    <release version="{version}" timestamp="{timestamp}">
      <description>
        <p>Built from {rom}.</p>
      </description>
    </release>
  </releases>
  <custom>
    <value key="LVFS::UpdateProtocol">org.uefi.capsule</value>
    <value key="LVFS::VersionFormat">number</value>
  </custom>
</component>
"""


def build_cab(cap, out, guid, version, rom_name):
    """Pack the capsule into the cabinet archive fwupd consumes.

    fwupdmgr does not take bare capsules: it wants a cab holding the payload
    plus a MetaInfo naming the ESRT GUID and the release version. The version
    is the decimal form of the FMP version, because that is how fwupd renders
    the ESRT entry ("number"). gcab lives in the build image, not on the host
    (Dockerfile.deps).
    """
    probe = subprocess.run(
        ["podman", "run", "--rm", "--network=none", IMAGE, "sh", "-c", "command -v gcab"],
        capture_output=True)
    if probe.returncode != 0:
        print("WARNING: no gcab in the build image - no .cab for fwupd was written.\n"
              "         Rebuild the image once:  ./fetch.sh --rebuild-deps")
        return None

    stage = Path(tempfile.mkdtemp(prefix=".cabstage-", dir=out.parent))
    try:
        # fwupd looks for the payload under the default id firmware.bin;
        # any other name fails with "no image id firmware.bin found".
        shutil.copy2(cap, stage / "firmware.bin")
        (stage / "firmware.metainfo.xml").write_text(METAINFO.format(
            guid=guid, version=version, timestamp=int(time.time()), rom=rom_name))
        subprocess.run(
            ["podman", "run", "--rm", "--network=none", "--user", "root",
             "-v", f"{stage}:/stage:z", "-w", "/stage", IMAGE,
             "gcab", "-cn", f"/stage/{out.name}",
             "firmware.bin", "firmware.metainfo.xml"],
            check=True)
        shutil.move(stage / out.name, out)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Build an update capsule containing both RW slots of a ROM")
    ap.add_argument("rom", help="ROM built by scripts/build-firmware.py")
    ap.add_argument("-o", "--output", help="output file (default: <rom>.cap)")
    ap.add_argument("--signer-cert", help="signing certificate with its private key")
    ap.add_argument("--other-cert", help="intermediate certificate")
    ap.add_argument("--trusted-cert", help="root certificate the firmware trusts")
    args = ap.parse_args()

    rom_path = Path(args.rom).resolve()
    if not rom_path.is_file():
        sys.exit(f"ERROR: {rom_path} does not exist.")
    out = Path(args.output).resolve() if args.output else rom_path.with_suffix(".cap")

    rom = rom_path.read_bytes()
    areas = find_fmap(rom)

    missing = [n for n in ("RW_SECTION_A", "RW_SECTION_B") if n not in areas]
    if missing:
        sys.exit(f"ERROR: {', '.join(missing)} missing from the flash map - "
                 f"this ROM was not built with verified boot.")

    (off_a, size_a), (off_b, size_b) = areas["RW_SECTION_A"], areas["RW_SECTION_B"]
    if size_a != size_b:
        sys.exit(f"ERROR: the slots differ in size ({size_a:#x} vs {size_b:#x}); "
                 f"the firmware side splits the image in half and would write "
                 f"the wrong bytes.")

    payload = rom[off_a:off_a + size_a] + rom[off_b:off_b + size_b]
    payload_path = out.with_suffix(".payload")
    payload_path.write_bytes(payload)

    guid = defconfig_value("CONFIG_DRIVERS_EFI_MAIN_FW_GUID")
    version = int(defconfig_value("CONFIG_DRIVERS_EFI_MAIN_FW_VERSION"), 0)
    lsv = int(defconfig_value("CONFIG_DRIVERS_EFI_MAIN_FW_LSV"), 0) or version

    own = (args.signer_cert, args.other_cert, args.trusted_cert)
    if any(own) and not all(own):
        sys.exit("ERROR: --signer-cert, --other-cert and --trusted-cert go together.")

    # Without explicit options, use the set scripts/gen-capsule-certs.sh put
    # into keys/capsule/ - the same root the firmware embeds via the
    # defconfig, so what this signs is what that build accepts.
    capdir = PROJECT / "keys" / "capsule"
    if not any(own):
        certs = (capdir / "signer.pem", capdir / "sub.pub.pem", capdir / "root.pub.pem")
        if all(c.is_file() for c in certs):
            own = tuple(str(c) for c in certs)
            print(f"signing with keys/capsule/ ({certs[2].name} is the firmware's trust anchor)")

    if all(own):
        certs = [Path(c).resolve() for c in own]
        mounts, signer, other, trusted = [], *(f"/certs/{c.name}" for c in certs)
        for c in certs:
            mounts += ["-v", f"{c}:/certs/{c.name}:ro,z"]
    else:
        print("WARNING: signing with EDK2's published test certificates. Anyone\n"
              "         can produce a capsule this firmware will accept. Pass\n"
              "         --signer-cert/--other-cert/--trusted-cert for your own.")
        mounts = []
        # The .pem files carry the private keys; the public certificates the
        # two -public-cert options want are the .pub.pem ones. TestSub.pem is
        # not even PEM, which openssl reports as an undecodable certificate.
        signer, other, trusted = (f"{TESTCERTS}/TestCert.pem",
                                  f"{TESTCERTS}/TestSub.pub.pem",
                                  f"{TESTCERTS}/TestRoot.pub.pem")

    cmd = [
        "podman", "run", "--rm", "--network=none", "--user", "root",
        "-v", f"{payload_path.parent}:/out:z", *mounts, IMAGE, "bash", "-c",
        f'cd {EDK2} && export WORKSPACE=$PWD EDK_TOOLS_PATH=$PWD/BaseTools '
        f'PYTHONPATH=$PWD/BaseTools/Source/Python && '
        f'python3 BaseTools/Source/Python/Capsule/GenerateCapsule.py -e '
        f'-o /out/{out.name} --guid {guid} --capflag PersistAcrossReset '
        f'--fw-version {version} --lsv {lsv} '
        f'--signer-private-cert {signer} --other-public-cert {other} '
        f'--trusted-public-cert {trusted} /out/{payload_path.name}'
    ]
    print("   $ " + " ".join(cmd))
    subprocess.run(cmd, check=True)
    payload_path.unlink()

    cab = build_cab(out, out.with_suffix(".cab"), guid, version, rom_path.name)

    print(f"\n=== {out.name} ===")
    print(f"  slots  : A at {off_a:#x}, B at {off_b:#x}, {size_a:#x} bytes each")
    print(f"  payload: {len(payload)} bytes")
    print(f"  guid   : {guid}")
    print(f"  version: {version:#010x}  lsv {lsv:#010x}")
    print(f"  path   : {out}")
    if cab:
        print(f"  fwupd  : {cab}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
