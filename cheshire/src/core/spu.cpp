// SPDX-License-Identifier: GPL-2.0-or-later
// Sequential port of rtl/spg2xx/spg2xx_spu.sv (itself following MAME's
// spg2xx_audio_device). The FPGA engine and the CPU never run concurrently,
// so its queued start/stop/ramp-down commands are applied at the write.
#include "cheshire/spu.hpp"
#include <algorithm>
#include <stdexcept>

namespace cheshire {
namespace {
enum : unsigned { wave = 0, mode = 1, loop = 2, pan_volume = 3, env0 = 4, env_data = 5, env1 = 6,
    env_address_high = 7, env_address = 8, wave_previous = 9, env_loop = 10, wave_data = 11, adpcm_select = 13 };
enum : unsigned { phase_high = 0, ramp_clock = 3, phase_low = 4 };
constexpr std::array<std::uint16_t, 89> ima_steps = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};
std::uint32_t ramp_count(unsigned clock) {
    constexpr std::array<std::uint32_t, 8> counts = {52, 208, 832, 3328, 13312, 53248, 106496, 106496};
    return counts[clock & 7];
}
std::uint32_t envelope_count(unsigned clock) { return clock >= 11 ? 8192 : 4u << clock; }
}
void Spu::reset(bool spg28x) {
    regs_.fill(0); phase_.fill(0); misc_.fill(0); ctrl_.fill(0); channels_.fill({});
    ctrl_[20] = ctrl_[env_mode] = 0x3f;
    samples_ = 0; beat_ = 0; spg28x_ = spg28x;
}
std::uint32_t Spu::wave_address(unsigned ch) const {
    return std::uint32_t(regs_[ch * 16 + mode] & 63) << 16 | regs_[ch * 16 + wave];
}
void Spu::set_wave_address(unsigned ch, std::uint32_t address) {
    reg(ch, mode) = std::uint16_t((reg(ch, mode) & ~63) | ((address >> 16) & 63));
    reg(ch, wave) = std::uint16_t(address);
}
std::uint16_t Spu::read(std::uint32_t address) const {
    const unsigned offset = (address - 0x3000) & 0x7ff;
    if (offset < 0x200) return regs_[offset];
    if (offset < 0x400) return phase_[offset - 0x200];
    return offset & 0x3e0 ? misc_[offset & 0x3ff] : ctrl_[offset & 31];
}
void Spu::write(std::uint32_t address, std::uint16_t value) {
    const unsigned offset = (address - 0x3000) & 0x7ff;
    if (offset < 0x200) {
        if (offset < 0x100) switch (offset & 15) {
            case pan_volume: value &= 0x7f7f; break;
            case env_data: value &= 0xff7f; break;
            case adpcm_select: value &= 0xfe00; break;
            default: break;
        }
        regs_[offset] = value;
    } else if (offset < 0x400) {
        const unsigned r = offset & 15;
        if (offset < 0x300) {
            if (r < 4) value &= 7;
            if (r == phase_high || r == phase_low) channels_[(offset >> 4) & 15].accumulator = 0;
        }
        phase_[offset - 0x200] = value;
    } else if (offset & 0x3e0) misc_[offset & 0x3ff] = value;
    else control_write(offset & 31, value);
}
void Spu::start(std::uint16_t mask) {
    for (unsigned ch = 0; ch < 16; ++ch) {
        if (!(mask & (1u << ch))) continue;
        auto& c = channels_[ch];
        c.fiq_timer = ctrl_[fiq_enable] & (1u << ch);
        c.env_address = std::uint32_t(reg(ch, env_address_high) & 63) << 16 | reg(ch, env_address);
        c.adpcm_signal = 0; c.adpcm_step = 0; c.shift = 0;
        if (reg(ch, adpcm_select) & 0x8000) { c.adpcm36_remaining = 0; c.adpcm36_header = 0; c.adpcm36_previous = 0; }
        reg(ch, env_data) = std::uint16_t((reg(ch, env1) & 255) << 8 | (reg(ch, env_data) & 127));
    }
    ctrl_[status] |= mask;
}
void Spu::stop_channel(unsigned ch, bool set_stop_bit) {
    const auto bit = std::uint16_t(1u << ch);
    ctrl_[status] &= ~bit; ctrl_[tone_release] &= ~bit; ctrl_[ramp_down] &= ~bit;
    if (set_stop_bit) ctrl_[stop] |= bit;
    channels_[ch].fiq_timer = false;
    reg(ch, mode) &= 0x7fff;
}
void Spu::control_write(unsigned offset, std::uint16_t value) {
    auto& x = ctrl_[offset];
    switch (offset) {
    case enable: {
        const auto changed = std::uint16_t(x ^ value);
        const auto starting = std::uint16_t(changed & value & ~ctrl_[stop] & ~ctrl_[status]);
        const auto stopping = std::uint16_t(changed & ~value & ctrl_[status]);
        x = value;
        for (unsigned ch = 0; ch < 16; ++ch) if (stopping & (1u << ch)) stop_channel(ch, false);
        start(starting);
        break;
    }
    case main_volume: x = value & 0x7f; break;
    case fiq_status: x &= ~value; break;
    case beat_base: x = value & 0x7ff; beat_ = value & 0x7ff; break;
    case beat_count: x = std::uint16_t((x & ~(value & 0x4000) & 0x4000) | (value & ~0x4000)); break;
    case env_clock0: case env_clock1: case env_clock0_high: case env_clock1_high: {
        const auto changed = std::uint16_t(x ^ value);
        const unsigned base = offset >= env_clock1 ? 8 : 0;
        const bool high = offset == env_clock0_high || offset == env_clock1_high;
        x = value;
        // MAME reloads frame[ch + 4] from the low register's nibble for ch.
        const auto source = high ? ctrl_[base ? env_clock1 : env_clock0] : value;
        for (unsigned i = 0; i < 4; ++i)
            if ((changed >> (4 * i)) & 15)
                channels_[base + i + (high ? 4 : 0)].env_clock = envelope_count((source >> (4 * i)) & 15);
        break;
    }
    case ramp_down: {
        const auto next = std::uint16_t(value & ctrl_[status]);
        const auto rising = std::uint16_t((x ^ next) & value);
        x = next;
        for (unsigned ch = 0; ch < 16; ++ch)
            if (rising & (1u << ch)) channels_[ch].ramp = ramp_count(phase_[ch * 16 + ramp_clock]);
        break;
    }
    case stop: {
        const auto next = std::uint16_t(x & ~value);
        const auto starting = std::uint16_t((x ^ next) & ctrl_[enable] & ~ctrl_[status]);
        x = next;
        start(starting);
        break;
    }
    case control: x = value & 0x9fe8; break;
    case status: break;
    case env_irq: x &= ~value; break;
    case 0x1b: case 0x1c: case 0x1d: case 0x1e: x = value & 0x7f7f; break;
    default: x = value; break;
    }
}
void Spu::decode(unsigned ch, unsigned nibble) {
    auto& c = channels_[ch];
    if (reg(ch, adpcm_select) & 0x8000) {
        const unsigned shift = c.adpcm36_header & 15;
        const int f0 = int((c.adpcm36_header >> 4) & 63) - ((c.adpcm36_header & 0x200) ? 64 : 0);
        const auto sample = std::int16_t(std::uint16_t(nibble << 12));
        const auto value = std::int16_t((sample >> shift) + ((c.adpcm36_previous * f0 + 32) >> 12));
        c.adpcm36_previous = value;
        reg(ch, wave_data) = std::uint16_t(value) ^ 0x8000;
        return;
    }
    const int step = ima_steps[c.adpcm_step];
    int delta = step >> 3;
    if (nibble & 4) delta += step;
    if (nibble & 2) delta += step >> 1;
    if (nibble & 1) delta += step >> 2;
    if (nibble & 8) delta = -delta;
    c.adpcm_signal = std::clamp(c.adpcm_signal + delta, -32768, 32767);
    constexpr std::array<int, 4> increase = {2, 4, 6, 8};
    c.adpcm_step = unsigned(std::clamp(int(c.adpcm_step) + (nibble & 4 ? increase[nibble & 3] : -1), 0, 88));
    reg(ch, wave_data) = std::uint16_t(c.adpcm_signal) ^ 0x8000;
}
bool Spu::fetch(unsigned ch) {
    auto& c = channels_[ch];
    reg(ch, wave_previous) = reg(ch, wave_data);
    if (c.fiq_timer) ctrl_[fiq_status] |= std::uint16_t(1u << ch);
    const unsigned tone = (reg(ch, mode) >> 12) & 3;
    const bool adpcm36 = reg(ch, adpcm_select) & 0x8000, adpcm = reg(ch, mode) & 0x8000, pcm16 = reg(ch, mode) & 0x4000;
    // MAME checks for a pending ADPCM36 header before every fetch, so a tick
    // that fetches twice reads one header at most (the RTL clears hdr_need).
    if (adpcm36 && tone && !c.adpcm36_remaining) {
        c.adpcm36_header = memory_read(wave_address(ch));
        c.adpcm36_remaining = 8;
        set_wave_address(ch, wave_address(ch) + 1);
    }
    const auto raw = tone ? memory_read(wave_address(ch)) : reg(ch, wave_data);
    bool end = false;
    int nibble = -1;
    if (adpcm || adpcm36) {
        if (tone && raw == 0xffff) end = true; else nibble = (raw >> c.shift) & 15;
    } else if (pcm16) {
        if (tone && raw == 0xffff) end = true; else reg(ch, wave_data) = raw;
    } else if (tone) {
        auto value = std::uint16_t(c.shift ? raw & 0xff00 : raw << 8);
        value |= value >> 8;
        if (value == 0xffff) end = true; else reg(ch, wave_data) = value;
    }
    if (end && tone == 1) {
        // ADPCM and 8-bit one-shots set the STOP bit; 16-bit PCM does not.
        stop_channel(ch, !pcm16 || adpcm || adpcm36);
        return false;
    }
    auto address = end ? std::uint32_t(reg(ch, mode) >> 6 & 63) << 16 | reg(ch, loop) : wave_address(ch);
    unsigned shift = end ? 0 : c.shift;
    auto m = reg(ch, mode);
    if (end && (adpcm || adpcm36)) m &= 0x7fff;
    const auto next_word = [&] { shift = 0; ++address; if (adpcm36) c.adpcm36_remaining = (c.adpcm36_remaining - 1) & 15; };
    if ((m & 0x8000) || adpcm36) { if ((shift += 4) >= 16) next_word(); }
    else if (m & 0x4000) ++address;
    else if ((shift += 8) >= 16) { shift = 0; ++address; }
    c.shift = shift;
    reg(ch, mode) = std::uint16_t((m & ~63) | ((address >> 16) & 63));
    reg(ch, wave) = std::uint16_t(address);
    if (nibble >= 0) decode(ch, unsigned(nibble));
    return true;
}
std::int32_t Spu::mix(unsigned ch, unsigned lerp) {
    const std::int32_t sample = std::int16_t(reg(ch, wave_data) ^ 0x8000);
    const std::int32_t previous = std::int16_t(reg(ch, wave_previous) ^ 0x8000);
    const std::int32_t factor = ctrl_[control] & 0x200 ? 256 : std::int32_t(lerp);
    const std::int32_t level = ((sample * factor) >> 8) + ((previous * (256 - factor)) >> 8);
    return std::int16_t((level * std::int32_t(reg(ch, env_data) & 127)) >> 7);
}
void Spu::envelope(unsigned ch) {
    auto& c = channels_[ch];
    const auto bit = 1u << ch;
    auto& data = reg(ch, env_data);
    if ((ctrl_[ramp_down] & bit) && !(spg28x_ && (ctrl_[env_mode] & bit))) {
        // Baby (SPG28x) ramp-down leaves manual-envelope narration channels alone.
        if (c.ramp) --c.ramp;
        if (c.ramp) return;
        const int level = std::max(0, int(data & 127) - int(reg(ch, env_loop) >> 9));
        if (!level) { stop_channel(ch, true); return; }
        data = std::uint16_t((data & ~127) | level);
        c.ramp = ramp_count(phase_[ch * 16 + ramp_clock]);
        return;
    }
    if (ctrl_[env_mode] & bit) return;
    if (c.env_clock > 1) { --c.env_clock; return; }
    const auto clocks = ctrl_[env_clock0 + ch / 4];
    c.env_clock = envelope_count((clocks >> (4 * (ch & 3))) & 15);

    unsigned count = data >> 8;
    if (count) { --count; data = std::uint16_t((data & 255) | count << 8); }
    if (count) return;
    const auto e0 = reg(ch, env0);
    const int current = data & 127, target = (e0 >> 8) & 127, increment = e0 & 127;
    int level = current;
    if (level != target) {
        if (e0 & 0x80) {
            level = current - increment;
            if (level < 0) level = 0; else if (level < target) level = target;
            if (!level) { stop_channel(ch, true); return; }
        } else level = std::min(current + increment, target);
    }
    const auto load = [&](bool repeat_end) {
        const auto base = c.env_address;
        reg(ch, env0) = memory_read(base & 0x3fffff);
        reg(ch, env1) = memory_read((base + 1) & 0x3fffff);
        if (repeat_end) {
            reg(ch, env_loop) = memory_read((base + 2) & 0x3fffff);
            c.env_address = (std::uint32_t(reg(ch, env_address_high) & 63) << 16 | reg(ch, env_address))
                + (reg(ch, env_loop) & 0x1ff);
        } else c.env_address = base + 2;
        c.env_address &= 0x3fffff;
    };
    // A reached target loads the next envelope entry, or counts down a repeat.
    auto& e1 = reg(ch, env1);
    if (level == target && !(e1 & 0x100)) load(false);
    else if (level == target) {
        const unsigned repeat = ((e1 >> 9) - 1) & 0xffff;
        if (!repeat) load(true);
        else e1 = std::uint16_t((e1 & 0x1ff) | (repeat & 127) << 9);
    }
    data = std::uint16_t((e1 & 255) << 8 | level);
}
void Spu::tick() {
    if (beat_) --beat_;
    if (!beat_) {
        beat_ = ctrl_[beat_base] & 0x7ff;
        auto count = ctrl_[beat_count] & 0x3fff;
        if (count) { --count; ctrl_[beat_count] = std::uint16_t((ctrl_[beat_count] & 0xc000) | count); }
        if (!count && (ctrl_[beat_count] & 0x8000)) ctrl_[beat_count] |= 0x4000;
    }
    std::int32_t left = 0, right = 0;
    for (unsigned ch = 0; ch < 16; ++ch) {
        if (!(ctrl_[status] & (1u << ch))) continue;
        auto& c = channels_[ch];
        const std::uint32_t step = (std::uint32_t(phase_[ch * 16 + phase_high] & 7) << 16 | phase_[ch * 16 + phase_low]) << 2;
        const auto sum = c.accumulator + step;
        c.accumulator = sum & 0x7ffff;
        bool playing = true;
        for (unsigned i = 0; i < (sum >> 19) && playing; ++i) playing = fetch(ch);
        if (!playing) continue;
        const std::int32_t sample = mix(ch, (sum >> 11) & 255);
        const std::int32_t volume = reg(ch, pan_volume) & 127, pan = (reg(ch, pan_volume) >> 8) & 127;
        const std::int32_t pan_left = pan < 64 ? 127 * volume : (127 - pan) * 2 * volume;
        const std::int32_t pan_right = pan < 64 ? pan * 2 * volume : 127 * volume;
        left += (sample * pan_left) >> 14;
        right += (sample * pan_right) >> 14;
        envelope(ch);
    }
    if (ctrl_[wave_in_l]) left += std::int32_t(ctrl_[wave_in_l]) - 32768;
    if (ctrl_[wave_in_r]) right += std::int32_t(ctrl_[wave_in_r]) - 32768;
    const unsigned scale = (ctrl_[control] >> 6) & 3 ? 2 : 4;
    left >>= scale; right >>= scale;
    const std::int32_t volume = ctrl_[main_volume];
    ++samples_;
    if (sample_sink) sample_sink(std::int16_t((left * volume) >> 7), std::int16_t((right * volume) >> 7));
}
void Spu::serialize(StateArchive& a) {
    a.section("SPU ");
    a(regs_); a(phase_); a(misc_); a(ctrl_); a(samples_); a(beat_); a(spg28x_);
    for (auto& c : channels_) {
        a(c.accumulator); a(c.env_clock); a(c.ramp); a(c.env_address); a(c.shift); a(c.adpcm_step); a(c.adpcm36_remaining);
        a(c.adpcm_signal); a(c.adpcm36_header); a(c.adpcm36_previous); a(c.fiq_timer);
        if (a.loading() && (c.shift > 15 || c.adpcm_step > 88)) throw std::runtime_error("Corrupt save state (SPU)");
    }
}
}
