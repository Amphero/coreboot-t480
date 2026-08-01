#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# fetch-sources.sh  -  PHASE 1 (FETCH).  Runs INSIDE the coreboot-t480-deps
# container WITH network. Downloads every source the offline build (PHASE 2)
# needs into /sources/<BUILD_MODE>/ so PHASE 2 can run with --network=none.
#
# Driven by env (set by ./fetch.sh):
#   BUILD_MODE   pinned | latest
#   REFRESH      1 = re-resolve 'latest' versions even if versions.lock exists
#   Overrides (optional, win over defaults/auto-detect in BOTH modes):
#     COREBOOT_REF  EDK2_BRANCH  LIBREBOOT_VERSION  LBMK_REF
#   LIBREBOOT_TARBALL_PROVIDED  1 = tarball already placed in <src>/libreboot/
#
# Everything is idempotent: a component with its .stamp present is skipped.
set -euo pipefail

MODE="${BUILD_MODE:?BUILD_MODE not set}"
REFRESH="${REFRESH:-0}"
SRC="/sources/$MODE"
NPROC="$(nproc)"
# Throwaway MAC for the PHASE-1 lbmk populate run ONLY (this inject result is
# discarded). The REAL MAC lives in config/defconfig and is injected in PHASE 2.
POPULATE_MAC="02:00:00:00:00:01"

# git identity (lbmk + submodule ops need one; container user has no ~/.gitconfig)
export HOME="${HOME:-/tmp/fetchhome}"; mkdir -p "$HOME"
git config --global user.name  "builder"           2>/dev/null || true
git config --global user.email "builder@localhost" 2>/dev/null || true
git config --global --add safe.directory '*'        2>/dev/null || true
git config --global advice.detachedHead false       2>/dev/null || true

