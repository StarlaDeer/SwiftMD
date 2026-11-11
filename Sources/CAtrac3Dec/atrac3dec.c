/*
 * Standalone ATRAC3 decoder for SwiftMD, ported from FFmpeg 7.1 (libavcodec/atrac3.c and atrac.c).
 *
 * Copyright (c) 2006-2008 Maxim Poliakovski
 * Copyright (c) 2006-2008 Benjamin Larsson
 * SwiftMD port: FFmpeg's bit reader, VLC, float DSP and av_tx MDCT replaced by small local
 * equivalents (the MDCT as a matrix product with Accelerate). The decoding logic is unchanged.
 *
 * This file is part of SwiftMD. Like FFmpeg, it is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License as published by the Free
 * Software Foundation; either version 2.1 of the License, or (at your option) any later version.
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <Accelerate/Accelerate.h>
#include <pthread.h>

#include "atrac3dec.h"
#include "atrac3data.h"

#define FFSWAP(type, a, b) do { type SWAP_tmp = b; b = a; a = SWAP_tmp; } while (0)
#define FFMIN(a, b) ((a) > (b) ? (b) : (a))
#define FFMAX(a, b) ((a) > (b) ? (a) : (b))
#define AVERROR_INVALIDDATA (-1)

#define JOINT_STEREO      0x12
#define SINGLE            0x2
#define SAMPLES_PER_FRAME 1024
#define MDCT_SIZE         512

/* ---- Bit reader (big-endian, MSB first), reads zeros past the end ---- */

typedef struct GetBitContext {
    const uint8_t *buffer;
    int index;
    int size_in_bits;
} GetBitContext;

static void init_get_bits(GetBitContext *s, const uint8_t *buffer, int bit_size)
{
    s->buffer = buffer;
    s->index = 0;
    s->size_in_bits = bit_size < 0 ? 0 : bit_size;
}

static int init_get_bits8(GetBitContext *s, const uint8_t *buffer, int byte_size)
{
    if (byte_size < 0) return AVERROR_INVALIDDATA;
    init_get_bits(s, buffer, byte_size * 8);
    return 0;
}

static unsigned get_bits1(GetBitContext *s)
{
    unsigned bit = 0;
    if (s->index < s->size_in_bits)
        bit = (s->buffer[s->index >> 3] >> (7 - (s->index & 7))) & 1;
    s->index++;
    return bit;
}

static unsigned get_bits(GetBitContext *s, int n)
{
    unsigned v = 0;
    while (n-- > 0) v = (v << 1) | get_bits1(s);
    return v;
}

static int get_sbits(GetBitContext *s, int n)
{
    int v = (int)get_bits(s, n);
    return (v ^ (1 << (n - 1))) - (1 << (n - 1)); /* sign-extend */
}

/* ---- VLC: canonical codes assigned in table order, as ff_vlc_init_from_lengths does ---- */

typedef struct VLCTable {
    int count;
    uint32_t code[64];
    uint8_t len[64];
    int8_t symbol[64];
} VLCTable;

static VLCTable spectral_coeff_tab[7];

static void vlc_init_from_lengths(VLCTable *t, int nb_codes, const uint8_t (*tab)[2], int offset)
{
    uint64_t code = 0; /* left-aligned in 32 bits */
    t->count = nb_codes;
    for (int i = 0; i < nb_codes; i++) {
        int len = tab[i][1];
        t->len[i] = (uint8_t)len;
        t->symbol[i] = (int8_t)(tab[i][0] + offset);
        t->code[i] = (uint32_t)(code >> (32 - len));
        code += 1ULL << (32 - len);
    }
}

static int get_vlc(GetBitContext *gb, const VLCTable *t)
{
    uint32_t code = 0;
    for (int len = 1; len <= 16; len++) {
        code = (code << 1) | get_bits1(gb);
        for (int i = 0; i < t->count; i++)
            if (t->len[i] == len && t->code[i] == code)
                return t->symbol[i];
    }
    return 0; /* invalid code; FFmpeg's table returns 0 here too */
}

/* ---- atrac.c ---- */

typedef struct AtracGainInfo {
    int num_points;
    int lev_code[7];
    int loc_code[7];
} AtracGainInfo;

typedef struct AtracGCContext {
    float gain_tab1[16];
    float gain_tab2[31];
    int id2exp_offset;
    int loc_scale;
    int loc_size;
} AtracGCContext;

static float ff_atrac_sf_table[64];
static float qmf_window[48];

static const float qmf_48tap_half[24] = {
   -0.00001461907, -0.00009205479,-0.000056157569,0.00030117269,
    0.0002422519,  -0.00085293897,-0.0005205574,  0.0020340169,
    0.00078333891, -0.0042153862, -0.00075614988, 0.0078402944,
   -0.000061169922,-0.01344162,    0.0024626821,  0.021736089,
   -0.007801671,   -0.034090221,   0.01880949,    0.054326009,
   -0.043596379,   -0.099384367,   0.13207909,    0.46424159
};

