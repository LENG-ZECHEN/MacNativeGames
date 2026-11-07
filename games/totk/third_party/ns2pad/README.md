# ns2pad (vendored)

The Nintendo Switch 2 Pro Controller over Bluetooth LE (CoreBluetooth), or on a Mac also over its USB cable (IOUSBHost +
IOHIDManager, about 250 reports a second), read in the game's own process
(no driver, no system-wide gamepad). Copied unchanged from ns2pad commit `157114c`:

- `include/ns2pad.h` - the C API
- `core/ns2_core.c`, `core/ns2_core.h` - the protocol (C99, no platform code)
- `transport/apple/ns2pad_apple.m` - the CoreBluetooth layer (macOS and iOS, ARC)
- `LICENSE` (MIT), `THIRD_PARTY_NOTICES.md` (where the protocol knowledge came from)

The game's side is `runtime/ns2pad_bridge.m`. To update, copy the same files from a newer ns2pad commit and change the
commit above.
