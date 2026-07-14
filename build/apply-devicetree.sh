#!/usr/bin/env sh
# apply-devicetree.sh — schaltet die optionalen Devicetree-Geräte des T480-Ports
# gemäß den "# DT_DEVICE NAME=y/n"-Markern in der Konfig-Datei (defconfig).
#
# Wird im Offline-Build (Dockerfile.offline) VOR `make` ausgeführt und editiert
#   src/mainboard/lenovo/sklkbl_thinkpad/devicetree.cb
# innerhalb von "device domain 0 on ... end", direkt nach "device ref hda on end".
# So ist die Auswahl über die Konfig-Datei steuerbar UND clean-build-fest/
# reproduzierbar (kein manueller Edit im coreboot-Checkout, den ein Clean-Build
# verwerfen würde).
#
# Deklarativ + idempotent: der Devicetree wird exakt auf den Konfig-Stand
# gebracht (verwaltete Geräte werden erst entfernt, dann die auf =y gesetzten
# wieder eingefügt) — mehrfaches Ausführen ändert nichts.
#
#   sh apply-devicetree.sh <coreboot-tree>     # liest <tree>/defconfig
set -eu

CB="${1:?Usage: apply-devicetree.sh <coreboot-tree>}"
CFG="$CB/defconfig"
DT="$CB/src/mainboard/lenovo/sklkbl_thinkpad/devicetree.cb"
[ -f "$CFG" ] || { echo "apply-devicetree: '$CFG' fehlt" >&2; exit 1; }
[ -f "$DT" ]  || { echo "apply-devicetree: '$DT' fehlt" >&2; exit 1; }

TAB=$(printf '\t')
NL=$(printf '\nx'); NL=${NL%x}          # ein echtes Newline

# Von diesem Skript verwaltete Geräte (Marker-NAME -> devicetree-Alias = lowercase).
# Nur diese Aliase sind erlaubt (existieren im Skylake-Chipset: smbus 1f.4,
# heci1 16.0, fast_spi 1f.5) — alles andere wird ignoriert.
MANAGED="smbus heci1 fast_spi"

# 1) Alle verwalteten Geräte-Zeilen entfernen (deklarativ, idempotent):
for ref in $MANAGED; do
	sed -i "/^[[:space:]]*device ref ${ref} on end[[:space:]]*\$/d" "$DT"
done

# 2) Aktivierte (=y) Geräte in Konfig-Reihenfolge sammeln:
enabled=""
specs=$(grep -E '^# DT_DEVICE ' "$CFG" | awk '{print $3}' || true)   # z.B. SMBUS=y
for kv in $specs; do
	name=${kv%%=*}; val=${kv#*=}
	ref=$(printf '%s' "$name" | tr 'A-Z' 'a-z')
	case " $MANAGED " in
		*" $ref "*) : ;;
		*) echo "apply-devicetree: unbekanntes Gerät '$name' — ignoriert" >&2; continue ;;
	esac
	[ "$val" = "y" ] && enabled="$enabled $ref"
done

# 3) Aktivierte Geräte nach "device ref hda on end" einfügen (mit 2 Tabs Einrückung):
TEXT=""
for ref in $enabled; do
	line="${TAB}${TAB}device ref ${ref} on end"
	if [ -z "$TEXT" ]; then TEXT="$line"; else TEXT="${TEXT}${NL}${line}"; fi
done
if [ -n "$TEXT" ]; then
	grep -qE '^[[:space:]]*device ref hda on end[[:space:]]*$' "$DT" || {
		echo "apply-devicetree: Einfügepunkt 'device ref hda on end' nicht gefunden" >&2; exit 1; }
	awk -v ins="$TEXT" '
		{ print }
		/^[[:space:]]*device ref hda on end[[:space:]]*$/ && !d { print ins; d=1 }
	' "$DT" > "$DT.tmp" && mv "$DT.tmp" "$DT"
fi

echo "apply-devicetree: aktiviert ->${enabled:- (keine)}"
echo "apply-devicetree: domain-0-Endgeräte im devicetree.cb:"
grep -nE 'device ref (hda|smbus|heci1|fast_spi) on end' "$DT" | sed 's/^/    /'
