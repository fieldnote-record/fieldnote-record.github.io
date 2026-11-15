# Turntable Recorder

Record a record player straight into your browser.

Plug the turntable's headphone or line-out jack into your computer's audio input, or into a USB audio adapter. Choose that input on the page and press **Record**. While it records, the page shows the live signal, L/R level meters and a growing waveform of the whole side, and it can play the audio through your speakers. Press **End** to stop.

Leveling happens after recording. When you press End, the page measures the finished side's loudest peak and applies one gain to the whole side so that peak lands at −1 dBFS. Quiet and loud passages keep their natural difference. Each side is saved as a 16-bit stereo WAV in the browser's storage, with a player, download and delete for each one.

## Fieldnote Companion (Mac)

An optional menu bar app that lets the website change your Mac's input volume in small steps (±0.1 dB) or big ones (±1 dB, ±6 dB), or with a slider. Install it from Terminal:

```
curl -fsSL https://fieldnote-record.github.io/companion/install.sh | bash
```

Click the record icon in the menu bar to see a 6-digit pairing code and enter it on the website. The app runs only on this Mac (`127.0.0.1:47823`), answers only fieldnote-record.github.io, and needs a paired browser before it changes anything. Volume is locked while a side is recording so the whole side stays at one level. Remove it with:

```
curl -fsSL https://fieldnote-record.github.io/companion/uninstall.sh | bash
```

Source is in `companion/source`; `companion/build.sh` rebuilds `FieldnoteCompanion.zip` (Apple silicon and Intel, macOS 12+).

## Hosting

The whole site is `index.html`. It needs https (GitHub Pages provides it) or `localhost` to use the audio input.
