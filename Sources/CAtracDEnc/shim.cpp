// SwiftMD - in-memory front end for atracdenc's ATRAC3 encoder, replacing its
// WAV reader and OMA writer (src/main.cpp in atracdenc).

#include "atracdenc_shim.h"

#include <cstring>
#include <stdexcept>
#include <vector>

#include "atracdenc/atrac3denc.h"

using namespace NAtracDEnc;

namespace {

constexpr int kChannels = 2;

class TMemoryPCMReader : public IPCMReader<TFloat> {
    const float *Samples;
    const uint64_t Frames;
    mutable uint64_t Position = 0;
public:
    TMemoryPCMReader(const float *samples, uint64_t frames) : Samples(samples), Frames(frames) {}

    void Read(TPCMBuffer<TFloat> &data, const uint32_t size) const override {
        for (uint32_t i = 0; i < size; i++, Position++) {
            for (int ch = 0; ch < kChannels; ch++) {
                // Past the end, pad the last frame with silence.
                data[i][ch] = Position < Frames ? Samples[Position * kChannels + ch] : 0.0;
            }
        }
    }
};

class TMemoryCompressedOutput : public ICompressedIO {
public:
    std::vector<uint8_t> Data;
    size_t FrameSize = 0;

    void WriteFrame(std::vector<char> frame) override {
        FrameSize = frame.size();
        Data.insert(Data.end(), frame.begin(), frame.end());
    }
    std::unique_ptr<TFrame> ReadFrame() override { throw std::runtime_error("write-only"); }
    std::string GetName() const override { return "SwiftMD"; }
    uint8_t GetChannelNum() const override { return kChannels; }
    uint64_t GetLengthInSamples() const override { return 0; }
};

} // namespace

extern "C" int atracdenc_encode_atrac3(const float *pcm, uint64_t frames, uint32_t bitrateKbps,
                                       uint8_t **out, size_t *outLength, size_t *frameSize) {
    try {
        auto *output = new TMemoryCompressedOutput();
        TCompressedIOPtr outputPtr(output);
        NAtrac3::TAtrac3EncoderSettings settings(bitrateKbps * 1024, false, false, kChannels, 0);
        TAtrac3Processor processor(std::move(outputPtr), std::move(settings));
        TPCMEngine<TFloat> engine(4096, kChannels,
                                  TPCMEngine<TFloat>::TReaderPtr(new TMemoryPCMReader(pcm, frames)));
        auto lambda = processor.GetEncodeLambda();
        while (engine.ApplyProcess(NAtrac3::TAtrac3Data::NumSamples, lambda) < frames) {
        }

        *outLength = output->Data.size();
        *frameSize = output->FrameSize;
        *out = static_cast<uint8_t *>(malloc(*outLength));
        if (!*out) return 2;
        memcpy(*out, output->Data.data(), *outLength);
        return 0;
    } catch (...) {
        return 1;
    }
}

extern "C" void atracdenc_free(uint8_t *buffer) { free(buffer); }
