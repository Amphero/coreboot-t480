#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-only
# gen-vboot-keys.sh - generate the vboot signing keyset into keys/.
#
#   sh scripts/gen-vboot-keys.sh
#
# Produces root_key, firmware_data_key, recovery_key (.vbpubk/.vbprivk) and
# firmware.keyblock. keys/ is untracked (.gitignore); the private halves never
# leave this machine, and without them you cannot build firmware your own RO
# accepts. Refuses to overwrite an existing keyset.
#
# Runs inside the build image because it needs futility. Upstream's
# create_new_keys.sh is not usable here - it insists on ChromeOS AP-RO keys -
# so this calls the same helpers from common.sh directly, plus two shims:
# dumpRSAPublicKey has to be compiled (the vboot Makefile wants libflashrom),
# and vbutil_key/vbutil_keyblock only exist as futility subcommands.
set -eu

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS="$PROJECT/keys"
IMAGE="${IMAGE:-coreboot-t480-deps}"

die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Any fetched tree will do - only the vboot sources are used here.
CB=""
for m in ${MODE:-pinned latest}; do
	if [ -d "$PROJECT/sources/$m/coreboot/3rdparty/vboot" ]; then
		CB="$PROJECT/sources/$m/coreboot"; break
	fi
done

command -v podman >/dev/null || die "podman is missing"
[ -n "$CB" ] || die "no fetched sources with a vboot tree - run ./fetch.sh first"
podman image exists "$IMAGE" || die "image '$IMAGE' does not exist - run ./fetch.sh first"
[ -e "$KEYS/root_key.vbpubk" ] && die "keys/ already holds a keyset - move it away first"

mkdir -p "$KEYS"
podman run --rm --userns=keep-id -v "$CB":/cb:z -v "$KEYS":/keys:z "$IMAGE" sh -c '
	set -e
	cd /cb/3rdparty/vboot
	INC=$(dirname $(find . -name openssl_compat.h | head -1))
	cc -O2 -o /tmp/dumpRSAPublicKey utility/dumpRSAPublicKey.c -I"$INC" -lcrypto 2>/dev/null
	# USE_FLASHROM=0: the libflashrom headers are not in the build image and
	# futility does not need them for key handling. BUILD=/tmp keeps the
	# artifacts out of the mounted tree - that tree is the offline build
	# context, and touching it invalidates the crossgcc layer cache.
	make USE_FLASHROM=0 BUILD=/tmp/vbuild -j"$(nproc)" futil >/dev/null 2>&1 || true
	FUT=/tmp/vbuild/futility/futility
	[ -x "$FUT" ] || { echo "could not build futility"; exit 1; }
	for c in vbutil_key vbutil_keyblock; do
		printf "#!/bin/sh\nexec %s %s \"\$@\"\n" "$FUT" "$c" > /tmp/$c
		chmod +x /tmp/$c
	done
	PATH=/tmp:$PATH
	export PATH
	cd /keys
	. /cb/3rdparty/vboot/scripts/keygeneration/common.sh
	make_pair root_key          $ROOT_KEY_ALGOID
	make_pair firmware_data_key $FIRMWARE_DATAKEY_ALGOID
	make_pair recovery_key      $RECOVERY_KEY_ALGOID
	make_keyblock firmware $FIRMWARE_KEYBLOCK_MODE firmware_data_key root_key
' || die "key generation failed"

for f in root_key.vbpubk root_key.vbprivk firmware_data_key.vbpubk \
         firmware_data_key.vbprivk recovery_key.vbpubk recovery_key.vbprivk \
         firmware.keyblock; do
	[ -f "$KEYS/$f" ] || die "$f was not created"
done
chmod 600 "$KEYS"/*.vbprivk

echo
echo "keyset in $KEYS:"
podman run --rm --userns=keep-id -v "$CB":/cb:z -v "$KEYS":/keys:z "$IMAGE" sh -c '
	cd /cb/3rdparty/vboot
	make USE_FLASHROM=0 BUILD=/tmp/vbuild -j"$(nproc)" futil >/dev/null 2>&1 || true
	F=/tmp/vbuild/futility/futility
	cd /keys
	for k in root_key firmware_data_key recovery_key; do
		printf "  %-20s " "$k"
		$F vbutil_key --unpack $k.vbpubk | sed -n "s/^Algorithm: *//p" | tr -d "\n"
		echo
	done
	printf "  %-20s " "firmware.keyblock"
	$F vbutil_keyblock --unpack firmware.keyblock --signpubkey root_key.vbpubk >/dev/null 2>&1 \
		&& echo "signature valid against root_key" || echo "SIGNATURE INVALID"
'
echo
echo "Keep a backup of the private keys somewhere else - they are not in git."
