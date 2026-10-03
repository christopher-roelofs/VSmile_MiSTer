// SPDX-License-Identifier: GPL-2.0-or-later
// Register and timer behavior follows rtl/spg2xx/{spg2xx_io,spg2xx_vctl}.sv.
#include "cheshire/soc.hpp"
#include <algorithm>
#include <stdexcept>

namespace cheshire {
namespace {
constexpr auto never = Joystick::never;
std::uint16_t prng_next(std::uint16_t value) {
    return std::uint16_t(((value << 1) & 0x7fff) | (((value >> 14) ^ (value >> 13)) & 1));
}
unsigned source_rate(unsigned control) {
    switch (control & 7) { case 2: return 32768; case 3: return 8192; case 4: return 4096; default: return 0; }
}
}
Soc::Soc(std::array<std::uint16_t, 0x4000>& memory)
    : io_(memory.data() + 0x3d00, 128), video_(memory.data() + 0x2800, 256) {
    for (SerialController* port : {static_cast<SerialController*>(&pad_), static_cast<SerialController*>(&keyboard_)}) {
        port->rts_out = [this](bool high) { if (high) io_[0x22] |= 0x200; else io_[0x22] &= ~0x200; };
        port->byte_out = [this](std::uint8_t byte) { receive_uart(byte); };
    }
}
void Soc::reset(bool baby, bool pal, bool reference_timing, Peripheral peripheral, std::uint8_t keyboard_layout) {
    baby_ = baby; pal_ = pal; reference_ = reference_timing;
    std::fill(io_.begin(), io_.end(), 0); std::fill(video_.begin(), video_.end(), 0);
    video_[0x36] = video_[0x37] = 0xffff;
    io_[0x23] = 0x28; io_[0x2c] = 0x1418; io_[0x2d] = 0x1658;
    timers_.fill({}); rx_fifo_.clear();
    now_ = frames_ = line_start_ = rx_bytes_ = tx_bytes_ = 0;
    line_ = 240; line_fraction_ = 0;
    line_length_ = pal_ ? 1728 : reference_ ? 1717 : 1716;
    system_divider_ = a_divider_ = a_rate_ = 0; a_preload_ = b_preload_ = 0;
    rx_available_ = rx_irq_ = tx_irq_ = fiq_selected_ = baud28_ = reset_pending_ = false;
    baby_buttons_ = baby_mode_ = 0;
    const bool keyboard = peripheral == Peripheral::keyboard || peripheral == Peripheral::tablet;
    pad_.reset(0, !baby && !keyboard, peripheral == Peripheral::mat);
    keyboard_.reset(0, !baby && keyboard, peripheral == Peripheral::tablet, keyboard_layout);
    port_ = keyboard ? static_cast<SerialController*>(&keyboard_) : &pad_;
    periodic(system_timer, 4096); periodic(rng, 1234);
    timers_[video_line].deadline = line_length_;
    spu_.reset(baby);
    timers_[audio].deadline = Spu::ticks_per_sample;
}
void Soc::periodic(Event id, unsigned frequency) {
    timers_[id] = {now_, frequency, frequency ? frequency - 1 : 0};
    reschedule(id);
}
void Soc::reschedule(Event id) {
    auto& timer = timers_[id];
    if (!timer.frequency) { timer.deadline = never; return; }
    auto interval = master_clock / timer.frequency;
    timer.phase += master_clock % timer.frequency;
    if (timer.phase >= timer.frequency) { ++interval; timer.phase -= timer.frequency; }
    timer.deadline += interval;
}
void Soc::advance(std::uint64_t ticks) {
    if (ticks > never - now_) throw std::runtime_error("Emulated clock overflow");
    const auto target = now_ + ticks;
    while (true) {
        unsigned next = 0;
        for (unsigned i = 1; i < event_count; ++i)
            if (timers_[i].deadline < timers_[next].deadline) next = i;
        const auto pad_time = port_->next_event();
        const auto deadline = std::min(timers_[next].deadline, pad_time);
        if (deadline == never || deadline > target) break;
        now_ = deadline;
        if (pad_time < timers_[next].deadline) port_->event(now_);
        else {
            const auto id = static_cast<Event>(next);
            if (timers_[id].frequency) reschedule(id); else timers_[id].deadline = never;
            event(id);
        }
    }
    now_ = target;
}
unsigned Soc::hpos() const { return unsigned((now_ - line_start_) * 320 / line_length_); }
void Soc::schedule_position() {
    timers_[video_position].deadline = never;
    if (video_[0x36] != line_ || line_ > 240 || video_[0x37] >= 160) return;
    const auto offset = (std::uint64_t(video_[0x37]) * 2 * line_length_ + 319) / 320;
    const auto deadline = line_start_ + offset;
    if (deadline >= now_) timers_[video_position].deadline = deadline;
}
void Soc::adc_done() {
    io_[0x27] = 0x8fff; io_[0x25] |= 0x2000;
    if (io_[0x25] & 0x200) io_[0x22] |= 0x2000;
}
void Soc::event(Event id) {
    switch (id) {
    case system_timer:
        io_[0x22] |= 0x40;
        ++system_divider_;
        if (!(system_divider_ & 1)) io_[0x22] |= 0x20;
        if (!(system_divider_ & 3)) io_[0x22] |= 0x10;
        if (!(system_divider_ & 1023)) io_[0x22] |= 8;
        break;
    case rng: io_[0x2c] = prng_next(io_[0x2c]); io_[0x2d] = prng_next(io_[0x2d]); break;
    case timebase1: io_[0x22] |= 1; break;
    case timebase2: io_[0x22] |= 2; break;
    case timer_a:
        if (a_rate_ && ++a_divider_ >= a_rate_) {
            a_divider_ = 0;
            if (++io_[0x12] == 0) { io_[0x12] = a_preload_; io_[0x22] |= 0x800; }
        }
        break;
    case timer_b:
        if (++io_[0x16] == 0) { io_[0x16] = b_preload_; io_[0x22] |= 0x400; }
        break;
    case video_line: {
        line_start_ = now_;
        line_fraction_ += 146;
        if (line_fraction_ >= 262) line_fraction_ -= 262;
        line_ = (line_ + 1) % (pal_ ? 312 : 262);
        if (line_ == 0) video_[0x63] &= ~1;
        if (line_ == 240) { ++frames_; if (video_[0x62] & 1) video_[0x63] |= 1; }
        line_length_ = pal_ ? 1728 : reference_ ? (line_fraction_ + 146 >= 262 ? 1718 : 1717) : 1716;
        timers_[video_line].deadline = now_ + line_length_;
        schedule_position();
        if (line_started) line_started(line_);
        break;
    }
    case video_position: if (video_[0x62] & 2) video_[0x63] |= 2; break;
    case watchdog: reset_pending_ = true; break;
    case audio: spu_.tick(); timers_[audio].deadline = now_ + Spu::ticks_per_sample; break;
    case adc_once: case adc_auto: adc_done(); break;
    case uart_tx:
        io_[0x31] = std::uint16_t((io_[0x31] | 2) & ~0x40);
        ++tx_bytes_; port_->receive(std::uint8_t(io_[0x35]), now_);
        if (io_[0x30] & 2) { tx_irq_ = true; io_[0x22] |= 0x100; }
        break;
    case uart_rx:
        rx_available_ = true; io_[0x31] |= 0x81;
        if (io_[0x30] & 1) { rx_irq_ = true; io_[0x22] |= 0x100; }
        break;
    default: break;
    }
}
std::uint16_t Soc::interrupts() const {
    std::uint16_t lines = 0;
    if (video_[0x62] & video_[0x63]) lines |= fiq_selected_ && (io_[0x2e] & 7) == 0 ? 1 : 2;
    const auto status = io_[0x21] & io_[0x22];
    if (status & 0xc00) lines |= 1 << 3;
    if (status & 0x6100) lines |= 1 << 4;
    if (spu_.irq()) lines |= 1 << 5;
    if (spu_.fiq()) lines |= 1;
    if (status & 0x1200) lines |= 1 << 6;
    if (status & 0x70) lines |= 1 << 7;
    if (status & 0x8b) lines |= 1 << 8;
    return lines;
}
std::uint16_t Soc::gpio_output(unsigned port) const {
    const unsigned base = 5 * port;
    return std::uint16_t((io_[base + 2] ^ (io_[base + 3] & ~io_[base + 4])) & ~io_[base + 5]);
}
std::uint16_t Soc::gpio_direction(unsigned port) const { return std::uint16_t(io_[5 * port + 3] & ~io_[5 * port + 5]); }
std::uint16_t Soc::read(std::uint32_t address, const std::array<std::uint16_t, 3>& inputs, unsigned csb, unsigned ds) {
    if (address < 0x2900) {
        const unsigned offset = address - 0x2800;
        if (offset == 0x38) return std::uint16_t(line_);
        if (offset == 0x3e || offset == 0x3f) return 0;
        return video_[offset];
    }
    const unsigned offset = address - 0x3d00;
    if (offset >= 128) return 0;
    if (offset == 1 || offset == 6 || offset == 11) {
        const unsigned port = (offset - 1) / 5;
        const auto dir = io_[5 * port + 3];
        unsigned special = 0;
        if (port == 0) special = ((1u << csb) << 12) & 0xe000 & io_[5];
        io_[offset] = std::uint16_t((gpio_output(port) & dir) | (inputs[port] & ~dir) | special);
        return io_[offset];
    }
    if (offset == 0x1c) return std::uint16_t(line_);
    if (offset == 0x2b) return pal_;
    if (offset == 0x2f) return std::uint16_t(ds);
    if (offset == 0x2c || offset == 0x2d) { const auto value = io_[offset]; io_[offset] = prng_next(value); return value; }
    if (offset == 0x36) {
        if (!rx_available_) { io_[0x37] |= 0x2000; return io_[0x36]; }
        io_[0x31] &= ~0x81;
        if (!rx_fifo_.empty()) { io_[0x36] = rx_fifo_.front(); rx_fifo_.pop_front(); }
        if (rx_fifo_.empty()) rx_available_ = false;
        else if (timers_[uart_rx].deadline == never) timers_[uart_rx].deadline = now_ + uart_frame_ticks();
        return io_[0x36];
    }
    if (offset == 0x37) return std::uint16_t((io_[0x37] & ~0x70) | (rx_available_ ? 0x70 : 0));
    return io_[offset];
}
unsigned Soc::uart_frame_ticks() const {
    const unsigned bits = io_[0x30] & 0x20 ? 11 : 10;
    if (baby_ && baud28_) return bits * (0x10000u - io_[0x33]);
    const auto baud = std::uint16_t((io_[0x34] & 255) << 8 | (baby_ ? io_[0x33] : io_[0x33] & 255));
    return bits * 16 * (0x10000u - baud);
}
void Soc::receive_uart(std::uint8_t byte) {
    if (!(io_[0x30] & 0x40)) return;
    if (rx_fifo_.size() == 8) { io_[0x37] |= 0x4000; return; }
    rx_fifo_.push_back(byte); ++rx_bytes_;
    if (timers_[uart_rx].deadline == never) timers_[uart_rx].deadline = now_ + uart_frame_ticks();
}
void Soc::write(std::uint32_t address, std::uint16_t value) {
    if (address < 0x2900) {
        const unsigned offset = address - 0x2800;
        switch (offset) {
        case 0x10: case 0x16: case 0x36: case 0x37: value &= 0x1ff; break;
        case 0x11: case 0x17: case 0x30: value &= 0xff; break;
        case 0x2a: value &= 3; break;
        case 0x39: value &= 1; break;
        case 0x3d: value &= 15; break;
        case 0x70: value &= 0x3fff; break;
        case 0x71: value &= 0x3ff; break;
        case 0x3e: case 0x3f: return;
        case 0x62: value &= 7; break;
        case 0x63: video_[offset] &= ~value; return;
        default: break;
        }
        video_[offset] = value;
        if (offset == 0x36 || offset == 0x37) schedule_position();
        return;
    }
    const unsigned offset = address - 0x3d00;
    if (offset >= 128) return;
    const auto old = io_[offset];
    switch (offset) {
    case 0x11: system_divider_ = 0; return;
    case 0x15: io_[0x22] &= ~0x800; return;
    case 0x19: io_[0x22] &= ~0x400; return;
    case 0x22:
        io_[0x22] &= ~value;
        if (rx_irq_ || tx_irq_) io_[0x22] |= 0x100;
        return;
    case 0x24:
        if (value == 0x55aa && (io_[0x20] & 0x8000)) timers_[watchdog].deadline = now_ + master_clock * 3 / 4;
        return;
    case 0x31:
        if (value & 1) { rx_irq_ = false; io_[0x31] &= ~1; }
        if (value & 2) { tx_irq_ = false; io_[0x31] &= ~2; }
        if (!rx_irq_ && !tx_irq_) io_[0x22] &= ~0x100;
        return;
    case 0x36: return;
    case 0x37:
        if (value & 0x8000) { rx_available_ = false; io_[0x36] = 0; }
        io_[0x37] = std::uint16_t((old & ~value & 0x6000) | (value & 7));
        return;
    default: break;
    }
    io_[offset] = value;
    if (offset == 1 || offset == 6 || offset == 11) io_[offset + 1] = value;
    switch (offset) {
    case 0x10: {
        constexpr std::array<unsigned, 8> rates1 = {8, 16, 32, 64, 12000, 24000, 40000, 40000};
        constexpr std::array<unsigned, 8> rates2 = {128, 256, 512, 1024, 105000, 210000, 420000, 840000};
        periodic(timebase1, rates1[(value & 16 ? 4 : 0) | (value & 3)]);
        periodic(timebase2, rates2[(value & 16 ? 4 : 0) | ((value >> 2) & 3)]);
        break;
    }
    case 0x12: a_preload_ = value; break;
    case 0x13: {
        const auto rate = source_rate(value);
        constexpr std::array<unsigned, 8> shifts = {11, 10, 8, 0, 2, 1, 0, 0};
        const unsigned divisor = (value >> 3) & 7;
        a_rate_ = divisor == 6 ? 1 : divisor == 3 || divisor == 7 ? 0 : rate >> shifts[divisor];
        periodic(timer_a, rate);
        break;
    }
    case 0x16: b_preload_ = value; break;
    case 0x17: if (io_[0x18] & 1) periodic(timer_b, source_rate(value)); break;
    case 0x18: io_[0x18] &= 1; periodic(timer_b, value & 1 ? source_rate(io_[0x17]) : 0); break;
    case 0x20:
        if ((old ^ value) & 0x8000) timers_[watchdog].deadline = value & 0x8000 ? now_ + master_clock * 3 / 4 : never;
        break;
    case 0x25:
        io_[0x25] &= ~0x2000;
        if ((old & value) & 0x2000) io_[0x22] &= ~0x2000;
        if (value & 1) {
            io_[0x25] |= 0x2000;
            if (!(old & 0x1000) && (value & 0x1000)) {
                io_[0x25] &= ~0x3000; io_[0x27] &= ~0x8000;
                timers_[adc_once].deadline = now_ + (16u << ((value >> 2) & 3));
            }
            if (value & 0x400) { io_[0x27] &= ~0x8000; periodic(adc_auto, 8000); }
        } else { timers_[adc_once].deadline = never; periodic(adc_auto, 0); }
        break;
    case 0x26:
        if (!(value & (1u << ((io_[0x25] >> 4) & 3)))) { timers_[adc_once].deadline = never; periodic(adc_auto, 0); }
        break;
    case 0x2c: case 0x2d: io_[offset] &= 0x7fff; break;
    case 0x2e: fiq_selected_ = true; break;
    case 0x30:
        if (!(value & 0x40)) { rx_available_ = false; io_[0x36] = 0; }
        if ((old ^ value) & 0x80) {
            if (value & 0x80) io_[0x31] |= 2;
            else { io_[0x31] &= ~0x42; timers_[uart_tx].deadline = never; }
        }
        break;
    case 0x33: baud28_ = true; break;
    case 0x34: baud28_ = false; break;
    case 0x35:
        if (io_[0x30] & 0x80) { timers_[uart_tx].deadline = now_ + uart_frame_ticks(); io_[0x31] = std::uint16_t((io_[0x31] & ~2) | 0x40); }
        break;
    default: break;
    }
}
void Soc::sprite_dma_done() { video_[0x72] = 0; if (video_[0x62] & 4) video_[0x63] |= 4; }
bool Soc::take_watchdog_reset() { const bool reset = reset_pending_; reset_pending_ = false; return reset; }
void Soc::set_input(const InputState& input) {
    if (!baby_) { port_->set_input(input, now_); return; }
    const auto mode = std::min<unsigned>(input.baby_mode, 2);
    const auto packet = [&](std::uint16_t code) {
        const auto value = std::uint16_t(((mode + 1) << 10) | code);
        receive_uart(std::uint8_t(value >> 8)); receive_uart(std::uint8_t(value));
    };
    if (mode != baby_mode_) { packet(0x80); baby_mode_ = std::uint8_t(mode); }
    constexpr std::array<std::uint16_t, 8> codes = {0x1fe, 0x3ee, 0x3de, 0x3be, 0x2fe, 0x3f6, 0x3fa, 0x3fc};
    for (unsigned b = 0; b < 8; ++b)
        if ((input.baby_buttons ^ baby_buttons_) & (1u << b)) packet(input.baby_buttons & (1u << b) ? codes[b] : 0x80);
    baby_buttons_ = input.baby_buttons;
}
void Soc::serialize(StateArchive& a) {
    a.section("SOC ");
    for (auto& timer : timers_) { a(timer.deadline); a(timer.frequency); a(timer.phase); }
    a(rx_fifo_); a(now_); a(frames_); a(line_start_); a(rx_bytes_); a(tx_bytes_);
    a(line_); a(line_length_); a(line_fraction_); a(system_divider_); a(a_divider_); a(a_rate_);
    a(a_preload_); a(b_preload_); a(baby_); a(pal_); a(reference_); a(baud28_);
    a(rx_available_); a(rx_irq_); a(tx_irq_); a(fiq_selected_); a(reset_pending_); a(baby_buttons_); a(baby_mode_);
    bool keyboard = port_ == &keyboard_;
    a(keyboard);
    if (a.loading()) {
        port_ = keyboard ? static_cast<SerialController*>(&keyboard_) : &pad_;
        if (line_ >= (pal_ ? 312u : 262u) || rx_fifo_.size() > 8 || !line_length_) throw std::runtime_error("Corrupt save state (SoC)");
    }
    a.section("PORT"); pad_.serialize(a); keyboard_.serialize(a);
    spu_.serialize(a);
}
}
