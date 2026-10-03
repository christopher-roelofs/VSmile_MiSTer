// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <filesystem>
#include <span>
#include <string_view>
#include <vector>

namespace cheshire {
enum class System { automatic, vsmile, motion, baby };
enum class Peripheral { joystick, keyboard, mat, tablet };
struct CartridgeInfo {
    bool baby = false, motion = false, nvram = false;
    Peripheral peripheral = Peripheral::joystick;
    std::uint8_t keyboard_layout = 0x40;
};
class Rom {
public:
    static Rom load(const std::filesystem::path& path, std::size_t max_bytes = 16 * 1024 * 1024);
    static Rom from_bytes(std::span<const std::uint8_t> bytes, std::size_t max_bytes = 16 * 1024 * 1024);
    std::uint16_t read(std::uint32_t address) const;
    const std::vector<std::uint16_t>& words() const { return words_; }
    std::size_t byte_size() const { return byte_size_; }
    bool contains_word_string(std::string_view text) const;
    CartridgeInfo identify() const;
private:
    std::vector<std::uint16_t> words_;
    std::size_t byte_size_ = 0;
};
std::string_view system_name(System system);
}
