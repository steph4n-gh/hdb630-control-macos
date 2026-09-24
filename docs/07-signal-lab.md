# Signal Lab telemetry map

Signal Lab reads three separate connections. The Mac sends audio to the BTD 700 over USB. The dongle sends audio to the HDB 630 over Bluetooth. The Mac also has a direct Bluetooth Classic connection to the HDB 630 for GAIA controls. The latter is a separate radio link and uses the headphones' second multipoint slot.

| Reading | Source | Meaning |
| --- | --- | --- |
| Control RSSI (dBm) | macOS `IOBluetoothDevice.rawRSSI()` | Signal received by the Mac from the headphones on the direct control link. Not the dongle's RSSI. `+127` means unavailable and is hidden. |
| Codec, link sample rate and bit depth, transmission mode | BTD 700 USB HID commands `0x05`, `0x08`, `0x01` | Dongle report for its Bluetooth audio link. This does not measure the source file's format or end-to-end fidelity. |
| Dongle connection state, codec capability mask, firmware | BTD 700 USB HID commands `0x06`, `0x03`, `0x12` | Dongle status. The mask names codecs the dongle reports as available for the current link. |
| USB device sample rate, virtual and physical stream format | Core Audio device and stream properties | Host-side audio format for the BTD 700 USB output. The virtual stream can differ from the physical USB stream. |
| Buffer size, device latency, safety offset | Core Audio output properties | Frames and derived milliseconds at the reported device rate. These are host/device scheduling values, **not** measured wireless or end-to-end latency. |
| Battery, charging, codec, firmware, ANC, wind mode, audio mode | HDB 630 GAIA v3 | Headphone-reported state. Some settings arrive via notifications; the diagnostics window also refreshes polled fields every 10 seconds. |
| Wear detection enabled | HDB 630 GAIA `0x0401` | Whether the on-head detection feature is enabled. It is **not** the current wearing state. |

Mac metrics sample every two seconds while the window is open. Headphone and dongle state refreshes every ten seconds and on supported device events. Closing the window stops its polling.

## Raw sensors

The HDB 630 product capability config sets `OnHeadDetection.raw_sensor_data_supported` to `false`. We have a working command for its enable setting but no verified command that returns current wear state or proximity samples. The headphones contain microphones for ANC, but the GAIA control channel has no verified raw microphone stream. No verified motion, temperature, battery-health, or ear-pressure telemetry endpoint was found in the supported GAIA commands or BTD 700 HID command set. Signal Lab does not synthesize these values from unrelated data.

Potential future discovery would require capturing a device event or a first-party app request that carries a specific value, then reproducing and validating it against a known physical change. The existing `SignalPath` and `Telemetry` capability names alone do not establish a readable stream.

Sources: [HDB 630 capability extraction](03-hdb630-device-config.md), [GAIA command map](02-gaia-v3-commands.md), [BTD 700 command map](06-btd700-dongle.md), [Apple raw RSSI API](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/rawrssi%28%29), [Apple Core Audio device properties](https://developer.apple.com/documentation/coreaudio/audiohardwaredevice), [Sennheiser HDB 630 manual](https://cdn.sennheiser-hearing.com/product-documents/product-downloads/hdb-630/Instruction%20manual%20HDB%20630/Instruction_manual_HDB_630.pdf).
