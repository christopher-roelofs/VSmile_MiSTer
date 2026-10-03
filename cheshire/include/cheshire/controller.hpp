// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <array>
#include <cstdint>
#include <deque>
#include <functional>
#include <limits>
#include <optional>
#include "cheshire/state.hpp"

namespace cheshire {
struct InputState {
    std::uint8_t directions = 0; // up, down, left, right
    std::uint8_t colors = 0; // green, blue, yellow, red
    std::uint8_t buttons = 0; // OK, Quit, Help, ABC
    std::uint8_t ud_level = 7, lr_level = 7;
    std::uint8_t baby_buttons = 0; // yellow, blue, orange, green, red, cloud, ball, exit
    std::uint8_t baby_mode = 0;
    // Smart Keyboard matrix, rows as MAME's ROW0-4 ports (column = bit).
    std::array<std::uint16_t, 5> keys{};
    // Art Studio pen: horizontal 0..1023, vertical 0..255, about screen pixels.
    bool pen_down = false;
    std::uint16_t pen_x = 160;
    std::uint8_t pen_y = 120;
};

// A device on controller port 1, talking to the SoC UART.
class SerialController {
public:
    static constexpr std::uint64_t never = std::numeric_limits<std::uint64_t>::max();
    std::function<void(bool)> rts_out;
    std::function<void(std::uint8_t)> byte_out;
    virtual ~SerialController() = default;
    virtual void set_input(const InputState& input, std::uint64_t now) = 0;
    virtual void select(bool value, std::uint64_t now) = 0;
    virtual void receive(std::uint8_t byte, std::uint64_t now) = 0;
    virtual std::uint64_t next_event() const = 0;
    virtual void event(std::uint64_t now) = 0;
    virtual void serialize(StateArchive& archive) { archive(rts_); archive(active_); }
    bool rts() const { return rts_; }
    bool active() const { return active_; }
protected:
    bool rts_ = false, active_ = false;
    void set_rts(bool value) { rts_ = value; if (rts_out) rts_out(value); }
};

class Joystick final : public SerialController {
public:
    void reset(std::uint64_t now, bool enabled, bool mat);
    void set_input(const InputState& input, std::uint64_t now) override;
    void select(bool value, std::uint64_t now) override;
    void receive(std::uint8_t byte, std::uint64_t now) override;
    std::uint64_t next_event() const override;
    void event(std::uint64_t now) override;
    void serialize(StateArchive& archive) override;
private:
    std::deque<std::uint8_t> fifo_;
    bool enabled_ = false, mat_ = false, selected_ = false;
    std::uint64_t tx_ = never, timeout_ = never, idle_ = never;
    std::uint8_t ud_ = 0x80, lr_ = 0xc0, colors_ = 0, buttons_ = 0;
    std::uint8_t sent_ud_ = 0x80, sent_lr_ = 0xc0, sent_colors_ = 0, sent_buttons_ = 0;
    std::uint8_t stale_ = 0x7f, probe_ = 0;
    void queue(std::uint8_t byte, std::uint64_t now);
    void report(std::uint8_t stale, std::uint64_t now);
};

// Smart Keyboard (MAME vsmile_keyboard_device), or in pen mode the Art Studio
// tablet; follows rtl/vsmile_kbd.sv.
class Keyboard final : public SerialController {
public:
    static constexpr std::uint8_t pen_id = 0x54; // unverified: the cart accepts any 0x5x
    void reset(std::uint64_t now, bool enabled, bool pen, std::uint8_t layout);
    void set_input(const InputState& input, std::uint64_t now) override;
    void select(bool value, std::uint64_t now) override;
    void receive(std::uint8_t byte, std::uint64_t now) override;
    std::uint64_t next_event() const override;
    void event(std::uint64_t now) override;
    void serialize(StateArchive& archive) override;
    bool running() const { return state_ == State::run; }
private:
    enum class State { hello, rx1, rx2, rp1, rp2, rp3, run };
    std::deque<std::uint8_t> fifo_;
    State state_ = State::hello;
    bool enabled_ = false, pen_ = false, selected_ = false, sending_ = false;
    std::uint8_t layout_ = 0x40, probe0_ = 0, probe1_ = 0;
    std::uint64_t tx_ = never, timeout_ = never, idle_ = never, hello_ = never, hello_end_ = never, scan_ = never, stall_ = never;
    unsigned row_ = 0;
    std::array<std::uint16_t, 5> keys_{}, key_states_{};
    std::uint8_t joy_ = 0, sent_joy_ = 0, buttons_ = 0, sent_buttons_ = 0;
    std::uint32_t pen_state_ = 0, sent_pen_ = 0x7ffff;
    void queue(std::uint8_t byte, std::uint64_t now, bool reset_idle = true);
    void report(std::uint64_t now);
    void update_stall(std::uint64_t now);
};
}
