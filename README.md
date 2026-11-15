# Turntable Recorder

Record a record player straight into your browser.

Plug the turntable's headphone or line-out jack into your computer's audio input, or into a USB audio adapter. Choose that input on the page and press **Record**. While it records, the page shows the live signal, L/R level meters and a growing waveform of the whole side, and it can play the audio through your speakers. Press **End** to stop.

Leveling happens after recording. When you press End, the page measures the finished side's loudest peak and applies one gain to the whole side so that peak lands at −1 dBFS. Quiet and loud passages keep their natural difference. Each side is saved as a 16-bit stereo WAV in the browser's storage, with a player, download and delete for each one.

The whole site is `index.html`. It needs https (GitHub Pages provides it) or `localhost` to use the audio input.
