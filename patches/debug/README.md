# Debug patches

Never built: the image build applies `patches/base/*.patch` and
`patches/edk2/*.patch` only, and the config hash covers only those two
directories. To use one, move it into the tree it names and rebuild with
`--rebuild-base`; move it back out before a release build.

- `0099-TEMP-tcg2-log-trace.patch` (edk2) - T2LOG/T2GET prints in Tcg2Dxe:
  every log append and every GetEventLog answer, with addresses and sizes.

The prints are `DEBUG()` calls, so the payload has to be a debug build and
its console has to go somewhere readable. In `config/defconfig`:

```
CONFIG_EDK2_DEBUG=y
CONFIG_CONSOLE_CBMEM_BUFFER_SIZE=0x100000
CONFIG_EDK2_CUSTOM_BUILD_PARAMS="-D VARIABLE_SUPPORT=SMMSTORE -D USE_CBMEM_FOR_CONSOLE=TRUE"
```

The output then lands in the CBMEM console (`/sys/firmware/log`), which
survives warm reboots - the log of the previous boot is still there.
