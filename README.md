# Cornix HUD

A macOS menu-bar companion for the [Cornix](https://github.com/hitsmaxft/zmk-keyboard-cornix)
split keyboard running ZMK.

- **Battery for both halves** in the menu bar, read over Bluetooth.
- **Active Bluetooth profile** (BT1–BT3).
- **Layer overlay**: hold a layer key and the layer's keymap appears at the
  bottom of the screen; hold Shift too and it shows the shifted symbols
  (`!` instead of `1`). It fades out when you let go.
- **Keymap read from the keyboard** through ZMK Studio's Bluetooth service, so
  edits made in ZMK Studio show up as soon as you save them. Nothing about
  the keymap is compiled into the app.

## Requirements

- macOS 14 or later.
- A Cornix on ZMK with ZMK Studio enabled (the
  [zmk-keyboard-cornix](https://github.com/hitsmaxft/zmk-keyboard-cornix) board
  module enables it on the left half).
- For the live layer and profile: the left half built with the HUD add-on
  from [meta-boy/zmk-keyboard-cornix@stock-keymap](https://github.com/meta-boy/zmk-keyboard-cornix/tree/stock-keymap).
  Without it the app still shows batteries and the keymap, but cannot tell
  which layer is held.

## Install

Download `CornixHUD.zip` from the [latest release](../../releases/latest),
unzip, and move `CornixHUD.app` to Applications. The build is ad-hoc signed,
not notarised, so on first launch right-click it and choose **Open**. Allow
Bluetooth access when asked.

Or build it yourself (Xcode 16+ command line tools):

```bash
cd app
./bundle.sh
open build/CornixHUD.app
```

## Firmware

The overlay needs to know which layer is held, which stock ZMK does not tell
the host. The add-on in the fork above does, in about 60 lines
(`src/cornix_hud.c`): it adds [zzeneg/zmk-raw-hid](https://github.com/zzeneg/zmk-raw-hid)
to the left half and sends a 32-byte report on every layer or profile change.

| Byte | Keyboard → host |
|---|---|
| 0 | `0xCD` magic |
| 1 | protocol version, `1` |
| 2 | `0x01` state message |
| 3–6 | active layer bitmask by layer id, little endian |
| 7 | highest active layer id |
| 8 | active BLE profile index |
| 9 | `1` if that profile is connected |

The host sends `[0xCD, 0x01]` to ask for the current state.

To build it, fork [meta-boy/zmk-keyboard-cornix](https://github.com/meta-boy/zmk-keyboard-cornix),
check out `stock-keymap`, and run the **Build ZMK firmware** workflow; flash
`cornix_left_default_nosd.uf2` to the left half. `firmware/config/cornix.keymap`
here is the keymap that branch builds: the stock Cornix layout printed on the
keycaps. `firmware/build.sh` builds the same thing locally in ZMK's Docker
image.

After flashing the add-on for the first time, forget the keyboard in
**System Settings → Bluetooth** and pair it again: the add-on adds a second
HID service and macOS keeps the old service list until the keyboard is
re-paired.

## How it reads the keymap

On connect the app opens the ZMK Studio RPC characteristic
(`00000001-0196-6107-c967-c5cfb1c2482a`) and asks for the behavior list, the
keymap and the physical layout, using the messages from
[zmk-studio-messages](https://github.com/zmkfirmware/zmk-studio-messages).
Bindings become keycap labels through the USB HID usage tables. The last
keymap read is cached in `~/Library/Application Support/CornixHUD/keymap.json`
so the overlay works before the keyboard answers.

## License

MIT
