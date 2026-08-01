#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-only
# apply-devicetree.sh - toggles the optional devicetree devices of the T480 port
# according to the "DT_DEVICE_<NAME>=y/n" lines in config/board.conf.
#
# Runs in the offline build (Dockerfile.offline) BEFORE `make` and edits
#   src/mainboard/lenovo/sklkbl_thinkpad/devicetree.cb
# inside "device domain 0 on ... end", right after "device ref hda on end".
# That keeps the selection driven by the config file AND clean-build-safe/
# reproducible (no manual edit in the coreboot checkout that a clean build
# would throw away).
#
# Declarative + idempotent: the devicetree is brought to exactly the config
# state (managed devices are removed first, then the ones set to =y are
# re-inserted) - running it multiple times changes nothing.
#
#   sh apply-devicetree.sh <coreboot-tree>     # reads <tree>/board.conf
set -eu

CB="${1:?Usage: apply-devicetree.sh <coreboot-tree>}"
CFG="$CB/board.conf"
DT="$CB/src/mainboard/lenovo/sklkbl_thinkpad/devicetree.cb"
[ -f "$CFG" ] || { echo "apply-devicetree: '$CFG' is missing" >&2; exit 1; }
[ -f "$DT" ]  || { echo "apply-devicetree: '$DT' is missing" >&2; exit 1; }

TAB=$(printf '\t')
NL=$(printf '\nx'); NL=${NL%x}          # a real newline

# Devices managed by this script (marker NAME -> devicetree alias = lowercase).
# Only these aliases are allowed (they exist in the Skylake chipset: smbus 1f.4,
# heci1 16.0, fast_spi 1f.5) - everything else is ignored.
MANAGED="smbus heci1 fast_spi"

# 1) Remove all managed device lines (declarative, idempotent). Only the
#    single-line "device ref X on|off end" form is managed; if the device
#    appears in any other shape (e.g. with a config body), abort instead of
#    silently inserting a duplicate next to it.
for ref in $MANAGED; do
	sed -i -e "/^[[:space:]]*device ref ${ref} on end[[:space:]]*\$/d" \
	       -e "/^[[:space:]]*device ref ${ref} off end[[:space:]]*\$/d" "$DT"
	if grep -q "device ref ${ref} " "$DT"; then
		echo "apply-devicetree: 'device ref ${ref}' exists in a form this script does not manage - fix devicetree.cb or this script" >&2
		exit 1
	fi
done

# 2) Collect enabled (=y) devices in config order (lines like DT_DEVICE_SMBUS=y,
#    optionally with a trailing comment; commented-out lines never match):
enabled=""
specs=$(sed -nE 's/^[[:space:]]*(DT_DEVICE_[A-Z0-9_]+=[yn]).*/\1/p' "$CFG" || true)
for kv in $specs; do
	name=${kv%%=*}; name=${name#DT_DEVICE_}; val=${kv#*=}
	ref=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
	case " $MANAGED " in
		*" $ref "*) : ;;
		*) echo "apply-devicetree: unknown device '$name' - ignored" >&2; continue ;;
	esac
	[ "$val" = "y" ] && enabled="$enabled $ref"
done

# 3) Insert enabled devices after "device ref hda on end" (indented with 2 tabs):
TEXT=""
for ref in $enabled; do
	line="${TAB}${TAB}device ref ${ref} on end"
	if [ -z "$TEXT" ]; then TEXT="$line"; else TEXT="${TEXT}${NL}${line}"; fi
done
if [ -n "$TEXT" ]; then
	grep -qE '^[[:space:]]*device ref hda on end[[:space:]]*$' "$DT" || {
		echo "apply-devicetree: insertion point 'device ref hda on end' not found" >&2; exit 1; }
	awk -v ins="$TEXT" '
		{ print }
		/^[[:space:]]*device ref hda on end[[:space:]]*$/ && !d { print ins; d=1 }
	' "$DT" > "$DT.tmp" && mv "$DT.tmp" "$DT"
fi

echo "apply-devicetree: enabled ->${enabled:- (none)}"
echo "apply-devicetree: domain-0 leaf devices in devicetree.cb:"
grep -nE 'device ref (hda|smbus|heci1|fast_spi) on end' "$DT" | sed 's/^/    /'