log(){ printf '\n\033[1;36m[fetch:%s] %s\033[0m\n' "$MODE" "$*"; }
die(){ printf '\n\033[1;31m[fetch:%s] ERROR: %s\033[0m\n' "$MODE" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- coreboot upstream
CB_URL="https://review.coreboot.org/coreboot.git"
CB_GH="https://github.com/coreboot/coreboot.git"
EDK2_URL="https://github.com/mrchromebox/edk2"
LBMK_URL="https://codeberg.org/libreboot/lbmk.git"
LBMK_BKUP="https://git.disroot.org/libreboot/lbmk.git"
LR_MIRRORS=(
  "https://mirrors.mit.edu/libreboot"
  "https://mirror.math.princeton.edu/pub/libreboot"
  "https://rsync.libreboot.org"
)
LEAH_KEY="8BB1F7D28CF7696DBF4F71925C654067D383B1FF"

# coreboot submodules the T480 EDK2 build actually consumes (mirrors coreboot's
# Makefile.mk: the blanket `git submodule update --init` plus the forced
# update=none ones). We fetch ONLY these; PHASE 2's blanket init will try the
# rest, fail instantly offline (errors are swallowed by coreboot) and move on.
CB_SUBMODULES=(3rdparty/vboot 3rdparty/libgfxinit 3rdparty/libhwbase \
               3rdparty/cmocka 3rdparty/blobs 3rdparty/intel-microcode 3rdparty/fsp)

# =====================================================================
# 1) Resolve versions  (constants for pinned; ls-remote/mirror for latest)
# =====================================================================
LOCK="$SRC/versions.lock"
mkdir -p "$SRC"

sortver(){ sort -V; }

resolve_pinned(){
  COREBOOT_REF="${COREBOOT_REF:-2a2ab9e0cca320b98fb47ad41a2a4baf7a31b7d2}"
  EDK2_BRANCH="${EDK2_BRANCH:-uefipayload_2603}"
  # uefipayload_* branch heads MOVE - pin the exact commit, otherwise a fresh
  # 'pinned' fetch can silently pick up a newer payload than the tested one.
  EDK2_COMMIT="${EDK2_COMMIT:-1d840d4e6ed0e9a13fee47936c330f4f0cbf6510}"
  LIBREBOOT_VERSION="${LIBREBOOT_VERSION:-26.01rev1}"
  LBMK_REF="${LBMK_REF:-26.01rev1}"
}

resolve_latest(){
  # coreboot: newest release tag YY.MM[.p]  (NOT master snapshots)
  if [ -z "${COREBOOT_REF:-}" ]; then
    log "resolving newest coreboot release tag ..."
    COREBOOT_REF="$(git ls-remote --tags --refs "$CB_GH" 2>/dev/null \
      | sed -n 's#.*refs/tags/\([0-9][0-9]\.[0-9][0-9]\(\.[0-9]\+\)\?\)$#\1#p' \
      | sortver | tail -1)" || true
    [ -n "$COREBOOT_REF" ] || die "could not resolve a coreboot release tag (network?)"
  fi
  # edk2: newest uefipayload_* branch. Two naming schemes coexist -
  # old uefipayload_YYYYMM (e.g. 202309) and new uefipayload_YYMM (e.g. 2605) -
  # so normalise a 4-digit YYMM to 20YYMM before the numeric date sort, else the
  # 6-digit 2023xx would wrongly rank above the 4-digit 26xx.
  if [ -z "${EDK2_BRANCH:-}" ]; then
    log "resolving newest MrChromebox uefipayload_* branch ..."
    EDK2_BRANCH="$(git ls-remote --heads "$EDK2_URL" 2>/dev/null \
      | sed -n 's#.*refs/heads/\(uefipayload_[0-9]\+\)$#\1#p' \
      | while read -r b; do n="${b#uefipayload_}"; [ "${#n}" -eq 4 ] && n="20$n"; echo "$n $b"; done \
      | sort -k1,1n | tail -1 | awk '{print $2}')" || true
    [ -n "$EDK2_BRANCH" ] || die "could not resolve a uefipayload_* branch (network?)"
  fi
  # lbmk: newest release tag (new scheme YY.MM[revN])
  if [ -z "${LBMK_REF:-}" ]; then
    log "resolving newest lbmk release tag ..."
    LBMK_REF="$(git ls-remote --tags --refs "$LBMK_URL" 2>/dev/null \
      | sed -n 's#.*refs/tags/\([0-9][0-9]\.[0-9][0-9]\(rev[0-9]\+\)\?\)$#\1#p' \
      | sortver | tail -1)" || true
    [ -n "$LBMK_REF" ] || die "could not resolve an lbmk release tag (network?)"
  fi
  # libreboot: newest stable release that ships the t480_vfsp_16mb tarball.
  # Mirror dir listings look like href="./26.01rev1/" (note the ./ prefix); we
  # strip an optional ./ and trailing /, keep only YY.MM[suffix] release dirs,
  # sort newest-first and pick the first that actually has the t480 tarball.
  if [ -z "${LIBREBOOT_VERSION:-}" ]; then
    log "resolving newest libreboot stable with t480_vfsp_16mb ..."
    local base idx vers v
    for base in "${LR_MIRRORS[@]}"; do
      idx="$(curl -fsL "$base/stable/" 2>/dev/null || true)"
      vers="$(printf '%s' "$idx" | grep -oE 'href="[^"]+/"' \
        | sed -E 's#href="\.?/?([^"]+)/"#\1#' \
        | grep -E '^[0-9][0-9]\.[0-9][0-9][a-z0-9]*$' | sort -Vr | uniq)"
      for v in $vers; do
        if curl -fsI "$base/stable/$v/roms/libreboot-${v}_t480_vfsp_16mb.tar.xz" >/dev/null 2>&1; then
          LIBREBOOT_VERSION="$v"; break 2
        fi
      done
    done
    [ -n "${LIBREBOOT_VERSION:-}" ] || die "could not find a libreboot stable with t480_vfsp_16mb"
  fi
}

if [ "$MODE" = "latest" ] && [ -f "$LOCK" ] && [ "$REFRESH" != "1" ]; then
  log "existing versions.lock is frozen (--refresh to re-resolve):"
  # shellcheck disable=SC1090
  . "$LOCK"
elif [ "$MODE" = "pinned" ]; then
  resolve_pinned
else
  resolve_latest
fi

# Derive tarball name + resolve exact commits (so versions.lock is complete).
# Every resolution is guarded: a value already set (pinned constant, frozen
# lock, env override) is NEVER re-resolved from the network - previously the
# frozen path loaded the lock and then overwrote EDK2_COMMIT with the current
# branch head, so the lock could name a commit the tree does not contain.
LIBREBOOT_TARBALL="libreboot-${LIBREBOOT_VERSION}_t480_vfsp_16mb.tar.xz"
lsref(){ git ls-remote "$1" "$2" 2>/dev/null | awk 'NR==1{print $1}'; }
[ -n "${EDK2_COMMIT:-}" ] || EDK2_COMMIT="$(lsref "$EDK2_URL" "refs/heads/$EDK2_BRANCH")"
if [ -z "${LBMK_COMMIT:-}" ]; then
  LBMK_COMMIT="$(git ls-remote "$LBMK_URL" "refs/tags/$LBMK_REF^{}" 2>/dev/null | awk 'NR==1{print $1}')"
  [ -n "$LBMK_COMMIT" ] || LBMK_COMMIT="$(lsref "$LBMK_URL" "refs/tags/$LBMK_REF")"
fi
# coreboot: pinned is already a commit; a tag needs dereferencing
if [ -z "${COREBOOT_COMMIT:-}" ]; then
  if printf '%s' "$COREBOOT_REF" | grep -qE '^[0-9a-f]{40}$'; then
    COREBOOT_COMMIT="$COREBOOT_REF"
  else
    COREBOOT_COMMIT="$(git ls-remote "$CB_URL" "refs/tags/$COREBOOT_REF^{}" 2>/dev/null | awk 'NR==1{print $1}')"
    [ -n "$COREBOOT_COMMIT" ] || COREBOOT_COMMIT="$(lsref "$CB_URL" "refs/tags/$COREBOOT_REF")"
  fi
fi

cat > "$LOCK" <<EOF
# versions.lock  -  BUILD_MODE=$MODE  (generated by fetch-sources.sh)
BUILD_MODE=$MODE
COREBOOT_REF=$COREBOOT_REF
COREBOOT_COMMIT=$COREBOOT_COMMIT
EDK2_BRANCH=$EDK2_BRANCH
EDK2_COMMIT=$EDK2_COMMIT
LIBREBOOT_VERSION=$LIBREBOOT_VERSION
LIBREBOOT_TARBALL=$LIBREBOOT_TARBALL
LBMK_REF=$LBMK_REF
LBMK_COMMIT=$LBMK_COMMIT
EOF
log "resolved versions:"; sed 's/^/    /' "$LOCK"

# =====================================================================
# 2) coreboot  (source + selected submodules + crossgcc toolchain tarballs)
# =====================================================================
CB="$SRC/coreboot"
# Two stamps on purpose: the clone is ~1.5 GB and the tarball download hangs
# off third-party mirrors that fail on their own schedule. With a single stamp
# a failed download meant the next run re-cloned everything just to die in the
# same place.
crossgcc_fetch() {
  ( cd "$CB/util/crossgcc" \
      && ./buildgcc -f "$@" \
      && ./buildgcc -f -P IASL "$@" \
      && ./buildgcc -f -P NASM "$@" )
}

if [ -f "$CB/.stamp-fetch" ] && [ "$REFRESH" != "1" ]; then
  log "coreboot already fetched - skipping"
else
  if [ -f "$CB/.stamp-clone" ] && [ "$REFRESH" != "1" ]; then
    log "coreboot source already cloned - skipping to the tarballs"
  else
    log "fetching coreboot $COREBOOT_REF (+ submodules) ..."
    rm -rf "$CB"; mkdir -p "$CB"
    git -C "$CB" init -q
    git -C "$CB" remote add origin "$CB_URL"
    # shallow fetch of the exact commit/tag (review.coreboot.org serves SHAs)
    git -C "$CB" fetch -q --depth 1 origin "$COREBOOT_REF" \
      || git -C "$CB" fetch -q --depth 1 "$CB_GH" "$COREBOOT_REF" \
      || die "coreboot fetch of $COREBOOT_REF failed"
    git -C "$CB" checkout -q FETCH_HEAD
    for m in "${CB_SUBMODULES[@]}"; do
      log "  submodule $m ..."
      git -C "$CB" submodule update --init --checkout -- "$m" \
        || die "coreboot submodule $m failed"
    done
    touch "$CB/.stamp-clone"
  fi

  # buildgcc pulls gmp/mpfr/mpc/binutils/gcc from ftpmirror.gnu.org, which is
  # down often enough to matter. Its own -m switch serves the same tarballs
  # from coreboot.org; the hashes are verified either way, so the fallback
  # costs nothing but is not the default (upstream first).
  log "pre-loading coreboot crossgcc tarballs (buildgcc -f) ..."
  crossgcc_fetch || {
    log "  direct download failed - retrying via the coreboot mirror (-m) ..."
    crossgcc_fetch -m
  } || die "crossgcc tarball download failed (upstream and coreboot mirror)"
  ls "$CB/util/crossgcc/tarballs/"*.tar.* >/dev/null 2>&1 \
    || die "no crossgcc tarballs in util/crossgcc/tarballs/"
  touch "$CB/.stamp-fetch"
fi

# =====================================================================
# 3) EDK2 (MrChromebox)  -  full clone + submodules, detached on the branch.
#     Pre-placed in PHASE 2 at payloads/external/edk2/workspace/mrchromebox so
#     coreboot's edk2 Makefile skips the online clone. Keeping the github URL in
#     CONFIG_EDK2_REPOSITORY keeps the workspace dir name = "mrchromebox".
# =====================================================================
ED="$SRC/edk2/mrchromebox"
if [ -f "$SRC/edk2/.stamp-fetch" ] && [ "$REFRESH" != "1" ]; then
  log "edk2 already fetched - skipping"
else
  log "cloning edk2 branch $EDK2_BRANCH (+ submodules) ..."
  rm -rf "$SRC/edk2"; mkdir -p "$SRC/edk2"
  git clone -q --branch "$EDK2_BRANCH" --single-branch --recurse-submodules -j"$NPROC" \
    "$EDK2_URL" "$ED" || die "edk2 clone ($EDK2_BRANCH) failed"
  # Detach on the RESOLVED commit, not the branch head - for pinned that is a
  # constant, so the tree is reproducible even after the branch moved on.
  if [ -n "${EDK2_COMMIT:-}" ]; then
    git -C "$ED" checkout -q --detach "$EDK2_COMMIT" \
      || die "edk2: pinned commit $EDK2_COMMIT not on branch $EDK2_BRANCH (history rewritten?)"
  else
    git -C "$ED" checkout -q --detach "origin/$EDK2_BRANCH"
  fi
  git -C "$ED" submodule update --init --checkout --recursive \
    || die "edk2 submodules failed"
  touch "$SRC/edk2/.stamp-fetch"
fi

# versions.lock must state what the tree ACTUALLY contains - read the commit
# back from the checkout instead of trusting an ls-remote answer (the skip
# path above can keep an older tree than a freshly resolved branch head).
EDK2_HEAD="$(git -C "$ED" rev-parse HEAD 2>/dev/null)" \
  || die "edk2: cannot read HEAD of $ED"
if [ "$EDK2_HEAD" != "$EDK2_COMMIT" ]; then
  log "edk2: lock said '$EDK2_COMMIT', tree has '$EDK2_HEAD' - recording the tree's commit"
  EDK2_COMMIT="$EDK2_HEAD"
  sed -i "s/^EDK2_COMMIT=.*/EDK2_COMMIT=$EDK2_COMMIT/" "$LOCK"
  grep -q "^EDK2_COMMIT=$EDK2_COMMIT\$" "$LOCK" || die "failed to update EDK2_COMMIT in $LOCK"
fi

# =====================================================================
# 4) libreboot release tarball  (mirror download + verify, unless provided)
# =====================================================================
LRDIR="$SRC/libreboot"
mkdir -p "$LRDIR"
TB="$LRDIR/$LIBREBOOT_TARBALL"
if [ "${LIBREBOOT_TARBALL_PROVIDED:-0}" = "1" ] && [ -f "$TB" ]; then
  log "libreboot tarball provided externally: $LIBREBOOT_TARBALL"
elif [ -f "$TB" ] && [ "$REFRESH" != "1" ]; then
  log "libreboot tarball already present - skipping download"
else
  log "downloading libreboot tarball $LIBREBOOT_TARBALL ..."
  ok=0
  for base in "${LR_MIRRORS[@]}"; do
    url="$base/stable/$LIBREBOOT_VERSION/roms/$LIBREBOOT_TARBALL"
    if curl -fLo "$TB" "$url" \
       && curl -fLo "$TB.sha512" "$url.sha512" \
       && curl -fLo "$TB.sig"    "$url.sig"; then ok=1; break; fi
    log "  mirror $base failed, trying next ..."
  done
  [ "$ok" = "1" ] || die "no libreboot mirror served $LIBREBOOT_TARBALL (use LIBREBOOT_TARBALL=...)"
fi
# Integrity (sha512) is mandatory; authenticity (gpg) is best-effort.
if [ -f "$TB.sha512" ]; then
  ( cd "$LRDIR" && sha512sum -c "$(basename "$TB").sha512" ) \
    || die "libreboot tarball SHA512 mismatch - corrupt!"
  log "libreboot SHA512 ok"
fi
if [ -f "$TB.sig" ]; then
  gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$LEAH_KEY" 2>/dev/null || true
  if gpg --verify "$TB.sig" "$TB" 2>/dev/null; then log "libreboot GPG signature ok (Leah Rowe)"
  else log "libreboot GPG not verified (key missing) - SHA512 already confirmed integrity"; fi
fi

# =====================================================================
# 5) lbmk  -  clone pinned, then POPULATE its cache by running a throwaway
#     inject once (online). Afterwards the whole lbmk tree (cache/ src/ elf/
#     vendorfiles/) is self-contained and re-injects OFFLINE in PHASE 2.
#     What this pulls: lbmk's coreboot tree (ifdtool/nvmutil), me_cleaner,
#     deguard, and the Intel-ME blob (Dell Inspiron .exe -> me_cleaner+deguard).
# =====================================================================
LB="$SRC/lbmk"
if [ -f "$LB/.stamp-populated" ] && [ "$REFRESH" != "1" ]; then
  log "lbmk already populated - skipping"
else
  log "cloning lbmk $LBMK_REF ..."
  rm -rf "$LB"
  git clone -q "$LBMK_URL" "$LB" || git clone -q "$LBMK_BKUP" "$LB" \
    || die "lbmk clone failed"
  git -C "$LB" checkout -q "$LBMK_REF" || die "lbmk checkout $LBMK_REF failed"
  log "populating lbmk: ./mk inject (once, online) - pulls the coreboot tree, me_cleaner, deguard, Intel ME blob ..."
  cp "$TB" "/tmp/$LIBREBOOT_TARBALL"
  ( cd "$LB" && XBMK_THREADS="$NPROC" ./mk inject "/tmp/$LIBREBOOT_TARBALL" setmac "$POPULATE_MAC" ) \
    || die "lbmk populate inject failed (see log above)"
  rm -f "/tmp/$LIBREBOOT_TARBALL"
  # sanity: the tools + ME blob the offline inject relies on must now exist
  [ -x "$LB/elf/coreboot/default/ifdtool" ] || die "lbmk: ifdtool not built"
  [ -n "$(ls -A "$LB/cache" 2>/dev/null)" ] || die "lbmk: cache/ empty - populate cached nothing"
  touch "$LB/.stamp-populated"
fi

# =====================================================================
# 6) checksums  (sha256 of every downloaded tarball; verified in PHASE 2)
# =====================================================================
log "generating sha256sums.txt ..."
( cd "$SRC"
  : > sha256sums.txt
  sha256sum "libreboot/$LIBREBOOT_TARBALL" >> sha256sums.txt
  for f in coreboot/util/crossgcc/tarballs/*.tar.*; do
    [ -f "$f" ] && sha256sum "$f" >> sha256sums.txt
  done
)

log "PHASE 1 done. Contents of $SRC:"
du -sh "$SRC"/* 2>/dev/null | sed 's/^/    /' || true
printf '\n\033[1;32m[fetch:%s] sources/%s ready for the offline build.\033[0m\n' "$MODE" "$MODE"