static void ff_atrac_generate_tables(void)
{
    for (int i = 0; i < 64; i++)
        ff_atrac_sf_table[i] = pow(2.0, (i - 15) / 3.0);
    for (int i = 0; i < 24; i++) {
        float s = qmf_48tap_half[i] * 2.0;
        qmf_window[i] = qmf_window[47 - i] = s;
    }
}

static void ff_atrac_init_gain_compensation(AtracGCContext *gctx, int id2exp_offset, int loc_scale)
{
    gctx->loc_scale     = loc_scale;
    gctx->loc_size      = 1 << loc_scale;
    gctx->id2exp_offset = id2exp_offset;
    for (int i = 0; i < 16; i++)
        gctx->gain_tab1[i] = powf(2.0, id2exp_offset - i);
    for (int i = -15; i < 16; i++)
        gctx->gain_tab2[i + 15] = powf(2.0, -1.0f / gctx->loc_size * i);
}

static void ff_atrac_gain_compensation(AtracGCContext *gctx, float *in, float *prev,
                                       AtracGainInfo *gc_now, AtracGainInfo *gc_next,
                                       int num_samples, float *out)
{
    float lev, gc_scale, gain_inc;
    int i, pos, lastpos;

    gc_scale = gc_next->num_points ? gctx->gain_tab1[gc_next->lev_code[0]] : 1.0f;

    if (!gc_now->num_points) {
        for (pos = 0; pos < num_samples; pos++)
            out[pos] = in[pos] * gc_scale + prev[pos];
    } else {
        pos = 0;
        for (i = 0; i < gc_now->num_points; i++) {
            lastpos = gc_now->loc_code[i] << gctx->loc_scale;
            lev = gctx->gain_tab1[gc_now->lev_code[i]];
            gain_inc = gctx->gain_tab2[(i + 1 < gc_now->num_points ? gc_now->lev_code[i + 1]
                                                                   : gctx->id2exp_offset) -
                                       gc_now->lev_code[i] + 15];
            for (; pos < lastpos; pos++)
                out[pos] = (in[pos] * gc_scale + prev[pos]) * lev;
            for (; pos < lastpos + gctx->loc_size; pos++) {
                out[pos] = (in[pos] * gc_scale + prev[pos]) * lev;
                lev *= gain_inc;
            }
        }
        for (; pos < num_samples; pos++)
            out[pos] = in[pos] * gc_scale + prev[pos];
    }
    memcpy(prev, &in[num_samples], num_samples * sizeof(float));
}

static void ff_atrac_iqmf(float *inlo, float *inhi, unsigned int nIn, float *pOut,
                          float *delayBuf, float *temp)
{
    unsigned i, j;
    float *p1, *p3;

    memcpy(temp, delayBuf, 46 * sizeof(float));
    p3 = temp + 46;
    for (i = 0; i < nIn; i += 2) {
        p3[2*i+0] = inlo[i  ] + inhi[i  ];
        p3[2*i+1] = inlo[i  ] - inhi[i  ];
        p3[2*i+2] = inlo[i+1] + inhi[i+1];
        p3[2*i+3] = inlo[i+1] - inhi[i+1];
    }
    p1 = temp;
    for (j = nIn; j != 0; j--) {
        float s1 = 0.0, s2 = 0.0;
        for (i = 0; i < 48; i += 2) {
            s1 += p1[i] * qmf_window[i];
            s2 += p1[i+1] * qmf_window[i+1];
        }
        pOut[0] = s2;
        pOut[1] = s1;
        p1 += 2;
        pOut += 2;
    }
    memcpy(delayBuf, temp + nIn * 2, 46 * sizeof(float));
}

/* ---- atrac3.c ---- */

typedef struct GainBlock {
    AtracGainInfo g_block[4];
} GainBlock;

typedef struct TonalComponent {
    int pos;
    int num_coefs;
    float coef[8];
} TonalComponent;

typedef struct ChannelUnit {
    int            bands_coded;
    int            num_components;
    float          prev_frame[SAMPLES_PER_FRAME];
    int            gc_blk_switch;
    TonalComponent components[64];
    GainBlock      gain_block[2];
    float          spectrum[SAMPLES_PER_FRAME];
    float          imdct_buf[SAMPLES_PER_FRAME];
    float          delay_buf1[46];
    float          delay_buf2[46];
    float          delay_buf3[46];
} ChannelUnit;

struct Atrac3Decoder {
    GetBitContext gb;
    int coding_mode;
    int channels;
    int block_align;
    ChannelUnit units[2];
    int matrix_coeff_index_prev[4];
    int matrix_coeff_index_now[4];
    int matrix_coeff_index_next[4];
    int weighting_delay[6];
    uint8_t decoded_bytes_buffer[4096 + 64];
    float temp_buf[1070];
    AtracGCContext gainc_ctx;
};

