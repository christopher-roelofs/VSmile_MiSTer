// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <array>
#include <cstdint>
#include <optional>

namespace cheshire {
class WordBus {
public:
    virtual ~WordBus() = default;
    virtual std::uint16_t read(std::uint32_t address) = 0;
    virtual void write(std::uint32_t address, std::uint16_t value) = 0;
    virtual void instruction_elapsed(unsigned) {}
    virtual std::uint16_t interrupt_lines() const { return 0; }
};

struct CpuState {
    // SP, R1..R4, BP, SR, PC. Addresses are words, not bytes.
    std::array<std::uint16_t, 8> r{};
    std::uint8_t shift_buffer = 0;
    bool irq_enabled = false, fiq_enabled = false;
    bool in_irq = false, in_fiq = false, fir_move = true;
    std::uint64_t cycles = 0, instructions = 0;
};

struct StepResult {
    std::uint32_t pc;
    std::uint16_t opcode;
    unsigned cycles;
    int interrupt = -1;
};

class Unsp {
public:
    explicit Unsp(WordBus& bus) : bus_(bus) {}
    void reset();
    StepResult step(std::optional<std::uint16_t> interrupt_override = {});
    std::uint32_t pc() const;
    const CpuState& state() const { return state_; }
    void set_state(const CpuState& state) { state_ = state; }
    void set_ds(std::uint16_t ds);
private:
    WordBus& bus_;
    CpuState state_;
    void set_pc(std::uint32_t address);
    std::uint16_t fetch();
    void push(std::uint16_t value, unsigned reg = 0);
    std::uint16_t pop(unsigned reg = 0);
    unsigned execute(std::uint16_t opcode);
    int check_interrupts(std::uint16_t lines);
};
}
