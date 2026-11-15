// Fieldnote Turntable Bridge
// ESP32 (classic, with Bluetooth Classic) firmware.
//
// 1. Shows up as a Bluetooth speaker called "Fieldnote Recorder".
// 2. The turntable pairs with it and streams A2DP audio (16-bit stereo PCM).
// 3. When the web page sends a start command over USB serial, PCM is framed
//    into packets and streamed to the computer at 2,000,000 baud.
//
// Serial protocol (ESP32 -> computer), little endian:
//   0xF5 0xA1 | type (1 byte) | length (uint16) | payload
//   type 'A' = audio: uint16 sequence number, then int16 PCM samples
//   type 'S' = status: JSON text
// Commands (computer -> ESP32), one character:
//   'm' start mono stream (full rate)   's' start stereo stream
//   'h' start mono stream at half rate (for slower USB chips)
//   'x' stop                             'i' send status now

#include <Arduino.h>
#include "BluetoothA2DPSink.h"
#include "freertos/stream_buffer.h"

static const char *BT_NAME = "Fieldnote Recorder";
static const uint32_t BAUD = 2000000;
static const size_t RING_BYTES = 48 * 1024;
static const size_t CHUNK_BYTES = 1024;  // PCM bytes per audio packet

BluetoothA2DPSink a2dp;
StreamBufferHandle_t ring;

volatile bool streaming = false;
// 0 = mono, 1 = stereo, 2 = mono at half sample rate
volatile uint8_t mode = 0;
volatile uint32_t droppedBytes = 0;
volatile uint32_t lastAudioMs = 0;
uint16_t seq = 0;
uint32_t lastStatusMs = 0;
bool statusDirty = true;

// Called from the Bluetooth task with interleaved int16 L/R frames,
// before any volume scaling, so recordings keep full resolution.
void onAudio(const uint8_t *data, uint32_t len) {
  lastAudioMs = millis();
  if (!streaming) return;

  const int16_t *in = (const int16_t *)data;
  uint32_t frames = len / 4;

  if (mode == 0 || mode == 2) {
    static int16_t tmp[1024];
    uint32_t step = (mode == 2) ? 2 : 1;
    uint32_t done = 0;
    while (done + step <= frames) {
      uint32_t n = 0;
      while (n < 1024 && done + step <= frames) {
        int32_t sum = 0;
        for (uint32_t k = 0; k < step; k++) {
          sum += in[(done + k) * 2] + in[(done + k) * 2 + 1];
        }
        tmp[n++] = (int16_t)(sum / (int32_t)(2 * step));
        done += step;
      }
      size_t want = n * 2;
      size_t sent = xStreamBufferSend(ring, tmp, want, 0);
      if (sent < want) droppedBytes += want - sent;
    }
  } else {
    size_t sent = xStreamBufferSend(ring, data, len, 0);
    if (sent < len) droppedBytes += len - sent;
  }
}

void onSampleRate(uint16_t rate) { statusDirty = true; }
void onConnection(esp_a2d_connection_state_t state, void *) { statusDirty = true; }

void writePacket(uint8_t type, const uint8_t *payload, uint16_t len) {
  uint8_t header[5] = {0xF5, 0xA1, type, (uint8_t)(len & 0xFF), (uint8_t)(len >> 8)};
  Serial.write(header, 5);
  Serial.write(payload, len);
}

void sendStatus() {
  char json[256];
  const char *peer = a2dp.is_connected() ? a2dp.get_peer_name() : "";
  if (!peer) peer = "";
  bool playing = a2dp.is_connected() && (millis() - lastAudioMs < 500);
  // Strip quotes from the peer name so the JSON stays valid.
  char name[64];
  size_t j = 0;
  for (size_t i = 0; peer[i] && j < sizeof(name) - 1; i++) {
    if (peer[i] != '"' && peer[i] != '\\') name[j++] = peer[i];
  }
  name[j] = 0;
  const char *modeName = mode == 1 ? "stereo" : (mode == 2 ? "half" : "mono");
  int n = snprintf(json, sizeof(json),
                   "{\"fw\":\"1.0.0\",\"bt\":\"%s\",\"peer\":\"%s\",\"playing\":%s,"
                   "\"rate\":%u,\"mode\":\"%s\",\"streaming\":%s,\"dropped\":%lu}",
                   a2dp.is_connected() ? "connected" : "waiting", name,
                   playing ? "true" : "false", a2dp.sample_rate(),
                   modeName, streaming ? "true" : "false",
                   (unsigned long)droppedBytes);
  writePacket('S', (const uint8_t *)json, n);
  lastStatusMs = millis();
  statusDirty = false;
}

void handleCommands() {
  while (Serial.available()) {
    char c = Serial.read();
    switch (c) {
      case 'm':
      case 's':
      case 'h':
        mode = (c == 's') ? 1 : (c == 'h' ? 2 : 0);
        xStreamBufferReset(ring);
        droppedBytes = 0;
        seq = 0;
        streaming = true;
        statusDirty = true;
        break;
      case 'x':
        streaming = false;
        statusDirty = true;
        break;
      case 'i':
        statusDirty = true;
        break;
    }
  }
}

void setup() {
  Serial.setTxBufferSize(16384);
  Serial.setRxBufferSize(256);
  Serial.begin(BAUD);

  ring = xStreamBufferCreate(RING_BYTES, 1);

  a2dp.set_stream_reader(nullptr, false);  // no I2S speaker output
  a2dp.set_raw_stream_reader(onAudio);
  a2dp.set_sample_rate_callback(onSampleRate);
  a2dp.set_on_connection_state_changed(onConnection);
  a2dp.start(BT_NAME, true);  // auto-reconnect to the last turntable
}

void loop() {
  handleCommands();

  static uint8_t pkt[2 + CHUNK_BYTES];
  // Drain the ring buffer in fixed-size chunks.
  while (streaming && xStreamBufferBytesAvailable(ring) >= CHUNK_BYTES) {
    pkt[0] = seq & 0xFF;
    pkt[1] = seq >> 8;
    size_t got = xStreamBufferReceive(ring, pkt + 2, CHUNK_BYTES, 0);
    if (got == 0) break;
    writePacket('A', pkt, 2 + got);
    seq++;
    handleCommands();
  }

  bool wasPlaying = (millis() - lastAudioMs < 500);
  static bool prevPlaying = false;
  if (wasPlaying != prevPlaying) {
    prevPlaying = wasPlaying;
    statusDirty = true;
  }

  if (statusDirty || millis() - lastStatusMs > 1000) sendStatus();
  delay(1);
}
