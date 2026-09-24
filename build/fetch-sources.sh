#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# fetch-sources.sh  -  PHASE 1 (FETCH). Runs INSIDE the coreboot-t480-deps
# container WITH network and fills /sources/, so PHASE 2 builds with
# --network=none.
#
# Versions come from /config/versions.lock (read-only) and are used verbatim.
# --latest resolves the newest upstream instead and writes them to
# /sources/versions.lock; ./fetch.sh copies that back into config/ on success.
#
# Driven by env (set by ./fetch.sh):
#   LATEST       1 = resolve newest upstream instead of reading the lock
#   CHECK        1 = compare the lock with upstream, print, download nothing
#   REFRESH      1 = re-fetch every component, ignoring its .stamp
#   GIT_JOBS     parallel submodule clones (default 4)
#   NET_TRIES    attempts per network step before giving up (default 3)
#   Overrides (LATEST=1 only; with the lock they would contradict it):
#     COREBOOT_REF  EDK2_BRANCH  LIBREBOOT_VERSION  LBMK_REF
#   LIBREBOOT_TARBALL_PROVIDED  1 = tarball already placed in /sources/libreboot/
#
# Idempotent: a component with its .stamp is skipped. A changed ref drops that
# component's stamp, so one new version does not re-download the other three.
set -euo pipefail

LATEST="${LATEST:-0}"
CHECK="${CHECK:-0}"
REFRESH="${REFRESH:-0}"
SRC="/sources"
# CHECK=1 also runs on the host, where the lock is not at /config.
LOCK_IN="${LOCK_IN:-/config/versions.lock}"      # input, read-only
NPROC="$(nproc)"
# Parallel clones, not NPROC: how hard we hit a forge, not how many cores build.
# github throttles bursts; that shows up as "could not read Username".
GIT_JOBS="${GIT_JOBS:-4}"
NET_TRIES="${NET_TRIES:-3}"
# For the lbmk populate run only; that inject is discarded. The real MAC comes
# from config/board.conf (or --mac) in PHASE 2.
POPULATE_MAC="02:00:00:00:00:01"

# git identity (lbmk + submodule ops need one; container user has no ~/.gitconfig).
# Not for CHECK: it only reads refs, and on the host --global is the user's own.
if [ "$CHECK" != "1" ]; then
  export HOME="${HOME:-/tmp/fetchhome}"; mkdir -p "$HOME"
  git config --global user.name  "builder"           2>/dev/null || true
  git config --global user.email "builder@localhost" 2>/dev/null || true
  git config --global --add safe.directory '*'        2>/dev/null || true
  git config --global advice.detachedHead false       2>/dev/null || true
fi

