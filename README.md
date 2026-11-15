# Turntable Recorder

Record a Bluetooth turntable into your browser through an ESP32.

The turntable streams Bluetooth audio to an original ESP32 (WROOM-32 / DevKitC; the C3, S2 and S3 can't receive it). The ESP32 sends the audio over USB to the web page, which saves each side as a WAV file in browser storage. The same page flashes the firmware onto the ESP32.

Open the site in Chrome or Edge on a computer. Other browsers don't support Web Serial.

## Files

- `index.html`: the whole site, with the flasher library and firmware built in
- `firmware/`: ESP32 source (PlatformIO) and the built image `fieldnote-merged.bin`
- `web/`: page source and `build.py`, which produces `index.html`

## Rebuilding

```
cd firmware && pio run && python3 merge.py
cd ../web && python3 build.py
```
