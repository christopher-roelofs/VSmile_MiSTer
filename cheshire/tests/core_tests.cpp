// SPDX-License-Identifier: GPL-2.0-or-later
#include "cheshire/audio.hpp"
#include "cheshire/machine.hpp"
#include "cheshire/trace.hpp"
#include "cheshire/video.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <utility>

using namespace cheshire;
namespace {
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
template<class F> void rejects(F function, const char* message) {
    try { function(); } catch (const std::exception&) { return; }
    throw std::runtime_error(message);
}
struct TestBus : WordBus {
    std::unordered_map<std::uint32_t, std::uint16_t> words;
    std::uint16_t read(std::uint32_t a) override { return words[a & 0x3fffff]; }
    void write(std::uint32_t a, std::uint16_t v) override { words[a & 0x3fffff] = v; }
};
constexpr std::uint16_t alu(unsigned f, unsigned a, unsigned form, unsigned mode = 0, unsigned b = 0) {
    return std::uint16_t((f << 12) | (a << 9) | (form << 6) | (mode << 3) | b);
}
void cpu_tests() {
    TestBus bus;
    bus.words[0xfff7] = 0x8000;
    Unsp cpu(bus); cpu.reset();
    require(cpu.pc() == 0x8000 && cpu.state().fir_move, "Reset vector/state");
    auto state = cpu.state(); state.r[1] = 0xffff; cpu.set_state(state);
    bus.words[0x8000] = alu(0, 1, 1, 0, 1); // add 1
    require(cpu.step().cycles == 2, "ADD cycles");
    require(cpu.state().r[1] == 0 && (cpu.state().r[6] & 0x340) == 0x140, "ADD carry/zero/sign flags");
    state = cpu.state(); state.r[1] = 0x8000; state.r[2] = 1; cpu.set_state(state);
    bus.words[cpu.pc()] = alu(2, 1, 4, 0, 2);
    cpu.step();
    require(cpu.state().r[1] == 0x7fff && (cpu.state().r[6] & 0x2c0) == 0xc0, "SUB overflow flags");
    bus.words[cpu.pc()] = alu(4, 1, 1, 0, 1);
    cpu.step(); require(cpu.state().r[1] == 0x7fff, "CMP must not write back");
    state = {}; state.r[7] = 0xffff; state.r[6] = 2; cpu.set_state(state);
    bus.words[0x2ffff] = 0xf165;
    cpu.step(); require(cpu.pc() == 0x30000, "PC segment carry");
    state = {}; state.r[7] = 0x8000; cpu.set_state(state);
    bus.words[0x8000] = alu(0, 1, 4, 1, 7); bus.words[0x8001] = 3;
    cpu.step(); require(cpu.state().r[1] == 0x8004, "Immediate ALU captures PC source before operand fetch");
    state = {}; state.r[7] = 0x8000; state.r[1] = 0x200; cpu.set_state(state);
    bus.words[0x8000] = alu(9, 0, 2, 1, 1); bus.words[0x201] = 0x3456;
    cpu.step(); require(cpu.state().r[1] == 0x3456, "POP loaded value wins when destination aliases stack pointer");
    state = {}; state.r[7] = 0x8000; state.r[2] = 0xffff; state.r[6] = 4 << 10; cpu.set_state(state);
    bus.words[0x8000] = alu(9, 1, 3, 6, 2); bus.words[0x4ffff] = 0xabcd;
    cpu.step();
    require(cpu.state().r[1] == 0xabcd && cpu.state().r[2] == 0 && cpu.state().r[6] >> 10 == 5, "DS postincrement rollover");
    state = {}; state.r[7] = 0x8000; state.r[2] = 0xffff; state.r[6] = 4 << 10; cpu.set_state(state);
    bus.words[0x8000] = alu(9, 1, 3, 7, 2); bus.words[0x50000] = 0x1234;
    cpu.step(); require(cpu.state().r[1] == 0x1234, "DS preincrement effective address");
    state = {}; state.r[7] = 0x8000; state.r[1] = 0x8000; cpu.set_state(state);
    bus.words[0x8000] = alu(9, 2, 4, 4, 1);
    cpu.step(); require(cpu.state().r[2] == 0xc000, "Arithmetic right shift sign extension");
    state = {}; state.r[7] = 0x8000; state.r[1] = 0xffff; state.r[2] = 2; cpu.set_state(state);
    bus.words[0x8000] = 0xf30a; // R1 * R2 signed
    cpu.step(); require(cpu.state().r[3] == 0xfffe && cpu.state().r[4] == 0xffff, "Signed multiply");
    state = {}; state.r[7] = 0x8000; state.r[0] = 0x200; state.r[6] = 0x8400; cpu.set_state(state);
    bus.words[cpu.pc()] = 0xf043; bus.words[cpu.pc() + 1] = 0x9000;
    require(cpu.step().cycles == 9 && cpu.pc() == 0x39000, "Far CALL target/cost");
    require(bus.words[0x200] == 0x8002 && bus.words[0x1ff] == 0x8400 && cpu.state().r[0] == 0x1fe, "Far CALL stack");
    bus.words[0x39000] = 0x9a98;
    cpu.step(); require(cpu.pc() == 0x8002 && cpu.state().r[0] == 0x200, "Far return stack");
    state = {}; state.r[7] = 0x8000; state.r[0] = 0x200; cpu.set_state(state);
    bus.words[0x8000] = 0xf141; bus.words[0xfff8] = 0x9000;
    require(cpu.step(2).interrupt == 1 && cpu.state().in_irq && cpu.pc() == 0x9000, "Enable IRQ takes pending interrupt immediately");
    bus.words[0x9000] = 0x9a98;
    require(cpu.step(2).interrupt == -1 && cpu.pc() == 0x8001 && !cpu.state().in_irq, "RETI skips interrupt check");
    bus.words[0x8001] = 0xf165;
    require(cpu.step(2).interrupt == 1, "Level interrupt can retrigger after RETI");
    state = {}; state.r[7] = 0x8000; state.r[0] = 0x200; state.irq_enabled = true; cpu.set_state(state);
    bus.words[0x8000] = 0xf165;
    require(cpu.step(3).interrupt == -1, "Disabled FIQ blocks lower-priority IRQ");
    state = {}; state.r[7] = 0x8000; state.r[1] = 0x100; state.r[2] = 0x110; cpu.set_state(state);
    bus.words[0x8000] = 0xf392; // MULS signed, size 2
    bus.words[0x100] = 3; bus.words[0x101] = 0xfffc; bus.words[0x110] = 2; bus.words[0x111] = 5;
    cpu.step();
    require(cpu.state().r[3] == 0xfff2 && cpu.state().r[4] == 0xffff && bus.words[0x101] == 3, "MULS accumulation/FIR writeback");
    state = {}; state.r[7] = 0x8000; cpu.set_state(state); bus.words[0x8000] = 0xe100;
    rejects([&] { cpu.step(); }, "Unknown opcode must fail explicitly");
}
Rom image(std::size_t bytes, std::uint16_t reset = 0x8000, std::string_view marker = {}) {
    std::vector<std::uint8_t> data(bytes, 0);
    if (bytes >= 0x1fff0) { data[0x1ffee] = reset & 255; data[0x1ffef] = reset >> 8; }
    for (std::size_t i = 0; i < marker.size(); ++i) data[0x100 + 2 * i] = marker[i];
    return Rom::from_bytes(data);
}
void board_tests() {
    const std::array<std::uint8_t, 6> bytes = {0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a};
    const auto rom = Rom::from_bytes(bytes);
    require(rom.read(0) == 0x1234 && rom.read(1) == 0x5678 && rom.read(3) == 0xffff && rom.read(4) == 0x1234, "Little-endian loading, padding and ROM mirroring");
    rejects([] { Rom::from_bytes(std::array<std::uint8_t, 1>{0}); }, "Odd-length ROM rejection");
    Machine m;
    m.load_cartridge(image(0x20000, 0x5152));
    require(m.system() == System::baby && m.read(0x3d06) == 0x80, "Baby detection/GPIO");
    m.load_cartridge(image(0x20000, 0x8000, "V.Smile\\084"));
    require(m.system() == System::vsmile, "Auto Motion requires BIOS as in FPGA core");
    m.load_bios(image(2 * 1024 * 1024));
    require(m.system() == System::motion && m.read(0x3d01) == 0xc000, "Motion BIOS/detection");
    m.write(0x3d23, 0x80);
    require(m.read(0x30fff7) == 0x8000, "BIOS window banking");
    m.write(0x20, 0x1234); m.write(0x21, 0x5678);
    m.write(0x3e00, 0x20); m.write(0x3e01, 0); m.write(0x3e03, 0x30); m.write(0x3e02, 2);
    require(m.read(0x30) == 0x1234 && m.read(0x31) == 0x5678 && m.read(0x3e02) == 0 && m.read(0x3e00) == 0x22, "System DMA effects/register updates");
    m.write(0x2870, 0x20); m.write(0x2871, 0x3ff); m.write(0x2872, 2);
    require(m.read(0x2fff) == 0x1234 && m.read(0x3000) == 0, "Sprite DMA clips at RAM boundary");
    m.load_cartridge(image(0x20000, 0x8000, "80670"));
    require(m.cartridge_info().nvram && m.cartridge_info().peripheral == Peripheral::tablet, "Art Studio identification");
    m.write(0x3d23, 0x40); m.write(0x200000, 0xabcd);
    require(m.read(0x300000) == 0xabcd, "Cart RAM mirrors in mode 1");
    m.write(0x3d23, 0x80); require(m.read(0x200000) == 0xabcd && m.read(0x300000) != 0xabcd, "BIOS replaces upper RAM window in mode 2");
    m.reset(); m.write(0x3d23, 0x40); require(m.read(0x200000) == 0xabcd, "Reset preserves cartridge RAM");
    std::vector<std::uint8_t> large(16 * 1024 * 1024, 0);
    large[0x8000] = 0x12; large[0x808000] = 0x34;
    m.load_cartridge(Rom::from_bytes(large));
    require(m.read(0x4000) == 0x12, "16 MB cart low bank");
    m.write(0x3d09, 2); m.write(0x3d08, 2); m.write(0x3d06, 0);
    require(m.read(0x4000) == 0x34, "GPIO selects 16 MB cart high bank");
    setup_demo(m);
    const auto before = presented_frame(m, true);
    require(before.size() == 320 * 240 && before[110 * 320 + 150] == 0xffff00ff, "Demo sprite renderer pixel");
    for (unsigned i = 0; i < 4; ++i) m.step();
    require(m.peek(0x2c01) == 151 && m.cpu().pc() == 0x8000, "Demo CPU updates sprite and loops");
    const auto after = presented_frame(m, true);
    require(after[110 * 320 + 150] == 0xff000000 && after[110 * 320 + 151] == 0xffff00ff, "CPU writes alter rendered sprite");
}
struct TempDirectory {
    std::filesystem::path path;
    TempDirectory() {
        const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
        path = std::filesystem::temp_directory_path() / ("cheshire-test-" + std::to_string(stamp));
        if (!std::filesystem::create_directory(path)) throw std::runtime_error("Cannot create test directory");
    }
    ~TempDirectory() { std::error_code error; std::filesystem::remove_all(path, error); }
};
void trace_and_save_tests() {
    TempDirectory temporary;
    Machine m;
    setup_demo(m);
    {
        std::ofstream cpu(temporary.path / "cpu.tr");
        cpu << "0000 0000 0000 0000 0000 0000 0000 008000: r1 = [2c01]\n"
            << "0096 0000 0000 0000 0000 0000 0000 008002: r1 += 1\n";
        std::ofstream mem(temporary.path / "mem.log");
    }
    { TraceSession trace(m, temporary.path); require(trace.step() && trace.step() && !trace.step(), "Instruction trace parsing/comparison/end"); }
    setup_demo(m);
    { std::ofstream cpu(temporary.path / "cpu.tr"); cpu << "0001 0000 0000 0000 0000 0000 0000 008000: wrong r1\n"; }
    { TraceSession trace(m, temporary.path); rejects([&] { trace.step(); }, "Trace rejects changed register"); }
    m.load_cartridge(image(0x20000, 0x8000, "80670"));
    m.write(0x3d23, 0x40); m.write(0x200000, 0x1234); m.write(0x2fffff, 0xabcd);
    m.write_save(temporary.path / "save.sav");
    m.load_cartridge(image(0x20000, 0x8000, "80670")); m.load_save(temporary.path / "save.sav"); m.write(0x3d23, 0x40);
    require(m.read(0x200000) == 0x1234 && m.read(0x2fffff) == 0xabcd, "Portable backup RAM serialization round trip");
}
void timed_soc_tests() {
    MachineConfig config; config.reference_timing = true;
    Machine m(config); setup_demo(m);
    m.step(); require(m.soc().ticks() == 7 && m.cpu().state().cycles == 7, "CPU cycle charges advance emulated time");
    m.reset(); m.write(0x2862, 1); m.advance(449999);
    require(m.soc().frames() == 0, "Reference frame must not end early");
    m.advance(1);
    require(m.soc().frames() == 1 && m.read(0x2838) == 240 && m.interrupt_lines() == 2, "Exact 450000-tick reference frame/vblank IRQ");
    m.write(0x2863, 1); require(m.interrupt_lines() == 0, "Video status is write-one-to-clear");
    m.write(0x3d2e, 0); m.advance(450000);
    require(m.interrupt_lines() == 1, "FIQ selection routes video interrupt");
    Machine hardware; hardware.write(0x2862, 2); hardware.write(0x2836, 0); hardware.write(0x2837, 5);
    hardware.advance(37805); require(hardware.interrupt_lines() == 0, "Beam position IRQ must not fire early");
    hardware.advance(1); require(hardware.interrupt_lines() == 2 && hardware.soc().hpos() == 10, "Horizontal/vertical beam position IRQ");
    hardware.reset(); hardware.advance(449592); require(hardware.soc().frames() == 1, "Hardware timing follows FPGA line lengths");
    MachineConfig pal_config; pal_config.pal = true;
    Machine pal(pal_config); pal.advance(539136);
    require(pal.soc().frames() == 1 && pal.read(0x3d2b) == 1, "PAL frame clock and GPIO TV-mode register");
    m.reset();
    require(m.read(0x3d23) == 0x28 && m.read(0x3d2c) == 0x1418 && m.read(0x3d2c) == 0x2830, "I/O reset values and PRNG read side effect");
    m.write(0x3d21, 0x40); m.advance(6591); require(m.interrupt_lines() == 0, "4096 Hz timer first deadline");
    m.advance(1); require(m.interrupt_lines() == 0x80 && (m.read(0x3d22) & 0x40), "System timer IRQ/status");
    m.write(0x3d22, 0x40); require(m.interrupt_lines() == 0, "I/O status acknowledgment");
    m.reset(); m.write(0x3d12, 0xfffe); m.write(0x3d13, 0x32); m.write(0x3d21, 0x800);
    m.advance(1647); require(m.read(0x3d12) == 0xffff && m.interrupt_lines() == 0, "Timer A count before overflow");
    m.advance(1); require(m.read(0x3d12) == 0xfffe && m.interrupt_lines() == 8, "Timer A overflow reload and IRQ");
    m.write(0x3d15, 0); require(m.interrupt_lines() == 0, "Timer A IRQ clear strobe");
    m.reset(); m.write(0x3d16, 0xffff); m.write(0x3d17, 4); m.write(0x3d18, 1); m.write(0x3d21, 0x400);
    m.advance(6592); require(m.read(0x3d16) == 0xffff && m.interrupt_lines() == 8, "Timer B overflow reload");
    m.write(0x3d19, 0); m.write(0x3d18, 0); m.advance(6592); require(m.interrupt_lines() == 0, "Timer B stops when disabled");
    m.reset(); m.write(0x3d10, 0); m.advance(210938);
    require((m.read(0x3d22) & 3) == 2, "Timebase2 128 Hz rate");
    m.advance(3375000 - 210938); require((m.read(0x3d22) & 3) == 3, "Timebase1 8 Hz rate");
    m.reset(); m.write(0x3d25, 0x1201); m.advance(15);
    require(!(m.read(0x3d27) & 0x8000), "ADC conversion remains busy before deadline");
    m.advance(1); require(m.read(0x3d27) == 0x8fff && (m.read(0x3d22) & 0x2000), "ADC conversion result and IRQ");
    m.reset(); m.write(0x3d08, 2); m.write(0x3d06, 0);
    require(m.soc().gpio_output(1) == 2 && (m.read(0x3d06) & 2), "GPIO attribute inversion");
    m.write(0x3d09, 2); require(!(m.soc().gpio_output(1) & 2), "GPIO attribute write recomputes board output");
    setup_demo(m); auto state = m.cpu().state(); state.r[7] = 0x8100; m.cpu().set_state(state);
    m.write(0x3d20, 0x8000); m.advance(20249999); require(m.cpu().pc() == 0x8100, "Watchdog deadline");
    m.write(0x3d24, 0x55aa); m.advance(20249999); require(m.cpu().pc() == 0x8100, "Watchdog kick reschedules deadline");
    m.advance(1); require(m.cpu().pc() == 0x8000 && m.soc().ticks() == 40499999, "Watchdog resets CPU without rewinding master clock");
    Machine whole(config), pieces(config);
    whole.write(0x3d10, 0x1f); pieces.write(0x3d10, 0x1f);
    whole.advance(100000);
    for (unsigned i = 0; i < 100; ++i) pieces.advance(1000);
    require(whole.memory() == pieces.memory() && whole.soc().ticks() == pieces.soc().ticks()
        && whole.soc().hpos() == pieces.soc().hpos(), "Scheduler result is independent of host chunk sizes");
}
void uart_controller_tests() {
    Machine m;
    m.write(0x3d33, 0xa0); m.write(0x3d34, 0xfe); m.write(0x3d30, 0xc3); m.write(0x3d21, 0x100);
    require(m.read(0x3d31) == 2, "Enabling UART transmitter sets ready");
    m.write(0x3d35, 0x70); m.soc().receive_uart(0x42);
    m.advance(56319); require(m.read(0x3d31) == 0x40, "UART frame timing before completion");
    m.advance(1); require(m.read(0x3d31) == 0x83 && m.interrupt_lines() == 16, "UART TX/RX completion and IRQ");
    require(m.read(0x3d36) == 0x42 && m.read(0x3d31) == 2, "UART receive buffer read side effects");
    m.write(0x3d31, 1); require(m.interrupt_lines() == 16, "TX interrupt survives RX acknowledgment");
    m.write(0x3d31, 2); require(m.interrupt_lines() == 0, "UART status acknowledges both sources");
    for (unsigned i = 0; i < 9; ++i) m.soc().receive_uart(std::uint8_t(i));
    require(m.read(0x3d37) & 0x4000, "Bounded UART FIFO reports overflow");
    m.write(0x3d37, 0x4000); require(!(m.read(0x3d37) & 0x4000), "UART overflow status is write-one-to-clear");
    MachineConfig config; config.system = System::baby;
    Machine baby(config); baby.write(0x3d33, 0xea07); baby.write(0x3d30, 0x41);
    InputState input; input.baby_buttons = 1; baby.set_input(input);
    baby.advance(56249); require(!(baby.read(0x3d31) & 1), "Baby baud divisor before frame end");
    baby.advance(1); require(baby.read(0x3d36) == 5 && baby.read(0x3d36) == 0xfe, "Baby button packet and 4800 baud formula");
    input.baby_buttons = 0; input.baby_mode = 2; baby.set_input(input); baby.advance(56250);
    require(baby.read(0x3d36) == 12 && baby.read(0x3d36) == 0x80, "Baby mode switch packet");
    Joystick pad;
    std::vector<std::uint8_t> bytes; std::vector<bool> rts;
    pad.byte_out = [&](std::uint8_t byte) { bytes.push_back(byte); };
    pad.rts_out = [&](bool value) { rts.push_back(value); };
    pad.reset(0, true, false); pad.select(true, 0);
    for (unsigned i = 0; i < 6; ++i) pad.event(pad.next_event());
    require(bytes == std::vector<std::uint8_t>({0x55, 0x80, 0xc0, 0x90, 0xa0}) && pad.active() && !pad.rts(), "Joystick keep-alive/full initial report/RTS");
    const auto now = 27000000ull + 5 * 28125;
    pad.receive(0x70, now); pad.event(pad.next_event()); require(bytes.back() == 0xba, "Joystick probe checksum response");
    input = {}; input.directions = 1; input.colors = 4; input.buttons = 1;
    pad.set_input(input, now + 28125);
    for (unsigned i = 0; i < 3; ++i) pad.event(pad.next_event());
    require(bytes[bytes.size() - 3] == 0x87 && bytes[bytes.size() - 2] == 0x94 && bytes.back() == 0xa1, "Joystick directions/colors/buttons protocol");
    // Exercise board select + both serial delays, not just the controller model.
    m.reset(); m.write(0x3d33, 0xa0); m.write(0x3d34, 0xfe); m.write(0x3d30, 0xc1);
    m.write(0x3d0e, 0x100); m.write(0x3d0d, 0x100); m.write(0x3d0b, 0x100); m.write(0x3d35, 0x70);
    m.advance(56320 + 28125 + 56320);
    require(m.read(0x3d36) == 0xba && m.soc().transmitted_bytes() == 1 && m.soc().received_bytes() >= 1, "End-to-end GPIO select/UART/controller probe");
}
void spu_tests() {
    std::vector<std::uint16_t> rom(0x20000, 0);
    std::vector<std::pair<int, int>> out;
    Spu spu;
    spu.memory_read = [&](std::uint32_t a) { return rom[a & 0x1ffff]; };
    spu.sample_sink = [&](std::int16_t l, std::int16_t r) { out.emplace_back(l, r); };
    spu.reset(false);
    // Channel 0: 16-bit hardware one-shot at 0x10000, one fetch per sample, no interpolation.
    rom[0x10000] = 0xc000; rom[0x10001] = 0xffff;
    spu.write(0x3001, 0x5001); spu.write(0x3003, 0x407f); spu.write(0x3005, 0x7f); spu.write(0x3200, 2);
    spu.write(0x340d, 0x240); spu.write(0x3401, 0xff);
    require(spu.read(0x3401) == 0x7f && spu.read(0x340d) == 0x240, "SPU control register masks");
    spu.write(0x3400, 1);
    require(spu.channel_status() == 1, "SPU channel start");
    spu.tick();
    require(out.back() == std::pair(3937, 3968), "SPU 16-bit sample, envelope, pan, gain and main volume");
    spu.tick();
    require(spu.channel_status() == 0 && !(spu.read(0x340b) & 1) && out.back() == std::pair(0, 0), "16-bit one-shot end stops without STOP bit");
    // Channel 1: IMA ADPCM one-shot with its sample FIQ enabled.
    rom[0x10010] = 0x0007;
    spu.write(0x3011, 0x9001); spu.write(0x3010, 0x0010); spu.write(0x3210, 2); spu.write(0x3402, 2);
    spu.write(0x3400, 2); spu.tick();
    require(spu.read(0x301b) == 0x800b && spu.fiq(), "IMA ADPCM first nibble and channel FIQ");
    spu.write(0x3403, 2); require(!spu.fiq(), "Channel FIQ acknowledge");
    spu.tick(); require(spu.read(0x301b) == 0x800d && spu.read(0x3010) == 0x0010, "IMA ADPCM step adaptation and nibble shift");
    // Channel 2: software sample with an automatic envelope ramping up, then loading its next entry.
    rom[0x10100] = 0x2088;
    spu.write(0x3415, 0x3b); spu.write(0x3406, 0x0100);
    spu.write(0x3021, 0x4000); spu.write(0x302b, 0xc000); spu.write(0x3024, 0x4010);
    spu.write(0x3027, 1); spu.write(0x3028, 0x100); spu.write(0x3400, 4);
    for (unsigned i = 0; i < 7; ++i) spu.tick();
    require((spu.read(0x3025) & 127) == 0, "Envelope clock divider");
    spu.tick(); require((spu.read(0x3025) & 127) == 0x10, "Envelope increment");
    for (unsigned i = 0; i < 24; ++i) spu.tick();
    require((spu.read(0x3025) & 127) == 0x40 && spu.read(0x3024) == 0x2088, "Envelope target loads next entry");
    // Beat counter IRQ through the board's IRQ4 line.
    Machine m;
    m.write(0x3404, 1); m.write(0x3405, 0x8001);
    m.advance(Spu::ticks_per_sample - 1); require(!(m.interrupt_lines() & 0x20), "Beat IRQ before sample tick");
    m.advance(1); require(m.interrupt_lines() & 0x20, "Beat IRQ on IRQ4");
    m.write(0x3405, 0x4000); require(!(m.interrupt_lines() & 0x20), "Beat IRQ acknowledge");
    require(m.soc().spu().samples() == 1, "SPU sample period");
}
void scanline_video_tests() {
    // Demo sprite: 16x16 at (150, 110), magenta. NTSC line 0 starts 22 lines after reset.
    Machine m; setup_demo(m);
    const std::uint64_t line0 = 22 * 1716, line = 1716;
    m.advance(line0 + 115 * line + 10); // lines 0..116 are drawn
    m.write(0x2c01, 50);
    m.advance(240 * line);
    const auto& frame = m.display().frame();
    require(m.display().completed_frames() == 1, "Frame published at vblank");
    require(frame[112 * 320 + 150] == 0xffff00ff && frame[112 * 320 + 50] == 0xff000000, "Lines drawn before a write keep the old sprite position");
    require(frame[120 * 320 + 50] == 0xffff00ff && frame[120 * 320 + 150] == 0xff000000, "Lines drawn after a write use the new sprite position");
    m.write(0x2830, 0x80);
    m.advance(262 * line);
    require(m.display().frame()[120 * 320 + 50] == 0xff7f007f, "Fade offset subtracts from each 8-bit channel");
}
void keyboard_tests() {
    std::vector<std::uint8_t> bytes;
    Keyboard kb;
    kb.byte_out = [&](std::uint8_t byte) { bytes.push_back(byte); };
    const auto run_until = [&](std::size_t count) {
        for (unsigned guard = 0; bytes.size() < count && guard < 10000; ++guard) kb.event(kb.next_event());
    };
    // Smart Keyboard (French): ID three times after the hello RTS pulse, then its layout.
    kb.reset(0, true, false, 0x42); kb.select(true, 0);
    run_until(3);
    require(bytes == std::vector<std::uint8_t>({0x52, 0x52, 0x52}) && !kb.running(), "Keyboard hello ID");
    for (std::uint8_t b : {0x02, 0x02, 0xe6, 0xd6, 0x60}) kb.receive(b, kb.next_event());
    run_until(4);
    require(kb.running() && kb.active() && bytes.back() == 0x42, "Keyboard handshake answers its layout");
    InputState input;
    input.keys[2] = 2; kb.set_input(input, 0); run_until(5);
    require(bytes.back() == 0x1b, "Key press code (A)");
    input.keys[2] = 0; input.keys[3] = 1; kb.set_input(input, 0); run_until(7);
    require(bytes[5] == 0xdb && bytes[6] == 0xa9, "Key release code and Shift press");
    input.keys[3] = 0; kb.set_input(input, 0); run_until(8);
    require(bytes.back() == 0xaa, "Shift release code");
    input.directions = 1; input.buttons = 1; kb.set_input(input, 0); run_until(9);
    require(bytes.back() == 0x87, "Keyboard joystick up");
    run_until(10); require(bytes.back() == 0xa1, "Keyboard OK button");
    // Art Studio tablet: its ID, the cart's three-byte answer, no layout, then pen reports.
    bytes.clear();
    kb.reset(0, true, true, 0x40); kb.select(true, 0);
    run_until(3);
    require(bytes == std::vector<std::uint8_t>({0x54, 0x54, 0x54}), "Tablet ID");
    input = {}; input.pen_down = true; input.pen_x = 0x123; input.pen_y = 0xab;
    kb.set_input(input, 0);
    for (std::uint8_t b : {0xe6, 0xd6, 0x60}) kb.receive(b, kb.next_event());
    run_until(7);
    require(bytes == std::vector<std::uint8_t>({0x54, 0x54, 0x54, 0x41, 0x12, 0x0e, 0x2b}), "Tablet pen packet without layout byte");
    kb.receive(0x70, kb.next_event()); run_until(8);
    require(bytes.back() == 0xb0 + ((0x70 + 15) & 15 ^ 5), "Tablet probe answer");
}
void save_state_tests() {
    Machine m; setup_demo(m);
    for (unsigned i = 0; i < 2000; ++i) m.step();
    m.write(0x3404, 1); m.write(0x3405, 0x8003); m.advance(100000);
    const auto state = m.save_state();
    const auto cpu = m.cpu().state();
    const auto frame = presented_frame(m, true);
    std::vector<std::pair<int, int>> after_a, after_b;
    m.soc().spu().sample_sink = [&](std::int16_t l, std::int16_t r) { after_a.emplace_back(l, r); };
    for (unsigned i = 0; i < 5000; ++i) m.step();
    const auto end_a = m.cpu().state();
    m.load_state(state);
    require(m.cpu().state().instructions == cpu.instructions && m.cpu().state().r == cpu.r
        && presented_frame(m, true) == frame, "State restores CPU and video");
    m.soc().spu().sample_sink = [&](std::int16_t l, std::int16_t r) { after_b.emplace_back(l, r); };
    for (unsigned i = 0; i < 5000; ++i) m.step();
    require(m.cpu().state().cycles == end_a.cycles && m.cpu().state().r == end_a.r && after_a == after_b && !after_a.empty(),
        "Execution after a restored state repeats exactly");
    // Refusals leave the machine unchanged.
    const auto before = m.save_state();
    auto truncated = state; truncated.resize(truncated.size() / 2);
    rejects([&] { m.load_state(truncated); }, "Truncated state rejected");
    require(m.save_state() == before, "Failed load leaves the machine unchanged");
    auto other_bytes = std::vector<std::uint8_t>(0x20000, 0);
    other_bytes[2 * 0xfff7 + 1] = 0x80; other_bytes[1] = 1;
    Machine other; other.load_cartridge(Rom::from_bytes(other_bytes));
    rejects([&] { other.load_state(state); }, "State for another cartridge rejected");
    Machine pal(MachineConfig{.pal = true}); setup_demo(pal);
    rejects([&] { pal.load_state(state); }, "State for another TV standard rejected");
}
}
int main() {
    try { cpu_tests(); board_tests(); trace_and_save_tests(); timed_soc_tests(); uart_controller_tests(); spu_tests(); scanline_video_tests(); keyboard_tests(); save_state_tests(); std::cout << "Core tests passed\n"; return 0; }
    catch (const std::exception& e) { std::cerr << "FAIL: " << e.what() << '\n'; return 1; }
}
