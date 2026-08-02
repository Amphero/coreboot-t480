#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# vboot-slot-check.sh - which slot booted, and what vboot logged about it.
#   run0 bash scripts/vboot-slot-check.sh
set -u

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
CBMEM="$(command -v cbmem || echo "$PROJECT/sources/latest/coreboot/util/cbmem/cbmem")"
[ -x "$CBMEM" ] || { echo "cbmem not found - build it: make -C sources/latest/coreboot/util/cbmem" >&2; exit 1; }

echo "== slot selection and vboot messages =="
"$CBMEM" -c 2>/dev/null | grep -iE 'slot [ab] is|recovery|vb2_|vboot|failed|invalid' | head -20

echo
echo "== where the measurements came from (FW_MAIN_A/B or COREBOOT) =="
"$CBMEM" -L 2>/dev/null | grep 'Event data' | head -15

echo
echo "== system state =="
echo -n "  Secure Boot: "; sbctl status 2>/dev/null | grep -i '^Secure Boot' || echo "?"
echo -n "  Firmware:    "; cat /sys/class/dmi/id/bios_version
