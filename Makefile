# Makefile — dünne Komfort-Wrapper um die eigentlichen Build-Skripte.
#
# Dieses Repo ist KEIN Software-Projekt: die echte Build-Logik steckt in
# fetch.sh (PHASE 1) und scripts/*.py (PHASE 2). Dieses Makefile delegiert nur,
# damit die in der Doku genannten `make`-Aufrufe wörtlich funktionieren.
# `make pinned` / `make latest` bauen die Standard-Firmware (TPM + Setup Mode + RNG).
#
#   make fetch BASE=pinned        # = ./fetch.sh pinned              (PHASE 1, Netz)
#   make pinned                   # = build-firmware.py --mode pinned  (Standard, MIT TPM)
#   make latest                   # = build-firmware.py --mode latest
#   make pinned ARGS=--tpm-reset  # zusätzlich ein Reset-ROM (TPM2_Clear) -> README.md
#   make pinned ARGS=--no-tpm     # ohne TPM
#
# Beliebige weitere build-firmware.py-Flags via ARGS="…":
#   make latest ARGS="--tpm-reset --no-rng"

BASE ?=
ARGS ?=
PY   := python3

.PHONY: pinned latest fetch fetch-pinned fetch-latest help

## pinned / latest: die Standard-Firmware (TPM + Setup Mode + RNG).
## Zusatz-ROMs/Optionen via ARGS=… (z. B. ARGS=--tpm-reset für ein Reset-ROM).
pinned:
	$(PY) scripts/build-firmware.py --mode pinned $(ARGS)

latest:
	$(PY) scripts/build-firmware.py --mode latest $(ARGS)

## fetch: PHASE 1 (Quellen laden, braucht Netz). BASE=pinned|latest (Default pinned).
fetch:
	./fetch.sh $(if $(BASE),$(BASE),pinned)

fetch-pinned:
	./fetch.sh pinned

fetch-latest:
	./fetch.sh latest

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
	@echo ""
	@echo "  Vollständige Anleitung: README.md"
