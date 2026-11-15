"""Combine bootloader, partition table, boot_app0 and app into one image flashed at 0x1000."""
import glob, os, sys
b = ".pio/build/esp32dev"
ba = glob.glob(os.path.expanduser("~/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"))[0]
parts = [(0x1000, f"{b}/bootloader.bin"), (0x8000, f"{b}/partitions.bin"), (0xE000, ba), (0x10000, f"{b}/firmware.bin")]
out = bytearray()
for off, p in parts:
    out += b"\xff" * (off - 0x1000 - len(out))
    out += open(p, "rb").read()
open("fieldnote-merged.bin", "wb").write(out)
print("fieldnote-merged.bin", len(out), "bytes, flash at 0x1000")
