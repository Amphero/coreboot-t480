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
firmware (fwupd 2.1.7, 2026-08-17): every HSI-1 test passes; at HSI-2 the
platform tests pass and four tests are open, tracked as issues.

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
| coreboot verified boot flag | ✘ open | vboot is active but fwupd's detection does not see it |
| Locked MTD | ✘ open | `/dev/mtd0` (Fast SPI) reports writable; writes are refused by the protected ranges, the flag disagrees |
| TPM PCR0 reconstruction | ✘ open | measurements go to PCR 2 (coreboot), the PCR 0 event log does not reconstruct |

The three open items are firmware-side and will ship as capsule updates.

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

## Repo layout

| | |
|---|---|
| `fetch.sh` | PHASE 1: fetch the pinned sources, build the container image |
| `scripts/build-firmware.py` | PHASE 2: offline build, ROM + capsule + cab |
| `scripts/make-capsule.py` | build and sign an update capsule from a ROM |
| `scripts/gen-vboot-keys.sh` | generate the vboot keyset into `keys/` |
| `scripts/gen-capsule-certs.sh` | generate the capsule signing chain into `keys/capsule/` |
| `scripts/vbnv.py` | read and steer the vboot state (slots, trial boots, boot-ok) |
| `scripts/transfer-settings.py` | carry SMMSTORE from a backup into a fresh ROM |
| `scripts/spi-ranges.py` | dump the SPI protected ranges from SPIBAR |
| `config/` | defconfig, board.conf, versions.lock, splash |
| `patches/` | coreboot and EDK2 patches, each documented |
| `docs/` | design notes: vboot, capsules, firmware versions |

## License

[GPL-3.0](LICENSE), inherited from the upstream project. The sources fetched
during the build (coreboot, EDK2, libreboot) have their own licenses and are
not part of this repo.
