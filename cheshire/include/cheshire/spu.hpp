// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <array>
#include <cstdint>
#include <functional>
#include "cheshire/state.hpp"

namespace cheshire {
// 16-channel SPG2xx wavetable unit at 0x3000-0x37ff, one stereo sample
// per 384 master ticks (70,312.5 Hz).
class Spu {
public:
    static constexpr unsigned ticks_per_sample = 384;
    using MemoryRead = std::function<std::uint16_t(std::uint32_t)>;
    using SampleSink = std::function<void(std::int16_t, std::int16_t)>;
    MemoryRead memory_read;
    SampleSink sample_sink;
    void reset(bool spg28x);
    std::uint16_t read(std::uint32_t address) const;
    void write(std::uint32_t address, std::uint16_t value);
    void tick();
    bool irq() const { return (ctrl_[beat_count] & 0xc000) == 0xc000; }
    bool fiq() const { return ctrl_[fiq_status] != 0; }
    std::uint64_t samples() const { return samples_; }
    std::uint16_t channel_status() const { return ctrl_[status]; }
    void serialize(StateArchive& archive);
private:
    enum : unsigned { enable = 0, main_volume = 1, fiq_enable = 2, fiq_status = 3, beat_base = 4, beat_count = 5,
        env_clock0 = 6, env_clock0_high = 7, env_clock1 = 8, env_clock1_high = 9, ramp_down = 10, stop = 11,
        control = 13, status = 15, wave_in_l = 16, wave_in_r = 17, env_mode = 21, tone_release = 22, env_irq = 23 };
    struct Channel {
        std::uint32_t accumulator = 0, env_clock = 0x4040404, ramp = 0, env_address = 0;
        unsigned shift = 0, adpcm_step = 0, adpcm36_remaining = 0;
        std::int32_t adpcm_signal = 0;
        std::uint16_t adpcm36_header = 0;
        std::int16_t adpcm36_previous = 0;
        bool fiq_timer = false;
    };
    std::array<std::uint16_t, 512> regs_{}, phase_{};
    std::array<std::uint16_t, 1024> misc_{};
    std::array<std::uint16_t, 32> ctrl_{};
    std::array<Channel, 16> channels_{};
    std::uint64_t samples_ = 0;
    unsigned beat_ = 0;
    bool spg28x_ = false;
    std::uint16_t& reg(unsigned ch, unsigned r) { return regs_[ch * 16 + r]; }
    std::uint32_t wave_address(unsigned ch) const;
    void set_wave_address(unsigned ch, std::uint32_t address);
    void start(std::uint16_t mask);
    void stop_channel(unsigned ch, bool set_stop_bit);
    void control_write(unsigned offset, std::uint16_t value);
    bool fetch(unsigned ch);
    void decode(unsigned ch, unsigned nibble);
    void envelope(unsigned ch);
    std::int32_t mix(unsigned ch, unsigned lerp);
};
}
