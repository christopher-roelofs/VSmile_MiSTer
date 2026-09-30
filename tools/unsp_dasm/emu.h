// Minimal stand-ins for the MAME types MAME's uNSP disassembler uses, so it
// builds on its own (tools/unsp_dasm).
#pragma once
#include <cstdint>
#include <cstdio>
#include <ostream>
#include <string>
#include <vector>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint32_t offs_t;
namespace util {
template <typename... A> void stream_format(std::ostream &s, const char *f, A... a)
{ char b[256]; snprintf(b, sizeof b, f, a...); s << b; }
inline void stream_format(std::ostream &s, const char *f) { s << f; }
class disasm_interface {
public:
    enum : u32 { SUPPORTED = 0x80000000, STEP_OVER = 0x20000000, STEP_OUT = 0x40000000 };
    class data_buffer {
    public:
        const std::vector<u16> *w; offs_t base;
        u16 r16(offs_t a) const { a -= base; return a < w->size() ? (*w)[a] : 0; }
    };
    virtual ~disasm_interface() = default;
    virtual u32 opcode_alignment() const = 0;
    virtual offs_t disassemble(std::ostream &, offs_t, const data_buffer &, const data_buffer &) = 0;
};
}
