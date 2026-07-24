# SPDX-License-Identifier: GPL-3.0-only
# Makefile - thin convenience wrappers around the actual build scripts.
#
# This repo is NOT a classic software project: the real build logic lives in
# fetch.sh (PHASE 1) and scripts/*.py (PHASE 2). This Makefile only delegates
# so the `make` calls mentioned in the docs work verbatim.
# `make pinned` / `make latest` build the standard firmware (TPM + Setup Mode + RNG).
#
#   make fetch BASE=pinned        # = ./fetch.sh pinned              (PHASE 1, network)
#   make pinned                   # = build-firmware.py --mode pinned  (standard, WITH TPM)
#   make latest                   # = build-firmware.py --mode latest
#   make pinned ARGS=--tpm-reset  # additionally a reset ROM (TPM2_Clear) -> README.md
#   make pinned ARGS=--no-tpm     # without TPM
#
# Any further build-firmware.py flags via ARGS="...":
#   make latest ARGS="--tpm-reset --no-rng"

BASE ?=
ARGS ?=
PY   := python3

.PHONY: pinned latest fetch fetch-pinned fetch-latest help

## pinned / latest: the standard firmware (TPM + Setup Mode + RNG).
## Extra ROMs/options via ARGS=... (e.g. ARGS=--tpm-reset for a reset ROM).
pinned:
	$(PY) scripts/build-firmware.py --mode pinned $(ARGS)

latest:
	$(PY) scripts/build-firmware.py --mode latest $(ARGS)

## fetch: PHASE 1 (download sources, needs network). BASE=pinned|latest (default pinned).
fetch:
	./fetch.sh $(if $(BASE),$(BASE),pinned)

fetch-pinned:
	./fetch.sh pinned

fetch-latest:
	./fetch.sh latest

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
	@echo ""
	@echo "  Full guide: README.md"