static float mdct_window[MDCT_SIZE];
/* Inverse MDCT as a 512 x 256 matrix (row-major): out = M * in, scaled by 1/32768. */
static float *imdct_matrix;
/* Tables are built once, thread-safely: several tracks may be decoded at the same time. */
static pthread_once_t static_once = PTHREAD_ONCE_INIT;

static void init_imdct_window(void)
{
    int i, j;
    for (i = 0, j = 255; i < 128; i++, j--) {
        float wi = sin(((i + 0.5) / 256.0 - 0.5) * M_PI) + 1.0;
        float wj = sin(((j + 0.5) / 256.0 - 0.5) * M_PI) + 1.0;
        float w  = 0.5 * (wi * wi + wj * wj);
        mdct_window[i] = mdct_window[511 - i] = wi / w;
        mdct_window[j] = mdct_window[511 - j] = wj / w;
    }
}

static void build_static_data(void)
{
    init_imdct_window();
    ff_atrac_generate_tables();

    const uint8_t (*hufftabs)[2] = atrac3_hufftabs;
    for (int i = 0; i < 7; i++) {
        vlc_init_from_lengths(&spectral_coeff_tab[i], huff_tab_sizes[i], hufftabs, -31);
        hufftabs += huff_tab_sizes[i];
    }

    /* Full inverse MDCT, N = 256 coefficients -> 512 samples:
     * out[n] = scale * sum_k in[k] * cos(pi/N * (n + 0.5 + N/2) * (k + 0.5)). The sign and scale
     * convention matching FFmpeg's av_tx AV_TX_FULL_IMDCT is checked against FFmpeg's output. */
    const int N = 256;
    const double scale = -1.0 / 32768.0;
    imdct_matrix = malloc(sizeof(float) * 2 * N * N);
    for (int n = 0; n < 2 * N; n++)
        for (int k = 0; k < N; k++)
            imdct_matrix[n * N + k] = (float)(scale * cos(M_PI / N * (n + 0.5 + N / 2.0) * (k + 0.5)));
}

static void init_static_data(void)
{
    pthread_once(&static_once, build_static_data);
}

static void imlt(float *input, float *output, int odd_band)
{
    if (odd_band) {
        for (int i = 0; i < 128; i++)
            FFSWAP(float, input[i], input[255 - i]);
    }
    cblas_sgemv(CblasRowMajor, CblasNoTrans, 512, 256, 1.0f, imdct_matrix, 256, input, 1, 0.0f, output, 1);
    for (int i = 0; i < MDCT_SIZE; i++)
        output[i] *= mdct_window[i];
}

static void read_quant_spectral_coeffs(GetBitContext *gb, int selector, int coding_flag,
                                       int *mantissas, int num_codes)
{
    int i, code, huff_symb;

    if (selector == 1)
        num_codes /= 2;

    if (coding_flag != 0) {
        int num_bits = clc_length_tab[selector];
        if (selector > 1) {
            for (i = 0; i < num_codes; i++) {
                code = num_bits ? get_sbits(gb, num_bits) : 0;
                mantissas[i] = code;
            }
        } else {
            for (i = 0; i < num_codes; i++) {
                code = num_bits ? (int)get_bits(gb, num_bits) : 0;
                mantissas[i * 2    ] = mantissa_clc_tab[code >> 2];
                mantissas[i * 2 + 1] = mantissa_clc_tab[code &  3];
            }
        }
    } else {
        if (selector != 1) {
            for (i = 0; i < num_codes; i++)
                mantissas[i] = get_vlc(gb, &spectral_coeff_tab[selector - 1]);
        } else {
            for (i = 0; i < num_codes; i++) {
                huff_symb = get_vlc(gb, &spectral_coeff_tab[selector - 1]);
                if (huff_symb < 0 || huff_symb > 8) huff_symb = 0;
                mantissas[i * 2    ] = mantissa_vlc_tab[huff_symb * 2    ];
                mantissas[i * 2 + 1] = mantissa_vlc_tab[huff_symb * 2 + 1];
            }
        }
    }
}

static int decode_spectrum(GetBitContext *gb, float *output)
{
    int num_subbands, coding_mode, i, j, first, last, subband_size;
    int subband_vlc_index[32], sf_index[32];
    int mantissas[128];
    float scale_factor;

    num_subbands = get_bits(gb, 5);
    coding_mode  = get_bits1(gb);

    for (i = 0; i <= num_subbands; i++)
        subband_vlc_index[i] = get_bits(gb, 3);

    for (i = 0; i <= num_subbands; i++) {
        if (subband_vlc_index[i] != 0)
            sf_index[i] = get_bits(gb, 6);
    }

    for (i = 0; i <= num_subbands; i++) {
        first = subband_tab[i    ];
        last  = subband_tab[i + 1];
        subband_size = last - first;

        if (subband_vlc_index[i] != 0) {
            read_quant_spectral_coeffs(gb, subband_vlc_index[i], coding_mode, mantissas, subband_size);
            scale_factor = ff_atrac_sf_table[sf_index[i]] * inv_max_quant[subband_vlc_index[i]];
            for (j = 0; first < last; first++, j++)
                output[first] = mantissas[j] * scale_factor;
        } else {
            memset(output + first, 0, subband_size * sizeof(*output));
        }
    }

    first = subband_tab[i];
    memset(output + first, 0, (SAMPLES_PER_FRAME - first) * sizeof(*output));
    return num_subbands;
}

