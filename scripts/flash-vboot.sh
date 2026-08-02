#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# flash-vboot.sh - update a machine that already runs the vboot layout.
#
#   run0 bash scripts/flash-vboot.sh [rom]
#
# Writes WP_RO + RW_SECTION_A + RW_SECTION_B. SMMSTORE, RW_MRC_CACHE, RW_ELOG
# and RW_NVRAM are left alone, so UEFI variables, Secure Boot keys and the
# vboot state survive. The ROM defaults to the newest roms/coreboot_t480_*.rom.
#
# For the one-time move from the old single-CBFS layout to vboot this is the
# wrong tool - that migration writes the old FMAP+COREBOOT regions instead.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
ROMDIR="$PROJECT/roms"

die(){ printf '\n\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

ROM="${1:-$(ls -t "$ROMDIR"/coreboot_t480_*.rom 2>/dev/null | grep -v tpmreset | head -1 || true)}"
[ -n "$ROM" ] && [ -f "$ROM" ] || die "no ROM found in $ROMDIR (pass one explicitly)"
[ "$(stat -c %s "$ROM")" = 16777216 ] || die "$ROM is not exactly 16 MiB"
case "$ROM" in *tpmreset*) die "that is the TPM reset ROM" ;; esac

[ "$(id -u)" = 0 ] || die "run as root: run0 bash $0"
command -v flashrom >/dev/null || die "flashrom is missing"
grep -q 'iomem=relaxed' /proc/cmdline || die "kernel booted without iomem=relaxed"
if [ "${ALLOW_NO_AC:-0}" != "1" ]; then
	[ "$(cat /sys/class/power_supply/AC/online 2>/dev/null || echo 0)" = 1 ] \
	  || die "AC adapter not connected (ALLOW_NO_AC=1 overrides, check the battery first)"
fi

DUMP="$ROMDIR/backup_vboot_$(date +%Y%m%d_%H%M%S).bin"
echo "== reading the chip -> $DUMP"
flashrom -p internal -r "$DUMP" >/dev/null 2>&1 || die "read failed"
chown --reference="$ROMDIR" "$DUMP" 2>/dev/null || true

echo "== checks"
python3 - "$ROM" "$DUMP" <<'EOF' || exit 1
import struct, sys

def fmap(d):
    idx = d.find(b'__FMAP__')
    while idx != -1:
        try:
            if d[idx+8] == 1:
                n, = struct.unpack_from('<H', d, idx+54)
                if 0 < n <= 1024 and idx+56+n*42 <= len(d):
                    a, off = {}, idx+56
                    for _ in range(n):
                        o, s = struct.unpack_from('<II', d, off)
                        a[d[off+8:off+40].split(b'\0')[0].decode()] = (o, s)
                        off += 42
                    return a
        except Exception:
            pass
        idx = d.find(b'__FMAP__', idx+1)
    return None

def fail(msg):
    print(f"CHECK FAILED: {msg}", file=sys.stderr); sys.exit(1)

rom  = open(sys.argv[1], 'rb').read()
dump = open(sys.argv[2], 'rb').read()
if len(dump) != 16777216: fail("chip dump is not 16 MiB")
fr, fd = fmap(rom), fmap(dump)
if not fr: fail("no FMAP in the ROM")
if not fd: fail("no FMAP in the chip dump")
if 'RW_SECTION_A' not in fd:
    fail("chip still has the pre-vboot layout - this is the wrong tool")
if fr != fd: fail("ROM and chip FMAP differ")
for r in ('VBLOCK_A', 'VBLOCK_B'):
    o, _ = fr[r]
    if rom[o:o+8] != b'CHROMEOS': fail(f"{r} in the ROM carries no keyblock")
go, _ = fd['SI_GBE']
if rom[go:go+6] != dump[go:go+6]: fail("MAC in the ROM differs from the chip")
so, ss = fd['SMMSTORE']
seg = dump[so:so+ss]
guid = bytes.fromhex('61dfe48bca93d211aa0d00e098032b8c')
if not (b'P\x00K\x00' in seg and guid in seg):
    fail("no Platform Key variable in the chip's SMMSTORE")
print("  ok: layouts match, both slots signed, MAC identical, PK present")
print("  writing: WP_RO + RW_SECTION_A + RW_SECTION_B")
EOF

echo
printf 'Type YES: '
read -r ans
[ "$ans" = "YES" ] || die "not confirmed"

R="-i WP_RO -i RW_SECTION_A -i RW_SECTION_B"
flashrom -p internal --fmap $R -w "$ROM" || die "WRITE FAILED - do not reboot, report this"
flashrom -p internal --fmap $R -v "$ROM" || die "VERIFY FAILED - do not reboot, report this"

echo
echo "Done. Backup: $DUMP"
