#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# fetch.sh  -  PHASE 1 (FETCH).  Host wrapper; only needs `podman`.
#
# Builds the build-environment image (coreboot-t480-deps) and runs the fetch
# INSIDE it WITH network, populating ./sources/<BUILD_MODE>/ with EVERYTHING the
# offline build (PHASE 2) needs. After this has run once, PHASE 2 builds fully
# offline (--network=none).
#
#   ./fetch.sh                     # BUILD_MODE=pinned (default, HW-tested combo)
#   ./fetch.sh pinned
#   ./fetch.sh latest              # auto-detect newest coreboot/edk2/libreboot/lbmk
#   ./fetch.sh latest --refresh    # re-resolve 'latest' (otherwise versions.lock is frozen)
#   BUILD_MODE=latest ./fetch.sh
#
# Optional per-component overrides (win in BOTH modes), via env:
#   COREBOOT_REF=<commit|tag>  EDK2_BRANCH=uefipayload_JJMM  LBMK_REF=<tag|commit>
#   LIBREBOOT_VERSION=<ver>    LIBREBOOT_TARBALL=/path/to/..._t480_vfsp_16mb.tar.xz
#
# Flags: --refresh  --rebuild-deps
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$PROJECT/build"        # build recipes: Dockerfile.deps/.offline, fetch-sources.sh, apply-devicetree.sh
CONFIG="$PROJECT/config"      # board config + boot logo: defconfig, splash.bmp
DEPS_IMAGE="coreboot-t480-deps"

MODE="${BUILD_MODE:-pinned}"
REFRESH=0
REBUILD_DEPS=0
for a in "$@"; do
  case "$a" in
    pinned|latest) MODE="$a" ;;
    --refresh)      REFRESH=1 ;;
    --rebuild-deps) REBUILD_DEPS=1 ;;
    -h|--help) sed -n '3,31p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 2 ;;
  esac
done
[ "$MODE" = "pinned" ] || [ "$MODE" = "latest" ] || { echo "BUILD_MODE must be pinned|latest" >&2; exit 2; }

die(){ printf '\n\033[1;31mfetch.sh ERROR: %s\033[0m\n' "$*" >&2; exit 1; }
command -v podman >/dev/null || die "podman is missing (sudo pacman -S podman)"

SRC="$PROJECT/sources/$MODE"
mkdir -p "$SRC/libreboot"

# --- optional externally-provided libreboot tarball -------------------------
PROVIDED=0
if [ -n "${LIBREBOOT_TARBALL:-}" ]; then
  [ -f "$LIBREBOOT_TARBALL" ] || die "LIBREBOOT_TARBALL='$LIBREBOOT_TARBALL' does not exist"
  bn="$(basename "$LIBREBOOT_TARBALL")"
  case "$bn" in
    libreboot-*_t480_vfsp_16mb.tar.xz)
      : "${LIBREBOOT_VERSION:=$(printf '%s' "$bn" | sed 's/^libreboot-\(.*\)_t480_vfsp_16mb\.tar\.xz$/\1/')}" ;;
    *) [ -n "${LIBREBOOT_VERSION:-}" ] || die "unexpected tarball name; please set LIBREBOOT_VERSION=..." ;;
  esac
  cp -f "$LIBREBOOT_TARBALL" "$SRC/libreboot/$bn"
  [ -f "$LIBREBOOT_TARBALL.sha512" ] && cp -f "$LIBREBOOT_TARBALL.sha512" "$SRC/libreboot/$bn.sha512" || true
  [ -f "$LIBREBOOT_TARBALL.sig" ]    && cp -f "$LIBREBOOT_TARBALL.sig"    "$SRC/libreboot/$bn.sig"    || true
  PROVIDED=1
  echo "fetch.sh: using provided tarball $bn (version ${LIBREBOOT_VERSION:-?})"
fi

# --- build the deps image (network) -----------------------------------------
if [ "$REBUILD_DEPS" = "1" ] || ! podman image exists "$DEPS_IMAGE"; then
  echo "fetch.sh: building build-environment image '$DEPS_IMAGE' (once, with network) ..."
  podman build -t "$DEPS_IMAGE" -f "$BUILD/Dockerfile.deps" "$BUILD" \
    || die "deps image build failed"
else
  echo "fetch.sh: '$DEPS_IMAGE' exists (--rebuild-deps to rebuild)."
fi

# --- run the fetch inside the deps image (network ON, as the host user) ------
# --userns=keep-id: run as the host uid so (a) files under ./sources are owned
# by you and (b) lbmk runs non-root (it refuses uid 0).
echo "fetch.sh: PHASE 1 in the container (BUILD_MODE=$MODE, network on) ..."
podman run --rm \
  --userns=keep-id \
  -e HOME=/tmp/fetchhome \
  -e BUILD_MODE="$MODE" \
  -e REFRESH="$REFRESH" \
  -e LIBREBOOT_TARBALL_PROVIDED="$PROVIDED" \
  -e COREBOOT_REF="${COREBOOT_REF:-}" \
  -e EDK2_BRANCH="${EDK2_BRANCH:-}" \
  -e LIBREBOOT_VERSION="${LIBREBOOT_VERSION:-}" \
  -e LBMK_REF="${LBMK_REF:-}" \
  -v "$PROJECT/sources":/sources:z \
  -v "$BUILD":/work:ro,z \
  "$DEPS_IMAGE" \
  bash /work/fetch-sources.sh \
  || die "PHASE 1 (fetch-sources.sh) failed - see output above."

# --- freeze the build config next to the sources (self-contained context) ----
cp -f "$CONFIG/defconfig" "$SRC/defconfig"
cp -f "$BUILD/apply-devicetree.sh" "$SRC/apply-devicetree.sh"   # config-driven devicetree toggles
[ -f "$CONFIG/splash.bmp" ] && cp -f "$CONFIG/splash.bmp" "$SRC/splash.bmp" || true
rm -rf "$SRC/patches" && cp -a "$PROJECT/patches" "$SRC/patches" # base patches (Dockerfile.offline) + tpm-reset

echo
echo "fetch.sh: sources/$MODE ready. Continue with the offline build:"
echo "    python3 scripts/build-firmware.py --mode $MODE"