static int decode_tonal_components(GetBitContext *gb, TonalComponent *components, int num_bands)
{
    int i, b, c, m;
    int nb_components, coding_mode_selector, coding_mode;
    int band_flags[4], mantissa[8];
    int component_count = 0;

    nb_components = get_bits(gb, 5);
    if (nb_components == 0)
        return 0;

    coding_mode_selector = get_bits(gb, 2);
    if (coding_mode_selector == 2)
        return AVERROR_INVALIDDATA;

    coding_mode = coding_mode_selector & 1;

    for (i = 0; i < nb_components; i++) {
        int coded_values_per_component, quant_step_index;

        for (b = 0; b <= num_bands; b++)
            band_flags[b] = get_bits1(gb);

        coded_values_per_component = get_bits(gb, 3);

        quant_step_index = get_bits(gb, 3);
        if (quant_step_index <= 1)
            return AVERROR_INVALIDDATA;

        if (coding_mode_selector == 3)
            coding_mode = get_bits1(gb);

        for (b = 0; b < (num_bands + 1) * 4; b++) {
            int coded_components;

            if (band_flags[b >> 2] == 0)
                continue;

            coded_components = get_bits(gb, 3);

            for (c = 0; c < coded_components; c++) {
                TonalComponent *cmp = &components[component_count];
                int sf_index, coded_values, max_coded_values;
                float scale_factor;

                sf_index = get_bits(gb, 6);
                if (component_count >= 64)
                    return AVERROR_INVALIDDATA;

                cmp->pos = b * 64 + get_bits(gb, 6);

                max_coded_values = SAMPLES_PER_FRAME - cmp->pos;
                coded_values     = coded_values_per_component + 1;
                coded_values     = FFMIN(max_coded_values, coded_values);

                scale_factor = ff_atrac_sf_table[sf_index] * inv_max_quant[quant_step_index];

                read_quant_spectral_coeffs(gb, quant_step_index, coding_mode, mantissa, coded_values);

                cmp->num_coefs = coded_values;
                for (m = 0; m < coded_values; m++)
                    cmp->coef[m] = mantissa[m] * scale_factor;

                component_count++;
            }
        }
    }

    return component_count;
}

static int decode_gain_control(GetBitContext *gb, GainBlock *block, int num_bands)
{
    int b, j;
    int *level, *loc;
    AtracGainInfo *gain = block->g_block;

    for (b = 0; b <= num_bands; b++) {
        gain[b].num_points = get_bits(gb, 3);
        level              = gain[b].lev_code;
        loc                = gain[b].loc_code;

        for (j = 0; j < gain[b].num_points; j++) {
            level[j] = get_bits(gb, 4);
            loc[j]   = get_bits(gb, 5);
            if (j && loc[j] <= loc[j - 1])
                return AVERROR_INVALIDDATA;
        }
    }

    for (; b < 4 ; b++)
        gain[b].num_points = 0;

    return 0;
}

static int add_tonal_components(float *spectrum, int num_components, TonalComponent *components)
{
    int i, j, last_pos = -1;
    float *input, *output;

    for (i = 0; i < num_components; i++) {
        last_pos = FFMAX(components[i].pos + components[i].num_coefs, last_pos);
        input    = components[i].coef;
        output   = &spectrum[components[i].pos];
        for (j = 0; j < components[i].num_coefs; j++)
            output[j] += input[j];
    }

    return last_pos;
}

#define INTERPOLATE(old, new, nsample) \
    ((old) + (nsample) * 0.125 * ((new) - (old)))

