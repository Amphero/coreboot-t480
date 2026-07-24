# coreboot for the ThinkPad T480

Build system for a free firmware on the Lenovo ThinkPad T480:
coreboot with the EDK2 payload (MrChromebox), i.e. real UEFI — with Secure Boot
(your own keys via sbctl) and a working discrete TPM 2.0.

Tested on: Type 20L5, mainboard NM-B501, SPI flash Winbond W25Q128 (16 MB, position U49).

This is a fork of [radleylewis/t480_coreboot](https://github.com/radleylewis/t480_coreboot);
the board config and the splash screen are still from there. Everything around
them — the two-phase offline build, the build variants, the TPM reset ROM, the
settings migration — was rebuilt from scratch.

Everything builds inside podman containers, split into two phases: download all
sources once, then every build runs strictly **offline** (`--network=none`) —
reproducible, no surprises.

## Requirements

podman is enough to build; add flashrom for flashing (externally you also need a
CH341A programmer with a SOIC-8 clip):

```bash
sudo pacman -S podman flashrom
```

Nothing else — git, gcc, edk2 etc. all live inside the container.

## Building

```bash
./fetch.sh pinned                                   # phase 1: download sources (~8-12 GB, needs network)
python3 scripts/build-firmware.py --mode pinned     # phase 2: build offline
# -> roms/coreboot_t480_pinned.rom  (16 MB)
```

`pinned` means fixed versions tested on real hardware (listed in
`roms/versions_pinned.lock`). If you want the newest upstream state, use
`latest` in both commands — untested, take a backup first.

The first build takes 30–60 minutes because coreboot compiles its own
toolchain; subsequent builds are fast. The resulting firmware boots with the
TPM enabled, Secure Boot in Setup Mode (ready for your own keys) and the RNG on.

### Set your MAC address (needed once)

The MAC of the onboard ethernet port gets written into the GbE region at build
time. Read yours:

```bash
ip link show enp0s31f6 | grep ether        # on the running T480 (onboard NIC)
```

Alternatively it sits at offset 0x1000 in any full dump of the original
firmware:

```bash
xxd -s 0x1000 -l 6 -p backup.bin | sed 's/../&:/g;s/:$//'
```

Put the value into the `# MAC=` line in `config/defconfig`, or pass it per
build:

```bash
python3 scripts/build-firmware.py --mode pinned --mac AA:BB:CC:DD:EE:FF
```

Without a valid MAC the build stops and tells you.

### Options

```
--tpm-reset       additionally build a reset ROM that clears the TPM (see below)
--no-tpm          disable the TPM (the OS won't see one)
--auto-enroll     enroll the Microsoft keys automatically instead of Setup Mode
--no-rng          leave out the RNG (RDRAND)
--mac AA:BB:..    override the MAC
--rebuild-base    rebuild the base image (needed after changes to config/defconfig)
```

Optional devices (SMBus for the touchpad in RMI4 mode, HECI1, Fast SPI) are
toggled at the end of `config/defconfig` via the `# DT_DEVICE …=y/n` markers;
rebuild with `--rebuild-base` afterwards.

Custom boot logo: replace `config/splash.bmp` (BMP3, 24-bit, uncompressed; the
template is 640×360), then rebuild with `--rebuild-base`:

```bash
magick yourimage.png -type TrueColor -compress None BMP3:config/splash.bmp
```

## Flashing externally (CH341A) — the safe way

Laptop fully de-powered (battery out, PSU unplugged), clip on U49, pin 1 (red
wire) on the dot marking. Never write without a backup:

```bash
# backup: read twice and compare — identical results mean the clip contact was good
sudo flashrom -p ch341a_spi -r backup1.bin
sudo flashrom -p ch341a_spi -r backup2.bin
diff backup1.bin backup2.bin               # no output = ok

# write and verify
sudo flashrom -p ch341a_spi -w roms/coreboot_t480_pinned.rom
sudo flashrom -p ch341a_spi -v roms/coreboot_t480_pinned.rom
```

Afterwards reconnect the CMOS coin cell and set the clock in the OS
(`sudo timedatectl set-ntp true`) — Secure Boot keys are time-based and
enrolling fails silently with a wrong clock. Also add `reboot=pci` to the
kernel cmdline, otherwise soft reboots can hang.

## Flashing internally (from the running system)

Works without a programmer but is riskier — keep the CH341A and a backup at
hand, PSU plugged in, don't interrupt. Requires booting with `iomem=relaxed`.

```bash
sudo flashrom -p internal                  # detect the chip; look for "BIOS region ... is read-write"
sudo flashrom -p internal -r backup.bin    # fresh backup right before writing

sudo flashrom -p internal --ifd -i bios -w roms/coreboot_t480_pinned.rom
sudo flashrom -p internal --ifd -i bios -v roms/coreboot_t480_pinned.rom
```

If flashrom reports "read-only"/"write protected", the BIOS region is locked —
external flashing is the only way then.

## Setting up Secure Boot

The fresh firmware starts in Setup Mode; keys are enrolled from the OS:

```bash
sudo pacman -S sbctl
sudo timedatectl set-ntp true      # important, see above
sbctl create-keys                  # skip if you already have keys
sbctl sign -s /boot/EFI/...        # sign your boot files
sbctl enroll-keys -m               # enroll your keys + the Microsoft CA
sbctl status                       # "Secure Boot: Enabled"
```

If you would rather carry over the UEFI variables (keys, boot entries,
settings) from an already running coreboot firmware:

```bash
# option 1: new file = new firmware + the old SMMSTORE taken from a backup
python3 scripts/transfer-settings.py backup.bin roms/coreboot_t480_pinned.rom
# -> flash coreboot_t480_pinned_migrated.rom; --gbe also carries over the MAC region

# option 2 (internal): write only the COREBOOT region, the SMMSTORE stays untouched
sudo flashrom -p internal --fmap -i COREBOOT -w roms/coreboot_t480_pinned.rom
```

## Resetting the TPM 2.0 (`--tpm-reset`)

Fixes stuck vendor-BIOS states of the discrete TPM ("MFG mode", a set owner
auth, a latched `disableClear`): coreboot sends `TPM2_Clear` at boot through
the platform hierarchy, whose auth is empty after every startup per the TPM 2.0
spec — so no password and no physical presence are needed.

Careful: `TPM2_Clear` is irreversible (all TPM-bound secrets such as LUKS
sealings are gone afterwards), and the reset ROM clears on **every** boot.
So: boot it once, verify, immediately flash the normal ROM back.

```bash
python3 scripts/build-firmware.py --mode pinned --tpm-reset
# -> coreboot_t480_pinned.rom            (normal firmware)
# -> coreboot_t480_pinned_tpmreset.rom   (reset ROM, clears on every boot)

sudo flashrom -p ch341a_spi -w roms/coreboot_t480_pinned_tpmreset.rom   # 1. flash the reset ROM
# ... boot into the OS exactly ONCE, then verify:
sudo grep -i "TPM-RESET" /sys/firmware/log      # step2/step3 must show rc=0x0
tpm2_getcap properties-variable                 # ownerAuthSet/disableClear/... = 0
sudo flashrom -p ch341a_spi -w roms/coreboot_t480_pinned.rom            # 2. flash the normal ROM back
```

(step1 reporting `INVALID_POSTINIT` is expected — coreboot already started the
TPM itself. On systemd 257+ the `systemd-pcrproduct`/`pcrlogin` units fail
because the T480's TPM chip can't do NV `NT_EXTEND` — just mask them.)

## Cleaning up

Build images and sources are big; the finished ROMs are not affected:

```bash
podman image prune -a -f
rm -rf sources/pinned sources/latest
```

Everything is reproducible with the commands above; the exact versions are
recorded in `roms/versions_<mode>.lock`. For extra safety you can archive the
finished build image with `python3 scripts/archive-build.py`.

## Layout

```
fetch.sh                    phase 1: downloads all sources into sources/<mode>/
Makefile                    convenience wrapper (make fetch / make pinned / make latest)
scripts/
  build-firmware.py         phase 2: offline build (variants, --tpm-reset, MAC)
  setup-dev-env.py          check the host + kick off phase 1
  transfer-settings.py      carry over the SMMSTORE (UEFI variables/keys) from a dump
  archive-build.py          save the finished build image as tar.zst
build/
  Dockerfile.deps           build environment (image coreboot-t480-deps)
  Dockerfile.offline        the actual offline build
  fetch-sources.sh          core of phase 1 (runs inside the container)
  apply-devicetree.sh       applies the DT_DEVICE markers from defconfig
config/
  defconfig                 coreboot config (+ MAC and DT_DEVICE markers)
  splash.bmp / splash.png   boot logo (+ source image)
patches/tpm-reset/          the TPM2_Clear patch for the reset ROM
roms/                       build output (ROMs, gitignored) + versions_<mode>.lock
sources/                    phase 1 output (gitignored, ~8-12 GB per mode)
```

## License

GPL-3.0 (see `LICENSE`), inherited from the upstream project this repository
is forked from. The sources downloaded in phase 1 (coreboot, EDK2,
libreboot/lbmk) come under their own licenses and are not part of this
repository.
