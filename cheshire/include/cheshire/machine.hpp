// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "cheshire/display.hpp"
#include "cheshire/rom.hpp"
#include "cheshire/unsp.hpp"
#include "cheshire/soc.hpp"
#include <array>
#include <functional>
#include <span>

namespace cheshire {
struct MachineConfig {
    System system = System::automatic;
    bool pal = false;
    bool dummy_bios = true;
    bool reference_timing = false;
    std::uint8_t region = 0x1f;
    // ON button still held for the first 30 frames after power-on (FPGA core
    // 9f4eb4d). MAME reads it released, so trace replay turns this off.
    bool on_button = true;
    // Port 1 device and Smart Keyboard model (0x40 US, 0x42 FR, 0x44 DE); unset follows the cartridge.
    std::optional<Peripheral> peripheral;
    std::optional<std::uint8_t> keyboard_layout;
};

// Board/memory, timed SoC, scanline video, audio and controller ports.
class Machine final : public WordBus {
public:
    using RegisterHook = std::function<std::uint16_t(char, std::uint32_t, std::uint16_t)>;
    // Audio register writes and bank changes, tagged with the SPU sample count.
    using AudioLog = std::function<void(std::uint64_t, std::uint32_t, std::uint16_t)>;
    explicit Machine(MachineConfig config = {});
    Machine(const Machine&) = delete;
    Machine& operator=(const Machine&) = delete;
    void load_cartridge(Rom rom);
    void load_bios(Rom rom);
    void reset();
    std::uint16_t read(std::uint32_t address) override;
    void write(std::uint32_t address, std::uint16_t value) override;
    std::uint16_t peek(std::uint32_t address) const;
    StepResult step(std::optional<std::uint16_t> interrupt_override = {});
    void instruction_elapsed(unsigned ticks) override { soc_.advance(ticks); }
    std::uint16_t interrupt_lines() const override { return soc_.interrupts(); }
    void advance(std::uint64_t ticks);
    void set_input(const InputState& input) { soc_.set_input(input); }
    Soc& soc() { return soc_; }
    const Soc& soc() const { return soc_; }
    const Display& display() const { return display_; }
    void set_register_hook(RegisterHook hook) { register_hook_ = std::move(hook); }
    void set_audio_log(AudioLog log) { audio_log_ = std::move(log); }
    Unsp& cpu() { return cpu_; }
    const Unsp& cpu() const { return cpu_; }
    System system() const { return system_; }
    const CartridgeInfo& cartridge_info() const { return info_; }
    Peripheral peripheral() const { return config_.peripheral.value_or(info_.peripheral); }
    const MachineConfig& config() const { return config_; }
    const std::array<std::uint16_t, 0x4000>& memory() const { return memory_; }
    const std::vector<std::uint16_t>& cartridge_ram() const { return cartridge_ram_; }
    void load_save(const std::filesystem::path& path);
    void write_save(const std::filesystem::path& path) const;
    // Whole-machine snapshot. Loading requires the same cartridge, BIOS, system,
    // controller and TV standard; a failed load leaves the machine unchanged.
    std::vector<std::uint8_t> save_state();
    void load_state(std::span<const std::uint8_t> data);
    void save_state(const std::filesystem::path& path);
    void load_state(const std::filesystem::path& path);
    static bool is_register(std::uint32_t address);
private:
    MachineConfig config_;
    System system_ = System::vsmile;
    CartridgeInfo info_;
    Rom cartridge_, bios_;
    std::array<std::uint16_t, 0x4000> memory_{};
    Display display_;
    std::vector<std::uint16_t> cartridge_ram_;
    Soc soc_;
    Unsp cpu_;
    RegisterHook register_hook_;
    AudioLog audio_log_;
    unsigned chip_select_ = 0;
    bool second_bank_ = false;
    std::uint16_t sprite_source_ = 0, sprite_destination_ = 0;
    std::array<std::uint16_t, 4> dma_{};
    bool ram_selected(std::uint32_t address) const;
    std::uint16_t register_read(std::uint32_t address);
    void register_write(std::uint32_t address, std::uint16_t value);
    void detect_system();
    void apply_watchdog_reset();
    void scanline(unsigned line);
    void serialize(StateArchive& archive);
};
Rom make_demo_rom();
void setup_demo(Machine& machine);
}
