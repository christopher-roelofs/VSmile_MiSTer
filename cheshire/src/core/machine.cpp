// SPDX-License-Identifier: GPL-2.0-or-later
// Board banking and DMA adapted from the user's mister_vtech core.
#include "cheshire/machine.hpp"
#include <algorithm>
#include <fstream>
#include <stdexcept>
#include <utility>

namespace cheshire {
Machine::Machine(MachineConfig config)
    : config_(config), display_(memory_.data() + 0x2800, [this](std::uint32_t a) { return peek(a); }), soc_(memory_), cpu_(*this) {
    soc_.line_started = [this](unsigned line) { scanline(line); };
    soc_.spu().memory_read = [this](std::uint32_t a) { return peek(a); };
    detect_system(); reset();
}
void Machine::detect_system() {
    system_ = config_.system;
    if (system_ == System::automatic)
        system_ = info_.baby ? System::baby : info_.motion && bios_.byte_size() ? System::motion : System::vsmile;
}
void Machine::load_cartridge(Rom rom) {
    cartridge_ = std::move(rom); info_ = cartridge_.identify(); detect_system();
    cartridge_ram_.assign(info_.nvram ? 0x100000 : 0, 0); reset();
}
void Machine::load_bios(Rom rom) {
    if (rom.byte_size() != 2 * 1024 * 1024) throw std::runtime_error("V.Smile/Motion BIOS must be exactly 2 MB");
    bios_ = std::move(rom); detect_system(); reset();
}
void Machine::reset() {
    memory_.fill(0); dma_.fill(0); chip_select_ = 0; second_bank_ = false;
    sprite_source_ = sprite_destination_ = 0;
    soc_.reset(system_ == System::baby, config_.pal, config_.reference_timing, peripheral(),
        config_.keyboard_layout.value_or(info_.keyboard_layout));
    display_.reset(config_.pal, system_ == System::baby ? 64 : 256);
    cpu_.reset();
}
void Machine::scanline(unsigned line) {
    // Line y renders during line y-1 (line 0 during the frame's last line).
    if (line == Display::rendered_lines) display_.finish_frame();
    display_.render_line(line == (config_.pal ? 311u : 261u) ? 0 : line + 1);
}
void Machine::apply_watchdog_reset() {
    if (!soc_.take_watchdog_reset()) return;
    const auto previous = cpu_.state();
    cpu_.reset();
    auto state = cpu_.state();
    state.cycles = previous.cycles; state.instructions = previous.instructions;
    cpu_.set_state(state);
}
StepResult Machine::step(std::optional<std::uint16_t> interrupt_override) {
    const auto result = cpu_.step(interrupt_override);
    apply_watchdog_reset();
    return result;
}
void Machine::advance(std::uint64_t ticks) { soc_.advance(ticks); apply_watchdog_reset(); }
bool Machine::is_register(std::uint32_t a) {
    return (a >= 0x2800 && a <= 0x28ff) || (a >= 0x3000 && a <= 0x37ff) || (a >= 0x3d00 && a <= 0x3eff);
}
bool Machine::ram_selected(std::uint32_t a) const {
    return !cartridge_ram_.empty() && ((chip_select_ == 1 && (a & 0x200000)) || (chip_select_ >= 2 && (a >> 20) == 2));
}
std::uint16_t Machine::peek(std::uint32_t a) const {
    a &= 0x3fffff;
    if (a < 0x4000) return memory_[a];
    if (ram_selected(a)) return cartridge_ram_[a & 0xfffff];
    if (chip_select_ >= 2 && a >= 0x300000) {
        if (bios_.byte_size() && system_ != System::baby) return bios_.read(a);
        if (!config_.dummy_bios) return 0xffff;
        // Existing core's empty BIOS resource-pointer table (0x00310000).
        const auto offset = a & 0xfffff;
        return offset >= 0xfffc0 && offset <= 0xfffdb && (offset & 1) ? 0x31 : 0;
    }
    return cartridge_.read(a | (second_bank_ ? 0x400000 : 0));
}
std::uint16_t Machine::read(std::uint32_t a) {
    a &= 0x3fffff;
    if (!is_register(a)) return peek(a);
    const auto actual = register_read(a);
    return register_hook_ ? register_hook_('R', a, actual) : actual;
}
void Machine::write(std::uint32_t a, std::uint16_t v) {
    a &= 0x3fffff;
    if (a >= 0x4000) { if (ram_selected(a)) cartridge_ram_[a & 0xfffff] = v; return; }
    if (is_register(a)) {
        if (register_hook_) register_hook_('W', a, v);
        register_write(a, v);
    } else memory_[a] = v;
}
std::uint16_t Machine::register_read(std::uint32_t a) {
    if ((a >= 0x2800 && a <= 0x28ff) || (a >= 0x3d00 && a <= 0x3dff)) {
        const bool baby = system_ == System::baby, motion = system_ == System::motion;
        const auto port_a = std::uint16_t(baby ? 0x302 | ((config_.region & 0x10) << 3) : motion ? 0xc000 : 0);
        // Port B: OFF (bit 7) / ON (bit 6) released. Toy Story 2 (USA) checks
        // that ON is held at boot and otherwise keeps powering itself off.
        const bool on_held = config_.on_button && soc_.frames() < 30;
        const auto port_b = std::uint16_t(baby ? 0x80 : on_held ? 0x88 : 0xc8);
        const auto port_c = std::uint16_t(baby ? 0 : (soc_.controller_rts() ? 0x3020 : 0x3420) | (config_.region & 31));
        return soc_.read(a, {port_a, port_b, port_c}, cpu_.pc() >> 20, cpu_.state().r[6] >> 10);
    }
    if (a >= 0x3000 && a <= 0x37ff) return soc_.spu().read(a);
    return memory_[a];
}
void Machine::register_write(std::uint32_t a, std::uint16_t v) {
    if ((a >= 0x2800 && a <= 0x28ff) || (a >= 0x3d00 && a <= 0x3dff)) soc_.write(a, v);
    else if (a >= 0x3000 && a <= 0x37ff) {
        if (audio_log_) audio_log_(soc_.spu().samples(), a, v);
        soc_.spu().write(a, v);
    } else memory_[a] = v;
    const auto banks = std::pair(chip_select_, second_bank_);
    if (a >= 0x281c && a <= 0x281e) display_.update_vertical_compression();
    if (a == 0x3d23) chip_select_ = (v >> 6) & 3;
    if (a == 0x3d2f) cpu_.set_ds(v);
    // Board outputs use GPIO's direction, attribute/inversion and special masks.
    if (a >= 0x3d06 && a <= 0x3d09 && system_ != System::baby && (soc_.gpio_direction(1) & 2))
        second_bank_ = !(soc_.gpio_output(1) & 2);
    if (a >= 0x3d0b && a <= 0x3d0f && (soc_.gpio_direction(2) & 0x100))
        soc_.select_controller(soc_.gpio_output(2) & 0x100);
    // Pseudo-writes 0xc500/0xc520 follow the RTL SPU replay's bank events.
    if (audio_log_ && banks != std::pair(chip_select_, second_bank_)) {
        audio_log_(soc_.spu().samples(), 0xc500, std::uint16_t(chip_select_));
        audio_log_(soc_.spu().samples(), 0xc520, second_bank_);
    }
    if (a == 0x2870) sprite_source_ = v & 0x3fff;
    if (a == 0x2871) sprite_destination_ = v & 0x3ff;
    if (a == 0x2872) {
        const unsigned length = v & 0x3ff ? v & 0x3ff : 0x400;
        for (unsigned i = 0; i < length && sprite_destination_ + i < 0x400; ++i)
            memory_[0x2c00 + sprite_destination_ + i] = read(sprite_source_ + i);
        soc_.sprite_dma_done();
    }
    if (a >= 0x3e00 && a <= 0x3e03) {
        dma_[a & 3] = v;
        if ((a & 3) == 2 && !(v & 0xc000)) {
            auto source = (std::uint32_t(dma_[1] & 63) << 16) | dma_[0];
            auto dest = std::uint32_t(dma_[3] & 0x3fff);
            for (unsigned i = 0; i < v; ++i) write((dest + i) & 0x3fff, read(source + i));
            source += v; dest += v;
            dma_ = {std::uint16_t(source), std::uint16_t((source >> 16) & 63), 0, std::uint16_t(dest & 0x3fff)};
            std::copy(dma_.begin(), dma_.end(), memory_.begin() + 0x3e00);
        }
    }
}
void Machine::load_save(const std::filesystem::path& path) {
    if (cartridge_ram_.empty()) throw std::runtime_error("This cartridge has no backup RAM");
    const auto save = Rom::load(path, 2 * 1024 * 1024);
    if (save.byte_size() != 2 * 1024 * 1024) throw std::runtime_error("Backup RAM file must be exactly 2 MB");
    cartridge_ram_ = save.words();
}
void Machine::write_save(const std::filesystem::path& path) const {
    if (cartridge_ram_.empty()) throw std::runtime_error("This cartridge has no backup RAM");
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) throw std::runtime_error("Cannot open backup RAM file");
    for (auto word : cartridge_ram_) {
        const char bytes[2] = {static_cast<char>(word & 255), static_cast<char>(word >> 8)};
        file.write(bytes, 2);
    }
    file.flush();
    if (!file) throw std::runtime_error("Cannot write backup RAM file");
}
namespace {
std::uint64_t fingerprint(const Rom& rom) {
    std::uint64_t hash = 1469598103934665603ull ^ rom.byte_size();
    for (const auto word : rom.words()) hash = (hash ^ word) * 1099511628211ull;
    return hash;
}
}
void Machine::serialize(StateArchive& a) {
    a.section("CHES"); a.section("HIRE");
    std::uint32_t version = 1;
    a(version);
    if (version != 1) throw std::runtime_error("Unsupported save state version");
    auto cart = fingerprint(cartridge_), bios = fingerprint(bios_);
    auto system = system_;
    auto port = peripheral();
    bool pal = config_.pal, reference = config_.reference_timing;
    a(cart); a(bios); a(system); a(port); a(pal); a(reference);
    if (a.loading()) {
        if (cart != fingerprint(cartridge_)) throw std::runtime_error("Save state is for a different cartridge");
        if (bios != fingerprint(bios_)) throw std::runtime_error("Save state was made with a different system ROM");
        if (system != system_ || port != peripheral() || pal != config_.pal || reference != config_.reference_timing)
            throw std::runtime_error("Save state was made with a different system, controller, TV standard or timing");
    }
    a.section("BORD");
    a(memory_); a(cartridge_ram_); a(chip_select_); a(second_bank_); a(sprite_source_); a(sprite_destination_); a(dma_);
    if (a.loading() && chip_select_ > 3) throw std::runtime_error("Corrupt save state (board)");
    a.section("CPU ");
    auto cpu = cpu_.state();
    a(cpu.r); a(cpu.shift_buffer); a(cpu.irq_enabled); a(cpu.fiq_enabled); a(cpu.in_irq); a(cpu.in_fiq); a(cpu.fir_move);
    a(cpu.cycles); a(cpu.instructions);
    if (a.loading()) cpu_.set_state(cpu);
    soc_.serialize(a);
    display_.serialize(a);
    a.section("END ");
    a.finish();
}
std::vector<std::uint8_t> Machine::save_state() {
    auto archive = StateArchive::writer();
    serialize(archive);
    return archive.data();
}
void Machine::load_state(std::span<const std::uint8_t> data) {
    const auto backup = save_state();
    try { auto archive = StateArchive::reader(data); serialize(archive); }
    catch (...) { auto archive = StateArchive::reader(backup); serialize(archive); throw; }
}
void Machine::save_state(const std::filesystem::path& path) {
    const auto data = save_state();
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) throw std::runtime_error("Cannot open save state file");
    file.write(reinterpret_cast<const char*>(data.data()), std::streamsize(data.size()));
    file.flush();
    if (!file) throw std::runtime_error("Cannot write save state file");
}
void Machine::load_state(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("Cannot open save state file");
    std::vector<std::uint8_t> data;
    char buffer[65536];
    while (file.read(buffer, sizeof buffer) || file.gcount()) {
        data.insert(data.end(), buffer, buffer + file.gcount());
        if (data.size() > 64u << 20) throw std::runtime_error("Save state file is too large");
    }
    load_state(data);
}
Rom make_demo_rom() {
    std::vector<std::uint8_t> bytes(0x20000, 0);
    const auto put = [&](std::size_t a, std::uint16_t v) { bytes[2 * a] = v & 255; bytes[2 * a + 1] = v >> 8; };
    put(0xfff7, 0x8000);
    // Increment sprite X through real interpreted instructions.
    // R1 = [0x2c01]; R1 += 1; [0x2c01] = R1; JMP back.
    put(0x8000, 0x9311); put(0x8001, 0x2c01);
    put(0x8002, 0x0241);
    put(0x8003, 0xd311); put(0x8004, 0x2c01);
    put(0x8005, 0xee46);
    return Rom::from_bytes(bytes);
}
void setup_demo(Machine& m) {
    m.load_cartridge(make_demo_rom());
    // Packed 2bpp graphics: solid palette entry 1, two words per 16px row.
    for (unsigned a = 0x1100; a < 0x1140; ++a) m.write(a, 0x5555);
    m.write(0x2b00, 0x8000); m.write(0x2b01, 0x7c1f);
    m.write(0x2822, 0x40); // graphics base 0x1000
    m.write(0x2842, 3); // enable sprites, absolute coordinates
    m.write(0x2c00, 8); m.write(0x2c01, 150); m.write(0x2c02, 110); m.write(0x2c03, 0x50);
}
}
