// SPDX-License-Identifier: GPL-2.0-or-later
#include "cheshire/options.hpp"
#include <charconv>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace cheshire {
Options parse_options(int argc, char** argv) {
    Options result;
    const auto path = [](std::string_view value) {
        std::u8string utf8;
        utf8.reserve(value.size());
        for (unsigned char c : value) utf8.push_back(static_cast<char8_t>(c));
        return std::filesystem::path(utf8);
    };
    const auto number = [](std::string_view s) {
        std::uint64_t n;
        const auto [end, error] = std::from_chars(s.data(), s.data() + s.size(), n);
        if (error != std::errc{} || end != s.data() + s.size()) throw std::runtime_error("Invalid unsigned number: " + std::string(s));
        return n;
    };
    for (int i = 1; i < argc; ++i) {
        const std::string_view arg = argv[i];
        const auto value = [&]() -> std::string_view {
            if (++i >= argc) throw std::runtime_error("Missing value for " + std::string(arg));
            return argv[i];
        };
        if (arg == "--help" || arg == "-h") result.help = true;
        else if (arg == "--demo") result.demo = true;
        else if (arg == "--rom") result.rom = path(value());
        else if (arg == "--bios") result.bios = path(value());
        else if (arg == "--trace") result.trace = path(value());
        else if (arg == "--save") result.save = path(value());
        else if (arg == "--dump-frame") result.dump_frame = path(value());
        else if (arg == "--wav") result.wav = path(value());
        else if (arg == "--spu-log") result.spu_log = path(value());
        else if (arg == "--mute") result.mute = true;
        else if (arg == "--autoplay") result.autoplay = true;
        else if (arg == "--state") result.state = path(value());
        else if (arg == "--fullscreen") result.fullscreen = true;
        else if (arg == "--integer-scale") result.integer_scale = true;
        else if (arg == "--load-state") result.load_state = path(value());
        else if (arg == "--save-state") result.save_state = path(value());
        else if (arg == "--instructions") result.instructions = number(value());
        else if (arg == "--frames") {
            const auto n = number(value());
            if (n == 0 || n > 1000000) throw std::runtime_error("Frame limit must be 1..1000000");
            result.frames = static_cast<unsigned>(n);
        } else if (arg == "--renderer") result.renderer = value();
        else if (arg == "--pal") result.config.pal = true;
        else if (arg == "--audit-io") result.audit_io = true;
        else if (arg == "--timing") {
            const auto timing = value();
            if (timing == "reference") result.config.reference_timing = true;
            else if (timing == "hardware") result.config.reference_timing = false;
            else throw std::runtime_error("Timing must be reference or hardware");
        }
        else if (arg == "--region") {
            const auto n = number(value());
            if (n > 31) throw std::runtime_error("Region/intro bits must be 0..31");
            result.config.region = std::uint8_t(n);
        } else if (arg == "--controller") {
            const auto c = value();
            if (c == "auto") result.config.peripheral.reset();
            else if (c == "joystick") result.config.peripheral = Peripheral::joystick;
            else if (c == "keyboard") result.config.peripheral = Peripheral::keyboard;
            else if (c == "mat") result.config.peripheral = Peripheral::mat;
            else if (c == "tablet") result.config.peripheral = Peripheral::tablet;
            else throw std::runtime_error("Controller must be auto, joystick, keyboard, mat or tablet");
        } else if (arg == "--keyboard-layout") {
            const auto l = value();
            if (l == "us") result.config.keyboard_layout = 0x40;
            else if (l == "fr") result.config.keyboard_layout = 0x42;
            else if (l == "de") result.config.keyboard_layout = 0x44;
            else throw std::runtime_error("Keyboard layout must be us, fr or de");
        } else if (arg == "--system") {
            const auto s = value();
            if (s == "auto") result.config.system = System::automatic;
            else if (s == "vsmile") result.config.system = System::vsmile;
            else if (s == "motion") result.config.system = System::motion;
            else if (s == "baby") result.config.system = System::baby;
            else throw std::runtime_error("System must be auto, vsmile, motion or baby");
        } else throw std::runtime_error("Unknown option: " + std::string(arg));
    }
    if (argc == 1) result.help = true;
    if (!result.help) {
        if (result.demo == !result.rom.empty()) throw std::runtime_error("Choose exactly one of --demo or --rom FILE");
        if (result.demo && (!result.trace.empty() || !result.bios.empty() || !result.save.empty()))
            throw std::runtime_error("Demo cannot use a BIOS, save file or external trace");
        if (!result.trace.empty()) {
            result.config.dummy_bios = false;
            result.config.reference_timing = true;
            result.config.on_button = false;
            if (!result.save.empty()) throw std::runtime_error("Trace verification does not load or write saves");
        }
        if (!result.trace.empty() && (!result.state.empty() || !result.load_state.empty() || !result.save_state.empty()))
            throw std::runtime_error("Trace replay cannot use save states");
        if (result.autoplay && !result.trace.empty()) throw std::runtime_error("--autoplay cannot drive trace replay");
        if (result.audit_io && result.trace.empty()) throw std::runtime_error("--audit-io requires --trace");
    }
    return result;
}
void print_help(bool sdl) {
    std::cout << "Cheshire 0.1 — V.Smile emulator bring-up (C++20 / SDL2)\n"
              << "Usage: " << (sdl ? "cheshire" : "cheshire_headless") << " --demo | --rom FILE [options]\n"
              << "  --system auto|vsmile|motion|baby   --bios FILE (2 MB)\n"
              << "  --controller auto|joystick|keyboard|mat|tablet   --keyboard-layout us|fr|de\n"
              << "  --trace DIR       Compare cpu.tr and mem.log (optional .gz)\n"
              << "  --audit-io        Also compare timed video/I/O register reads against trace\n"
              << "  --timing MODE     hardware or reference (trace mode uses reference)\n"
              << "  --instructions N  Stop after N instructions\n"
              << "  --pal             PAL presentation (240 rendered + 48 black lines)\n"
              << "  --region N        Region/intro GPIO bits, 0..31 (default 31: English US + intro)\n"
              << "  --save FILE       Load existing 2 MB Art Studio RAM, write on clean exit\n"
              << "  --dump-frame FILE Write final framebuffer as PPM\n"
              << "  --wav FILE        Record audio as 70,313 Hz stereo WAV\n";
    if (sdl) std::cout << "  --mute            Do not open an audio device\n"
                       << "  --state FILE      Save state file for F5 (save) and F7 (load)\n"
                       << "  --fullscreen      Start fullscreen   --integer-scale  Scale by whole multiples only\n";
    if (!sdl) std::cout << "  --load-state FILE Restore a save state before running\n"
                        << "  --save-state FILE Write a save state when the run ends\n";
    if (!sdl) std::cout << "  --autoplay        Press the FPGA census button script (from frame 300, one input per 90 frames)\n";
    if (!sdl) std::cout << "  --spu-log PREFIX  Write PREFIX.w (audio writes) and PREFIX.s (samples) for RTL replay\n";
    if (!sdl) std::cout << "  --frames N        Stop after N emulated frame periods\n";
    if (sdl) std::cout << "  --frames N        Stop after N presentations\n"
                       << "  --renderer NAME   SDL2 backend (e.g. software or opengles2)\n"
                       << "Controls: arrows stick; Z/X/C/V green/blue/yellow/red; Enter OK, Backspace Quit, H Help, A ABC\n"
                       << "Baby mode: F1/F2/F3; Space pause, N step, R reset (outside trace), Escape quit\n"
                       << "Keyboard carts: keys by position, Enter OK, Esc Quit, F1 Help; F9 pause, F10 step, F11 reset, F12 quit\n"
                       << "Art Studio: mouse moves the pen, left button presses it\n"
                       << "F4 or Alt+Enter fullscreen, F5 save state, F6 screenshot (BMP), F7 load state, hold F8 fast-forward\n";
    std::cout << "CPU/board/DMA, timed video/I/O, audio, joystick/mat/keyboard/tablet/Baby input and scanline video implemented.\n"
              << "Trace mode replays reference I/O and interrupts; it is not independent game emulation.\n";
}
void initialize_machine(Machine& m, const Options& o) {
    if (o.demo) setup_demo(m);
    else m.load_cartridge(Rom::load(o.rom));
    if (!o.bios.empty()) m.load_bios(Rom::load(o.bios, 2 * 1024 * 1024));
    if (!o.save.empty()) {
        if (m.cartridge_ram().empty()) throw std::runtime_error("--save requires an Art Studio cartridge");
        if (std::filesystem::exists(o.save)) m.load_save(o.save);
    }
}
}
