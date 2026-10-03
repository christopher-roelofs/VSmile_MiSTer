// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "cheshire/machine.hpp"
#include <optional>
#include <string>

namespace cheshire {
struct Options {
    MachineConfig config;
    std::filesystem::path rom, bios, trace, save, dump_frame, wav, spu_log, state, load_state, save_state;
    std::optional<std::uint64_t> instructions;
    std::optional<unsigned> frames;
    std::string renderer;
    bool demo = false, help = false, audit_io = false, mute = false, autoplay = false, fullscreen = false, integer_scale = false;
};
Options parse_options(int argc, char** argv);
void print_help(bool sdl);
void initialize_machine(Machine& machine, const Options& options);
}
