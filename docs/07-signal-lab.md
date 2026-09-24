# Signal Lab telemetry map

Signal Lab reads three separate connections. The Mac sends audio to the BTD 700 over USB. The dongle sends audio to the HDB 630 over Bluetooth. The Mac also has a direct Bluetooth Classic connection to the HDB 630 for GAIA controls. The latter is a separate radio link and uses the headphones' second multipoint slot.

| Reading | Source | Meaning |
| --- | --- | --- |
| Control RSSI (dBm) | macOS `IOBluetoothDevice.rawRSSI()` | Signal received by the Mac from the headphones on the direct control link. Not the dongle's RSSI. `+127` means unavailable and is hidden. |
| Codec, link sample rate and bit depth, transmission mode | BTD 700 USB HID commands `0x05`, `0x08`, `0x01` | Dongle report for its Bluetooth audio link. This does not measure the source file's format or end-to-end fidelity. |
| Dongle connection state, codec capability mask, firmware | BTD 700 USB HID commands `0x06`, `0x03`, `0x12` | Dongle status. The mask names codecs the dongle reports as available for the current link. |
| Sink transport, LE Audio state | BTD 700 USB HID commands `0x15`, `0x07` | Dongle-reported transport and LE Audio connection state. Live response with HDB 630: `01` (Classic sink) and `01` (LE Audio disconnected). |
| USB device sample rate, virtual and physical stream format | Core Audio device and stream properties | Host-side audio format for the BTD 700 USB output. The virtual stream can differ from the physical USB stream. |
| Buffer size, device latency, safety offset | Core Audio output properties | Frames and derived milliseconds at the reported device rate. These are host/device scheduling values, **not** measured wireless or end-to-end latency. |
| Battery, charging, codec, firmware, ANC, wind mode, audio mode | HDB 630 GAIA v3 | Headphone-reported state. Some settings arrive via notifications; the diagnostics window also refreshes polled fields every 10 seconds. |
| Wear detection enabled | HDB 630 GAIA `0x0401` | Whether the on-head detection feature is enabled. It is **not** the current wearing state. |
| Physical device state | HDB 630 GAIA `0x0402`, notification `0x0482` | Device-reported state: 1=in case, 2=off head, 3=on head. Live response `03` observed; off-head transition awaits physical validation. |

Mac metrics sample every two seconds while the window is open. Headphone and dongle state refreshes every ten seconds and on supported device events. Closing the window stops its polling.

## Raw sensors

The HDB 630 product capability config sets `OnHeadDetection.raw_sensor_data_supported` to `false`. The physical-state command returns a discrete state, not proximity samples. The headphones contain microphones for ANC, but the GAIA control channel has no verified raw microphone stream. No verified motion, temperature, battery-health, or ear-pressure telemetry endpoint was found in the supported GAIA commands or BTD 700 HID command set. Signal Lab does not synthesize these values from unrelated data.

## Research-only statistics

The HDB 630 also answers Qualcomm GAIA vendor `0x001D` read-only statistics commands. `0x1800` with last-category ID `0x0000` returned category IDs `0x0001` and `0x0100`. `0x1801` returned 5 records for category `0x0001` and 19 records for `0x0100`, paginated by last statistic ID. Each record has an ID, flags, a byte count, and raw value. No reliable names or units were found for these IDs, so Signal Lab does not present them as battery health, RSSI, packet loss, or other measurements.

Across three category `0x0001` reads, statistic `04` changed `FF CF → FF D5 → FF C7`, and `05` changed `FF 78 → FF 7D → FF EE`. Interpreted as signed 16-bit integers, these are `-49 → -43 → -57` and `-136 → -131 → -18`. Their meaning is **unverified**; the changes alone do not identify them as RF metrics. In category `0x0100`, IDs `02` and `04` increased by five over about six minutes (`10760→10765` and `6359→6364`), suggesting counter-like values. ID `01` stayed `100` while the headphone battery reported `90%`, so it is not simply the current battery percentage. We need controlled changes and a schema before labeling any of them.

Other documented read-only candidates include hardware revision (`0x1200`), system release (`0x1201`), model ID (`0x1206`), and a headset low-latency flag (`0x0818`). The last returned `00` in one live read, but its relationship to the dongle's latency mode is not verified. The HDB capability file also names `SignalPath` and `Telemetry` features without a command map or data schema. We have no evidence that they expose continuous sensor streams.

Next validation: observe the `0x0402` state while physically removing/replacing the headphones; sample statistic IDs during a controlled change in distance, audio streaming, and charging, one variable at a time. Keep raw IDs and values until a reproducible mapping exists.

Sources: [HDB 630 capability extraction](03-hdb630-device-config.md), [Sennheiser desktop GAIA command database](https://github.com/zaval/sennheiser-desktop-client/blob/e770d91d7e98b09f73ac574b4431a70eff86cc98/gaiaV3/m4.json), [GAIA command map](02-gaia-v3-commands.md), [BTD 700 status enums](https://github.com/sobalap/btd700ctl/blob/747f3d6bcac91bdb36872038225e06eebc93f07a/include/btd700/btd700_c.h), [BTD 700 command map](06-btd700-dongle.md), [Apple raw RSSI API](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/rawrssi%28%29), [Apple Core Audio device properties](https://developer.apple.com/documentation/coreaudio/audiohardwaredevice), [Sennheiser HDB 630 manual](https://cdn.sennheiser-hearing.com/product-documents/product-downloads/hdb-630/Instruction%20manual%20HDB%20630/Instruction_manual_HDB_630.pdf).
