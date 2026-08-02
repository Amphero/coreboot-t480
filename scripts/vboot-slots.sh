#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# vboot-slots.sh - inspect and exercise the vboot RW slots on a running machine.
#
#   run0 bash scripts/vboot-slots.sh status        # what the chip currently holds
#   run0 bash scripts/vboot-slots.sh corrupt-a     # wipe VBLOCK_A  -> next boot must use slot B
#   run0 bash scripts/vboot-slots.sh corrupt-both  # wipe both      -> next boot must come from WP_RO
#   run0 bash scripts/vboot-slots.sh restore       # rewrite both slots from the ROM
#
# Only the affected VBLOCK/RW regions are written; WP_RO, SMMSTORE, the MRC
# cache and NVRAM are never touched. WP_RO carries a complete image including
# the payload, so a recovery boot is the safety net - the external programmer
# is only needed if that fails too.
#
# The ROM defaults to the newest roms/coreboot_t480_*.rom; pass another path as
# the second argument.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
ROMDIR="$PROJECT/roms"

die(){ printf '\n\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

MODE="${1:-}"
case "$MODE" in
  corrupt-a|corrupt-both|restore|status) : ;;
  *) die "usage: $0 status|corrupt-a|corrupt-both|restore [rom]" ;;
esac

ROM="${2:-$(ls -t "$ROMDIR"/coreboot_t480_*.rom 2>/dev/null | grep -v tpmreset | head -1 || true)}"
[ -n "$ROM" ] && [ -f "$ROM" ] || die "no ROM found in $ROMDIR (pass one explicitly)"
[ "$(stat -c %s "$ROM")" = 16777216 ] || die "$ROM is not exactly 16 MiB"

[ "$(id -u)" = 0 ] || die "run as root: run0 bash $0 $MODE"
command -v flashrom >/dev/null || die "flashrom is missing"
grep -q 'iomem=relaxed' /proc/cmdline || die "kernel booted without iomem=relaxed"
[ "$(cat /sys/class/power_supply/AC/online 2>/dev/null || echo 0)" = 1 ] \
  || die "AC adapter not connected"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DUMP="$WORK/chip.bin"

echo "== reading the chip"
flashrom -p internal -r "$DUMP" >/dev/null 2>&1 || die "read failed"

# Keep one current backup around; owned by whoever owns roms/.
LATEST="$(ls -t "$ROMDIR"/backup_vboot_*.bin 2>/dev/null | head -1 || true)"
if [ -z "$LATEST" ]; then
	LATEST="$ROMDIR/backup_vboot_$(date +%Y%m%d_%H%M%S).bin"
	cp "$DUMP" "$LATEST"
	chown --reference="$ROMDIR" "$LATEST" 2>/dev/null || true
	echo "   backup written: $LATEST"
else
	echo "   existing backup: $LATEST"
fi

python3 - "$ROM" "$DUMP" "$MODE" "$WORK" <<'EOF' || exit 1
import struct, sys, os

def fmap(d):
    idx = d.find(b'__FMAP__')
    while idx != -1:
        try:
            vmaj = d[idx+8]
            nareas, = struct.unpack_from('<H', d, idx+54)
            if vmaj == 1 and 0 < nareas <= 1024 and idx+56+nareas*42 <= len(d):
                areas, off = {}, idx+56
                for _ in range(nareas):
                    o, s = struct.unpack_from('<II', d, off)
                    nm = d[off+8:off+40].split(b'\0')[0].decode()
                    areas[nm] = (o, s); off += 42
                return areas
        except Exception:
            pass
        idx = d.find(b'__FMAP__', idx+1)
    return None

def fail(msg):
    print(f"CHECK FAILED: {msg}", file=sys.stderr); sys.exit(1)

rom_p, dump_p, mode, work = sys.argv[1:5]
rom  = open(rom_p, 'rb').read()
dump = open(dump_p, 'rb').read()
if len(dump) != 16777216: fail("chip dump is not 16 MiB")
fr, fd = fmap(rom), fmap(dump)
if not fr: fail("no FMAP in the ROM")
if not fd: fail("no FMAP in the chip dump")
if 'VBLOCK_A' not in fd: fail("chip does not carry the vboot layout")
if fr != fd: fail("ROM and chip FMAP differ")

def state(d, name):
    o, _ = fd[name]
    return "valid" if d[o:o+8] == b'CHROMEOS' else "WIPED"

print(f"  chip: VBLOCK_A={state(dump,'VBLOCK_A')}  VBLOCK_B={state(dump,'VBLOCK_B')}")
print(f"  rom : VBLOCK_A={state(rom,'VBLOCK_A')}  VBLOCK_B={state(rom,'VBLOCK_B')}")

if mode == 'status':
    sys.exit(0)

if mode == 'restore':
    for r in ('VBLOCK_A', 'VBLOCK_B'):
        o, _ = fr[r]
        if rom[o:o+8] != b'CHROMEOS': fail(f"{r} in the ROM is itself broken")
    open(os.path.join(work, 'write.bin'), 'wb').write(rom)
    open(os.path.join(work, 'regions'), 'w').write("RW_SECTION_A RW_SECTION_B")
    print("  -> rewrites RW_SECTION_A and RW_SECTION_B from the ROM")
    sys.exit(0)

targets = ['VBLOCK_A'] if mode == 'corrupt-a' else ['VBLOCK_A', 'VBLOCK_B']
img = bytearray(rom)
for r in targets:
    o, s = fr[r]
    img[o:o+s] = b'\x00' * s      # keyblock magic gone -> the slot fails verification
    print(f"  -> zeroing {r} (0x{o:07x} + 0x{s:07x})")
open(os.path.join(work, 'write.bin'), 'wb').write(bytes(img))
open(os.path.join(work, 'regions'), 'w').write(' '.join(targets))
EOF

[ "$MODE" = "status" ] && exit 0

REGIONS="$(cat "$WORK/regions")"
ARGS=""; for r in $REGIONS; do ARGS="$ARGS -i $r"; done

echo
case "$MODE" in
  corrupt-a)    echo "The next boot must select slot B. Undo: '$0 restore'." ;;
  corrupt-both) echo "The next boot falls back to WP_RO. If nothing comes up, the CH341A is the way back." ;;
  restore)      echo "Rewrites both slots from the ROM." ;;
esac
printf 'Type YES: '
read -r ans
[ "$ans" = "YES" ] || die "not confirmed"

flashrom -p internal --fmap $ARGS -w "$WORK/write.bin" || die "WRITE FAILED"
flashrom -p internal --fmap $ARGS -v "$WORK/write.bin" || die "VERIFY FAILED"

echo
echo "Done. Reboot, then: run0 bash scripts/vboot-slot-check.sh"
