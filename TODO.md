# TODO

- `make` is nowhere in the host requirements, but GUIDE.md and the Makefile
  both assume it. Document it or drop the targets.
- SdhciNonPciDxe rides along in the payload since uefipayload_2608 and does
  nothing on a T480. Patch it out, or decide it stays.
- fetch.sh retries only the edk2 step. A failure in the coreboot or lbmk step
  still throws the whole tree away and re-downloads it.
