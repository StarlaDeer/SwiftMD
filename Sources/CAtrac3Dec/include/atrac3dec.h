// Standalone ATRAC3 decoder (LP2 / LP4), ported from FFmpeg's libavcodec/atrac3.c. LGPL-2.1-or-later.
#ifndef ATRAC3DEC_H
#define ATRAC3DEC_H

#include <stdint.h>

typedef struct Atrac3Decoder Atrac3Decoder;

/// block_align: bytes per frame for both channels (LP2: 384, LP4: 192). joint_stereo: 1 for LP4.
Atrac3Decoder *atrac3_decoder_create(int block_align, int joint_stereo);
void atrac3_decoder_free(Atrac3Decoder *decoder);

/// Decodes one block_align-byte frame into 1024 samples per channel, roughly -1...1.
/// Returns 0, or a negative number if the frame couldn't be decoded (the output is then silence).
int atrac3_decode_frame(Atrac3Decoder *decoder, const uint8_t *frame, float *left, float *right);

/* ATRAC1 (SP), ported from FFmpeg's libavcodec/atrac1.c. */
typedef struct Atrac1Decoder Atrac1Decoder;

Atrac1Decoder *atrac1_decoder_create(int channels);
void atrac1_decoder_free(Atrac1Decoder *decoder);

/// Decodes one 212 * channels byte frame into 512 samples per channel (right is ignored for mono).
/// Returns 0, or a negative number if the frame couldn't be decoded (the output is then silence).
int atrac1_decode_frame(Atrac1Decoder *decoder, const uint8_t *frame, float *left, float *right);

#endif
