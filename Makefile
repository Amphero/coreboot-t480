# SPDX-License-Identifier: GPL-3.0-only
# Makefile - thin convenience wrappers around the actual build scripts.
#
# This repo is NOT a classic software project: the real build logic lives in
# fetch.sh (PHASE 1) and scripts/*.py (PHASE 2). This Makefile only delegates
# so the `make` calls mentioned in the docs work verbatim.
#
#   make fetch                   # = ./fetch.sh            (PHASE 1, network)
#   make fetch-latest            # = ./fetch.sh --latest    (moves config/versions.lock)
#   make build                   # = build-firmware.py      (standard, WITH TPM)
#   make build ARGS=--tpm-reset  # additionally a reset ROM (TPM2_Clear) -> README.md
#   make build ARGS=--no-tpm     # without TPM
#
# Any further build-firmware.py flags via ARGS="...":
#   make build ARGS="--tpm-reset --no-rng"

ARGS ?=
PY   := python3

.PHONY: build fetch fetch-latest help

## build: the standard firmware (TPM + Setup Mode + RNG).
## Extra ROMs/options via ARGS=... (e.g. ARGS=--tpm-reset for a reset ROM).
build:
	$(PY) scripts/build-firmware.py $(ARGS)

## fetch: PHASE 1 (download the sources named in config/versions.lock, needs network).
fetch:
	./fetch.sh

## fetch-latest: resolve the newest upstream versions and rewrite config/versions.lock.
fetch-latest:
	./fetch.sh --latest

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
	@echo ""
	@echo "  Full guide: README.md"
