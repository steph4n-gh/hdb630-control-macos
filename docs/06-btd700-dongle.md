# BTD 700 on macOS

The BTD 700 has two independent USB interfaces relevant here:

- USB audio carries the Mac's sound to the dongle. The dongle transmits it to the HDB 630 over Bluetooth.
- A vendor HID interface accepts dongle settings and returns live status. The macOS app uses this interface through IOKit. No custom driver is needed.

The headphone controls in this project still use a direct Mac-to-headphone Bluetooth Classic RFCOMM connection. The dongle's USB HID interface controls the dongle; it does not relay GAIA commands to the headphones. With dongle audio and Mac headphone control together, the HDB 630's two multipoint slots are occupied.

## HID interface

The tested BTD 700 enumerates as vendor `0x3542`, product `0x3001`. The relevant HID collection has usage page `0xFFA2`, usage `1`, and 64-byte reports with ID `0x34`.

Host commands use `[0x34, 0xFE, command, payload_length, payload..., zero_padding]`. Replies use `[0x34, 0xFF, command, payload_length, payload..., zero_padding]`. Unsolicited events use marker `0xFC`. The app currently uses commands:

| ID | Purpose |
| --- | --- |
| `0x12` | Firmware version |
| `0x06` | Connection state |
| `0x01` / `0x02` | Get / set audio mode |
| `0x03` | Codec capability mask reported by the dongle |
| `0x04` | Request codec mask |
| `0x05` | Active codec |
| `0x08` | Active bit depth and sample rate |
| `0x14` | Request connection / disconnection |

These identifiers were documented by [btd700ctl](https://github.com/sobalap/btd700ctl). The macOS implementation was tested directly against a plugged-in BTD 700 on firmware 3.11.0. It returned streaming state, Gaming mode, aptX Adaptive, and 24-bit/48-kHz audio. Changing the mode to High Quality and back returned success (`0x00`) and read back correctly. Codec requests returned status `0x01` and left aptX Adaptive active; the app reports that rejection.

The currently active audio quality is a report from the dongle, not a promise of source or headphone capability. To reach 96 kHz, the Mac's USB output format and the headphones' Hi-Res priority setting must also allow it.
