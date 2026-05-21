# coreboot T480 build with EDK2/UEFI payload
#
# Requires:
#   - libreboot/libreboot-26.01rev1_t480_vfsp_16mb.tar.xz in the build context
#   - One build arg: MAC_ADDRESS
#
# Build:
#   podman build \
#     --build-arg MAC_ADDRESS="xx:xx:xx:xx:xx:xx" \
#     -t coreboot-t480 .
#
# Get ROM:
#   mkdir -p roms
#   podman run --rm -v $(pwd)/roms:/out:z --user root coreboot-t480 \
#     bash -c "cp /opt/coreboot/build/coreboot.rom /out/"

# ---------- Stage 1: libreboot injection ----------
# Runs mk inject to produce ROMs with correctly deguarded ME (via lbmk's
# pre-computed T480 delta + me_cleaner) and GbE with the correct MAC address.
FROM debian:bookworm AS libreboot

ARG MAC_ADDRESS
RUN test -n "$MAC_ADDRESS" \
    || { echo "ERROR: MAC_ADDRESS build arg is required"; exit 1; }

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    wget \
    curl \
    xz-utils \
    ca-certificates \
    build-essential \
    python3 \
    sudo \
    gnupg \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m builder

WORKDIR /opt

RUN git clone https://codeberg.org/libreboot/lbmk.git

WORKDIR /opt/lbmk

RUN apt-get update && yes | ./mk dependencies debian

COPY libreboot/libreboot-26.01rev1_t480_vfsp_16mb.tar.xz /opt/lbmk/

RUN chown -R builder:builder /opt/lbmk

USER builder

WORKDIR /opt/lbmk

# Mock the git user/email for the lbmk step which requires it
RUN git config --global user.name "builder" && \
    git config --global user.email "builder@localhost"

RUN ./mk inject libreboot-26.01rev1_t480_vfsp_16mb.tar.xz setmac "$MAC_ADDRESS"

RUN tar -xf libreboot-26.01rev1_t480_vfsp_16mb.tar.xz

# ---------- Stage 2: coreboot + EDK2 build ----------
FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    wget \
    curl \
    xz-utils \
    ca-certificates \
    build-essential \
    python3 \
    python3-pip \
    sudo \
    gnupg \
    software-properties-common \
    bison \
    flex \
    libncurses-dev \
    zlib1g-dev \
    libssl-dev \
    libelf-dev \
    cmake \
    pkg-config \
    uuid-dev \
    nasm \
    acpica-tools \
    innoextract \
    xxd \
    vim \
    gnat \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages pefile

# EDK2 build scripts expect `python` not `python3`
RUN ln -s /usr/bin/python3 /usr/bin/python

RUN useradd -m -s /bin/bash builder && \
    echo "builder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

WORKDIR /opt

# Pinned to the commit that produced a known-good build for T480 with
# MrChromebox EDK2 uefipayload_2603. Uses init+fetch to get a shallow
# clone of a specific commit (--depth 1 --branch doesn't accept hashes).
RUN git init coreboot && \
    git -C coreboot fetch --depth 1 https://review.coreboot.org/coreboot.git 2a2ab9e0cca320b98fb47ad41a2a4baf7a31b7d2 && \
    git -C coreboot checkout FETCH_HEAD

# Expose "Restore AC power after loss" in the EDK2 setup menu.
# Default Intel ME to disabled (the Kconfig symbol may not exist in this commit,
# so patch the default_value directly rather than relying on defconfig).
RUN sed -i 's/\t\t&me_state,/\t\t\&power_on_after_fail,\n\t\t\&me_state,/' \
    coreboot/src/mainboard/lenovo/sklkbl_thinkpad/cfr.c && \
    sed -i 's/\.default_value\t= CONFIG(CSE_DEFAULT_CFR_OPTION_STATE_DISABLED),/.default_value\t= 1,/' \
    coreboot/src/soc/intel/common/block/include/intelblocks/cfr.h

RUN mkdir -p /opt/coreboot/binaries

# Copy a libreboot ROM from stage 1 — all three blobs are extracted from it:
# - IFD: libreboot layout (small ME region, large BIOS region for 14MB CBFS)
# - ME:  deguarded + me_cleaned by lbmk (Boot Guard bypassed)
# - GbE: correct MAC address injected by mk inject
COPY --from=libreboot /opt/lbmk/bin/t480_vfsp_16mb/seagrub_t480_vfsp_16mb_libgfxinit_corebootfb_usqwerty.rom \
    /opt/libreboot.rom

RUN chown -R builder:builder /opt/coreboot

USER builder

WORKDIR /opt/coreboot

RUN echo "" && \
    echo "========================================" && \
    echo "  STEP 1 - extracting blobs from libreboot ROM" && \
    echo "========================================" && \
    echo ""

RUN make -C util/ifdtool && \
    util/ifdtool/ifdtool -x -p sklkbl /opt/libreboot.rom && \
    mv flashregion_0_flashdescriptor.bin binaries/ifd.bin && \
    mv flashregion_2_intel_me.bin binaries/me.bin && \
    mv flashregion_3_gbe.bin binaries/gbe.bin && \
    rm -f flashregion_*.bin

RUN echo "" && \
    echo "========================================" && \
    echo "  STEP 2 - loading defconfig" && \
    echo "========================================" && \
    echo ""

COPY defconfig /opt/coreboot/defconfig
# NOTE! The addition of a splash is optional. The glob form of COPY does not fail if the source is absent.
# If splash.bmp was not provided, strip the two splash options from defconfig so
# the build falls back to the coreboot default (grey screen).
COPY splash.bmp* /opt/coreboot/
RUN [ -f /opt/coreboot/splash.bmp ] || \
    sed -i '/CONFIG_EDK2_BOOTSPLASH_FILE/d; /CONFIG_EDK2_FOLLOW_BGRT_SPEC/d' /opt/coreboot/defconfig

RUN cd /opt/coreboot && \
    cp defconfig .config && \
    make olddefconfig

RUN echo "" && \
    echo "========================================" && \
    echo "  STEP 3 - building cross-compiler" && \
    echo "  this takes a while" && \
    echo "========================================" && \
    echo ""

RUN until make crossgcc-i386 CPUS=$(nproc); do \
        echo "Download failed, retrying..."; \
        sleep 5; \
    done

RUN echo "" && \
    echo "========================================" && \
    echo "  STEP 4 - building coreboot" && \
    echo "  this might also take a while" && \
    echo "========================================" && \
    echo ""

RUN make -j$(nproc)

RUN echo "" && \
    echo "========================================" && \
    echo "  DONE - coreboot.rom is ready" && \
    echo "  run: podman run --rm -v \$(pwd)/roms:/out:z --user root coreboot-t480 bash -c 'cp /opt/coreboot/build/coreboot.rom /out/'" && \
    echo "========================================" && \
    echo ""

CMD ["bash"]
