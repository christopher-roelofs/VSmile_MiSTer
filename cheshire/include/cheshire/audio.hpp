// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <filesystem>
#include <fstream>

namespace cheshire {
// 16-bit stereo PCM WAV at the SPU's integer-rounded 70,313 Hz.
class WavWriter {
public:
    static constexpr std::uint32_t rate = 70313;
    explicit WavWriter(const std::filesystem::path& path);
    WavWriter(const WavWriter&) = delete;
    WavWriter& operator=(const WavWriter&) = delete;
    ~WavWriter();
    void write(std::int16_t left, std::int16_t right);
    void finish();
private:
    std::ofstream file_;
    std::uint32_t frames_ = 0;
    bool finished_ = false;
    void header();
};
}