static void reverse_matrixing(float *su1, float *su2, int *prev_code, int *curr_code)
{
    int i, nsample, band;
    float mc1_l, mc1_r, mc2_l, mc2_r;

    for (i = 0, band = 0; band < 4 * 256; band += 256, i++) {
        int s1 = prev_code[i];
        int s2 = curr_code[i];
        nsample = band;

        if (s1 != s2) {
            mc1_l = matrix_coeffs[s1 * 2    ];
            mc1_r = matrix_coeffs[s1 * 2 + 1];
            mc2_l = matrix_coeffs[s2 * 2    ];
            mc2_r = matrix_coeffs[s2 * 2 + 1];

            for (; nsample < band + 8; nsample++) {
                float c1 = su1[nsample];
                float c2 = su2[nsample];
                c2 = c1 * INTERPOLATE(mc1_l, mc2_l, nsample - band) +
                     c2 * INTERPOLATE(mc1_r, mc2_r, nsample - band);
                su1[nsample] = c2;
                su2[nsample] = c1 * 2.0 - c2;
            }
        }

        switch (s2) {
        case 0:
            for (; nsample < band + 256; nsample++) {
                float c1 = su1[nsample];
                float c2 = su2[nsample];
                su1[nsample] =  c2       * 2.0;
                su2[nsample] = (c1 - c2) * 2.0;
            }
            break;
        case 1:
            for (; nsample < band + 256; nsample++) {
                float c1 = su1[nsample];
                float c2 = su2[nsample];
                su1[nsample] = (c1 + c2) *  2.0;
                su2[nsample] =  c2       * -2.0;
            }
            break;
        default:
            for (; nsample < band + 256; nsample++) {
                float c1 = su1[nsample];
                float c2 = su2[nsample];
                su1[nsample] = c1 + c2;
                su2[nsample] = c1 - c2;
            }
            break;
        }
    }
}

static void get_channel_weights(int index, int flag, float ch[2])
{
    if (index == 7) {
        ch[0] = 1.0;
        ch[1] = 1.0;
    } else {
        ch[0] = (index & 7) / 7.0;
        ch[1] = sqrt(2 - ch[0] * ch[0]);
        if (flag)
            FFSWAP(float, ch[0], ch[1]);
    }
}

static void channel_weighting(float *su1, float *su2, int *p3)
{
    int band, nsample;
    float w[2][2];

    if (p3[1] != 7 || p3[3] != 7) {
        get_channel_weights(p3[1], p3[0], w[0]);
        get_channel_weights(p3[3], p3[2], w[1]);

        for (band = 256; band < 4 * 256; band += 256) {
            for (nsample = band; nsample < band + 8; nsample++) {
                su1[nsample] *= INTERPOLATE(w[0][0], w[0][1], nsample - band);
                su2[nsample] *= INTERPOLATE(w[1][0], w[1][1], nsample - band);
            }
            for (; nsample < band + 256; nsample++) {
                su1[nsample] *= w[1][0];
                su2[nsample] *= w[1][1];
            }
        }
    }
}

static int decode_channel_sound_unit(Atrac3Decoder *q, GetBitContext *gb, ChannelUnit *snd,
                                     float *output, int channel_num, int coding_mode)
{
    int band, ret, num_subbands, last_tonal, num_bands;
    GainBlock *gain1 = &snd->gain_block[    snd->gc_blk_switch];
    GainBlock *gain2 = &snd->gain_block[1 - snd->gc_blk_switch];

    if (coding_mode == JOINT_STEREO && (channel_num % 2) == 1) {
        if (get_bits(gb, 2) != 3)
            return AVERROR_INVALIDDATA;
    } else {
        if (get_bits(gb, 6) != 0x28)
            return AVERROR_INVALIDDATA;
    }

    snd->bands_coded = get_bits(gb, 2);

    ret = decode_gain_control(gb, gain2, snd->bands_coded);
    if (ret)
        return ret;

    snd->num_components = decode_tonal_components(gb, snd->components, snd->bands_coded);
    if (snd->num_components < 0)
        return snd->num_components;

    num_subbands = decode_spectrum(gb, snd->spectrum);

    last_tonal = add_tonal_components(snd->spectrum, snd->num_components, snd->components);

    num_bands = (subband_tab[num_subbands] - 1) >> 8;
    if (last_tonal >= 0)
        num_bands = FFMAX((last_tonal + 256) >> 8, num_bands);

    for (band = 0; band < 4; band++) {
        if (band <= num_bands)
            imlt(&snd->spectrum[band * 256], snd->imdct_buf, band & 1);
        else
            memset(snd->imdct_buf, 0, 512 * sizeof(*snd->imdct_buf));

        ff_atrac_gain_compensation(&q->gainc_ctx, snd->imdct_buf, &snd->prev_frame[band * 256],
                                   &gain1->g_block[band], &gain2->g_block[band], 256, &output[band * 256]);
    }

    snd->gc_blk_switch ^= 1;
    return 0;
}

