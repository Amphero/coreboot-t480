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

coreboot with MrChromebox's EDK2 payload for the ThinkPad T480. A real UEFI
with Secure Boot (your own keys), a working discrete TPM 2.0, verified boot
with signed A/B firmware slots, and signed firmware updates through fwupd.

Forked from [radleylewis/t480_coreboot](https://github.com/radleylewis/t480_coreboot).
The board config is from there, the build system around it is new. The lowest
layer reuses [Libreboot's](https://libreboot.org/docs/install/t480.html)
`lbmk` for the ME/Boot Guard handling; payload, security model and update
mechanism are this repo's own.

Tested on a Type 20L5 (mainboard NM-B501). The SPI flash is a Winbond
W25Q128, 16 MB, at position U49.

> [!WARNING]
> Flashing firmware can permanently brick your laptop. Everything in this repo
> is provided WITHOUT ANY WARRANTY and without liability for any damage, as
> stated in the [LICENSE](LICENSE) (GPL-3.0, sections 15 and 16). You flash at
> your own risk. Keep a backup of your original flash and never flash anything
> you cannot restore.

## Security state

`fwupdmgr security` grades a machine against the
[Host Security ID](https://fwupd.github.io/hsi.html) tests. Measured on this
firmware (fwupd 2.1.7, 2026-08-24): every HSI-1 and HSI-2 test passes
(HSI:2). The MTD pair needs one host-side config line - see the table.

| HSI-1 | Status | Mechanism |
|---|---|---|
| Firmware updates | ✓ enabled | signed UEFI capsules into the inactive vboot slot, applied via fwupd |
| SPI write / SPI lock / BIOS region | ✓ locked | SMM BIOS write protect (`BOOTMEDIA_SMM_BWP`), BIOS Lock on |
| SPI BIOS descriptor | ✓ locked | descriptor locked at build, host write access dropped |
| TPM v2.0, empty PCRs | ✓ | discrete TPM 2.0, cleared and re-owned at first vboot boot |
| UEFI Secure Boot, platform key | ✓ enabled | your own keys via `sbctl`, no vendor keys |
| UEFI boot service variables | ✓ locked | SMMSTORE v2 behind SMM |
| Platform debugging | ✓ disabled | Intel DCI off |

| HSI-2 | Status | |
|---|---|---|
| IOMMU | ✓ enabled | VT-d |
| Platform debugging locked | ✓ | |
| coreboot verified boot flag | ✓ detected | passes since the event log reconstructs ([#6](https://github.com/Amphero/coreboot-t480/issues/6)) |
| Locked MTD | ✓ no MTD device | fwupd wants block-protection bits in the flash chip itself; setting them would lock out the SMM capsule writer along with everything else. The protection is PCH protected ranges + SMM BWP, so the spi-intel driver is blacklisted on the host (GUIDE) and no MTD device exists ([#7](https://github.com/Amphero/coreboot-t480/issues/7)) |
| TPM PCR0 reconstruction | ✓ valid | sha256-only PCR bank; coreboot's measurements are replayed into the TCG2 log and the log parses end to end ([#8](https://github.com/Amphero/coreboot-t480/issues/8)) |

**Boot Guard is deliberately absent** and stays that way. It is removed with
`deguard` (the only way to run coreboot on this platform at all), so the
hardware root of trust is gone. Its role is taken by vboot: verstage in the
write-protected `WP_RO` region verifies the signed slots with your root key,
and PCH protected ranges seal `WP_RO`, the descriptor and the GbE region
against every write from a running system - root, SMM and BIOS Lock
included. The trust boundary is physical access to the chip, and the keys
are yours instead of the vendor's.

Details and the measurements behind all of this: [docs/](docs/).

## Build

```bash
sudo pacman -S podman flashrom       # host needs nothing else

./fetch.sh                           # PHASE 1: download sources (8-12 GB), once
sh scripts/gen-vboot-keys.sh         # slot signing keyset, once
sh scripts/gen-capsule-certs.sh      # capsule signing chain, once
MAC=AA:BB:CC:DD:EE:FF python3 scripts/build-firmware.py   # PHASE 2: offline
```

`AA:BB:CC:DD:EE:FF` is a placeholder and the build refuses it. It wants the
MAC of your onboard NIC, which ends up in the GbE region:
`ip link show enp0s31f6 | grep ether`.

Every build produces three artifacts in `roms/`: the ROM, an update capsule
(`.cap`) and a fwupd cabinet (`.cab`). The build runs entirely in podman,
offline, from sources pinned in `config/versions.lock`. Both keysets are
untracked in `keys/`; the build refuses to fall back to public keys.

Variants (`--tpm-reset`, `--no-tpm`, custom splash, device toggles):
[GUIDE.md - Building](GUIDE.md#building).

## Install and update

**First install** - external flash with a CH341A programmer while the vendor
BIOS is still on the chip. Bring the EC to `n24ur39w` first and dump the
original flash; both are impossible later.
[GUIDE.md - First install](GUIDE.md#first-install).

**Updates** - through fwupd, from the running system:

```bash
fwupdmgr install roms/coreboot_t480_<version>.cab
reboot
```

The firmware verifies the capsule against your signing root, writes the
inactive slot and gives it one trial boot; if the new firmware does not come
up, the next boot falls back to the old slot on its own. Secure Boot keys
and settings are never touched. One-time fwupd setup and the alternative
paths (kernel capsule loader, flashrom):
[GUIDE.md - Updating](GUIDE.md#updating).

**`WP_RO` refresh or a new vboot keyset** - the only case that needs the
programmer again: the region is sealed against the running system by design.
[GUIDE.md - Externally, WP_RO included](GUIDE.md#externally-wp_ro-included).

## What else is in there

- Five-level fan control with four profiles in the setup menu
- Bluetooth/WWAN rfkill that stays off across reboots
- Setup options for ME, AC-after-power-loss, BIOS Lock
- Measured boot into TPM PCR 2, usable for LUKS binding
- A TPM-reset ROM variant for machines with a stuck TPM
- Rollback protection with a recorded version history
  ([docs/firmware-versions.md](docs/firmware-versions.md))

All documented in [GUIDE.md](GUIDE.md); the design notes and hardware
measurements behind them are in [docs/](docs/) and
[patches/README.md](patches/README.md).

## License

[GPL-3.0](LICENSE) for the build system, scripts and documentation, inherited
from the upstream project. The patch files carry the license of the tree they
modify instead: GPL-2.0-only for `patches/base/` (coreboot), BSD-2-Clause-Patent
for `patches/edk2/` (EDK2) - the SPDX headers inside the patches say so per
file. The sources fetched during the build have their own licenses and are not
part of this repo.
