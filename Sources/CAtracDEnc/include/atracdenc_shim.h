// SwiftMD - C interface to the vendored atracdenc ATRAC3 encoder.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Encodes interleaved stereo float PCM (44.1 kHz, samples in -1...1) into raw ATRAC3 frames.
/// `bitrateKbps` follows atracdenc's --bitrate option: 128 for LP2, 64 for LP4.
/// On success returns 0 and sets `out` (free with atracdenc_free), `outLength` and `frameSize`.
int atracdenc_encode_atrac3(const float *pcm, uint64_t frames, uint32_t bitrateKbps,
                            uint8_t **out, size_t *outLength, size_t *frameSize);

void atracdenc_free(uint8_t *buffer);

#ifdef __cplusplus
}
#endif
