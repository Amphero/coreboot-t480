# Guide

Step-by-step procedures for building, installing and updating this firmware.
The [README](README.md) has the short version of everything here.

Contents:

- [First install](#first-install)
- [Building](#building)
- [Updating](#updating)
- [Verified boot](#verified-boot)
- [Secure Boot](#secure-boot)
- [Measured boot and the TPM](#measured-boot-and-the-tpm)
- [Hardware notes](#hardware-notes)
- [Troubleshooting](#troubleshooting)
- [Cleaning up](#cleaning-up)

## First install

### While the vendor BIOS is still installed

Two things have to happen before coreboot goes on - both are impossible
afterwards:

- **Bring the EC to `n24ur39w`.** Lenovo's updater does not run under
  coreboot, and the EC has no update path afterwards. Update (or downgrade)
  with Lenovo's bootable updater to the BIOS release that carries EC firmware
  `n24ur39w` - coreboot's EC support, including the debug UART unlock, is
  written against exactly that EC code. In the vendor BIOS setup disable
  "Secure Rollback Prevention" and enable "Flash BIOS Updating by End Users"
  (both under Security → UEFI BIOS Update Option); the bootable updater wants
  Secure Boot off and legacy/CSM boot on. Run it on AC with a charged battery
  and pick the option that also updates the EC.
- **Dump the original firmware.** Once before the Lenovo update and once more
  right before flashing coreboot - the second dump is what you restore if
  anything goes wrong.

> [!WARNING]
> This ROM is for the T480 only. The T480s looks the same on the outside but
> is wired differently - flashing a T480 image onto it bricks it.

### Build the ROM

See [Building](#building) for the details; the short form:

```bash
./fetch.sh                                       # once, downloads 8-12 GB
sh scripts/gen-vboot-keys.sh                     # vboot keyset, once
sh scripts/gen-capsule-certs.sh                  # capsule signing chain, once
MAC=AA:BB:CC:DD:EE:FF python3 scripts/build-firmware.py
```

Both keysets live in `keys/`, untracked. The build refuses to run without
them rather than falling back to public keys anyone can use. The MAC is that
of the onboard NIC - read it with `ip link show enp0s31f6 | grep ether`, or
from a dump of the original firmware (offset 0x1000):

```bash
xxd -s 0x1000 -l 6 -p backup.bin | sed 's/../&:/g;s/:$//'
```

### Flash

External flashing with the CH341A is the only way for the first install.
Power off, unplug AC, remove the external battery, take off the bottom cover
(all screws out, then pry gently - Lenovo's Hardware Maintenance Manual or
any teardown video shows how), unplug the internal battery's connector from
the board and pop out the CR2032 coin cell.

The chip is the Winbond W25Q128 at U49, towards the middle of the board near
the RAM slots. A second, smaller SOIC-8 nearby holds the Thunderbolt
firmware - don't clip that one. Clip on U49, pin 1 on the dot.

The W25Q128 is a 3.3 V chip and many cheap CH341A boards drive the data
lines at 5 V - use a fixed/modded one. Wiring and general SPI flashing:
[Libreboot's 25xx NOR guide](https://libreboot.org/docs/install/spi.html).

```bash
# read twice and compare - no diff output means good clip contact
sudo flashrom -p ch341a_spi -r backup1.bin
sudo flashrom -p ch341a_spi -r backup2.bin
diff backup1.bin backup2.bin

sudo flashrom -p ch341a_spi -w roms/coreboot_t480_<version>.rom
sudo flashrom -p ch341a_spi -v roms/coreboot_t480_<version>.rom
```

A bad flash is not fatal as long as the backup exists: write it back the
same way and the machine is where it started. Keep the backup off the
machine.

### First boot

Reconnect the internal battery and the coin cell, boot and set the clock:

```bash
sudo timedatectl set-ntp true
```

> [!NOTE]
> The clock matters. Secure Boot key enrollment silently fails if it's wrong.

The first boot with vboot clears the TPM: coreboot's
`factory_initialize_tpm2()` starts with a force-clear to set up the vboot NV
spaces. Anything sealed to the TPM before is invalidated; LUKS falls back to
the passphrase and needs re-enrolling
(`systemd-cryptenroll --wipe-slot=tpm2 ...`, delete
`/var/lib/systemd/tpm2-srk-public-key.*`). This happens once.

Pulling the coin cell staled the legacy CMOS checksum, so `vbnv` reports an
I/O error until it is recomputed once:

```bash
sudo python3 scripts/vbnv.py fix-checksum
```

Install the boot-ok service - it reports a successful boot to vboot, which
is what lets the rollback counter advance
([rollback protection](#rollback-protection)):

```bash
sudo install -o root -g root -m 755 scripts/vbnv.py /usr/local/bin/vbnv
sudo tee /etc/systemd/system/vboot-boot-ok.service >/dev/null <<'EOF'
[Unit]
Description=Report a successful boot to vboot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vbnv boot-ok

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now vboot-boot-ok.service
```

The copy is deliberate: the unit runs as root, and a repo in `$HOME` is
writable by your user - root should not execute from there. It also means
the copy has to be refreshed whenever `scripts/vbnv.py` changes.

Then enroll Secure Boot ([Secure Boot](#secure-boot)) and set up fwupd
([updating with fwupd](#with-fwupd)).

## Building

### The two phases

```bash
./fetch.sh                          # PHASE 1: downloads sources, needs network
python3 scripts/build-firmware.py   # PHASE 2: builds offline, in podman
```

The ROM ends up in `roms/coreboot_t480_<version>.rom`, `<version>` being
`git describe` of the checkout. An update capsule (`.cap`) and a fwupd
cabinet (`.cab`) are built alongside every ROM. The first build takes 30-60
minutes because coreboot builds its own toolchain, after that it's fast.

`config/versions.lock` names the four upstream sources (coreboot, EDK2,
libreboot, lbmk) down to the commit, and `./fetch.sh` fetches exactly those.
It is tracked, so a git tag pins the versions together with the defconfig,
the patch series and the build scripts. `./fetch.sh --latest` resolves the
newest upstream versions and rewrites the file; `--refresh` only forces a
re-download; `--rebuild-deps` rebuilds the build-environment image after a
`build/Dockerfile.deps` change.

### Choosing what to build

Two kinds of switch decide what ends up on the chip. **Build flags** pick a
payload variant and are passed per run - the base image is shared, so they
are cheap. **Config changes** in `config/` alter the firmware itself and
need `--rebuild-base` (about 20 minutes; the toolchain layer is cached).

The defaults produce the machine this repo is built for: verified boot with
your own keys, all three write protections on, authenticated capsule
updates, Secure Boot in Setup Mode, TPM enabled.

| If you want | change | note |
|-------------|--------|------|
| no verified boot at all | drop `CONFIG_VBOOT`/`CONFIG_FMDFILE` from `config/defconfig` | different flash layout - needs an external flash, settings are lost |
| verified boot with your own keys | `sh scripts/gen-vboot-keys.sh` | the build refuses to sign with the public devkeys |
| capsule updates with your own root | `sh scripts/gen-capsule-certs.sh` | the build refuses to embed a missing trust anchor |
| flash writes blocked outside SMM | `CONFIG_BOOTMEDIA_SMM_BWP` + `..._RUNTIME_OPTION` | adds the **BIOS Lock** toggle to the setup menu |
| `WP_RO` sealed against the OS | `CONFIG_BOOTMEDIA_LOCK_CONTROLLER` + `CONFIG_BOOTMEDIA_LOCK_WPRO_VBOOT_RO` | RO changes need the programmer afterwards |
| descriptor and GbE sealed too | `CONFIG_BOOTMEDIA_LOCK_DESCRIPTOR_GBE` | second range, patch 0043 - the MAC then needs the programmer |
| rollback protection to bite | raise `CONFIG_VBOOT_KEYBLOCK_VERSION`, record it | see [versions and the rollback counter](#versions-and-the-rollback-counter) |
| newer upstream sources | `./fetch.sh --latest`, or edit `config/versions.lock` | only the components whose ref moved are re-fetched |
| the SPI controller hidden from Linux | `DT_DEVICE_FAST_SPI=n` in `config/board.conf` | hides `/dev/mtd*`, fwupd's SPI checks and `setpci` |
| a different boot logo | replace `config/splash.bmp` | 24-bit uncompressed BMP, max 1920x1080 |
| a different MAC | `--mac` or `MAC=` in `config/board.conf` | `board.conf` is tracked - a MAC there shows up in diffs |

Build flags, no rebuild needed:

| Flag | Effect |
|------|--------|
| `--tpm-reset` | also build a ROM that clears a stuck TPM ([TPM reset](#tpm-reset)) |
| `--no-tpm` | build without TPM support |
| `--auto-enroll` | enroll Microsoft's Secure Boot keys instead of Setup Mode |
| `--no-rng` | leave out the RNG |
| `--plain` | just the raw base ROM (TPM on, Microsoft keys auto-enrolled) |
| `--version NAME` | version part of the ROM **file name** - unrelated to the firmware versions |
| `--rebuild-base` | rebuild from scratch after editing `config/defconfig`, `config/board.conf` or `patches/` |

Patches in `patches/base/` are applied to the coreboot tree when the base
image is built, in lexical order and with a mandatory `git apply --check` -
a patch that no longer applies aborts the build instead of being skipped
silently. `patches/edk2/` works the same way for the payload tree. **Each
patch is documented in [patches/README.md](patches/README.md).**

`config/board.conf` toggles optional devices with a simple `y`/`n`
(`config/defconfig` is pure Kconfig; machine identity and device toggles
live in `board.conf`):

```
DT_DEVICE_SMBUS=y        # SMBus - touchpad in RMI4/InterTouch mode (PCI 1f.4)
DT_DEVICE_HECI1=n        # HECI1 (PCI 16.0)
DT_DEVICE_FAST_SPI=y     # Fast SPI (PCI 1f.5)
```

A custom boot logo goes into `config/splash.bmp` (24-bit uncompressed BMP).
ImageMagick turns any image into the right format:

```bash
magick yourimage.png -type TrueColor -compress None BMP3:config/splash.bmp
```

The logo is centered per the BGRT spec, so keep it no larger than the panel
(1920x1080). Both need `--rebuild-base`.

<details>
<summary>Manual build without the scripts</summary>
<br>

The first step only exists as a script, it downloads too much to type by
hand. But once `sources/` is filled you can run the build itself manually:

```bash
# build-environment image (only needed if it doesn't exist yet)
podman build -t coreboot-t480-deps -f build/Dockerfile.deps build

# offline build; the build context is the sources dir. Set YOUR MAC here -
# there is no placeholder check on this manual path, what you type goes into
# the GbE region verbatim.
MAC=AA:BB:CC:DD:EE:FF
podman build --network=none --build-arg MAC_ADDRESS="$MAC" \
    -f build/Dockerfile.offline -t coreboot-t480 sources

# copy the ROM out of the image
mkdir -p roms
podman run --rm --network=none -v "$PWD/roms":/out:z --user root \
    coreboot-t480 bash -c 'cp /opt/coreboot/build/coreboot.rom /out/coreboot.rom'
```

That produces the base image (TPM on, Microsoft keys auto-enrolled). The
default variant - TPM, Setup Mode, RNG - is the variant pass on top of it,
which only `build-firmware.py` does, as does the capsule/cab step.

</details>

### Versions and the rollback counter

Two version numbers, two jobs:

- **`CONFIG_DRIVERS_EFI_MAIN_FW_VERSION`** is the version the ESRT reports
  and capsules carry - fwupd compares against it. Encoding is
  `(major << 16) | minor`, e.g. `0x001A0008` for 26.08. Raise it for every
  release, or fwupd only installs with `--allow-reinstall`.
- **`CONFIG_VBOOT_KEYBLOCK_VERSION`** is the rollback version. vboot refuses
  any slot below the counter in the TPM, so raising it locks out every older
  image - backups included - once the counter follows. Raise it only for a
  release that should do that (a fixed verstage bug, a leaked key), and
  record it first in
  [docs/firmware-versions.md](docs/firmware-versions.md) - the build refuses
  unrecorded values. Full mechanics, pitfalls and the ways back:
  [rollback protection](#rollback-protection).

### Cleaning up

A full build cycle leaves four things on disk; together they run to some
50 GB. All of it is reproducible - the only artifacts worth keeping are the
`.rom`/`.cap`/`.cab` of the deployed version and everything under `keys/`
(which no cleanup below touches).

| What | Where | Size | Comes back via |
|------|-------|------|----------------|
| fetched sources | `sources/` | ~11 GB | `./fetch.sh` (network) |
| build environment | podman image `coreboot-t480-deps` | ~5 GB | `./fetch.sh` |
| build image | podman image `coreboot-t480` (+ `debian` base) | ~13 GB | `make build` |
| dangling layers | untagged podman images, mostly from aborted builds | up to tens of GB | - |
| old ROMs | `roms/coreboot_t480_*` | ~33 MB each | rebuild of that tag |

```bash
rm roms/coreboot_t480_<old-version>*                 # keep the deployed set
rm -rf sources/
podman rmi coreboot-t480 coreboot-t480-deps debian
podman image prune                                   # dangling layers
podman rmi -a -f                                     # or: simply drop every image
```

Keeping `sources/` and the two images skips the re-fetch and most of the
compile on the next build; dropping everything costs one `./fetch.sh` plus
a full toolchain build (~1-2 h). Aborted builds (power loss, Ctrl-C) leave
their half-finished layers behind as untagged images - `podman image prune`
after an aborted build is always safe.

## Updating

Four paths. The first is the normal one; the machine boots from the slots,
so none of them touches `WP_RO` except the last.

Whatever the path, settings survive: SMMSTORE (Secure Boot keys, boot
entries, setup options), the MRC cache and the vboot state sit outside every
region an update writes.

### With fwupd

One-time host setup. Local cabs carry no LVFS signature, fwupd runs this
machine on two batteries whose combined level trips its power check, and
with your own Secure Boot keys there is no shim - three config lines and one
signature deal with all of it. Capsule authenticity does not depend on any
of this: the firmware verifies the PKCS#7 chain against the root in
`keys/capsule/` and refuses anything else.

```bash
sudo tee -a /etc/fwupd/fwupd.conf >/dev/null <<'EOF'
[fwupd]
OnlyTrusted=false
IgnorePower=true

[uefi_capsule]
DisableShimForSecureBoot=true
EOF
sudo sbctl sign -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi
sudo systemctl restart fwupd
```

The MTD pair of HSI-2 checks (#7) is host setup too. fwupd asks the flash
chip for its block-protection bits (`MEMISLOCKED`), and those cannot be set
here without locking the SMM capsule writer out along with everything else -
the protection is the PCH protected ranges plus SMM BWP. The honest state is
no MTD device at all; flashrom's internal path talks PCI directly and does
not use it. Disabling the mtd *plugin* instead would taint the daemon
(gnome-control-center flags it).

```bash
sudo tee /etc/modprobe.d/spi-intel-blacklist.conf >/dev/null <<'EOF'
blacklist spi_intel_pci
blacklist spi_intel
EOF
```

The update itself:

```bash
sudo systemctl restart fwupd                           # required, see below
fwupdmgr install roms/coreboot_t480_<version>.cab      # same version: --allow-reinstall
reboot
```

The restart is not superstition. The ESP on this machine is a gpt-auto
automount on `/efi` that idle-unmounts after 120 s, so at install time it
is usually not mounted; fwupd then asks UDisks to mount it, the request
itself touches `/efi`, the automount wins the race and UDisks fails the
install with `UDisks2.Error.AlreadyMounted`. A daemon started while `/efi`
is mounted binds to the existing mountpoint and never calls mount - and
the restart's own ESP probing mounts it, which is why install-right-after-
restart works every time. The alternative is pinning the automount
(`TimeoutIdleSec=infinity` drop-in for `efi.automount`) so the ESP stays
mounted permanently; an unmounted ESP is the safer resting state, so this
setup keeps the restart instead.

What happens: fwupd stages the capsule and sets `BootNext` to its EFI
binary; the reboot runs it once, it hands the capsule to `UpdateCapsule()`
and warm-resets; coreboot finds the capsule and the payload's FmpDxe
verifies the signature, writes the inactive slot and arms a one-shot trial
boot; the firmware resets again and the trial boot comes up on the new
firmware. `vboot-boot-ok.service` reports it good - if it never gets that
far, the next boot falls back to the old slot on its own.

Afterwards `fwupdmgr get-history` shows the update,
`cat /sys/firmware/efi/esrt/entries/entry0/last_attempt_status` is `0` on
success. On failure that field names the failed check - the slot library
reports codes from `0x1800` up (see
`patches/edk2/0003-fmp-device-slot-lib.patch`), FmpDxe's own codes start at
`0x1000`.

### With the kernel capsule loader

Same firmware path, no fwupd - useful for testing capsules directly:

```bash
sudo modprobe capsule-loader
sudo sh -c 'cat roms/coreboot_t480_<version>.cap > /dev/efi_capsule_loader'
reboot        # warm reboot; a poweroff discards the staged capsule
```

The `modprobe` is not optional: the module does not auto-load, and a
redirect into a missing `/dev/efi_capsule_loader` silently creates a regular
file there instead of staging anything.

### Internally with flashrom

The pre-capsule path; still useful for development. Switch **BIOS Lock**
off in the setup menu and reboot. Then, with `<other>` being whichever slot
`show` does not report as running:

```bash
sudo vbnv show                                    # "running slot"

sudo flashrom -p internal -r backup.bin
sudo flashrom -p internal --fmap -i RW_SECTION_<other> \
    -w roms/coreboot_t480_<version>.rom
sudo flashrom -p internal --fmap -i RW_SECTION_<other> \
    -v roms/coreboot_t480_<version>.rom

sudo vbnv arm-update                              # one trial boot
```

Switch BIOS Lock back on and reboot. The trial-boot semantics are the same
as with a capsule.

flashrom checks neither of these: that the ROM carries the same MAC as the
chip (`xxd -s 0x1000 -l 6 -p`), and that both use the same FMAP layout. A
layout change needs an external flash, not this path.

### Externally, WP_RO included

Needed when the RO half really changes - verstage, the bootblock, the GBB
(keyset, rollback flag), the FMAP layout - or to refresh the RO fallback
copy. This is the only way to write `WP_RO` once the controller lock is on,
and the only update path that needs the clip:

```bash
sudo flashrom -p ch341a_spi --fmap -i WP_RO -i RW_SECTION_A -i RW_SECTION_B \
    -w roms/coreboot_t480_<version>.rom
```

Both slots and RO are replaced at once, so there is no trial-boot fallback.
When the build also raises the rollback version, disable
`vboot-boot-ok.service` before flashing and re-enable it after the new
firmware has booted a few times - the counter follows the first boot after a
success report, and a success reported by the *old* firmware would advance
it before the new one has proven itself.

Pulling the coin cell for the flash stales the CMOS checksum again - run
`sudo vbnv fix-checksum` once after boot. The vboot state itself survives:
coreboot restores it from the copy in `RW_NVRAM`.

### Replacing the vboot keyset

Same procedure whether you lost the keys, suspect they leaked, or just want
new ones. It is a normal external update that happens to carry a new root
key:

```bash
mv keys keys.old                     # gen-vboot-keys.sh will not overwrite
sh scripts/gen-vboot-keys.sh
python3 scripts/build-firmware.py --rebuild-base
sudo flashrom -p ch341a_spi --fmap -i WP_RO -i RW_SECTION_A -i RW_SECTION_B \
    -w roms/coreboot_t480_<version>.rom
```

Nothing else has to be prepared, and nothing is lost: Secure Boot keys and
settings sit in SMMSTORE outside the written regions, and the TPM is not
cleared, so a LUKS auto-unlock keeps working. The old keyset plays no part
in the process.

**`WP_RO` has to be written** - the root key lives there. Writing only the
slots leaves the old root key in place, both slots fail verification, and
the machine ends up in a recovery boot. Recoverable by repeating the flash
with `WP_RO` included, but avoidable. A power cut in the middle is
survivable too: RO and slots no longer match, the machine boots the RO
copy, and the flash can be repeated from there.

The capsule signing chain in `keys/capsule/` is replaced the same way:
`mv keys/capsule keys/capsule.old`, `sh scripts/gen-capsule-certs.sh`,
rebuild, update. The new root rides into the firmware with any update path,
programmer not required - the trust anchor lives in the slots, not in RO.

## Verified boot

The flash is split into a read-only section and two signed, switchable
copies of the firmware. `WP_RO` holds the bootblock with verstage and the
GBB with the public root key; `RW_SECTION_A` and `RW_SECTION_B` each hold a
full signed firmware. verstage checks the signature of a slot before jumping
into it and falls back A → B → RO when that fails.

```
0x240000  RW_MRC_CACHE   0x010000
0x250000  SMMSTORE       0x040000     UEFI variables, Secure Boot keys
0x290000  RW_ELOG        0x004000
0x294000  RW_NVRAM       0x006000     vboot state backup
0x2a0000  RW_SECTION_A   0x400000     VBLOCK_A + FW_MAIN_A
0x6a0000  RW_SECTION_B   0x400000     VBLOCK_B + FW_MAIN_B
0xaa0000  WP_RO          0x560000     FMAP, GBB, RO copy of coreboot
```

What this holds against a running system: firmware in the RW slots cannot be
swapped for something you did not sign - a correctly signed image from a
different keyset is refused and the machine boots the other slot. `WP_RO` is
sealed by a PCH protected range on every boot, out of reach of root, SMM and
the BIOS Lock toggle alike. What remains: writing correctly-signed images
into the slots, and everything a person with a programmer can always do.

### The keysets

Three, with different jobs, all untracked in `keys/`:

- **vboot keys** (`gen-vboot-keys.sh`) sign the firmware slots; the public
  root key sits in the GBB inside `WP_RO`.
- **capsule certificates** (`gen-capsule-certs.sh`) sign update capsules;
  the firmware embeds the root and refuses capsules from any other chain.
- **Secure Boot keys** (`sbctl`, on the OS side) sign what the firmware
  boots; they live in SMMSTORE and no firmware update touches them.

Storing the first two is about theft, not loss. Whoever holds the private
keys can build firmware or capsules this machine accepts, and there is no
revocation list - invalidating a stolen key means rolling the keyset
([replacing the vboot keyset](#replacing-the-vboot-keyset)). Losing them
costs one rebuild.

<details>
<summary>vboot keys by hand</summary>
<br>

Tools first - `dumpRSAPublicKey` needs compiling, `vbutil_*` only exist as
futility subcommands (`$V` = `3rdparty/vboot`):

```bash
cc -O2 -o dumpRSAPublicKey $V/utility/dumpRSAPublicKey.c -I$V/host/include -lcrypto
make -C $V USE_FLASHROM=0 futil
```

Per key, algorithm 8 = RSA4096/SHA512 (root, recovery), 7 = RSA4096/SHA256
(firmware data):

```bash
openssl genrsa -F4 -out root_key_4096.pem 4096
openssl req -batch -new -x509 -key root_key_4096.pem -out root_key_4096.crt
./dumpRSAPublicKey -cert root_key_4096.crt > root_key_4096.keyb
futility vbutil_key --pack root_key.vbpubk  --key root_key_4096.keyb --version 1 --algorithm 8
futility vbutil_key --pack root_key.vbprivk --key root_key_4096.pem --algorithm 8
rm root_key_4096.{pem,crt,keyb}
```

Then the keyblock (flags 23 = dev switch either way, not recovery, not
miniOS):

```bash
futility vbutil_keyblock --pack firmware.keyblock --flags 23 \
    --datapubkey firmware_data_key.vbpubk --signprivate root_key.vbprivk
futility vbutil_keyblock --unpack firmware.keyblock --signpubkey root_key.vbpubk
```

</details>

### Checking and testing the slots

Which slot booted, and whether it was a recovery boot - that MRC message
appears only in recovery, since there is no recovery MRC region here:

```bash
grep -aE 'Slot [AB] is|MRC: failed to locate region type 0' /sys/firmware/log
```

Slot selection is sticky: after a fallback vboot keeps booting the other
slot, because `VB2_NV_TRY_NEXT` persists and nothing in this firmware resets
it (upstream leaves that to the ChromeOS updater). Harmless while both slots
carry the same image - but repairing the broken slot does not move the
machine back onto it. `scripts/vbnv.py` is that missing step:

```bash
sudo vbnv show
sudo vbnv try-next A
```

`show` decodes which slot is running, what the previous boot did and which
slot the next one takes; `try-next` writes that last field and applies on
the next reboot. Needs `/dev/nvram`, i.e. a kernel with `CONFIG_NVRAM`, and
once after CMOS loss the `fix-checksum` run
([troubleshooting](#vbnv-reports-inputoutput-error)).

<details>
<summary>Testing the fallback</summary>
<br>

Wiping a slot means zeroing its VBLOCK: the keyblock magic goes and the slot
fails verification. VBLOCK_A is at 0x2a0000, VBLOCK_B at 0x6a0000, both
0x10000 long.

```bash
cp roms/coreboot_t480_<version>.rom /tmp/w.rom
dd if=/dev/zero of=/tmp/w.rom bs=1 conv=notrunc seek=$((0x2a0000)) count=$((0x10000))
sudo flashrom -p internal --fmap -i VBLOCK_A -w /tmp/w.rom
```

Planting an image signed with a different keyset is the same write with that
image as the source (`-i RW_SECTION_B -w other.rom`). Restoring is
`-i RW_SECTION_A -i RW_SECTION_B -w` from the good ROM.

Two things decide whether the test means anything: write into the slot the
machine actually boots - vboot never looks at the other one - and leave that
other slot intact, it is the way back. Wiping both lands you in an RO
recovery boot, which still comes up but retrains memory.

</details>

<details>
<summary>The VBNV block by hand</summary>
<br>

Reading needs no tool. The block is 16 bytes at CMOS index 0x34, which is
`CONFIG_VBOOT_VBNV_OFFSET` (0x26) plus the 14 RTC bytes - and `/dev/nvram`
hides exactly those 14, so the file offset is 0x26 again:

```bash
sudo od -An -tx1 -j 0x26 -N 16 /dev/nvram
```

| Byte | Meaning |
|------|---------|
| 0 | header - valid when `byte & 0xc3 == 0x40` |
| 1 | bits 0-3: trial boots left (`TRY_COUNT`) |
| 2 | recovery request |
| 7 | bits 0-1 result of this boot, bit 2 running slot, bit 3 next slot, bits 4-5 previous result, bit 6 previous slot (0 = A, 1 = B). Result: 0 unknown, 1 trying, 2 success, 3 failure |
| 15 | CRC-8 over bytes 0-14 |

So byte 7 = `02` reads as: this boot reported success, slot A is running,
slot A is next, and the previous boot is unknown on slot A. `2e` would be
success on B, B next, previous boot successful on A.

Writing needs the CRC recomputed - polynomial `x^8 + x^2 + x + 1`, vboot's
`vb2_crc8` - and a block whose CRC does not match is discarded by the
firmware on the next boot. `fix-checksum` is the `NVRAM_SETCKS` ioctl on
`/dev/nvram` and has no shell equivalent.

</details>

A recovery boot - both slots unusable - runs the RO copy and comes up fully,
so the slots can be rewritten from there. It skips the MRC cache and
retrains memory, which costs a minute or two of black screen.

### Rollback protection

vboot keeps a firmware version in the TPM and refuses any slot below it. The
counter only advances when the *previous* boot was reported successful, and
nothing in coreboot or vboot ever reports that - upstream leaves it to the
ChromeOS updater. `vbnv boot-ok` is that report; the service from
[first boot](#first-boot) runs it late in the boot, so "successful" means
the machine actually came up.

The counter then follows on the next boot. Read it with
`tpm2_nvread 0x1007 | od -An -tx1` - bytes 3-6 are the version, little
endian.

Two settings decide whether any of this has an effect:

- **`CONFIG_VBOOT_KEYBLOCK_VERSION`**, raised per lockout release and
  recorded in [docs/firmware-versions.md](docs/firmware-versions.md). The
  counter cannot move past a version that never changes.
- **`CONFIG_GBB_FLAG_DISABLE_FW_ROLLBACK_CHECK`**, off. coreboot enables it
  by default, and it makes vboot skip the comparison while the counter still
  advances - measured here, a version-2 slot booted with the counter at 3.
  It sits in the GBB, so changing it is a `WP_RO` write.

Once the counter has followed a version, every older image is refused: the
ROMs in `roms/` and any backup among them.

The roll-forward wants a success report from the previous boot and the same
slot. It does not check that the report came from the same image - which is
what `vbnv arm-update` (and the trial boot a capsule update arms itself) is
for. A trial boot is marked `TRYING` instead of trusting the old report, so
the counter waits for the new firmware to report for itself, and a slot that
never comes up falls back on its own. Without it, flashing a raised version
onto a machine that has already reported success advances the counter in
verstage, before the new firmware runs.

#### Making an old image bootable again

Once the counter has moved past an image, that image is refused. Three ways
out; the first two need no programmer.

**Re-sign it with a higher version.** The firmware body is not touched -
only the signature blocks are rewritten:

```bash
podman run --rm --network=none --user root -v "$PWD/roms":/w:z \
    coreboot-t480 \
    /opt/coreboot/build/util/futility/futility sign \
        --signprivate /opt/keys/firmware_data_key.vbprivk \
        --keyblock    /opt/keys/firmware.keyblock \
        --kernelkey   /opt/coreboot/3rdparty/vboot/tests/devkeys/kernel_subkey.vbpubk \
        --version <at least the counter> --flags 0 \
        /w/coreboot_t480_<version>.rom
```

Then flash the two slots ([internally with flashrom](#internally-with-flashrom)).
`futility` is not on the host - it comes from the build image, which also
carries the keys. The kernel subkey is the one the build used
(`CONFIG_VBOOT_KERNEL_KEY`, the vboot devkey by default); it plays no part
in firmware verification.

**Or clear the TPM.** The `--tpm-reset` ROM recreates the vboot spaces with
the counter at 0. It flashes into the slots, so the `WP_RO` lock does not
stand in the way - but everything sealed to the TPM is invalidated, LUKS
included ([TPM reset](#tpm-reset)).

**Or set `GBB_FLAG_DISABLE_FW_ROLLBACK_CHECK`**, which disables the check
altogether. That one is a `WP_RO` write.

## Secure Boot

The firmware starts in Setup Mode. Enroll your own keys from Linux:

```bash
sudo pacman -S sbctl
sudo timedatectl set-ntp true
sudo sbctl create-keys
sudo sbctl verify                # lists every boot file that still needs a signature
sudo sbctl sign -s /boot/vmlinuz-linux              # sign each unsigned file it listed
sudo sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
sudo sbctl enroll-keys -m
sbctl status                     # should report "Secure Boot: Enabled" after a reboot
```

The keys live in SMMSTORE and survive every update path in this guide. To
carry them from a chip backup into a full image for an external re-install:

```bash
python3 scripts/transfer-settings.py backup.bin roms/coreboot_t480_<version>.rom
```

<details>
<summary>Copy the SMMSTORE by hand (dd)</summary>
<br>

The SMMSTORE region sits at offset 0x250000 and is 0x40000 bytes. To copy it
from a backup into a fresh ROM without the script:

```bash
cp roms/coreboot_t480_<version>.rom new_with_settings.rom
dd if=backup.bin of=new_with_settings.rom bs=1 conv=notrunc \
   skip=$((0x250000)) seek=$((0x250000)) count=$((0x40000))
```

`skip` is the read offset in the backup, `seek` the write offset in the new
file, `count` the size.

</details>

## Measured boot and the TPM

coreboot hashes every stage and blob (romstage, FSP, microcode, the EDK2
payload ...) into TPM PCR 2 before running it, so the measurement chain
starts at the firmware itself instead of at the payload. Inspect it:

```bash
sudo cbmem -L          # the eventlog
tpm2_pcrread sha256:2
```

`cbmem` is not packaged; build it from the fetched tree:
`make -C sources/coreboot/util/cbmem`.

LUKS can be bound to it on top of the usual policy
(`systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=2`), so the disk only
auto-unlocks under unmodified firmware. Caveat: **every firmware update
changes PCR 2** - the first boot after an update falls back to the
passphrase, and the binding has to be re-enrolled
(`systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=2`).

The root of trust stays in software: Boot Guard is deliberately disabled
(deguard) so the ME can be neutered. Measured boot therefore makes firmware
tampering detectable and keeps sealed secrets from being released to a
modified firmware - it does not stop an attacker who can rewrite the flash
and fake the measurements.

### TPM reset

If the TPM is stuck in a vendor-BIOS state (MFG mode, owner auth set,
disableClear latched), build with `--tpm-reset`. That produces a second ROM
that clears the TPM on every boot via TPM2_Clear.

> [!CAUTION]
> TPM2_Clear wipes everything sealed to the TPM (LUKS keys etc.) and cannot
> be undone. The reset ROM clears on every boot: flash it, boot Linux
> exactly once, check the result, then flash the normal ROM back.

<details>
<summary>Procedure and aftermath</summary>
<br>

```bash
python3 scripts/build-firmware.py --tpm-reset
```

Internal flashing only works with coreboot already on the chip - it needs
the FMAP that only a coreboot image has, and the vendor BIOS locks the flash
anyway. Running coreboot, only the slots are written, so all settings
survive and the sealed `WP_RO` is never touched - the reset hook runs from
the booted slot, the RO copy stays the normal firmware:

```bash
R="-i RW_SECTION_A -i RW_SECTION_B"
sudo flashrom -p internal --fmap $R -w roms/coreboot_t480_<version>_tpmreset.rom
# boot once, then:
sudo grep -i "TPM-RESET" /sys/firmware/log     # step2/step3 should say rc=0x0
tpm2_getcap properties-variable                # ownerAuthSet, disableClear = 0
sudo flashrom -p internal --fmap $R -w roms/coreboot_t480_<version>.rom
```

Coming straight from the vendor BIOS (e.g. doing the reset as part of the
first install), flash externally with the programmer instead:

```bash
sudo flashrom -p ch341a_spi -w roms/coreboot_t480_<version>_tpmreset.rom
# boot once and check as above, then:
sudo flashrom -p ch341a_spi -w roms/coreboot_t480_<version>.rom
```

step1 may report INVALID_POSTINIT, that's fine (coreboot already started the
TPM itself). On systemd 257+ mask `systemd-pcrproduct.service`, the T480's
TPM chip doesn't support what it needs.

The clear is authorized through the TPM's platform hierarchy, whose auth is
empty right after firmware startup - that is why it needs no owner password
and also lifts a latched disableClear. Not combinable with `--no-tpm`.

Afterwards, re-enroll anything sealed to the old TPM state: wipe and re-add
the LUKS TPM slot (`systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto`)
and delete `/var/lib/systemd/tpm2-srk-public-key.*`, otherwise unlocking
fails with "key does not belong to this TPM".

</details>

<details>
<summary>If the clear does not work</summary>
<br>

- No `TPM-RESET` lines in the log: the normal ROM was flashed instead of
  `..._tpmreset.rom`.
- step3 with rc != 0x0: the raw TPM response is logged right above it -
  `0x120` is TPM_RC_DISABLED, `0x9a2` is TPM_RC_BAD_AUTH. Flash the backup
  back and investigate before trying again.
- `tpm2_getcap` finds no TPM: check that `/dev/tpm0` exists and that the
  firmware log shows the TPM being set up at all.

</details>

## Hardware notes

### Thunderbolt firmware

The Thunderbolt controller has its own small SPI flash (the second SOIC-8
next to U49) and a known firmware bug: the controller writes debug logs into
that flash, among other things every time a USB-C charger is plugged in.
Once the flash is full, Thunderbolt PCIe and fast charging stop working
(slow charging survives). Lenovo's fix is a Thunderbolt firmware update to
NVM 23, and it installs from Linux with coreboot running:

```bash
fwupdmgr update        # "Thunderbolt host controller" -> NVM 23.00
```

Verified on this build (20.00 -> 23.00 with coreboot running). If the flash
has already filled up and the controller is dead, fwupd no longer sees it -
recovery is then external, on the small SOIC-8: erase, flash a 1 MB null
image, boot the machine once, then flash Lenovo's `tb.bin`. The procedure is
in [Libreboot's T480 guide](https://libreboot.org/docs/install/t480.html)
under "Thunderbolt issue".

### Fan control

The fan runs in five regulated levels driven by the ACPI thermal zone - the
old behaviour (EC automatic until 80 C, then unregulated full blast) is
gone. Four profiles can be picked in the setup menu under
**Embedded Controller → Fan profile**; a change applies on the next boot:

| Profile | Character | First fan level at |
|---------|-----------|--------------------|
| Quiet | quieter, runs hotter | 64 C |
| Balanced (default) | the tested middle ground | 58 C |
| Performance | louder, runs cooler | 48 C |
| EC only | firmware keeps its hands off the fan | - |

"EC only" is for userspace fan control (thinkfan, zcfan): the firmware trip
points move just below the critical threshold, so the EC curve - or your
tool - rules alone, with one ACPI escalation left as the last net. Curve
details and tuning: [patches/README.md](patches/README.md).

### Bluetooth and WWAN

**Embedded Controller → Bluetooth** has three settings:

| Setting | Behaviour |
|---------|-----------|
| Disabled | radio off at every boot |
| Enabled | radio on at every boot |
| Last state (default) | firmware leaves the radio as the OS left it |

With "Last state", turning the radio off in the OS is enough; it stays off.
Pulling both battery and charger clears the EC's memory and the radio comes
back.

**Embedded Controller → WWAN** has the same three settings and works the
same way - it is the neighbouring bit in the same EC register (patch 0034).
Untested: there is no WWAN card in the machine this was built on.

<details>
<summary>Background: why the radios come back on every boot upstream</summary>
<br>

Upstream only knows Disabled/Enabled and writes the EC bit on every boot, so
bluetooth turned off in the OS was back on after the next reboot -
`thinkpad_acpi` reads its rfkill state from exactly that bit. With "Last
state" the firmware does not touch it, and the EC keeps it across the reset.

The second half of the fix is patch 0031: the firmware no longer announces a
wireless master switch (`WLSW`), which the kernel answered by unblocking all
radios on every boot - details in [patches/README.md](patches/README.md).
The switch this all controls is `tpacpi_bluetooth_sw` in `rfkill list`;
`hci0` only exists while the radio has power.

At shutdown `thinkpad_acpi` asks the firmware to save both radio states
through ACPI methods that only Lenovo's BIOS has, and logged two
`AE_NOT_FOUND` errors when it did not find them. Patch 0035 adds the two
methods as empty stubs - the state is kept in the EC anyway, so there is
nothing for them to do.

</details>

### EC debugging

The T480's embedded controller (Microchip MEC1653) runs the fan, battery,
keyboard and more. Two ways to look inside while tuning things like the fan
curve:

<details>
<summary>Read EC registers from Linux (no rebuild needed, root required)</summary>
<br>

```bash
modprobe ec_sys
# one byte at an offset, e.g. the fan register HFSP (0x2f = 47):
dd if=/sys/kernel/debug/ec/ec0/io bs=1 skip=47 count=1 2>/dev/null | od -An -tu1
```

Useful offsets: `0x2f` fan control (bits 0-2 level, bit 6 disengage, bit 7
EC automatic), `0x78` CPU temperature in C (`0x79` would be a second sensor,
but on the T480 it always reads 128 = not fitted), `0x84`/`0x85` fan
tachometer (RPM, low/high byte).

</details>

<details>
<summary>EC debug UART (rebuild needed)</summary>
<br>

The EC has a debug console that is locked by default; the unlock key for the
T480/T580 is known and already in the coreboot tree. Enable it with
`CONFIG_MEC1653_ENABLE_UART=y` in `config/defconfig` and `--rebuild-base`.
coreboot then unlocks the EC debug interface at boot and maps the EC's UART
to host I/O port 0x3f8, IRQ 4 over LPC - that is the classic COM1, so no
soldering: the console should appear as `/dev/ttyS0` in Linux
(`screen /dev/ttyS0 115200`).

The 0x3f8/IRQ4 mapping and the unlock mechanism are read from the coreboot
code (`src/ec/lenovo/mec1653/uart.c`); that the EC actually prints anything
there, and at which baud rate, is NOT yet verified on hardware. Treat this
section as a pointer, not a promise.

</details>

## Troubleshooting

### What the write protections allow

Three mechanisms sit between a running system and the chip, all on by
default in this repo.

| | blocks | switch |
|---|--------|--------|
| **SMM BIOS write protect** (`BOOTMEDIA_SMM_BWP`) | every write from the OS - the whole BIOS region | **BIOS Lock** in the setup menu, System form |
| **`WP_RO` controller lock** (`BOOTMEDIA_LOCK_WPRO_VBOOT_RO`) | writes to `WP_RO` only - FMAP, GBB with the root key, RO copy | none; re-armed on every boot |
| **descriptor + GbE lock** (`BOOTMEDIA_LOCK_DESCRIPTOR_GBE`) | writes to `SI_DESC` and `SI_GBE` - region permissions, MAC | none; re-armed on every boot |

The last two have no off switch by design. Both are protected ranges in the
SPI controller, sealed with `FLOCKDN` before the payload runs, and they
ignore BIOS Lock, root and SMM alike. Reads are untouched, so a full-chip
backup still works. `WP_RO`, the descriptor and the MAC need the CH341A.

Everything else - both slots, SMMSTORE, the MRC cache - stays writable
internally once BIOS Lock is off. Capsule updates work with BIOS Lock on:
their write path runs inside SMM. Check the current state:

```bash
grep -a "BM-LOCKDOWN\|FPR " /sys/firmware/log
sudo setpci -s 00:1f.5 dc.b                     # aa = BIOS Lock on, 8b = off
```

The log shows two `FPR` lines, one for `0x00aa0000-0x00ffffff` and one for
`0x00000000-0x00002fff`, plus `Enabled bootmedia protection` and
`Enabled protection for SI_DESC + SI_GBE`. `No SPI FPR free!` means a lock
did not happen - check after a coreboot or FSP update.

`flashrom --flash-name` does not report the chipset registers here. With the
controller visible it opens `/dev/mtd0` and takes the MTD path, which prints
no `BIOS Control`, `FREG` or `PR` lines at all. BIOS Control is PCI config
space and `setpci` reads it; the protected ranges live in SPIBAR at offset
0x84. Nothing in the kernel exports them, so `scripts/spi-ranges.py` maps
them through `/dev/mem`:

```bash
sudo python3 scripts/spi-ranges.py
```

That one does need `iomem=relaxed`, which loosens the kernel's `/dev/mem`
restrictions in general, so add it for the check and take it out again. The
log is the everyday answer and says what was programmed at boot; the
registers say what is in force.

### flashrom quirks

- "Laptop detected": use `-p internal:laptop=this_is_not_a_laptop`. Once
  coreboot is on the chip, flashrom finds the coreboot table and usually
  needs no override.
- The kernel binds the SPI controller and exposes the chip as `/dev/mtd0`.
  flashrom then prints `Erase/write done` even when the hardware dropped
  every write - only the `VERIFIED.` line proves anything.
- A full-chip verify always fails once the firmware has run:
  `RW_MRC_CACHE`, `SMMSTORE` and `RW_NVRAM` hold runtime state, and the ME
  writes a few bytes into `SI_ME`. Verify the firmware regions instead:
  `--fmap -i WP_RO -i RW_SECTION_A -i RW_SECTION_B -v <rom>`.
- If flashrom says the BIOS region is read-only and BIOS Lock is already
  off, flash externally.

### vbnv reports Input/output error

The kernel guards `/dev/nvram` with the legacy PC CMOS checksum and refuses
reads and writes while it is stale; coreboot only maintains that checksum
with an option table, which this board does not have. After every CMOS loss
(first install, coin cell pulled), once:

```bash
sudo vbnv fix-checksum
```

That writes CMOS 46/47 and nothing else. The checksum covers CMOS 16-45, the
vboot block sits at 52-67, and no part of this firmware reads either of the
two bytes.

### Capsule staging

`/dev/efi_capsule_loader` only exists after `modprobe capsule-loader`. A
shell redirect into the missing path creates a regular file in `/dev` and
stages nothing - no error anywhere. The kernel confirms a real staging with
`efi: Successfully uploaded capsule file` in dmesg. A staged capsule lives
in RAM: it survives a warm `reboot`, not a poweroff.

## Cleaning up

```bash
podman image prune -a -f
rm -rf sources/
```

The versions are in `config/versions.lock`, tracked, so everything can be
fetched and rebuilt later. `sources/` only saves the download.

To also keep the built toolchain, save the image itself - that turns a
30-60 minute rebuild into a `podman load`:

```bash
podman save coreboot-t480 | zstd -T0 > coreboot-t480.tar.zst
zstd -dc coreboot-t480.tar.zst | podman load               # restore
```
