// SPDX-License-Identifier: GPL-2.0-or-later
#include "cheshire/audio.hpp"
#include "cheshire/options.hpp"
#include "cheshire/trace.hpp"
#include "cheshire/video.hpp"
#include <fstream>
#include <iostream>
#include <limits>

int main(int argc, char** argv) {
    try {
        const auto options = cheshire::parse_options(argc, argv);
        if (options.help) { cheshire::print_help(false); return 0; }
        if (!options.renderer.empty()) throw std::runtime_error("--renderer requires the SDL2 frontend");
        cheshire::Machine machine(options.config);
        cheshire::initialize_machine(machine, options);
        if (!options.load_state.empty()) machine.load_state(options.load_state);
        std::unique_ptr<cheshire::WavWriter> wav;
        if (!options.wav.empty()) wav = std::make_unique<cheshire::WavWriter>(options.wav);
        std::ofstream spu_writes, spu_samples;
        if (!options.spu_log.empty()) {
            auto writes = options.spu_log, samples = options.spu_log;
            writes += ".w"; samples += ".s";
            spu_writes.open(writes); spu_samples.open(samples, std::ios::binary);
            if (!spu_writes || !spu_samples) throw std::runtime_error("Cannot open SPU log files");
            spu_writes << std::hex;
            machine.set_audio_log([&](std::uint64_t sample, std::uint32_t address, std::uint16_t value) {
                spu_writes << std::dec << sample << std::hex << ' ' << address << ' ' << value << '\n';
            });
        }
        machine.soc().spu().sample_sink = [&](std::int16_t left, std::int16_t right) {
            if (wav) wav->write(left, right);
            if (spu_samples.is_open()) {
                const char bytes[4] = {char(left & 255), char((left >> 8) & 255), char(right & 255), char((right >> 8) & 255)};
                spu_samples.write(bytes, 4);
            }
        };
        std::unique_ptr<cheshire::TraceSession> trace;
        if (!options.trace.empty()) trace = std::make_unique<cheshire::TraceSession>(machine, options.trace, options.audit_io);
        const auto limit = options.instructions.value_or(trace || options.frames ? std::numeric_limits<std::uint64_t>::max() : 1000000);
        // The FPGA census script (scripts/census.lua): after frame 300, one input
        // every 90 frames, held for 8, cycling through these.
        struct Press { std::uint8_t directions, colors, buttons; };
        constexpr Press script[] = {{0, 0, 1}, {8, 0, 0}, {0, 0, 1}, {2, 0, 0}, {0, 0, 1}, {0, 1, 0}, {4, 0, 0}, {0, 0, 1},
            {0, 8, 0}, {1, 0, 0}, {0, 0, 1}, {0, 2, 0}, {0, 0, 1}, {0, 4, 0}, {0, 0, 8}, {0, 0, 1}};
        std::uint64_t input_frame = ~0ull;
        while (machine.cpu().state().instructions < limit && (!options.frames || machine.soc().frames() < *options.frames)) {
            if (trace) { if (!trace->step()) break; }
            else machine.step();
            if (options.autoplay && machine.soc().frames() != input_frame) {
                input_frame = machine.soc().frames();
                cheshire::InputState input;
                if (input_frame > 300 && input_frame % 90 < 8) {
                    const auto& press = script[(input_frame / 90) % std::size(script)];
                    input.directions = press.directions; input.colors = press.colors; input.buttons = press.buttons;
                }
                machine.set_input(input);
            }
        }
        if (!options.dump_frame.empty()) cheshire::write_ppm(options.dump_frame, cheshire::presented_frame(machine, options.demo));
        if (!options.save.empty()) machine.write_save(options.save);
        if (wav) wav->finish();
        if (!options.save_state.empty()) machine.save_state(options.save_state);
        if (spu_writes.is_open() && (!spu_writes.flush() || !spu_samples.flush())) throw std::runtime_error("Cannot write SPU log files");
        std::cout << cheshire::system_name(machine.system()) << ": " << machine.cpu().state().instructions
                  << " instructions, " << machine.cpu().state().cycles << " charged cycles";
        if (trace) std::cout << ", " << trace->register_events() << " register events matched (reference I/O replay)";
        std::cout << '\n';
        std::cout << "Clock: " << machine.soc().ticks() << " ticks, " << machine.soc().frames() << " frames; UART: "
                  << machine.soc().transmitted_bytes() << " transmitted, " << machine.soc().received_bytes() << " received; audio: "
                  << machine.soc().spu().samples() << " samples\n";
        if (trace && options.audit_io) { trace->print_io_audit(std::cout); if (trace->io_mismatches()) return 1; }
        return 0;
    } catch (const std::exception& e) { std::cerr << "Cheshire: " << e.what() << '\n'; return 1; }
}
