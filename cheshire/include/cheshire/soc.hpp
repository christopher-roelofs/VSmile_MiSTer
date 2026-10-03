// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "cheshire/controller.hpp"
#include "cheshire/rom.hpp"
#include "cheshire/spu.hpp"
#include <array>
#include <functional>
#include <span>

namespace cheshire {
class Soc {
public:
    static constexpr std::uint64_t master_clock = 27000000;
    explicit Soc(std::array<std::uint16_t, 0x4000>& memory);
    void reset(bool baby, bool pal, bool reference_timing, Peripheral peripheral, std::uint8_t keyboard_layout = 0x40);
    void advance(std::uint64_t ticks);
    std::uint64_t ticks() const { return now_; }
    std::uint64_t frames() const { return frames_; }
    unsigned vpos() const { return line_; }
    unsigned hpos() const;
    std::uint16_t interrupts() const;
    std::uint16_t read(std::uint32_t address, const std::array<std::uint16_t, 3>& inputs, unsigned csb, unsigned ds);
    void write(std::uint32_t address, std::uint16_t value);
    std::uint16_t gpio_output(unsigned port) const;
    std::uint16_t gpio_direction(unsigned port) const;
    void select_controller(bool select) { port_->select(select, now_); }
    void set_input(const InputState& input);
    bool controller_rts() const { return port_->rts(); }
    const SerialController& controller() const { return *port_; }
    std::uint64_t received_bytes() const { return rx_bytes_; }
    std::uint64_t transmitted_bytes() const { return tx_bytes_; }
    void receive_uart(std::uint8_t byte);
    void sprite_dma_done();
    bool take_watchdog_reset();
    void serialize(StateArchive& archive);
    // Called as each scanline begins, with its number.
    std::function<void(unsigned)> line_started;
    Spu& spu() { return spu_; }
    const Spu& spu() const { return spu_; }
private:
    enum Event : unsigned { system_timer, rng, timebase1, timebase2, timer_a, timer_b,
        video_line, video_position, watchdog, adc_once, adc_auto, uart_tx, uart_rx, audio, event_count };
    struct Timer {
        std::uint64_t deadline = Joystick::never;
        unsigned frequency = 0, phase = 0;
    };
    std::span<std::uint16_t, 128> io_;
    std::span<std::uint16_t, 256> video_;
    std::array<Timer, event_count> timers_{};
    Joystick pad_;
    Keyboard keyboard_;
    SerialController* port_ = &pad_;
    Spu spu_;
    std::deque<std::uint8_t> rx_fifo_;
    std::uint64_t now_ = 0, frames_ = 0, line_start_ = 0, rx_bytes_ = 0, tx_bytes_ = 0;
    unsigned line_ = 240, line_length_ = 1716, line_fraction_ = 0;
    unsigned system_divider_ = 0, a_divider_ = 0, a_rate_ = 0;
    std::uint16_t a_preload_ = 0, b_preload_ = 0;
    bool baby_ = false, pal_ = false, reference_ = false, baud28_ = false;
    bool rx_available_ = false, rx_irq_ = false, tx_irq_ = false, fiq_selected_ = false, reset_pending_ = false;
    std::uint8_t baby_buttons_ = 0, baby_mode_ = 0;
    void periodic(Event event, unsigned frequency);
    void reschedule(Event event);
    void schedule_position();
    void event(Event event);
    unsigned uart_frame_ticks() const;
    void adc_done();
};
}
