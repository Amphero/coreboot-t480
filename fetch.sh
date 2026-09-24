#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# fetch.sh  -  PHASE 1 (FETCH).  Host wrapper; only needs `podman`.
#
# Builds the build-environment image (coreboot-t480-deps) and runs the fetch
# INSIDE it WITH network, populating ./sources/ with EVERYTHING the offline
# build (PHASE 2) needs. After this has run once, PHASE 2 builds fully offline
# (--network=none).
#
#   ./fetch.sh                     # fetch the versions in config/versions.lock
#   ./fetch.sh --latest            # resolve newest upstream, REWRITE config/versions.lock
#   ./fetch.sh --refresh           # re-fetch sources even where stamps exist
#   ./fetch.sh --check-updates     # compare the lock with upstream, change nothing
#
# --latest picks WHICH versions, --refresh whether to re-download; they are
# independent and can be combined. A ref that changed in the lock re-fetches
# its own component on the next run without --refresh.
#
# Optional per-component overrides for --latest only (env):
#   COREBOOT_REF=<commit|tag>  EDK2_BRANCH=uefipayload_JJMM  LBMK_REF=<tag|commit>
#   LIBREBOOT_VERSION=<ver>    LIBREBOOT_TARBALL=/path/to/..._t480_vfsp_16mb.tar.xz
#
# --check-updates writes nothing: it prints the newest upstream versions next
# to the lock and exits 0 (current) or 10 (something moved).
# GIT_JOBS=<n> lowers the parallel submodule clones (default 4).
#
# Flags: --latest  --refresh  --rebuild-deps  --check-updates
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$PROJECT/build"        # build recipes: Dockerfile.deps/.offline, fetch-sources.sh, apply-devicetree.sh
CONFIG="$PROJECT/config"      # board config + boot logo: defconfig, board.conf, versions.lock, splash.bmp
DEPS_IMAGE="coreboot-t480-deps"

LATEST=0
REFRESH=0
REBUILD_DEPS=0
CHECK=0
for a in "$@"; do
  case "$a" in
    --latest)        LATEST=1 ;;
    --refresh)       REFRESH=1 ;;
    --rebuild-deps)  REBUILD_DEPS=1 ;;
    --check-updates) CHECK=1 ;;
    -h|--help) sed -n '3,/^set -euo pipefail/p' "$0" | head -n -1; exit 0 ;;
    *) echo "Unknown argument: $a" >&2; exit 2 ;;
  esac
done

