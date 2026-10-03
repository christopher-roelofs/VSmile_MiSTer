// SPDX-License-Identifier: GPL-2.0-or-later
// Implements the UART controller behavior in rtl/vsmile_pad.sv and rtl/vsmile_kbd.sv.
#include "cheshire/controller.hpp"
#include <algorithm>
#include <stdexcept>

namespace cheshire {
namespace { constexpr std::uint64_t master = 27000000, byte_period = 28125; }
void Joystick::reset(std::uint64_t now, bool enabled, bool mat) {
    fifo_.clear(); enabled_ = enabled; mat_ = mat; selected_ = rts_ = active_ = false;
    tx_ = timeout_ = never; idle_ = enabled ? now + master : never;
    ud_ = sent_ud_ = 0x80; lr_ = sent_lr_ = 0xc0;
    colors_ = sent_colors_ = buttons_ = sent_buttons_ = probe_ = 0; stale_ = 0x7f;
}
void Joystick::queue(std::uint8_t byte, std::uint64_t now) {
    idle_ = never;
    if (fifo_.size() == 32) return;
    const bool empty = fifo_.empty();
    fifo_.push_back(byte);
    if (empty) {
        set_rts(true);
        if (selected_) tx_ = now + byte_period;
        else timeout_ = now + master / 2;
    }
}
void Joystick::select(bool value, std::uint64_t now) {
    if (!enabled_) return;
    if (value && !selected_ && !fifo_.empty() && tx_ == never) {
        timeout_ = never; tx_ = now + byte_period;
    }
    selected_ = value;
}
void Joystick::receive(std::uint8_t byte, std::uint64_t now) {
    if (!enabled_ || !selected_ || ((byte >> 4) != 7 && (byte >> 4) != 11)) return;
    const unsigned previous = byte >> 4 == 7 ? 0 : probe_;
    probe_ = byte;
    queue(std::uint8_t(0xb0 | (((previous + byte + 15) & 15) ^ 5)), now);
}
void Joystick::report(std::uint8_t stale, std::uint64_t now) {
    const auto axes = [&] {
        if (stale & 2) queue(ud_, now);
        if (stale & 1) queue(lr_, now);
    };
    if (mat_) { if (stale & 1) queue(lr_, now); if (stale & 2) queue(ud_, now); }
    else axes();
    if (stale & 3) { sent_ud_ = ud_; sent_lr_ = lr_; }
    if (stale & 4) { queue(std::uint8_t(0x90 | colors_), now); sent_colors_ = colors_; }
    if (stale & 0x78) {
        for (unsigned b = 0; b < 4; ++b)
            if ((stale & (8u << b)) && (buttons_ & (1u << b))) queue(std::uint8_t(0xa1 + b), now);
        if (!buttons_) queue(0xa0, now);
        sent_buttons_ = buttons_;
    }
}
void Joystick::set_input(const InputState& input, std::uint64_t now) {
    unsigned joy = input.directions & 15, colors = input.colors & 15, buttons = input.buttons & 15;
    unsigned ud_level = std::clamp<unsigned>(input.ud_level, 3, 7), lr_level = std::clamp<unsigned>(input.lr_level, 3, 7);
    if (mat_) {
        const bool up = joy & 1, down = joy & 2, left = joy & 4, right = joy & 8;
        const bool green = colors & 1, blue = colors & 2, yellow = colors & 4, red = colors & 8;
        joy = (red || left ? 2 : 0) | (yellow || right ? 4 : 0);
        ud_level = red ? 3 : 5; lr_level = yellow ? 3 : 5;
        colors = (green ? 8 : 0) | (down ? 4 : 0) | (up ? 2 : 0) | (buttons >> 3);
        buttons = (buttons & 7) | (blue ? 8 : 0);
    }
    const auto next_ud = std::uint8_t(joy & 1 ? 0x80 | ud_level : joy & 2 ? 0x88 | ud_level : 0x80);
    const auto next_lr = std::uint8_t(joy & 4 ? 0xc8 | lr_level : joy & 8 ? 0xc0 | lr_level : 0xc0);
    std::uint8_t changed = (ud_ != next_ud ? 2 : 0) | (lr_ != next_lr ? 1 : 0)
        | (colors_ != colors ? 4 : 0) | ((buttons_ ^ buttons) << 3);
    ud_ = next_ud; lr_ = next_lr; colors_ = std::uint8_t(colors); buttons_ = std::uint8_t(buttons);
    if (!enabled_ || !active_ || !changed) return;
    if (!fifo_.empty()) stale_ |= changed;
    else {
        // Button presses produce A1..A4; release all produces A0.
        changed = (changed & 7) | (((sent_buttons_ ^ buttons_) & buttons_) << 3)
            | (buttons_ == 0 && sent_buttons_ != 0 ? 0x78 : 0);
        report(changed, now);
        sent_buttons_ = buttons_;
    }
}
std::uint64_t Joystick::next_event() const { return std::min({tx_, timeout_, idle_}); }
void Joystick::event(std::uint64_t now) {
    if (tx_ == now) {
        tx_ = never;
        const auto byte = fifo_.front(); fifo_.pop_front();
        if (byte_out) byte_out(byte);
        if (fifo_.empty()) {
            report(stale_, now); stale_ = 0; active_ = true; idle_ = now + master;
        }
        if (fifo_.empty()) set_rts(false);
        else if (selected_) tx_ = now + byte_period;
    }
    if (timeout_ == now) {
        timeout_ = never;
        if (!fifo_.empty()) {
            fifo_.clear(); tx_ = never;
            if (active_) { active_ = false; stale_ = 0x7f; probe_ = 0; }
            queue(0x55, now);
        }
    }
    if (idle_ == now) { idle_ = never; queue(0x55, now); }
}

namespace {
constexpr std::uint64_t hello_period = master * 3 / 10, hello_timeout = 329400, scan_period = master / 2400;
// Ticks a tablet report may wait, queued and unselected, before RTS is re-raised.
constexpr std::uint64_t stall_period = 540000;
// MAME's translate(): matrix position to key code (0: no key).
constexpr std::array<std::array<std::uint8_t, 13>, 5> key_codes = {{
    {0x33, 0x34, 0x35, 0x37, 0x36, 0x30, 0x31, 0x3e, 0x3f, 0x38, 0x29, 0x39, 0},
    {0x22, 0x23, 0x24, 0x25, 0x27, 0x26, 0x20, 0x21, 0x3a, 0x3b, 0x3c, 0x2a, 0x3d},
    {0x1a, 0x1b, 0x1c, 0x1d, 0x1f, 0x1e, 0x18, 0x19, 0x0a, 0x0b, 0x01, 0, 0},
    {0xa9, 0x13, 0x14, 0x15, 0x17, 0x16, 0x08, 0x11, 0x0c, 0x2f, 0x12, 0, 0},
    {0x04, 0x2c, 0x05, 0x0e, 0x06, 0x0f, 0x0d, 0, 0, 0, 0, 0, 0}}};
}
void Keyboard::reset(std::uint64_t now, bool enabled, bool pen, std::uint8_t layout) {
    fifo_.clear(); state_ = State::hello;
    enabled_ = enabled; pen_ = pen; layout_ = layout;
    selected_ = sending_ = rts_ = active_ = false; probe0_ = probe1_ = 0;
    tx_ = timeout_ = idle_ = hello_end_ = scan_ = stall_ = never;
    hello_ = enabled ? now + hello_period : never;
    row_ = 0; keys_.fill(0); key_states_.fill(0);
    joy_ = sent_joy_ = buttons_ = sent_buttons_ = 0;
    pen_state_ = 0; sent_pen_ = 0x7ffff;
}
void Keyboard::queue(std::uint8_t byte, std::uint64_t now, bool reset_idle) {
    if (reset_idle) idle_ = never;
    if (fifo_.size() == 32) return;
    const bool empty = fifo_.empty();
    fifo_.push_back(byte);
    if (!empty) return;
    set_rts(true);
    if (selected_) { sending_ = true; tx_ = now + byte_period; }
    else timeout_ = now + master / 2;
}
void Keyboard::update_stall(std::uint64_t now) {
    // The Art Studio cart deselects right after its handshake; RTS raised
    // while it was busy leaves no edge for it, so the FPGA model re-raises it.
    if (!(pen_ && !fifo_.empty() && !sending_ && !selected_ && rts_)) stall_ = never;
    else if (stall_ == never) stall_ = now + stall_period;
}
void Keyboard::report(std::uint64_t now) {
    if (!active_ || state_ != State::run || !fifo_.empty()) return;
    if (joy_ != sent_joy_) {
        const auto changed = joy_ ^ sent_joy_;
        if (changed & 3) queue(joy_ & 1 ? 0x87 : joy_ & 2 ? 0x8f : 0x80, now);
        if (changed & 12) queue(joy_ & 4 ? 0x7f : joy_ & 8 ? 0x77 : 0x70, now);
        sent_joy_ = joy_;
    } else if (buttons_ != sent_buttons_) {
        const auto rise = (sent_buttons_ ^ buttons_) & buttons_;
        for (unsigned b = 0; b < 3; ++b) if (rise & (1u << b)) queue(std::uint8_t(0xa1 + b), now);
        if (!buttons_) queue(0xa0, now);
        sent_buttons_ = buttons_;
    } else if (pen_ && pen_state_ != sent_pen_) {
        const unsigned x = (pen_state_ >> 8) & 0x3ff, y = pen_state_ & 255;
        queue(std::uint8_t(0x40 | (pen_state_ >> 18)), now); // 0x40 hovering, 0x41 tip pressed
        queue(std::uint8_t(x >> 4), now);
        queue(std::uint8_t((x & 15) << 2 | y >> 6), now);
        queue(std::uint8_t(y & 63), now);
        sent_pen_ = pen_state_;
    }
    update_stall(now);
}
void Keyboard::set_input(const InputState& input, std::uint64_t now) {
    joy_ = input.directions & 15; buttons_ = input.buttons & 7;
    for (unsigned r = 0; r < 5; ++r) keys_[r] = input.keys[r] & 0x1fff;
    pen_state_ = std::uint32_t(input.pen_down) << 18 | std::uint32_t(std::min<unsigned>(input.pen_x, 1023)) << 8 | input.pen_y;
    if (enabled_) report(now);
}
void Keyboard::select(bool value, std::uint64_t now) {
    if (!enabled_) return;
    if (value && !selected_ && !fifo_.empty() && !sending_) {
        timeout_ = never; sending_ = true; tx_ = now + byte_period;
    }
    selected_ = value;
    update_stall(now);
}
void Keyboard::receive(std::uint8_t byte, std::uint64_t now) {
    if (!enabled_) return;
    switch (state_) {
    case State::hello: break;
    case State::rx1: state_ = State::rx2; break;
    case State::rx2: state_ = State::rp1; break;
    case State::rp1: state_ = State::rp2; break;
    case State::rp2: state_ = State::rp3; break;
    case State::rp3:
        // The keyboard answers with its layout; the tablet must not (0x4x is a pen header).
        if (!pen_) queue(layout_, now);
        idle_ = never; // the FPGA model's idle reset here also covers the tablet
        state_ = State::run; active_ = true;
        row_ = 0; scan_ = pen_ ? never : now + scan_period;
        break;
    case State::run:
        if (selected_ && ((byte >> 4) == 7 || (byte >> 4) == 11)) {
            probe0_ = (byte >> 4) == 7 ? 0 : probe1_;
            probe1_ = byte;
            queue(std::uint8_t(0xb0 | (((probe0_ + probe1_ + 15) & 15) ^ 5)), now);
        }
        break;
    }
    report(now);
}
std::uint64_t Keyboard::next_event() const { return std::min({tx_, timeout_, idle_, hello_, hello_end_, scan_, stall_}); }
void Keyboard::event(std::uint64_t now) {
    if (hello_ == now) { hello_ = never; set_rts(true); hello_end_ = now + hello_timeout; }
    if (hello_end_ == now) {
        hello_end_ = never; set_rts(false);
        if (!selected_) hello_ = now + hello_period;
        else {
            const std::uint8_t id = pen_ ? pen_id : 0x52;
            for (unsigned i = 0; i < 3; ++i) queue(id, now);
            // The Art Studio cart answers E6 D6 60 only, without the keyboard carts' 02 02.
            state_ = pen_ ? State::rp1 : State::rx1;
        }
    }
    if (tx_ == now) {
        tx_ = never;
        const auto byte = fifo_.front(); fifo_.pop_front();
        if (byte_out) byte_out(byte);
        if (fifo_.empty() && state_ == State::run) { idle_ = now + master; active_ = true; }
        if (fifo_.empty()) { sending_ = false; set_rts(false); }
        else if (selected_) tx_ = now + byte_period;
        else sending_ = false;
    }
    if (timeout_ == now) {
        timeout_ = never;
        if (!fifo_.empty()) {
            fifo_.clear();
            if (active_) { idle_ = never; active_ = false; probe0_ = probe1_ = 0; }
            set_rts(false);
            queue(0x55, now);
        }
    }
    if (stall_ == now) { set_rts(false); set_rts(true); stall_ = never; }
    if (idle_ == now) { idle_ = never; queue(0x55, now, false); }
    if (scan_ == now) {
        // One row per scan; the first changed column (others on a later pass).
        const auto changed = std::uint16_t(key_states_[row_] ^ keys_[row_]);
        if (changed) {
            unsigned c = 0;
            while (!(changed & (1u << c))) ++c;
            const bool down = keys_[row_] & (1u << c);
            key_states_[row_] ^= std::uint16_t(1u << c);
            if (const auto code = key_codes[row_][c]) queue(down ? code : code == 0xa9 ? 0xaa : code | 0xc0, now);
        }
        row_ = (row_ + 1) % 5;
        scan_ = now + scan_period;
    }
    update_stall(now);
    report(now);
}
void Joystick::serialize(StateArchive& a) {
    SerialController::serialize(a);
    a(fifo_); a(enabled_); a(mat_); a(selected_); a(tx_); a(timeout_); a(idle_);
    a(ud_); a(lr_); a(colors_); a(buttons_); a(sent_ud_); a(sent_lr_); a(sent_colors_); a(sent_buttons_);
    a(stale_); a(probe_);
}
void Keyboard::serialize(StateArchive& a) {
    SerialController::serialize(a);
    a(fifo_); a(state_); a(enabled_); a(pen_); a(selected_); a(sending_); a(layout_); a(probe0_); a(probe1_);
    a(tx_); a(timeout_); a(idle_); a(hello_); a(hello_end_); a(scan_); a(stall_); a(row_);
    a(keys_); a(key_states_); a(joy_); a(sent_joy_); a(buttons_); a(sent_buttons_); a(pen_state_); a(sent_pen_);
    if (a.loading() && (row_ > 4 || state_ > State::run || fifo_.size() > 32)) throw std::runtime_error("Corrupt save state (keyboard)");
}
}