static int decode_frame(Atrac3Decoder *q, const uint8_t *databuf, float **out_samples)
{
    int ret, i, ch;
    uint8_t *ptr1;
    int channels = q->channels;

    if (q->coding_mode == JOINT_STEREO) {
        const uint8_t *js_databuf = databuf;
        int js_block_align = (q->block_align / channels) * 2;
        ch = 0;

        init_get_bits(&q->gb, js_databuf, js_block_align * 8);

        ret = decode_channel_sound_unit(q, &q->gb, &q->units[ch], out_samples[ch], ch, JOINT_STEREO);
        if (ret != 0)
            return ret;

        /* The second sound unit is stored in reverse byte order. */
        const uint8_t *ptr2 = js_databuf + js_block_align - 1;
        for (i = 0; i < js_block_align; i++)
            q->decoded_bytes_buffer[i] = *ptr2--;

        /* Skip the sync codes (0xF8). */
        ptr1 = q->decoded_bytes_buffer;
        for (i = 4; *ptr1 == 0xF8; i++, ptr1++) {
            if (i >= js_block_align)
                return AVERROR_INVALIDDATA;
        }

        ret = init_get_bits8(&q->gb, ptr1, (int)(q->decoded_bytes_buffer + js_block_align - ptr1));
        if (ret < 0)
            return ret;

        memmove(q->weighting_delay, &q->weighting_delay[2], 4 * sizeof(*q->weighting_delay));
        q->weighting_delay[4] = get_bits1(&q->gb);
        q->weighting_delay[5] = get_bits(&q->gb, 3);

        for (i = 0; i < 4; i++) {
            q->matrix_coeff_index_prev[i] = q->matrix_coeff_index_now[i];
            q->matrix_coeff_index_now[i]  = q->matrix_coeff_index_next[i];
            q->matrix_coeff_index_next[i] = get_bits(&q->gb, 2);
        }

        ret = decode_channel_sound_unit(q, &q->gb, &q->units[ch + 1], out_samples[ch + 1], ch + 1, JOINT_STEREO);
        if (ret != 0)
            return ret;

        reverse_matrixing(out_samples[ch], out_samples[ch + 1], q->matrix_coeff_index_prev, q->matrix_coeff_index_now);
        channel_weighting(out_samples[ch], out_samples[ch + 1], q->weighting_delay);
    } else {
        for (i = 0; i < channels; i++) {
            init_get_bits(&q->gb, databuf + i * q->block_align / channels, q->block_align * 8 / channels);
            ret = decode_channel_sound_unit(q, &q->gb, &q->units[i], out_samples[i], i, q->coding_mode);
            if (ret != 0)
                return ret;
        }
    }

    for (i = 0; i < channels; i++) {
        float *p1 = out_samples[i];
        float *p2 = p1 + 256;
        float *p3 = p2 + 256;
        float *p4 = p3 + 256;
        ff_atrac_iqmf(p1, p2, 256, p1, q->units[i].delay_buf1, q->temp_buf);
        ff_atrac_iqmf(p4, p3, 256, p3, q->units[i].delay_buf2, q->temp_buf);
        ff_atrac_iqmf(p1, p3, 512, p1, q->units[i].delay_buf3, q->temp_buf);
    }

    return 0;
}

/* ---- Public API ---- */

Atrac3Decoder *atrac3_decoder_create(int block_align, int joint_stereo)
{
    if (block_align <= 0 || block_align > 4096) return NULL;
    init_static_data();
    Atrac3Decoder *q = calloc(1, sizeof(Atrac3Decoder));
    if (!q) return NULL;
    q->channels = 2;
    q->block_align = block_align;
    q->coding_mode = joint_stereo ? JOINT_STEREO : SINGLE;
    q->weighting_delay[0] = 0;
    q->weighting_delay[1] = 7;
    q->weighting_delay[2] = 0;
    q->weighting_delay[3] = 7;
    q->weighting_delay[4] = 0;
    q->weighting_delay[5] = 7;
    for (int i = 0; i < 4; i++) {
        q->matrix_coeff_index_prev[i] = 3;
        q->matrix_coeff_index_now[i]  = 3;
        q->matrix_coeff_index_next[i] = 3;
    }
    ff_atrac_init_gain_compensation(&q->gainc_ctx, 4, 3);
    return q;
}

void atrac3_decoder_free(Atrac3Decoder *decoder)
{
    free(decoder);
}

int atrac3_decode_frame(Atrac3Decoder *decoder, const uint8_t *frame, float *left, float *right)
{
    float *out[2] = { left, right };
    int ret = decode_frame(decoder, frame, out);
    if (ret) {
        memset(left, 0, SAMPLES_PER_FRAME * sizeof(float));
        memset(right, 0, SAMPLES_PER_FRAME * sizeof(float));
    }
    return ret;
}

/* ======================================================================================
 * ATRAC1 (SP), ported from FFmpeg 7.1 libavcodec/atrac1.c
 * Copyright (c) 2009 Maxim Poliakovski
 * Copyright (c) 2009 Benjamin Larsson
 * ====================================================================================== */

#include "atrac1data.h"

#define AT1_MAX_BFU      52
#define AT1_SU_SIZE      212
#define AT1_SU_SAMPLES   512
#define AT1_SU_MAX_BITS  AT1_SU_SIZE * 8
#define AT1_MAX_CHANNELS 2
#define AT1_QMF_BANDS    3
#define IDX_HIGH_BAND    2

typedef struct AT1SUCtx {
    int    log2_block_count[AT1_QMF_BANDS];
    int    num_bfus;
    float *spectrum[2];
    float  spec1[AT1_SU_SAMPLES];
    float  spec2[AT1_SU_SAMPLES];
    float  fst_qmf_delay[46];
    float  snd_qmf_delay[46];
    float  last_qmf_delay[256 + 39];
} AT1SUCtx;

