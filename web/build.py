"""Build the single-file recorder page: inlines esptool-js and the firmware image."""
import base64, pathlib
here = pathlib.Path(__file__).parent
src = (here / "recorder.src.html").read_text()
esptool = (here / "vendor/esptool-js-0.5.7.js").read_text()
fw = (here.parent / "firmware/fieldnote-merged.bin").read_bytes()
assert "</script" not in esptool
out = src.replace("/*ESPTOOL*/", esptool).replace("/*FIRMWARE_B64*/", base64.b64encode(fw).decode())
dest = here.parent / "index.html"
dest.write_text(out)
print(dest.name, f"{len(out)/1e6:.2f} MB")