die(){ printf '\n\033[1;31mfetch.sh ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- --check-updates ---------------------------------------------------------
# Same resolver as the fetch (build/fetch-sources.sh), so only one place knows
# how versions are found. In the deps image if it exists, else on the host -
# building a 2 GB image to answer a question is not worth it.
if [ "$CHECK" = "1" ]; then
  [ "$LATEST$REFRESH$REBUILD_DEPS" = "000" ] \
    || die "--check-updates reads only and combines with nothing else."
  [ -f "$CONFIG/versions.lock" ] || die "config/versions.lock is missing - nothing to compare against."
  if command -v podman >/dev/null && podman image exists "$DEPS_IMAGE"; then
    exec podman run --rm -e CHECK=1 -e HOME=/tmp/fetchhome \
      -v "$BUILD":/work:ro,z -v "$CONFIG":/config:ro,z \
      "$DEPS_IMAGE" bash /work/fetch-sources.sh
  fi
  command -v git >/dev/null && command -v curl >/dev/null \
    || die "no '$DEPS_IMAGE' image and no git/curl on the host.
   Run ./fetch.sh once (it builds the image), or install git and curl."
  exec env CHECK=1 LOCK_IN="$CONFIG/versions.lock" bash "$BUILD/fetch-sources.sh"
fi

command -v podman >/dev/null || die "podman is missing (sudo pacman -S podman)"
if [ -f /etc/subuid ] && ! grep -q "^$(id -un):" /etc/subuid; then
  echo "fetch.sh: no /etc/subuid entry for $(id -un) - rootless podman may need:"
  echo "    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)"
fi

SRC="$PROJECT/sources"
mkdir -p "$SRC/libreboot"

# Leftovers from the two-mode layout. They are not read any more and just eat
# disk, so say so once instead of letting the build fail on a missing tree.
for old in pinned latest; do
  if [ -d "$SRC/$old" ]; then
    echo "fetch.sh: sources/$old/ is from the old pinned/latest layout and is no longer used."
    echo "    rm -rf sources/$old   (and: podman rmi coreboot-t480-$old)"
  fi
done

[ "$LATEST" = "1" ] || [ -f "$CONFIG/versions.lock" ] \
  || die "config/versions.lock is missing - it is the input for the fetch.
   Run ./fetch.sh --latest to resolve the newest upstream versions and create it."

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
# config/ goes in read-only: the container never writes into the working tree.
# With --latest it writes the resolved set to /sources/versions.lock and the
# host copies it back below, so a fetch that dies halfway cannot leave
# config/versions.lock half-updated.
echo "fetch.sh: PHASE 1 in the container (network on) ..."
podman run --rm \
  --userns=keep-id \
  -e HOME=/tmp/fetchhome \
  -e LATEST="$LATEST" \
  -e REFRESH="$REFRESH" \
  -e GIT_JOBS="${GIT_JOBS:-}" \
  -e LIBREBOOT_TARBALL_PROVIDED="$PROVIDED" \
  -e COREBOOT_REF="${COREBOOT_REF:-}" \
  -e EDK2_BRANCH="${EDK2_BRANCH:-}" \
  -e LIBREBOOT_VERSION="${LIBREBOOT_VERSION:-}" \
  -e LBMK_REF="${LBMK_REF:-}" \
  -v "$SRC":/sources:z \
  -v "$BUILD":/work:ro,z \
  -v "$CONFIG":/config:ro,z \
  "$DEPS_IMAGE" \
  bash /work/fetch-sources.sh \
  || die "PHASE 1 (fetch-sources.sh) failed - see output above."

# --latest resolved new versions inside the container; take them over now that
# the fetch actually succeeded.
if [ "$LATEST" = "1" ]; then
  # Values only. The sources copy carries its own header ("edit config/, not
  # this file"), which would be nonsense in the file it points at.
  if [ -f "$CONFIG/versions.lock" ]; then
    sed -n '/^[A-Z]/q;p' "$CONFIG/versions.lock" > "$CONFIG/versions.lock.new"
  else
    cat > "$CONFIG/versions.lock.new" <<'EOF'
# versions.lock  -  the upstream sources this firmware is built from.
#
# INPUT, not output. ./fetch.sh reads this file and fetches exactly these refs.
# Nothing rewrites it behind your back; the one thing that does is
# `./fetch.sh --latest`, which resolves the newest upstream versions and writes
# them here, so the change lands in `git diff` and gets reviewed, built and
# committed like any other change.
#
# A git tag pins strictly more than this file does: the same four refs plus
# config/defconfig, the patch series, the Dockerfiles and the scripts. To
# reproduce a release, check out its tag - not just these versions.
#
# LIBREBOOT_TARBALL is derived from LIBREBOOT_VERSION by the fetch; it is
# recorded here so the file states the full set on its own.

EOF
  fi
  grep '^[A-Z]' "$SRC/versions.lock" >> "$CONFIG/versions.lock.new"
  mv -f "$CONFIG/versions.lock.new" "$CONFIG/versions.lock"
  echo
  echo "fetch.sh: config/versions.lock updated - review and commit it:"
  echo "    git diff config/versions.lock"
fi

# --- freeze the build config next to the sources (self-contained context) ----
cp -f "$CONFIG/defconfig" "$SRC/defconfig"
cp -f "$CONFIG/board.conf" "$SRC/board.conf"                    # MAC marker + DT_DEVICE toggles
cp -f "$BUILD/apply-devicetree.sh" "$SRC/apply-devicetree.sh"   # config-driven devicetree toggles
rm -rf "$SRC/keys"; mkdir -p "$SRC/keys"                        # vboot signing keys (untracked)
[ -d "$PROJECT/keys" ] && cp -a "$PROJECT/keys/." "$SRC/keys/" || true
[ -f "$CONFIG/splash.bmp" ] && cp -f "$CONFIG/splash.bmp" "$SRC/splash.bmp" || true
rm -rf "$SRC/patches" && cp -a "$PROJECT/patches" "$SRC/patches" # base patches (Dockerfile.offline) + tpm-reset

echo
echo "fetch.sh: sources/ ready. Continue with the offline build:"
echo "    python3 scripts/build-firmware.py"