struct Atrac1Decoder {
    AT1SUCtx SUs[AT1_MAX_CHANNELS];
    float spec[AT1_SU_SAMPLES];
    float low[256];
    float mid[256];
    float high[512];
    float *bands[3];
    int channels;
};

static const uint16_t samples_per_band[3] = {128, 128, 256};
static const uint8_t   mdct_long_nbits[3] = {7, 7, 8};

static float ff_sine_32[32];
/* Half inverse MDCTs (N coefficients -> the middle N samples) for N = 32, 128, 256. */
static float *at1_imdct_matrix[3];
static pthread_once_t at1_static_once = PTHREAD_ONCE_INIT;

static void at1_build_static_data(void)
{
    init_static_data(); /* sf table, QMF window */
    for (int i = 0; i < 32; i++)
        ff_sine_32[i] = sinf((i + 0.5) * (M_PI / (2.0 * 32)));
    const int sizes[3] = {32, 128, 256};
    /* FFmpeg uses scale -1/32768 with its av_tx convention, which is the opposite sign of the
     * formula here (see the ATRAC3 matrix above). */
    const double scale = 1.0 / 32768.0;
    for (int m = 0; m < 3; m++) {
        int N = sizes[m];
        at1_imdct_matrix[m] = malloc(sizeof(float) * N * N);
        for (int n = 0; n < N; n++)
            for (int k = 0; k < N; k++)
                at1_imdct_matrix[m][n * N + k] =
                    (float)(scale * cos(M_PI / N * ((n + N / 2) + 0.5 + N / 2.0) * (k + 0.5)));
    }
}

static void at1_init_static_data(void)
{
    pthread_once(&at1_static_once, at1_build_static_data);
}

static void vector_fmul_window(float *dst, const float *src0, const float *src1, const float *win, int len)
{
    int i, j;
    dst  += len;
    win  += len;
    src0 += len;
    for (i = -len, j = len - 1; i < 0; i++, j--) {
        float s0 = src0[i];
        float s1 = src1[j];
        float wi = win[i];
        float wj = win[j];
        dst[i] = s0 * wj - s1 * wi;
        dst[j] = s0 * wi + s1 * wj;
    }
}

static void at1_imdct(float *spec, float *out, int nbits, int rev_spec)
{
    int index = nbits - 5 - (nbits > 6);
    int transf_size = 1 << nbits;

    if (rev_spec) {
        for (int i = 0; i < transf_size / 2; i++)
            FFSWAP(float, spec[i], spec[transf_size - 1 - i]);
    }
    cblas_sgemv(CblasRowMajor, CblasNoTrans, transf_size, transf_size, 1.0f, at1_imdct_matrix[index],
                transf_size, spec, 1, 0.0f, out, 1);
}

static int at1_imdct_block(AT1SUCtx *su, Atrac1Decoder *q)
{
    int band_num, band_samples, log2_block_count, nbits, num_blocks, block_size;
    unsigned int start_pos, ref_pos = 0, pos = 0;

    for (band_num = 0; band_num < AT1_QMF_BANDS; band_num++) {
        float *prev_buf;
        int j;

        band_samples = samples_per_band[band_num];
        log2_block_count = su->log2_block_count[band_num];
        num_blocks = 1 << log2_block_count;

        if (num_blocks == 1) {
            block_size = band_samples >> log2_block_count;
            nbits = mdct_long_nbits[band_num] - log2_block_count;
            if (nbits != 5 && nbits != 7 && nbits != 8)
                return AVERROR_INVALIDDATA;
        } else {
            block_size = 32;
            nbits = 5;
        }

        start_pos = 0;
        prev_buf = &su->spectrum[1][ref_pos + band_samples - 16];
        for (j = 0; j < num_blocks; j++) {
            at1_imdct(&q->spec[pos], &su->spectrum[0][ref_pos + start_pos], nbits, band_num);
            vector_fmul_window(&q->bands[band_num][start_pos], prev_buf,
                               &su->spectrum[0][ref_pos + start_pos], ff_sine_32, 16);
            prev_buf = &su->spectrum[0][ref_pos + start_pos + 16];
            start_pos += block_size;
            pos += block_size;
        }

        if (num_blocks == 1)
            memcpy(q->bands[band_num] + 32, &su->spectrum[0][ref_pos + 16], 240 * sizeof(float));

        ref_pos += band_samples;
    }

    FFSWAP(float *, su->spectrum[0], su->spectrum[1]);
    return 0;
}