log(){ printf '\n\033[1;36m[fetch] %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31m[fetch] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

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

# Only the submodules the T480 EDK2 build consumes (coreboot's Makefile.mk:
# the blanket init plus the update=none ones). PHASE 2's blanket init tries the
# rest, fails instantly offline and moves on - coreboot swallows that.
CB_SUBMODULES=(3rdparty/vboot 3rdparty/libgfxinit 3rdparty/libhwbase \
               3rdparty/cmocka 3rdparty/blobs 3rdparty/intel-microcode 3rdparty/fsp)

# =====================================================================
# 1) Version set: read the lock, or resolve the newest upstream (--latest)
# =====================================================================
LOCK="$SRC/versions.lock"            # effective set, consumed by PHASE 2
[ "$CHECK" = "1" ] || mkdir -p "$SRC"   # CHECK writes nothing

# What the last run fetched - read before the new lock overwrites it.
lock_field(){ [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | head -1 || true; }
PREV_COREBOOT="$(lock_field "$LOCK" COREBOOT_COMMIT)"
PREV_EDK2="$(lock_field "$LOCK" EDK2_COMMIT)"
PREV_LBMK="$(lock_field "$LOCK" LBMK_COMMIT)"

sortver(){ sort -V; }
lsref(){ git ls-remote "$1" "$2" 2>/dev/null | awk 'NR==1{print $1}'; }
# $1 remote  $2 tag -> commit. Annotated tags need the ^{} peel, lightweight
# ones answer under the plain ref.
tagcommit(){
  local c
  c="$(lsref "$1" "refs/tags/$2^{}")"
  [ -n "$c" ] || c="$(lsref "$1" "refs/tags/$2")"
  printf '%s' "$c"
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
  # edk2: newest uefipayload_* branch. Two schemes coexist, YYYYMM (202309) and
  # YYMM (2605), so pad 4 digits to 20YYMM or 2023xx outranks 26xx.
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
  # libreboot: newest stable that ships the t480_vfsp_16mb tarball. Listings
  # look like href="./26.01rev1/", so strip ./ and the trailing slash.
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

# =====================================================================
# 1b) CHECK: compare the lock with upstream, write nothing
# =====================================================================
# Exit 0 = current, 10 = something moved, 1 = failed.
if [ "$CHECK" = "1" ]; then
  [ -f "$LOCK_IN" ] || die "config/versions.lock is missing - nothing to compare against."
  # An override would decide the answer instead of upstream.
  for v in COREBOOT_REF EDK2_BRANCH LIBREBOOT_VERSION LBMK_REF; do
    [ -z "$(eval "printf '%s' \"\${$v:-}\"")" ] \
      || die "$v is set in the environment - the check compares the lock against
   upstream and takes no overrides."
  done

  # Lock into HAVE_*: resolve_latest only fills what is empty, so the two sets
  # must not share variables.
  HAVE_COREBOOT_REF="$(lock_field "$LOCK_IN" COREBOOT_REF)"
  HAVE_COREBOOT_COMMIT="$(lock_field "$LOCK_IN" COREBOOT_COMMIT)"
  HAVE_EDK2_BRANCH="$(lock_field "$LOCK_IN" EDK2_BRANCH)"
  HAVE_EDK2_COMMIT="$(lock_field "$LOCK_IN" EDK2_COMMIT)"
  HAVE_LIBREBOOT_VERSION="$(lock_field "$LOCK_IN" LIBREBOOT_VERSION)"
  HAVE_LBMK_REF="$(lock_field "$LOCK_IN" LBMK_REF)"
  HAVE_LBMK_COMMIT="$(lock_field "$LOCK_IN" LBMK_COMMIT)"

  resolve_latest

  # Tags get re-cut, branches move: compare the commits too.
  NOW_COREBOOT_COMMIT="$(tagcommit "$CB_URL" "$COREBOOT_REF")"
  NOW_LBMK_COMMIT="$(tagcommit "$LBMK_URL" "$LBMK_REF")"
  NOW_EDK2_COMMIT="$(lsref "$EDK2_URL" "refs/heads/$EDK2_BRANCH")"

  CHANGED=0
  short(){ printf '%.12s' "$1"; }
  report(){                  # $1 name  $2 locked ref  $3 newest ref  [$4 locked commit  $5 upstream commit]
    local what="$1" have="$2" now="$3" havec="${4:-}" nowc="${5:-}" state
    if [ "$have" != "$now" ]; then
      state="-> $now"
      CHANGED=1
    elif [ -n "$havec" ] && [ -z "$nowc" ]; then
      state="current ref, upstream commit unreadable"
    elif [ -n "$havec" ] && [ "$havec" != "$nowc" ]; then
      state="same ref, moved $(short "$havec") -> $(short "$nowc")"
      CHANGED=1
    else
      state="current"
    fi
    printf '    %-10s %-22s %s\n' "$what" "$have" "$state"
  }

  printf '\n\033[1;36m[fetch] config/versions.lock vs upstream\033[0m\n\n'
  report coreboot  "$HAVE_COREBOOT_REF"      "$COREBOOT_REF"      "$HAVE_COREBOOT_COMMIT" "$NOW_COREBOOT_COMMIT"
  report edk2      "$HAVE_EDK2_BRANCH"       "$EDK2_BRANCH"       "$HAVE_EDK2_COMMIT"     "$NOW_EDK2_COMMIT"
  report libreboot "$HAVE_LIBREBOOT_VERSION" "$LIBREBOOT_VERSION"
  report lbmk      "$HAVE_LBMK_REF"          "$LBMK_REF"          "$HAVE_LBMK_COMMIT"     "$NOW_LBMK_COMMIT"
  echo

  if [ "$CHANGED" = "1" ]; then
    echo "    Newer upstream exists. ./fetch.sh --latest moves every ref at once;"
    echo "    for a single component edit config/versions.lock by hand. Either way"
    echo "    the patch series can need a rebase - build before you trust it."
    exit 10
  fi
  echo "    Everything current."
  exit 0
fi

if [ "$LATEST" = "1" ]; then
  log "resolving newest upstream versions - config/versions.lock will be rewritten"
  resolve_latest
else
  [ -f "$LOCK_IN" ] || die "config/versions.lock is missing - it is the input for the fetch.
   ./fetch.sh --latest resolves the newest upstream versions and creates it."
  # An override would contradict the file that is the source of truth.
  for v in COREBOOT_REF EDK2_BRANCH LIBREBOOT_VERSION LBMK_REF; do
    [ -z "$(eval "printf '%s' \"\${$v:-}\"")" ] \
      || die "$v is set in the environment, but overrides only apply to --latest.
   Edit config/versions.lock instead."
  done
  # shellcheck disable=SC1090
  . "$LOCK_IN"
  for v in COREBOOT_REF COREBOOT_COMMIT EDK2_BRANCH EDK2_COMMIT \
           LIBREBOOT_VERSION LBMK_REF LBMK_COMMIT; do
    [ -n "$(eval "printf '%s' \"\${$v:-}\"")" ] || die "config/versions.lock: $v is missing"
  done
  log "using config/versions.lock verbatim"
fi

# Tarball name + exact commits, so versions.lock is complete. Never re-resolve
# a value that is already set: an earlier version overwrote EDK2_COMMIT with the
# branch head and the lock then named a commit the tree did not contain.
LIBREBOOT_TARBALL="libreboot-${LIBREBOOT_VERSION}_t480_vfsp_16mb.tar.xz"
[ -n "${EDK2_COMMIT:-}" ] || EDK2_COMMIT="$(lsref "$EDK2_URL" "refs/heads/$EDK2_BRANCH")"
[ -n "${LBMK_COMMIT:-}" ] || LBMK_COMMIT="$(tagcommit "$LBMK_URL" "$LBMK_REF")"
# coreboot: a commit is already exact; a tag needs dereferencing
if [ -z "${COREBOOT_COMMIT:-}" ]; then
  if printf '%s' "$COREBOOT_REF" | grep -qE '^[0-9a-f]{40}$'; then
    COREBOOT_COMMIT="$COREBOOT_REF"
  else
    COREBOOT_COMMIT="$(tagcommit "$CB_URL" "$COREBOOT_REF")"
  fi
fi

cat > "$LOCK" <<EOF
# versions.lock  -  the set this sources/ tree was fetched with.
# Copy of config/versions.lock (or, after --latest, what got resolved); PHASE 2
# hashes it into the image label. Edit config/versions.lock, not this file.
COREBOOT_REF=$COREBOOT_REF
COREBOOT_COMMIT=$COREBOOT_COMMIT
EDK2_BRANCH=$EDK2_BRANCH
EDK2_COMMIT=$EDK2_COMMIT
LIBREBOOT_VERSION=$LIBREBOOT_VERSION
LIBREBOOT_TARBALL=$LIBREBOOT_TARBALL
LBMK_REF=$LBMK_REF
LBMK_COMMIT=$LBMK_COMMIT
EOF
log "versions in use:"; sed 's/^/    /' "$LOCK"

# Re-fetch only what moved; --refresh used to force all 8-12 GB. Dropping the
# stamp is enough, the skip logic below does the rest.
invalidate(){                 # $1 label  $2 previous  $3 now  $4.. stamps
  local label="$1" prev="$2" now="$3"; shift 3
  [ -n "$prev" ] || return 0                  # first fetch, nothing to compare
  [ "$prev" != "$now" ] || return 0
  log "$label changed ($prev -> $now) - will re-fetch it"
  rm -f "$@"
}
invalidate coreboot "$PREV_COREBOOT" "$COREBOOT_COMMIT" \
    "$SRC/coreboot/.stamp-clone" "$SRC/coreboot/.stamp-fetch"
invalidate edk2     "$PREV_EDK2"     "$EDK2_COMMIT"     "$SRC/edk2/.stamp-fetch"
invalidate lbmk     "$PREV_LBMK"     "$LBMK_COMMIT"     "$SRC/lbmk/.stamp-populated"
# libreboot needs no stamp: the version is in the file name, so a new one is
# simply a file that is not there yet.

# =====================================================================
# 2) coreboot  (source + selected submodules + crossgcc toolchain tarballs)
# =====================================================================
CB="$SRC/coreboot"
# Two stamps: the clone is ~1.5 GB, the tarballs hang off mirrors that fail on
# their own schedule. With one stamp a failed download re-cloned everything.
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
  # down often enough. -m serves the same tarballs from coreboot.org; hashes
  # are verified either way, so the fallback costs nothing. Upstream first.
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
# 3) EDK2 (MrChromebox)  -  clone + submodules, detached on the pinned commit.
#     PHASE 2 places it at payloads/external/edk2/workspace/mrchromebox, so
#     coreboot's edk2 Makefile skips its own clone. The github URL stays in
#     CONFIG_EDK2_REPOSITORY to keep that workspace dir name.
# =====================================================================
ED="$SRC/edk2/mrchromebox"
# 1-2 GB, no mirror fallback (coreboot and lbmk have one), and github fails it
# mid-transfer often enough. Retry with half the parallelism instead of starting
# the download over.  $1 label, then the command; it reads $JOBS for its -j.
retry_net(){
  local label="$1" attempt=1 rc=0; shift
  JOBS="$GIT_JOBS"
  while :; do
    rc=0; "$@" || rc=$?
    [ "$rc" = "0" ] && return 0
    [ "$attempt" -lt "$NET_TRIES" ] || return "$rc"
    if [ "$JOBS" -gt 1 ]; then JOBS=$(( JOBS / 2 )); fi
    log "$label failed (attempt $attempt/$NET_TRIES) - again with -j$JOBS in $(( attempt * 20 ))s"
    sleep $(( attempt * 20 ))
    attempt=$(( attempt + 1 ))
  done
}
# github cancels HTTP/2 streams on long packs ("curl 92 ... CANCEL", "early
# EOF"). Slower, but it arrives. -c reaches the submodule fetches.
GIT_NET=(-c http.version=HTTP/1.1)
# No --recurse-submodules: one failing submodule would take the finished
# top-level clone with it.
edk2_clone(){ git "${GIT_NET[@]}" clone -q --branch "$EDK2_BRANCH" --single-branch \
                "$EDK2_URL" "$ED"; }
edk2_update(){ git "${GIT_NET[@]}" -C "$ED" fetch -q --force "$EDK2_URL" \
                 "+refs/heads/$EDK2_BRANCH:refs/remotes/origin/$EDK2_BRANCH"; }
# --jobs, not -j: git 2.39's submodule update rejects the short form.
edk2_submodules(){ git "${GIT_NET[@]}" -C "$ED" submodule update --init --checkout \
                     --recursive --jobs "$JOBS"; }

if [ -f "$SRC/edk2/.stamp-fetch" ] && [ "$REFRESH" != "1" ]; then
  log "edk2 already fetched - skipping"
else
  # Keep a tree from a died run: fetching costs the delta, cloning the
  # gigabytes. Dropped only if it is no git tree or points elsewhere.
  if [ "$REFRESH" != "1" ] && [ -d "$ED/.git" ] \
     && [ "$(git -C "$ED" remote get-url origin 2>/dev/null)" = "$EDK2_URL" ]; then
    log "edk2 tree from an earlier run - fetching $EDK2_BRANCH into it instead of re-cloning"
    retry_net "edk2 fetch" edk2_update || die "edk2 fetch ($EDK2_BRANCH) failed"
  else
    log "cloning edk2 branch $EDK2_BRANCH ..."
    rm -rf "$SRC/edk2"; mkdir -p "$SRC/edk2"
    retry_net "edk2 clone" edk2_clone \
      || die "edk2 clone ($EDK2_BRANCH) failed - if the log says 'could not read
   Username for https://github.com', that is throttling: retry with GIT_JOBS=1."
  fi
  # The resolved commit, not the branch head: the lock names an exact commit,
  # so the tree stays reproducible after the branch moved on.
  if [ -n "${EDK2_COMMIT:-}" ]; then
    git -C "$ED" checkout -q --detach "$EDK2_COMMIT" \
      || die "edk2: pinned commit $EDK2_COMMIT not on branch $EDK2_BRANCH (history rewritten?)"
  else
    git -C "$ED" checkout -q --detach "origin/$EDK2_BRANCH"
  fi
  retry_net "edk2 submodules" edk2_submodules || die "edk2 submodules failed"
  touch "$SRC/edk2/.stamp-fetch"
fi

# State what the tree contains, not what ls-remote said: the skip path above
# can keep an older tree than a freshly resolved branch head.
EDK2_HEAD="$(git -C "$ED" rev-parse HEAD 2>/dev/null)" \
  || die "edk2: cannot read HEAD of $ED"
if [ "$EDK2_HEAD" != "$EDK2_COMMIT" ]; then
  log "WARNING: edk2 checkout is $EDK2_HEAD, config/versions.lock says $EDK2_COMMIT."
  log "         Recording what the tree contains. If this was not intended, remove"
  log "         sources/edk2/ and fetch again - the build follows the tree, not the lock."
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
# Integrity: prefer the SHA512 pinned in build/libreboot-sha512sums. A
# mirror-served .sha512 shares the tarball's origin and catches transfer
# corruption only, not a compromised mirror.
if grep -q " $LIBREBOOT_TARBALL\$" /work/libreboot-sha512sums 2>/dev/null; then
  ( cd "$LRDIR" && grep " $LIBREBOOT_TARBALL\$" /work/libreboot-sha512sums | sha512sum -c - ) \
    || die "libreboot tarball does not match the SHA512 pinned in build/libreboot-sha512sums!"
  log "libreboot SHA512 ok (pinned in repo)"
elif [ -f "$TB.sha512" ]; then
  ( cd "$LRDIR" && sha512sum -c "$(basename "$TB").sha512" ) \
    || die "libreboot tarball SHA512 mismatch - corrupt!"
  log "libreboot SHA512 ok (mirror-served - same origin as the tarball, integrity only)"
else
  log "WARNING: no SHA512 available for $LIBREBOOT_TARBALL - integrity unverified"
fi
# Authenticity: with build/leah-rowe.asc a present signature MUST verify;
# without the key file, best-effort.
if [ -f "$TB.sig" ]; then
  if [ -f /work/leah-rowe.asc ]; then
    gpg --import /work/leah-rowe.asc 2>/dev/null || true
    gpg --verify "$TB.sig" "$TB" 2>/dev/null \
      || die "libreboot GPG signature INVALID (key: build/leah-rowe.asc)"
    log "libreboot GPG signature ok (bundled key, Leah Rowe)"
  else
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$LEAH_KEY" 2>/dev/null || true
    if gpg --verify "$TB.sig" "$TB" 2>/dev/null; then log "libreboot GPG signature ok (Leah Rowe)"
    else log "libreboot GPG not verified (key missing) - SHA512 checked above"; fi
  fi
fi

# =====================================================================
# 5) lbmk  -  clone pinned, then populate its cache with one throwaway inject
#     (online). After that cache/ src/ elf/ vendorfiles/ are self-contained and
#     PHASE 2 re-injects offline. Pulls lbmk's coreboot tree (ifdtool/nvmutil),
#     me_cleaner, deguard and the Intel-ME blob (Dell Inspiron .exe).
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
printf '\n\033[1;32m[fetch] sources/ ready for the offline build.\033[0m\n'
