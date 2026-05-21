# coreboot T480

> GitHub: [radleylewis/t480_coreboot](https://www.github.com/radleylewis/t480_coreboot)

Clone the repo first — all steps below assume you are working from within it:

```bash
git clone https://www.github.com/radleylewis/t480_coreboot
cd t480_coreboot
```

Builds coreboot with MrChromebox EDK2 for the ThinkPad T480. Uses lbmk (libreboot's build toolchain) to prepare the ME and GbE blobs in a first stage, then compiles coreboot with a full UEFI payload in a second stage. Everything runs in a container (no host dependencies beyond Podman).

## What you need

- Podman (preferred) or Docker
- A SPI programmer (e.g. CH341A) with a SOIC-8 clip
- Your T480's MAC address (`ip link show` on the running machine, or check your router)
- `libreboot-26.01rev1_t480_vfsp_16mb.tar.xz` from the [libreboot releases page](https://libreboot.org/download.html)

---

## Prepare

**1. Download the libreboot ROM**

Download `libreboot-26.01rev1_t480_vfsp_16mb.tar.xz` from the [libreboot releases page](https://libreboot.org/download.html) and place it in a `libreboot/` directory in the repo root.

**2. Read & backup your OEM ROM**

Clip your SPI programmer (e.g. CH341A) onto the chip and read it twice. Only proceed if `diff` produces no output (this confirms the reads are identical):

```bash
mkdir -p oem
flashrom -p ch341a_spi -r oem/T480.img
flashrom -p ch341a_spi -r oem/diff.img
diff oem/T480.img oem/diff.img && rm oem/diff.img
```

> [!WARNING]
> Keep this somewhere in case you want to restore.

**3. Get your MAC address**

Find it via `ip link show` on the running machine, or from your router's DHCP table. You will pass it as a build arg in the next step.

---

## Layout

```
t480_coreboot/
|-- Dockerfile
|-- defconfig
|-- splash.bmp          <- optional boot splash (see below)
|-- README.md
```

**Optional: custom boot splash**

If `splash.bmp` is present it will be included. If not, the build falls back to the coreboot default. Must be a 24-bit uncompressed BMP under ~700KB. To convert from PNG:

```bash
magick splash.png -type TrueColor -compress None BMP3:splash.bmp
```

> [!WARNING]
> If the splash image is too large the EDK2 firmware volume will overflow and the build will fail.

---

## Build

```bash
# NOTE: add your MAC_ADDRESS here as per your specific machine
podman build --build-arg MAC_ADDRESS="xx:xx:xx:xx:xx:xx" -t coreboot-libreboot-t480 .
```

**Stage 1:** clones lbmk, injects the MAC address into the libreboot ROM, and produces a ROM with a correctly deguarded ME and correct GbE.
**Stage 2:** clones coreboot, extracts the blobs from that ROM, and compiles the final image with EDK2. Expect 30-60 minutes on first run. Subsequent builds use the layer cache so only changed steps re-run.

> [!TIP]
> Podman is preferred over Docker on Linux (its a drop in Docker replacement which is rootless by default and doesn't run a daemon). The `:z` label on volume mounts handles SELinux correctly (you can remove it using Docker).

---

## Copy the ROM from the container to the local directory we are working in

```bash
mkdir -p roms
podman run --rm -v $(pwd)/roms:/out:z --user root coreboot-libreboot-t480 \
  bash -c "cp /opt/coreboot/build/coreboot.rom /out/"
```

Verify it is approximately 16.7 MB:

```bash
ls -lh roms/coreboot.rom
```

---

## Flash

Flash the ROM to the chip (red wire lines up with the dot on the chip):

```bash
flashrom -p ch341a_spi -w roms/coreboot.rom
```

---

## Config

The `defconfig` file controls what gets built. Notable options:

- `CONFIG_POWER_STATE_ON_AFTER_FAILURE=y` - powers on automatically after AC loss (I've added this for an always on Home Server)
- `CONFIG_EDK2_BOOTSPLASH_FILE` - path to the boot splash inside the container (stripped automatically if `splash.bmp` is absent)
- `CONFIG_CBFS_SIZE=0xE0C000` - sized to fit the libreboot IFD region layout

To add iPXE network boot, append these two lines to `defconfig` and rebuild:

```
CONFIG_EDK2_ENABLE_IPXE=y
CONFIG_EDK2_DEBUG=y
```

> [!NOTE]
> `CONFIG_EDK2_DEBUG=y` is required because the release FV is too small to include iPXE.

---

## After flashing

Add `reboot=pci` to your kernel command line or soft reboots will hang:

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet reboot=pci"
sudo update-grub
```

---

## Notes

- ME is deguarded via lbmk's pre-computed T480 delta and the HAP bit is set to halt ME after hardware init
- GbE MAC address is injected at build time via the `MAC_ADDRESS` build arg
- coreboot is pinned to commit `2a2ab9e0` (known-good with MrChromebox EDK2 `uefipayload_2603`)
- No CPU whitelist under coreboot (any Kaby Lake Refresh CPU works)
- The power-on-AC setting is also exposed in the UEFI setup menu under System > Restore AC power after loss (along with other options like hyperthreading which Libreboot disables for what they state to be security reasons)