static int at1_parse_bsm(GetBitContext *gb, int log2_block_cnt[AT1_QMF_BANDS])
{
    int log2_block_count_tmp, i;

    for (i = 0; i < 2; i++) {
        log2_block_count_tmp = get_bits(gb, 2);
        if (log2_block_count_tmp & 1)
            return AVERROR_INVALIDDATA;
        log2_block_cnt[i] = 2 - log2_block_count_tmp;
    }

    log2_block_count_tmp = get_bits(gb, 2);
    if (log2_block_count_tmp != 0 && log2_block_count_tmp != 3)
        return AVERROR_INVALIDDATA;
    log2_block_cnt[IDX_HIGH_BAND] = 3 - log2_block_count_tmp;

    get_bits(gb, 2); /* skip */
    return 0;
}

static int at1_unpack_dequant(GetBitContext *gb, AT1SUCtx *su, float spec[AT1_SU_SAMPLES])
{
    int bits_used, band_num, bfu_num, i;
    uint8_t idwls[AT1_MAX_BFU];
    uint8_t idsfs[AT1_MAX_BFU];

    su->num_bfus = bfu_amount_tab1[get_bits(gb, 3)];

    bits_used = su->num_bfus * 10 + 32 +
                bfu_amount_tab2[get_bits(gb, 2)] +
                (bfu_amount_tab3[get_bits(gb, 3)] << 1);

    for (i = 0; i < su->num_bfus; i++)
        idwls[i] = get_bits(gb, 4);

    for (i = 0; i < su->num_bfus; i++)
        idsfs[i] = get_bits(gb, 6);

    for (i = su->num_bfus; i < AT1_MAX_BFU; i++)
        idwls[i] = idsfs[i] = 0;

    for (band_num = 0; band_num < AT1_QMF_BANDS; band_num++) {
        for (bfu_num = bfu_bands_t[band_num]; bfu_num < bfu_bands_t[band_num + 1]; bfu_num++) {
            int pos;
            int num_specs = specs_per_bfu[bfu_num];
            int word_len  = !!idwls[bfu_num] + idwls[bfu_num];
            float scale_factor = ff_atrac_sf_table[idsfs[bfu_num]];
            bits_used += word_len * num_specs;

            if (bits_used > AT1_SU_MAX_BITS)
                return AVERROR_INVALIDDATA;

            pos = su->log2_block_count[band_num] ? bfu_start_short[bfu_num] : bfu_start_long[bfu_num];

            if (word_len) {
                float max_quant = 1.0 / (float)((1 << (word_len - 1)) - 1);
                for (i = 0; i < num_specs; i++)
                    spec[pos + i] = get_sbits(gb, word_len) * scale_factor * max_quant;
            } else {
                memset(&spec[pos], 0, num_specs * sizeof(float));
            }
        }
    }

    return 0;
}

static void at1_subband_synthesis(Atrac1Decoder *q, AT1SUCtx *su, float *pOut)
{
    float temp[256];
    float iqmf_temp[512 + 46];

    ff_atrac_iqmf(q->bands[0], q->bands[1], 128, temp, su->fst_qmf_delay, iqmf_temp);

    memcpy( su->last_qmf_delay,    &su->last_qmf_delay[256], sizeof(float) *  39);
    memcpy(&su->last_qmf_delay[39], q->bands[2],             sizeof(float) * 256);

    ff_atrac_iqmf(temp, su->last_qmf_delay, 256, pOut, su->snd_qmf_delay, iqmf_temp);
}

Atrac1Decoder *atrac1_decoder_create(int channels)
{
    if (channels < 1 || channels > AT1_MAX_CHANNELS) return NULL;
    at1_init_static_data();
    Atrac1Decoder *q = calloc(1, sizeof(Atrac1Decoder));
    if (!q) return NULL;
    q->channels = channels;
    q->bands[0] = q->low;
    q->bands[1] = q->mid;
    q->bands[2] = q->high;
    for (int ch = 0; ch < AT1_MAX_CHANNELS; ch++) {
        q->SUs[ch].spectrum[0] = q->SUs[ch].spec1;
        q->SUs[ch].spectrum[1] = q->SUs[ch].spec2;
    }
    return q;
}

void atrac1_decoder_free(Atrac1Decoder *decoder)
{
    free(decoder);
}

int atrac1_decode_frame(Atrac1Decoder *q, const uint8_t *frame, float *left, float *right)
{
    float *out[2] = { left, right };
    for (int ch = 0; ch < q->channels; ch++) {
        AT1SUCtx *su = &q->SUs[ch];
        GetBitContext gb;
        int ret;

        init_get_bits(&gb, &frame[212 * ch], 212 * 8);
        if ((ret = at1_parse_bsm(&gb, su->log2_block_count)) < 0 ||
            (ret = at1_unpack_dequant(&gb, su, q->spec)) < 0 ||
            (ret = at1_imdct_block(su, q)) < 0) {
            for (int c = 0; c < q->channels; c++) memset(out[c], 0, AT1_SU_SAMPLES * sizeof(float));
            return ret;
        }
        at1_subband_synthesis(q, su, out[ch]);
    }
    return 0;
}
