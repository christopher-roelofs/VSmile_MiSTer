// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from mister_vtech/rtl/unsp/unsp_core.sv and MAME's interpreter.
// MAME copyright holders: Segher Boessenkool, Ryan Holtz, David Haywood.
#include "cheshire/unsp.hpp"
#include <sstream>
#include <stdexcept>

namespace cheshire {
namespace {
constexpr unsigned SP = 0, R3 = 3, R4 = 4, BP = 5, SR = 6, PC = 7;
constexpr std::uint16_t N = 0x200, Z = 0x100, S = 0x80, C = 0x40;
constexpr std::uint32_t address_mask = 0x3fffff;
[[noreturn]] void illegal(std::uint16_t op, std::uint32_t pc) {
    std::ostringstream message;
    message << "Unsupported u'nSP opcode 0x" << std::hex << op << " at word PC 0x" << pc;
    throw std::runtime_error(message.str());
}
bool branch(unsigned op, std::uint16_t sr) {
    const bool n = sr & N, z = sr & Z, s = sr & S, c = sr & C;
    switch (op) {
    case 0: return !c; case 1: return c; case 2: return !s; case 3: return s;
    case 4: return !z; case 5: return z; case 6: return !n; case 7: return n;
    case 8: return z || !c; case 9: return !z && c;
    case 10: return z || s; case 11: return !z && !s;
    case 12: return n == s; case 13: return n != s; default: return true;
    }
}
unsigned cost(unsigned form, unsigned mode, bool pc) {
    switch (form) {
    case 0: return 6; case 1: return 2; case 2: return 0;
    case 3: return pc ? 7 : 6;
    case 4:
        if (mode == 1) return pc ? 5 : 4;
        if (mode == 2 || mode == 3) return pc ? 8 : 7;
        return pc ? 5 : 3;
    case 5: case 6: return pc ? 5 : 3;
    default: return pc ? 6 : 5;
    }
}
// Explicit sign extension avoids implementation-defined unsigned-to-signed casts.
std::int32_t signed16(std::uint16_t v) { return v < 0x8000 ? v : std::int32_t(v) - 0x10000; }
}

void Unsp::reset() { state_ = {}; state_.r[PC] = bus_.read(0xfff7); }
std::uint32_t Unsp::pc() const { return (std::uint32_t(state_.r[SR] & 63) << 16) | state_.r[PC]; }
void Unsp::set_pc(std::uint32_t a) {
    a &= address_mask;
    state_.r[PC] = std::uint16_t(a);
    state_.r[SR] = std::uint16_t((state_.r[SR] & 0xffc0) | (a >> 16));
}
void Unsp::set_ds(std::uint16_t ds) { state_.r[SR] = std::uint16_t((state_.r[SR] & 0x3ff) | ((ds & 63) << 10)); }
std::uint16_t Unsp::fetch() { const auto value = bus_.read(pc()); set_pc(pc() + 1); return value; }
void Unsp::push(std::uint16_t value, unsigned reg) { bus_.write(state_.r[reg], value); --state_.r[reg]; }
std::uint16_t Unsp::pop(unsigned reg) { ++state_.r[reg]; return bus_.read(state_.r[reg]); }

int Unsp::check_interrupts(std::uint16_t lines) {
    lines &= 0x1ff;
    if (!lines) return -1;
    unsigned line = 0;
    while (!(lines & (1u << line))) ++line;
    if (line == 0 ? (!state_.fiq_enabled || state_.in_fiq) : (!state_.irq_enabled || state_.in_irq)) return -1;
    push(state_.r[PC]); push(state_.r[SR]);
    state_.r[PC] = bus_.read(line == 0 ? 0xfff6 : 0xfff7 + line);
    state_.r[SR] = 0;
    if (line == 0) state_.in_fiq = true; else state_.in_irq = true;
    return static_cast<int>(line);
}
StepResult Unsp::step(std::optional<std::uint16_t> interrupt_override) {
    const auto address = pc();
    const auto op = fetch();
    const unsigned ticks = execute(op);
    state_.cycles += ticks;
    ++state_.instructions;
    bus_.instruction_elapsed(ticks);
    const int irq = op == 0x9a98 ? -1 : check_interrupts(interrupt_override.value_or(bus_.interrupt_lines()));
    return {address, op, ticks, irq};
}

unsigned Unsp::execute(std::uint16_t op) {
    auto& r = state_.r;
    const unsigned f = op >> 12, a = (op >> 9) & 7, form = (op >> 6) & 7;
    const unsigned mode = (op >> 3) & 7, b = op & 7, imm = op & 63;
    if (f == 15) {
        switch (form) {
        case 0: case 4: {
            if (form == 4 && mode != 1) illegal(op, (pc() - 1) & address_mask);
            const std::int64_t lhs = form == 4 ? signed16(r[a]) : r[a];
            const auto product = std::uint32_t(lhs * signed16(r[b]));
            r[R3] = std::uint16_t(product); r[R4] = std::uint16_t(product >> 16);
            return 12;
        }
        case 1: {
            if ((op & 0xf3c0) != 0xf040) illegal(op, (pc() - 1) & address_mask);
            const auto target = fetch();
            push(r[PC]); push(r[SR]); set_pc((imm << 16) | target);
            return 9;
        }
        case 2:
            if ((op & 0xffc0) != 0xfe80) illegal(op, (pc() - 1) & address_mask);
            { const auto target = fetch(); set_pc((imm << 16) | target); }
            return 5;
        case 5:
            switch (imm) {
            case 0: case 1: case 2: case 3:
                state_.irq_enabled = imm & 1; state_.fiq_enabled = imm & 2; break;
            case 4: state_.fir_move = true; break;
            case 5: state_.fir_move = false; break;
            case 8: state_.irq_enabled = false; break;
            case 9: state_.irq_enabled = true; break;
            case 12: state_.fiq_enabled = false; break;
            case 14: state_.fiq_enabled = true; break;
            case 0x25: case 0x2d: case 0x35: case 0x3d: break;
            default: illegal(op, (pc() - 1) & address_mask);
            }
            return 2;
        case 6: case 7: {
            const unsigned count = form == 6 ? (mode ? mode : 16) : mode + 8;
            const auto left = r[a], right = r[b];
            std::array<std::uint16_t, 16> values{};
            std::int64_t sum = 0;
            for (unsigned i = 0; i < count; ++i) {
                values[i] = bus_.read(left + i);
                sum += std::int64_t(signed16(values[i])) * signed16(bus_.read(right + i));
            }
            state_.shift_buffer = 0;
            if (state_.fir_move)
                for (unsigned i = count - 1; i > 0; --i) bus_.write(left + i, values[i - 1]);
            // Match RTL simultaneous pointer updates when both operands alias.
            r[a] = std::uint16_t(left + count); r[b] = std::uint16_t(right + count);
            const auto result = std::uint32_t(sum);
            r[R3] = std::uint16_t(result); r[R4] = std::uint16_t(result >> 16);
            return 0; // MAME/RTL reference charges no cycles for MULS.
        }
        default: illegal(op, (pc() - 1) & address_mask);
        }
    }
    if (a == PC && form < 2) {
        if (!branch(f, r[SR])) return 2;
        set_pc(form == 0 ? pc() + imm : pc() - imm);
        return 4;
    }
    if (f == 14) illegal(op, (pc() - 1) & address_mask);
    if (form == 2 && f == 13) {
        for (unsigned i = 0; i < mode; ++i) push(r[(a - i) & 7], b);
        return 4 + 2 * mode;
    }
    if (op == 0x9a98) {
        r[SR] = pop(); r[PC] = pop();
        if (state_.in_fiq) state_.in_fiq = false; else state_.in_irq = false;
        return 8;
    }
    if (form == 2 && f == 9) {
        for (unsigned i = 1; i <= mode; ++i) r[(a + i) & 7] = pop(b);
        return 4 + 2 * mode;
    }

    std::uint16_t lhs = r[a], rhs = 0;
    std::uint32_t address = 0;
    const bool store = f == 13;
    switch (form) {
    case 0:
        address = std::uint16_t(r[BP] + imm);
        if (!store) rhs = bus_.read(address);
        break;
    case 1: rhs = std::uint16_t(imm); break;
    case 2: break;
    case 3: {
        const auto pointer = r[b];
        address = (mode & 4 ? std::uint32_t(r[SR] >> 10) << 16 : 0) | pointer;
        const unsigned update = mode & 3;
        if (update == 3) address = mode & 4 ? (address + 1) & address_mask : std::uint16_t(pointer + 1);
        if (!store) rhs = bus_.read(address);
        if (update) {
            r[b] = std::uint16_t(update == 1 ? pointer - 1 : pointer + 1);
            if (mode & 4) {
                if (update == 1 && r[b] == 0xffff) r[SR] -= 0x400;
                if (update != 1 && r[b] == 0) r[SR] += 0x400;
            }
        }
        break;
    }
    case 4:
        if (mode == 0) { rhs = r[b]; break; }
        if (mode <= 3) {
            const auto register_operand = r[b];
            const auto operand = fetch();
            if (mode == 1) { lhs = register_operand; rhs = operand; }
            else if (mode == 2) { lhs = register_operand; address = operand; if (!store) rhs = bus_.read(address); }
            else { rhs = lhs; lhs = register_operand; address = operand; }
            break;
        }
        { auto value = (std::uint32_t(r[b]) << 4) | state_.shift_buffer;
          if (value & 0x80000) value |= 0xf00000;
          value >>= mode - 3;
          rhs = std::uint16_t(value >> 4); state_.shift_buffer = value & 15; }
        break;
    case 5: {
        std::uint32_t value;
        if (mode & 4) {
            value = ((std::uint32_t(r[b]) << 4) | state_.shift_buffer) >> (mode - 3);
            rhs = std::uint16_t(value >> 4); state_.shift_buffer = value & 15;
        } else {
            value = ((std::uint32_t(state_.shift_buffer) << 16) | r[b]) << (mode + 1);
            rhs = std::uint16_t(value); state_.shift_buffer = (value >> 16) & 15;
        }
        break;
    }
    case 6: {
        auto value = (std::uint32_t(state_.shift_buffer) << 20) | (std::uint32_t(r[b]) << 4) | state_.shift_buffer;
        if (mode & 4) { value >>= mode - 3; state_.shift_buffer = value & 15; }
        else { value <<= mode + 1; state_.shift_buffer = (value >> 20) & 15; }
        rhs = std::uint16_t(value >> 4);
        break;
    }
    case 7: address = imm; rhs = bus_.read(address); break;
    }
    if (store) { bus_.write(address, lhs); return cost(form, mode, a == PC); }
    std::uint32_t result = 0;
    std::uint16_t flag_rhs = rhs;
    bool arithmetic = false, write_back = true;
    switch (f) {
    case 0: case 1:
        result = std::uint32_t(lhs) + rhs + (f == 1 && (r[SR] & C) ? 1 : 0); arithmetic = true; break;
    case 2: case 3: case 4:
        flag_rhs = std::uint16_t(~rhs);
        result = std::uint32_t(lhs) + flag_rhs + (f == 3 ? (r[SR] & C ? 1 : 0) : 1);
        arithmetic = true; write_back = f != 4; break;
    case 6: result = std::uint16_t(0 - rhs); break;
    case 8: result = lhs ^ rhs; break;
    case 9: result = rhs; break;
    case 10: result = lhs | rhs; break;
    case 11: case 12: result = lhs & rhs; write_back = f != 12; break;
    default: illegal(op, (pc() - 1) & address_mask);
    }
    if (a != PC) {
        auto sr = std::uint16_t(r[SR] & ~(N | Z));
        if (result & 0x8000) sr |= N;
        if (std::uint16_t(result) == 0) sr |= Z;
        if (arithmetic) {
            sr &= ~(S | C);
            const bool carry = result & 0x10000;
            if (carry) sr |= C;
            if (carry != bool((lhs ^ flag_rhs) & 0x8000)) sr |= S;
        }
        r[SR] = sr;
    }
    if (write_back) {
        if (form == 4 && mode == 3) bus_.write(address, std::uint16_t(result));
        else r[a] = std::uint16_t(result);
    }
    return cost(form, mode, a == PC);
}
}
