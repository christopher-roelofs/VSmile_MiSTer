// SPDX-License-Identifier: GPL-2.0-or-later
#include "cheshire/rom.hpp"
#include <algorithm>
#include <bit>
#include <fstream>
#include <stdexcept>

namespace cheshire {
Rom Rom::load(const std::filesystem::path& path, std::size_t max_bytes) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) throw std::runtime_error("Cannot open ROM: " + path.string());
    const auto end = file.tellg();
    if (end <= 0 || std::uint64_t(end) > max_bytes || (std::uint64_t(end) & 1))
        throw std::runtime_error("ROM must have a nonzero even byte size within the supported limit");
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(end));
    file.seekg(0);
    if (!file.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())))
        throw std::runtime_error("Cannot read ROM: " + path.string());
    return from_bytes(bytes, max_bytes);
}
Rom Rom::from_bytes(std::span<const std::uint8_t> bytes, std::size_t max_bytes) {
    if (bytes.empty() || bytes.size() > max_bytes || (bytes.size() & 1))
        throw std::runtime_error("ROM must have a nonzero even byte size within the supported limit");
    Rom result;
    result.byte_size_ = bytes.size();
    result.words_.assign(std::bit_ceil(bytes.size() / 2), 0xffff);
    for (std::size_t i = 0; i < bytes.size(); i += 2)
        result.words_[i / 2] = std::uint16_t(bytes[i] | (std::uint16_t(bytes[i + 1]) << 8));
    return result;
}
std::uint16_t Rom::read(std::uint32_t address) const {
    return words_.empty() ? 0xffff : words_[address & (words_.size() - 1)];
}
bool Rom::contains_word_string(std::string_view text) const {
    std::vector<std::uint16_t> pattern;
    for (const unsigned char c : text) pattern.push_back(c);
    const auto end = words_.begin() + static_cast<std::ptrdiff_t>(byte_size_ / 2);
    return std::search(words_.begin(), end, pattern.begin(), pattern.end()) != end;
}
CartridgeInfo Rom::identify() const {
    CartridgeInfo info;
    const auto vector = read(0xfff7);
    info.baby = byte_size_ >= 0x1fff0 && vector >= 0x4000 && vector < 0x8000;
    info.motion = contains_word_string("V.Smile\\084");
    if (contains_word_string("QRwklSfghjio")) {
        info.peripheral = Peripheral::keyboard;
        if (contains_word_string("8091444")) info.keyboard_layout = 0x44;
        else if (contains_word_string("8091445")) info.keyboard_layout = 0x42;
    } else if (contains_word_string("809132")) info.peripheral = Peripheral::mat;
    else if (contains_word_string("80670")) { info.peripheral = Peripheral::tablet; info.nvram = true; }
    return info;
}
std::string_view system_name(System s) {
    switch (s) {
    case System::automatic: return "Auto"; case System::vsmile: return "V.Smile";
    case System::motion: return "V.Smile Motion"; case System::baby: return "V.Smile Baby";
    }
    return "Unknown";
}
}
