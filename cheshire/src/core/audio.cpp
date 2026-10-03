// SPDX-License-Identifier: GPL-2.0-or-later
#include "cheshire/audio.hpp"
#include <array>
#include <stdexcept>

namespace cheshire {
namespace {
void put(std::ofstream& file, std::uint32_t value, unsigned bytes) {
    std::array<char, 4> data{};
    for (unsigned i = 0; i < bytes; ++i) data[i] = static_cast<char>((value >> (8 * i)) & 255);
    file.write(data.data(), bytes);
}
}
WavWriter::WavWriter(const std::filesystem::path& path) : file_(path, std::ios::binary | std::ios::trunc) {
    if (!file_) throw std::runtime_error("Cannot open WAV file");
    header();
}
WavWriter::~WavWriter() { try { finish(); } catch (...) {} }
void WavWriter::header() {
    const std::uint32_t data = frames_ * 4;
    file_.write("RIFF", 4); put(file_, 36 + data, 4); file_.write("WAVEfmt ", 8);
    put(file_, 16, 4); put(file_, 1, 2); put(file_, 2, 2); put(file_, rate, 4);
    put(file_, rate * 4, 4); put(file_, 4, 2); put(file_, 16, 2);
    file_.write("data", 4); put(file_, data, 4);
}
void WavWriter::write(std::int16_t left, std::int16_t right) {
    if (frames_ >= (0xffffffffu - 36) / 4) throw std::runtime_error("WAV file size limit reached");
    put(file_, std::uint16_t(left), 2); put(file_, std::uint16_t(right), 2);
    ++frames_;
}
void WavWriter::finish() {
    if (finished_) return;
    finished_ = true;
    file_.seekp(0); header(); file_.flush();
    if (!file_) throw std::runtime_error("Cannot write WAV file");
}
}
