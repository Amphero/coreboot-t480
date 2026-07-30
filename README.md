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

| | This repo | [Libreboot T480](https://libreboot.org/docs/install/t480.html) |
|---|---|---|
| Payload | EDK2 UEFI (`uefipayload_2605`) | GRUB or SeaBIOS (legacy BIOS) |
| coreboot base | upstream 26.06 | own tree (patchset 25) |
| Secure Boot | own keys via `sbctl` | — |
| UEFI variables | SMMSTORE v2, survive reflashing | — |
| Setup menu | graphical, incl. fan profile / ME / AC-loss | — |
| TPM 2.0 | on, LUKS auto-unlock | off (SeaBIOS driver bug) |
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
python3 scripts/build-firmware.py --mode pinned
```

The ROM ends up in `roms/coreboot_t480_pinned.rom`. The first build takes
30-60 minutes because coreboot builds its own toolchain, after that it's fast.

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

# offline build; the build context is the sources dir, the MAC comes from config/defconfig
MAC=$(grep -oE '# MAC=\S+' config/defconfig | cut -d= -f2)
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

Then put it in the `# MAC=` line of `config/defconfig`, or pass
`--mac AA:BB:CC:DD:EE:FF` to the build script. Without a MAC the build aborts.

### Options

| Flag | Effect |
|------|--------|
| `--tpm-reset` | also build a ROM that clears a stuck TPM (see below) |
| `--no-tpm` | build without TPM support |
| `--auto-enroll` | enroll Microsoft's Secure Boot keys instead of Setup Mode |
| `--no-rng` | leave out the RNG |
| `--plain` | just the raw base ROM (TPM on, Microsoft keys auto-enrolled) |
| `--version NAME` | version part of the ROM file name (default: `pinned` or the date) |
| `--rebuild-base` | rebuild from scratch after editing `config/defconfig` |

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

The markers at the end of `config/defconfig` toggle optional devices with a
simple `y`/`n`:

```
# DT_DEVICE SMBUS=y       # SMBus - touchpad in RMI4/InterTouch mode (PCI 1f.4)
# DT_DEVICE HECI1=n       # HECI1 (PCI 16.0)
# DT_DEVICE FAST_SPI=n    # Fast SPI (PCI 1f.5)
```

A custom boot logo goes into `config/splash.bmp` (24-bit uncompressed BMP).
ImageMagick turns any image into the right format:

```bash
magick yourimage.png -type TrueColor -compress None BMP3:config/splash.bmp
```

The logo is centered per the BGRT spec, so keep it no larger than the panel
(1920x1080). Both need `--rebuild-base`.

## Flashing

External flashing with the CH341A is the safe way. Laptop fully powered off,
battery disconnected, clip on U49, pin 1 on the dot.

```bash
# read twice and compare - no diff output means good clip contact
sudo flashrom -p ch341a_spi -r backup1.bin
sudo flashrom -p ch341a_spi -r backup2.bin
diff backup1.bin backup2.bin

sudo flashrom -p ch341a_spi -w roms/coreboot_t480_pinned.rom
sudo flashrom -p ch341a_spi -v roms/coreboot_t480_pinned.rom
```

After flashing: reconnect the CMOS battery, boot and set the clock
(`sudo timedatectl set-ntp true`).

> [!NOTE]
> The clock matters. Secure Boot key enrollment silently fails if it's wrong.

Internal flashing works too (boot with `iomem=relaxed`), but a failed write
bricks the machine, so keep the programmer at hand:

```bash
sudo flashrom -p internal -r backup.bin
sudo flashrom -p internal --ifd -i bios -w roms/coreboot_t480_pinned.rom
sudo flashrom -p internal --ifd -i bios -v roms/coreboot_t480_pinned.rom
```

If flashrom aborts with "Laptop detected", use
`-p internal:laptop=this_is_not_a_laptop`. Once coreboot is on the chip,
flashrom finds the coreboot table and usually needs no override.

If flashrom says the BIOS region is read-only, flash externally.

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

## Bluetooth

**Embedded Controller → Bluetooth** has three settings:

| Setting | Behaviour |
|---------|-----------|
| Disabled | radio off at every boot |
| Enabled | radio on at every boot |
| Last state (default) | firmware leaves the radio as the OS left it |

Upstream only knows Disabled/Enabled and writes the EC bit on every boot,
so bluetooth turned off in the OS was back on after the next reboot -
`thinkpad_acpi` reads its rfkill state from exactly that bit. With "Last
state" the firmware does not touch it, and the EC keeps it across the
reset. Turning the radio off in the OS is enough; it stays off. Pulling
both battery and charger clears the EC's memory and the radio comes back.

The second half of the fix is patch 0031: the firmware no longer
announces a wireless master switch (`WLSW`), which the kernel answered
by unblocking all radios on every boot - details in
[patches/README.md](patches/README.md). The switch this all controls is
`tpacpi_bluetooth_sw` in `rfkill list`; `hci0` only exists while the
radio has power.

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

or, when flashing internally, write only the COREBOOT region and leave the
rest of the chip alone:

```bash
sudo flashrom -p internal --fmap -i COREBOOT -w roms/coreboot_t480_pinned.rom
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

## TPM reset

If the TPM is stuck in a vendor-BIOS state (MFG mode, owner auth set,
disableClear latched), build with `--tpm-reset`. That produces a second ROM
that clears the TPM on every boot via TPM2_Clear.

> [!CAUTION]
> TPM2_Clear wipes everything sealed to the TPM (LUKS keys etc.) and cannot be
> undone. The reset ROM clears on every boot: flash it, boot Linux exactly
> once, check the result, then flash the normal ROM back.

```bash
python3 scripts/build-firmware.py --mode pinned --tpm-reset

sudo flashrom -p ch341a_spi -w roms/coreboot_t480_pinned_tpmreset.rom
# boot once, then:
sudo grep -i "TPM-RESET" /sys/firmware/log     # step2/step3 should say rc=0x0
tpm2_getcap properties-variable                # ownerAuthSet, disableClear = 0
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

**Read EC registers from Linux** (no rebuild needed, root required):

```bash
modprobe ec_sys
# one byte at an offset, e.g. the fan register HFSP (0x2f = 47):
dd if=/sys/kernel/debug/ec/ec0/io bs=1 skip=47 count=1 2>/dev/null | od -An -tu1
```

Useful offsets: `0x2f` fan control (bits 0-2 level, bit 6 disengage, bit 7
EC automatic), `0x78` CPU temperature in C (`0x79` would be a second
sensor, but on the T480 it always reads 128 = not fitted), `0x84`/`0x85`
fan tachometer (RPM, low/high byte).

**EC debug UART** (rebuild needed): the EC has a debug console that is
locked by default; the unlock key for the T480/T580 is known and already
in the coreboot tree. Enable it with `CONFIG_MEC1653_ENABLE_UART=y` in
`config/defconfig` and `--rebuild-base`. coreboot then unlocks the EC
debug interface at boot and maps the EC's UART to host I/O port 0x3f8,
IRQ 4 over LPC - that is the classic COM1, so no soldering: the console
should appear as `/dev/ttyS0` in Linux (`screen /dev/ttyS0 115200`).

> [!NOTE]
> The 0x3f8/IRQ4 mapping and the unlock mechanism are read from the
> coreboot code (`src/ec/lenovo/mec1653/uart.c`); that the EC actually
> prints anything there, and at which baud rate, is NOT yet verified on
> hardware. Treat this section as a pointer, not a promise.

## Cleaning up

```bash
podman image prune -a -f
rm -rf sources/
```

The exact versions of a build are recorded in `roms/versions_<mode>.lock`, so
everything can be rebuilt later.

## License

[GPL-3.0](LICENSE), inherited from the upstream project. The sources fetched
during the build (coreboot, EDK2, libreboot) have their own licenses and are
not part of this repo.
