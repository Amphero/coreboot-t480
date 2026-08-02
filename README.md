<h1 align="center">coreboot for the ThinkPad T480</h1>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/logo-dark.png">
    <img src=".github/logo-light.png" alt="coreboot logo" width="200">
  </picture>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License: GPL-3.0"></a>
  <img src="https://img.shields.io/badge/platform-ThinkPad%20T480-red" alt="Platform: ThinkPad T480">
</p>

coreboot with MrChromebox's EDK2 payload for the ThinkPad T480. You get a real
UEFI with Secure Boot (your own keys, enrolled with sbctl) and a working
discrete TPM 2.0.

Forked from [radleylewis/t480_coreboot](https://github.com/radleylewis/t480_coreboot).
The board config is from there, the build system around it is new.

Tested on a Type 20L5 (mainboard NM-B501). The SPI flash is a Winbond W25Q128,
16 MB, at position U49.

### How this differs from Libreboot

The lowest layer is the same — this build reuses Libreboot's `lbmk` for the
ME/Boot Guard handling. The differences start at the payload, and several
T480 quirks that Libreboot documents as
[known errata](https://libreboot.org/docs/install/t480.html) are fixed here
in the firmware itself.

<details>
<summary>Feature-by-feature comparison</summary>
<br>

| | This repo | [Libreboot T480](https://libreboot.org/docs/install/t480.html) |
|---|---|---|
| Payload | EDK2 UEFI (`uefipayload_2605`) | GRUB or SeaBIOS (legacy BIOS) |
| coreboot base | upstream 26.06 | own tree (patchset 25) |
| Secure Boot | own keys via `sbctl` | — |
| UEFI variables | SMMSTORE v2, survive reflashing | — |
| Setup menu | graphical, incl. fan profile / ME / AC-loss | — |
| TPM 2.0 | on, LUKS auto-unlock | off (SeaBIOS driver bug) |
| Measured boot | firmware chain into TPM PCR 2 | — |
| Verified boot | signed RW slots A/B, own keys, RO fallback | — |
| Fan behaviour | 5 regulated levels, 4 profiles | stock two-state (auto / full blast) |
| `thinkpad_acpi` | loads automatically | needs `force_load=1` (their FAQ) |
| Bluetooth/WWAN rfkill | works, Fn+F10 toggles, off stays off | may hard-block, manual unblock (errata) |
| Fn+F9…F12 | match the keycaps | may stop working (errata) |
| Kernel cmdline | nothing needed¹ | `thinkpad_acpi.force_load=1` |
| Boot splash | custom logo | — |
| Graphics init | libgfxinit | libgfxinit |
| ME / Boot Guard | `me_cleaner` + `deguard` | `me_cleaner` + `deguard` |
| EC firmware | Lenovo `n24ur39w`, untouched | Lenovo `n24ur39w`, untouched |
| First install | external flash (CH341A) | external flash (CH341A) |
| Updates | internal, keys preserved | internal |
| Build | two-phase offline podman | `lbmk` |

¹ earlier versions of this port required `reboot=pci`; fixed upstream, gone.

</details>

Trade-off: Libreboot's payload lives entirely in its own tree, this one adds
MrChromebox's EDK2. No UEFI, Secure Boot or TPM needed? Take Libreboot.

> [!WARNING]
> Flashing firmware can permanently brick your laptop. Everything in this repo
> is provided WITHOUT ANY WARRANTY and without liability for any damage, as
> stated in the [LICENSE](LICENSE) (GPL-3.0, sections 15 and 16). You flash at
> your own risk. Keep a backup of your original flash and never flash anything
> you cannot restore.

## What you need

- podman (the whole build runs in containers)
- flashrom and a CH341A programmer with a SOIC-8 clip for flashing

```bash
sudo pacman -S podman flashrom
```

## Build

Two steps. The first downloads all sources (8-12 GB, needs internet), the
second builds offline:

```bash
./fetch.sh pinned
sh scripts/gen-vboot-keys.sh                    # once, see Verified boot
python3 scripts/build-firmware.py --mode pinned
```

The ROM ends up in `roms/coreboot_t480_pinned.rom`. The first build takes
30-60 minutes because coreboot builds its own toolchain, after that it's fast.

The build signs both firmware slots, so it needs a keyset in `keys/` and
aborts without one rather than falling back to the public vboot devkeys.

`pinned` builds the versions this port was originally validated with;
`latest` resolves the newest upstream versions at fetch time. The recent
fan-control releases were built and tested from `latest` - the exact
versions of every build are recorded in `roms/versions_<mode>.lock`.

<details>
<summary>Manual build without the scripts</summary>
<br>

The first step only exists as a script, it downloads too much to type by hand.
But once `sources/<mode>/` is filled you can run the build itself manually:

```bash
# build-environment image (only needed if it doesn't exist yet)
podman build -t coreboot-t480-deps -f build/Dockerfile.deps build

# offline build; the build context is the sources dir. Set YOUR MAC here -
# there is no placeholder check on this manual path, what you type goes into
# the GbE region verbatim.
MAC=AA:BB:CC:DD:EE:FF
podman build --network=none --build-arg MAC_ADDRESS="$MAC" \
    -f build/Dockerfile.offline -t coreboot-t480-pinned sources/pinned

# copy the ROM out of the image
mkdir -p roms
podman run --rm --network=none -v "$PWD/roms":/out:z --user root \
    coreboot-t480-pinned bash -c 'cp /opt/coreboot/build/coreboot.rom /out/coreboot.rom'
```

This gives you the base image (TPM on, Microsoft keys auto-enrolled). The
default variant (TPM + Setup Mode + RNG) is what `build-firmware.py` adds on
top, so for the final ROM use the script.

</details>

### Your MAC address

The build writes the MAC of the onboard NIC into the GbE region. Read it out:

```bash
ip link show enp0s31f6 | grep ether
```

or from a dump of the original firmware (it sits at offset 0x1000):

```bash
xxd -s 0x1000 -l 6 -p backup.bin | sed 's/../&:/g;s/:$//'
```

Then pass it to the build - preferred, because nothing lands in a tracked file:

```bash
MAC=AA:BB:CC:DD:EE:FF python3 scripts/build-firmware.py --mode pinned
```

(or `--mac AA:BB:CC:DD:EE:FF`). Alternatively uncomment the `MAC=` line in
`config/board.conf` - note that this file is tracked in git, so the MAC will
show up in your diffs. Without a MAC from one of the three sources the build
aborts.

### Options

| Flag | Effect |
|------|--------|
| `--tpm-reset` | also build a ROM that clears a stuck TPM (see below) |
| `--no-tpm` | build without TPM support |
| `--auto-enroll` | enroll Microsoft's Secure Boot keys instead of Setup Mode |
| `--no-rng` | leave out the RNG |
| `--plain` | just the raw base ROM (TPM on, Microsoft keys auto-enrolled) |
| `--version NAME` | version part of the ROM file name (default: `pinned` or the date) |
| `--rebuild-base` | rebuild from scratch after editing `config/defconfig`, `config/board.conf` or `patches/` |

Patches in `patches/base/` are applied to the coreboot tree when the base
image is built, in lexical order and with a mandatory `git apply --check` -
a patch that no longer applies aborts the build instead of being skipped
silently. They carry everything this repo changes about coreboot itself:
the five-level stepped fan control for the T480 with four fan profiles
selectable in the setup menu (Quiet / Balanced / Performance / EC only),
the "Restore AC power after loss" setup option and the ME-disabled
default. **Each patch is documented in
[patches/README.md](patches/README.md).** Changes here need
`--rebuild-base`.

`config/board.conf` toggles optional devices with a simple `y`/`n`
(`config/defconfig` is pure Kconfig; machine identity and device toggles
live in `board.conf`):

```
DT_DEVICE_SMBUS=y        # SMBus - touchpad in RMI4/InterTouch mode (PCI 1f.4)
DT_DEVICE_HECI1=n        # HECI1 (PCI 16.0)
DT_DEVICE_FAST_SPI=n     # Fast SPI (PCI 1f.5)
```

A custom boot logo goes into `config/splash.bmp` (24-bit uncompressed BMP).
ImageMagick turns any image into the right format:

```bash
magick yourimage.png -type TrueColor -compress None BMP3:config/splash.bmp
```

The logo is centered per the BGRT spec, so keep it no larger than the panel
(1920x1080). Both need `--rebuild-base`.

## Flashing

### Before the first flash

Two things have to happen while the vendor BIOS is still installed - both
are impossible afterwards:

- **Bring the EC to `n24ur39w`.** Lenovo's updater does not run under
  coreboot, and this payload does no UEFI capsule updates, so fwupd cannot
  update BIOS or EC later either. Update (or downgrade) with Lenovo's
  bootable updater to the BIOS release that carries EC firmware
  `n24ur39w` - coreboot's EC support, including the debug UART unlock, is
  written against exactly that EC code. In the vendor BIOS setup disable
  "Secure Rollback Prevention" and enable "Flash BIOS Updating by End
  Users" (both under Security → UEFI BIOS Update Option); the bootable
  updater wants Secure Boot off and legacy/CSM boot on. Run it on AC with
  a charged battery and pick the option that also updates the EC.
- **Dump the original firmware.** Once before the Lenovo update and once
  more right before flashing coreboot - the second dump is what you
  restore if anything goes wrong.

> [!WARNING]
> This ROM is for the T480 only. The T480s looks the same on the outside
> but is wired differently - flashing a T480 image onto it bricks it.

### External flashing

External flashing with the CH341A is the safe way, and the only way for
the first install. Power off, unplug AC, remove the external battery, take
off the bottom cover (all screws out, then pry gently - Lenovo's Hardware
Maintenance Manual or any teardown video shows how), unplug the internal
battery's connector from the board and pop out the CR2032 coin cell.

The chip is the Winbond W25Q128 at U49, towards the middle of the board
near the RAM slots. A second, smaller SOIC-8 nearby holds the Thunderbolt
firmware (see below) - don't clip that one. Clip on U49, pin 1 on the dot.

The W25Q128 is a 3.3 V chip and many cheap CH341A boards drive the data
lines at 5 V - use a fixed/modded one. Wiring and general SPI flashing:
[Libreboot's 25xx NOR guide](https://libreboot.org/docs/install/spi.html).

```bash
# read twice and compare - no diff output means good clip contact
sudo flashrom -p ch341a_spi -r backup1.bin
sudo flashrom -p ch341a_spi -r backup2.bin
diff backup1.bin backup2.bin

sudo flashrom -p ch341a_spi -w roms/coreboot_t480_pinned.rom
sudo flashrom -p ch341a_spi -v roms/coreboot_t480_pinned.rom
```

A bad flash is not fatal as long as the backup exists: flash the backup
back the same way and the machine is exactly where it started. The only
real way to lose the machine is to lose the backup.

After flashing: reconnect the internal battery and the CMOS battery, boot
and set the clock (`sudo timedatectl set-ntp true`).

> [!NOTE]
> The clock matters. Secure Boot key enrollment silently fails if it's wrong.

### Internal flashing

Internal flashing works too (boot with `iomem=relaxed`), but a failed write
bricks the machine, so keep the programmer at hand:

```bash
sudo flashrom -p internal -r backup.bin
sudo flashrom -p internal --ifd -i bios -w roms/coreboot_t480_pinned.rom
sudo flashrom -p internal --ifd -i bios -v roms/coreboot_t480_pinned.rom
```

That writes the whole BIOS region, SMMSTORE included, so settings and
Secure Boot keys are gone afterwards. To update an existing install and
keep them, write only the firmware regions - see
[Verified boot](#verified-boot).

If flashrom aborts with "Laptop detected", use
`-p internal:laptop=this_is_not_a_laptop`. Once coreboot is on the chip,
flashrom finds the coreboot table and usually needs no override.

If flashrom says the BIOS region is read-only, flash externally.

## Thunderbolt firmware

The Thunderbolt controller has its own small SPI flash (the second SOIC-8
next to U49) and a known firmware bug: the controller writes debug logs
into that flash, among other things every time a USB-C charger is plugged
in. Once the flash is full, Thunderbolt PCIe and fast charging stop
working (slow charging survives). Lenovo's fix is a Thunderbolt firmware
update to NVM 23, and it installs from Linux with coreboot running - the
controller is flashed through the kernel's thunderbolt interface, no UEFI
needed:

```bash
fwupdmgr update        # "Thunderbolt host controller" -> NVM 23.00
```

Verified on this build (20.00 -> 23.00 with coreboot running). If the
flash has already filled up and the controller is dead, fwupd no longer
sees it - recovery is then external, on the small SOIC-8: erase, flash a
1 MB null image, boot the machine once, then flash Lenovo's `tb.bin`. The
procedure is in [Libreboot's T480 guide](https://libreboot.org/docs/install/t480.html)
under "Thunderbolt issue".

## Fan control

The fan runs in five regulated levels driven by the ACPI thermal zone -
the old behaviour (EC automatic until 80 C, then unregulated full blast)
is gone. Four profiles can be picked in the setup menu under
**Embedded Controller → Fan profile**; a change applies on the next boot:

| Profile | Character | First fan level at |
|---------|-----------|--------------------|
| Quiet | quieter, runs hotter | 64 C |
| Balanced (default) | the tested middle ground | 58 C |
| Performance | louder, runs cooler | 48 C |
| EC only | firmware keeps its hands off the fan | - |

"EC only" is for userspace fan control (thinkfan, zcfan): the firmware
trip points move just below the critical threshold, so the EC curve - or
your tool - rules alone, with one ACPI escalation left as the last net.
Curve details and tuning: [patches/README.md](patches/README.md).

## Bluetooth and WWAN

**Embedded Controller → Bluetooth** has three settings:

| Setting | Behaviour |
|---------|-----------|
| Disabled | radio off at every boot |
| Enabled | radio on at every boot |
| Last state (default) | firmware leaves the radio as the OS left it |

With "Last state", turning the radio off in the OS is enough; it stays
off. Pulling both battery and charger clears the EC's memory and the
radio comes back.

**Embedded Controller → WWAN** has the same three settings and works the
same way - it is the neighbouring bit in the same EC register (patch
0034). Untested: there is no WWAN card in the machine this was built on.

<details>
<summary>Background: why the radios come back on every boot upstream</summary>
<br>

Upstream only knows Disabled/Enabled and writes the EC bit on every boot,
so bluetooth turned off in the OS was back on after the next reboot -
`thinkpad_acpi` reads its rfkill state from exactly that bit. With "Last
state" the firmware does not touch it, and the EC keeps it across the
reset.

The second half of the fix is patch 0031: the firmware no longer
announces a wireless master switch (`WLSW`), which the kernel answered
by unblocking all radios on every boot - details in
[patches/README.md](patches/README.md). The switch this all controls is
`tpacpi_bluetooth_sw` in `rfkill list`; `hci0` only exists while the
radio has power.

At shutdown `thinkpad_acpi` asks the firmware to save both radio states
through ACPI methods that only Lenovo's BIOS has, and logged two
`AE_NOT_FOUND` errors when it did not find them. Patch 0035 adds the two
methods as empty stubs - the state is kept in the EC anyway, so there is
nothing for them to do.

</details>

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

To keep the settings of a previous coreboot install (keys, boot entries),
either copy the SMMSTORE from a backup into the new ROM:

```bash
python3 scripts/transfer-settings.py backup.bin roms/coreboot_t480_pinned.rom
```

or, when flashing internally, write only the firmware regions and leave
SMMSTORE alone:

```bash
sudo flashrom -p internal --fmap -i WP_RO -i RW_SECTION_A -i RW_SECTION_B \
    -w roms/coreboot_t480_pinned.rom
```

<details>
<summary>Copy the SMMSTORE by hand (dd)</summary>
<br>

The SMMSTORE region sits at offset 0x250000 and is 0x40000 bytes. To copy it
from a backup into a fresh ROM without the script:

```bash
cp roms/coreboot_t480_pinned.rom new_with_settings.rom
dd if=backup.bin of=new_with_settings.rom bs=1 conv=notrunc \
   skip=$((0x250000)) seek=$((0x250000)) count=$((0x40000))
```

`skip` is the read offset in the backup, `seek` the write offset in the new
file, `count` the size.

</details>

## Measured boot

coreboot hashes every stage and blob (romstage, FSP, microcode, the EDK2
payload ...) into TPM PCR 2 before running it, so the measurement chain
starts at the firmware itself instead of at the payload. Inspect it:

```bash
sudo cbmem -L          # the eventlog (cbmem lives in util/cbmem of the coreboot tree)
tpm2_pcrread sha256:2
```

LUKS can be bound to it on top of the usual policy
(`systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=2`), so the disk
only auto-unlocks under unmodified firmware. Caveat:
**every firmware update changes PCR 2** - the first boot
after flashing falls back to the passphrase, and the binding has to be
re-enrolled (`systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto
--tpm2-pcrs=2`).

The root of trust stays in software: Boot Guard is deliberately disabled
(deguard) so the ME can be neutered. Measured boot therefore makes
firmware tampering detectable and keeps sealed secrets from being
released to a modified firmware - it does not stop an attacker who can
rewrite the flash and fake the measurements.

## Verified boot

The flash is split into a read-only section and two signed, switchable
copies of the firmware. `WP_RO` holds the bootblock with verstage and
the GBB with the public root key; `RW_SECTION_A` and `RW_SECTION_B` each
hold a full signed firmware. verstage checks the signature of a slot
before jumping into it and falls back A -> B -> RO when that fails.
SMMSTORE and the MRC cache keep the offsets they had before vboot, so
settings and Secure Boot keys survive the switch.

```
0x240000  RW_MRC_CACHE   0x010000
0x250000  SMMSTORE       0x040000     UEFI variables, Secure Boot keys
0x290000  RW_ELOG        0x004000
0x294000  RW_NVRAM       0x006000     vboot state backup
0x2a0000  RW_SECTION_A   0x400000     VBLOCK_A + FW_MAIN_A
0x6a0000  RW_SECTION_B   0x400000     VBLOCK_B + FW_MAIN_B
0xaa0000  WP_RO          0x560000     FMAP, GBB, RO copy of coreboot
```

### Signing keys

`config/defconfig` points at `keys/`, which is untracked - generate your
own before the first vboot build. The build refuses to run without them
rather than falling back to the public vboot devkeys, which would leave
you with a signature anyone can produce:

```bash
sh scripts/gen-vboot-keys.sh
```

That writes `root_key`, `firmware_data_key`, `recovery_key` and
`firmware.keyblock`. Keep a copy elsewhere - without the private keys you
cannot build firmware the RO on your chip accepts.

<details>
<summary>By hand</summary>
<br>

Tools first - `dumpRSAPublicKey` needs compiling, `vbutil_*` only exist
as futility subcommands (`$V` = `3rdparty/vboot`):

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

Losing them is not fatal as long as WP_RO is still writable: generate a
new keyset, rebuild, and flash - the new root key goes into the GBB in
WP_RO and the new slots match it. Write `WP_RO` along with the slots;
slots alone would leave the old root key in place and both would be
refused. The TPM is not cleared again; its vboot spaces already exist.
Once WP_RO is write-protected (#3) this stops working and a lost keyset
means an external flash.

### Updating

Boot with `iomem=relaxed`, back up the chip first, then write the three
firmware regions:

```bash
sudo flashrom -p internal -r backup.bin
sudo flashrom -p internal --fmap -i WP_RO -i RW_SECTION_A -i RW_SECTION_B \
    -w roms/coreboot_t480_<date>.rom
sudo flashrom -p internal --fmap -i WP_RO -i RW_SECTION_A -i RW_SECTION_B \
    -v roms/coreboot_t480_<date>.rom
```

SMMSTORE, the MRC cache and the vboot state are outside those regions, so
settings and Secure Boot keys survive. Reboot afterwards.

Slot-only changes can skip `WP_RO`; anything touching verstage, the
bootblock, the GBB or the RO payload needs it.

flashrom checks neither of these: that the ROM carries the same MAC as
the chip (`xxd -s 0x1000 -l 6 -p`), and that both use the same FMAP
layout. A layout change needs the migration path, not this one.

> [!NOTE]
> The first boot after enabling vboot clears the TPM. coreboot's
> `factory_initialize_tpm2()` starts with `tlcl_force_clear()` to set up
> the vboot NV spaces, which invalidates everything sealed to the TPM.
> LUKS falls back to the passphrase; re-enroll afterwards
> (`systemd-cryptenroll --wipe-slot=tpm2 ...`, delete
> `/var/lib/systemd/tpm2-srk-public-key.*`). This happens once - the NV
> spaces persist.

### Checking and testing the slots

Which slot booted, and whether it was a recovery boot - that MRC message
appears only in recovery, since there is no recovery MRC region here:

```bash
sudo cbmem -1 | grep -iE 'slot [ab] is|MRC: failed to locate region type 0'
```

<details>
<summary>Testing the fallback</summary>
<br>

Wiping a slot means zeroing its VBLOCK: the keyblock magic goes and the
slot fails verification. VBLOCK_A is at 0x2a0000, VBLOCK_B at 0x6a0000,
both 0x10000 long.

```bash
cp roms/coreboot_t480_<date>.rom /tmp/w.rom
dd if=/dev/zero of=/tmp/w.rom bs=1 conv=notrunc seek=$((0x2a0000)) count=$((0x10000))
sudo flashrom -p internal --fmap -i VBLOCK_A -w /tmp/w.rom
```

Planting an image signed with a different keyset is the same write with
that image as the source (`-i RW_SECTION_B -w other.rom`). Restoring is
`-i RW_SECTION_A -i RW_SECTION_B -w` from the good ROM.

Two things decide whether the test means anything: write into the slot
the machine actually boots - vboot never looks at the other one - and
leave that other slot intact, it is the way back. Wiping both lands you
in an RO recovery boot, which still comes up but retrains memory.

</details>

Slot selection is sticky: after a fallback vboot keeps booting the other
slot, because `VB2_NV_TRY_NEXT` persists and nothing in this firmware
resets it (upstream leaves that to the ChromeOS updater). Harmless while
both slots carry the same image.

A recovery boot - both slots unusable - runs the RO copy and comes up
fully, so the slots can be rewritten from there. It skips the MRC cache
and retrains memory, which costs a minute or two of black screen.

### Limits

Firmware in the RW slots cannot be swapped for something you did not
sign: a correctly signed image from a different keyset is refused and the
machine boots the other slot. `WP_RO` itself is **not** write-protected
yet, so anyone with root can still rewrite the RO and the root key with
it - see issue #3. Rollback protection is inert as well: the TPM counter
only rolls forward when the OS reports a successful boot, which needs a
component this firmware does not have.

## TPM reset

If the TPM is stuck in a vendor-BIOS state (MFG mode, owner auth set,
disableClear latched), build with `--tpm-reset`. That produces a second ROM
that clears the TPM on every boot via TPM2_Clear.

> [!CAUTION]
> TPM2_Clear wipes everything sealed to the TPM (LUKS keys etc.) and cannot be
> undone. The reset ROM clears on every boot: flash it, boot Linux exactly
> once, check the result, then flash the normal ROM back.

<details>
<summary>Procedure and aftermath</summary>
<br>

```bash
python3 scripts/build-firmware.py --mode pinned --tpm-reset
```

Internal flashing only works with coreboot already on the chip - it needs
the FMAP that only a coreboot image has, and the vendor BIOS locks the
flash anyway. Running coreboot, only the firmware regions are written, so
all settings survive (boot with `iomem=relaxed`):

```bash
R="-i WP_RO -i RW_SECTION_A -i RW_SECTION_B"
sudo flashrom -p internal --fmap $R -w roms/coreboot_t480_pinned_tpmreset.rom
# boot once, then:
sudo grep -i "TPM-RESET" /sys/firmware/log     # step2/step3 should say rc=0x0
tpm2_getcap properties-variable                # ownerAuthSet, disableClear = 0
sudo flashrom -p internal --fmap $R -w roms/coreboot_t480_pinned.rom
```

Coming straight from the vendor BIOS (e.g. doing the reset as part of the
first install), flash externally with the programmer instead:

```bash
sudo flashrom -p ch341a_spi -w roms/coreboot_t480_pinned_tpmreset.rom
# boot once and check as above, then:
sudo flashrom -p ch341a_spi -w roms/coreboot_t480_pinned.rom
```

step1 may report INVALID_POSTINIT, that's fine (coreboot already started the
TPM itself). On systemd 257+ mask `systemd-pcrproduct.service`, the T480's TPM
chip doesn't support what it needs.

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

## EC debugging

The T480's embedded controller (Microchip MEC1653) runs the fan, battery,
keyboard and more. Two ways to look inside while tuning things like the
fan curve:

<details>
<summary>Read EC registers from Linux (no rebuild needed, root required)</summary>
<br>

```bash
modprobe ec_sys
# one byte at an offset, e.g. the fan register HFSP (0x2f = 47):
dd if=/sys/kernel/debug/ec/ec0/io bs=1 skip=47 count=1 2>/dev/null | od -An -tu1
```

Useful offsets: `0x2f` fan control (bits 0-2 level, bit 6 disengage, bit 7
EC automatic), `0x78` CPU temperature in C (`0x79` would be a second
sensor, but on the T480 it always reads 128 = not fitted), `0x84`/`0x85`
fan tachometer (RPM, low/high byte).

</details>

<details>
<summary>EC debug UART (rebuild needed)</summary>
<br>

The EC has a debug console that is locked by default; the unlock key for
the T480/T580 is known and already in the coreboot tree. Enable it with
`CONFIG_MEC1653_ENABLE_UART=y` in `config/defconfig` and `--rebuild-base`.
coreboot then unlocks the EC debug interface at boot and maps the EC's
UART to host I/O port 0x3f8, IRQ 4 over LPC - that is the classic COM1,
so no soldering: the console should appear as `/dev/ttyS0` in Linux
(`screen /dev/ttyS0 115200`).

The 0x3f8/IRQ4 mapping and the unlock mechanism are read from the
coreboot code (`src/ec/lenovo/mec1653/uart.c`); that the EC actually
prints anything there, and at which baud rate, is NOT yet verified on
hardware. Treat this section as a pointer, not a promise.

</details>

## Cleaning up

```bash
podman image prune -a -f
rm -rf sources/
```

The exact versions of a build are recorded in `roms/versions_<mode>.lock`, so
everything can be rebuilt later.

`sources/<mode>/` is what makes rebuilds independent of upstream staying
online. To also keep the built toolchain, save the image itself - that
turns a 30-60 minute rebuild into a `podman load`:

```bash
podman save coreboot-t480-pinned | zstd -T0 > coreboot-t480-pinned.tar.zst
zstd -dc coreboot-t480-pinned.tar.zst | podman load        # restore
```

## License

[GPL-3.0](LICENSE), inherited from the upstream project. The sources fetched
during the build (coreboot, EDK2, libreboot) have their own licenses and are
not part of this repo.
