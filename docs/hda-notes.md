# HDA notes

What the ALC257 verb table does on this board, how the stock BIOS programs it
differently, and why the transplant was measured and then not taken. Written up
because the extraction is tedious to repeat and the result is counterintuitive.

Context is issue #10: a whine tracking cpu load, reported on another T480, also
present in the setup menu. No repro on this machine.

## Where the stock table lives

Uncompressed at `0xda2c80` in a 16 MB dump, a second ALC257 table at `0xda3b20`,
616 bytes each. The DXE volumes are LZMA and hold nothing relevant - a plain
search for `0x10ec0257` finds the table in neither, because the encoding differs
from coreboot's:

| | coreboot | stock BIOS |
|---|---|---|
| header | `0x10ec0257` | bytes `ec 10 57 02`, i.e. `(did << 16) \| vid` |
| verb | one dword, `codec << 28 \| nid << 20 \| payload20` | same layout |
| coefficient | one dword pair, ready to write | `0x500`/`0x4xx` pairs, same thing |

Byte-identical in `n24ur39w`, in this board's pre-coreboot dump and in a foreign
NM-B501 image, so it is neither BIOS-version nor board specific.

Headers are findable: a dword whose low 16 bits are `0x10ec` or `0x8086`
followed by a dword ending in `0xffff`. That yields 14 tables in `n24ur39w`,
two of them ALC257.

## Pin configs match, coefficients do not

All ten pins in the `0xda2c80` table are identical to what upstream carries,
including `0x40661b45` on nid 0x1d and `0x0421101f` on nid 0x21. Upstream got
that part right.

The codec coefficients are a different set entirely - 49 writes against
upstream's 14, three in common:

| node/coef | stock | upstream |
|---|---|---|
| 0x20/0x38 | `0x7900` -> `0x7901` | `0x8981` |
| 0x20/0x3c | `0x0354` -> `0x0314` | `0x3154` -> `0x3114` |
| 0x20/0x09 | `0xe003` | `0x6003` |
| 0x20/0x04 0x08 0x0d 0x10 0x13 0x16 0x36 | set | - |
| 0x20/0x0a 0x1a 0x30 0x37 | - | set |
| 0x53 + 0x54, 32 writes | speaker EQ/DRC | - |
| 0x58/0x00 | - | `0xf880` |
| 0x20/0x1b, 0x20/0x46, 0x57/0x03 | same | same |

Coef 0x38 is the register upstream's own comment labels `ClassD 2W`. Coef 0x37
is its `Silence data mode Threshold (-84dB)`, which the stock BIOS never writes.

## The transplant, measured

Patch 0050 replaces the ALC257 entry with the stock one verbatim, jack count
18 -> 38. Built, capsule-installed, measured 2026-08-29 against the previous
firmware in the other slot - same machine, same volume, same stimulus (3 s of
440 Hz through `pw-play` at 63 %):

| | upstream table, `verb size: 72` | stock table, `verb size: 152` |
|---|---|---|
| click | none | one at signal onset, one at offset |
| tone | cleaner | audibly worse |

So the vendor's own table is the worse of the two on this board. The patch sits
in `patches/regression/`, where nothing builds it.

Ruled out for the click, each by measurement:

- the codec's D3/D0 transition - it survives `power_save=0`, codec pinned `active`
- stream start/stop - it survives a permanently open silent stream that keeps
  the output path up
- the missing silence threshold - writing upstream's `coef 0x37 = 0xFE15` and
  `coef 0x30 = 0x9004` into the running codec changed nothing

The last one is only evidence about runtime writes. The amp block may need the
full init sequence rather than two registers dropped on top of an initialised
codec; that was not chased further.

Hypothesis, not measured: under the stock BIOS the firmware table is half the
configuration and the Realtek Windows driver supplies the rest. Upstream's block
looks like it was taken off a different machine, but it is self-contained - it
has to work with no vendor driver behind it, which is why it carries the silence
threshold the vendor's does not.

## Second pin config

The table at `0xda3b20` differs from the first in exactly two pins - nid 0x12
(internal mic) and nid 0x19 (mic jack) both `0x411111f0`, no microphone input at
all. Not the T480s, whose upstream table has both populated. The legacy verb
path keys on vendor/device alone, so both SKUs get the first table's pins.
Tracked in issue #11; nothing found yet that would let the firmware tell them
apart at runtime.

## The likelier cause

Found while writing this up: coreboot carries FSP UPDs for exactly this symptom
and the board sets none of them. `AcousticNoiseMitigation` gates
`SlowSlewRateForIa/Gt/Sa` and `FastPkgCRampDisableIa/Gt/Sa`
(`src/soc/intel/skylake/chip.h:441-463`, passed through at `chip.c:475-481`).
Fast VR slew rates and fast package-C ramping are what make these rails audible
under changing load, which fits "tracks cpu load, present in the setup menu"
directly - where the HDA theory needs the codec to pick up and amplify rail
ripple, a second-order path. Other boards set them, e.g.
`acer/aspire_vn7_572g` and `clevo/cml-u`; `sklkbl_thinkpad` does not.

That is patch 0060. `IslVrCmd` sits right above these in `chip.c` and is
another VR C-state workaround, also unset and not touched - whether this board
has an Intersil VR is unknown.

Measured 2026-08-29, first attempt: mitigation on, Fast/16 on IA, GT and SA,
fast package-C ramping disabled on all three. It installed and ran - the sine
did not click, which is the control that confirms the click came from 0050 and
nothing else - but **the screen flickered badly enough to be hard to read**.
Reverted to the other slot.

GT feeds the iGPU and nothing about a load-tracking whine asks for slowing it.
The patch now raises `SlowSlewRateForIa` only.

One trap for anyone trimming it further: the registers left unset are not left
alone. With `AcousticNoiseMitigation` on they reach FSP as 0, which is `Fast/2`
- a value, not the pre-mitigation default. The mitigation cannot be enabled for
one rail in isolation, so a flicker that survives this version would point at
the mitigation flag itself or at GT's `Fast/2`, not at anything left over from
the first attempt.

There is a free proxy for it that needs no firmware at all:
`intel_idle.max_cstate=1` on the kernel command line suppresses deep package-C
states and with them the fast ramping. If the whine drops under that, the UPDs
are the fix and audio is a dead end. Costs battery, so it is a test and not a
setting.

## What is still worth doing

Patch 0050 is a diagnostic, not a fix. If the reporter's whine goes away with
it, the class-D path is implicated and the click is an acceptable price for one
test boot. Nothing about this board's own measurements says the transplant
should ship.

If the audio path does turn out to matter, a better A/B than 0050 is to drop
the node 0x20 block entirely, or turn `device ref hda` off. Swapping one vendor
block for another changes two things at once.
