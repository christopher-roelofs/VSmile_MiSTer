// SPDX-License-Identifier: GPL-2.0-or-later
#include "cheshire/audio.hpp"
#include "cheshire/options.hpp"
#include "cheshire/trace.hpp"
#include "cheshire/video.hpp"
#include "startup.hpp"
#include <SDL.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {
void check(int result) { if (result < 0) throw std::runtime_error(SDL_GetError()); }
struct Sdl {
    Sdl() {
        SDL_SetMainReady();
        check(cheshire::prepare_video_driver());
        check(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_GAMECONTROLLER));
        std::clog << "SDL video driver: " << SDL_GetCurrentVideoDriver() << '\n';
    }
    ~Sdl() { SDL_Quit(); }
};
template<class T, void (*Destroy)(T*)> using Handle = std::unique_ptr<T, decltype(Destroy)>;
// Resamples SPU output to the host device. Audio failures leave the emulator silent rather than stopping it.
class AudioOutput {
public:
    AudioOutput() {
        if (SDL_InitSubSystem(SDL_INIT_AUDIO) < 0) { std::clog << "SDL audio unavailable: " << SDL_GetError() << '\n'; return; }
        SDL_AudioSpec want{}, have{};
        want.freq = 48000; want.format = AUDIO_S16SYS; want.channels = 2; want.samples = 1024;
        device_ = SDL_OpenAudioDevice(nullptr, 0, &want, &have, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);
        if (!device_) { std::clog << "SDL audio device unavailable: " << SDL_GetError() << '\n'; return; }
        stream_ = SDL_NewAudioStream(AUDIO_S16SYS, 2, int(cheshire::WavWriter::rate), have.format, have.channels, have.freq);
        if (!stream_) { std::clog << "SDL audio stream unavailable: " << SDL_GetError() << '\n'; close(); return; }
        // Keep at most ~120 ms queued so host/emulated clock drift cannot build latency.
        limit_ = std::uint32_t(have.freq) * have.channels * SDL_AUDIO_BITSIZE(have.format) / 8 * 120 / 1000;
        std::clog << "SDL audio driver: " << SDL_GetCurrentAudioDriver() << ", " << have.freq << " Hz\n";
        SDL_PauseAudioDevice(device_, 0);
    }
    AudioOutput(const AudioOutput&) = delete;
    AudioOutput& operator=(const AudioOutput&) = delete;
    ~AudioOutput() { close(); }
    void push(std::int16_t left, std::int16_t right) { if (device_) { pending_.push_back(left); pending_.push_back(right); } }
    void flush() {
        if (!device_ || pending_.empty()) return;
        SDL_AudioStreamPut(stream_, pending_.data(), int(pending_.size() * sizeof(std::int16_t)));
        pending_.clear();
        std::array<std::uint8_t, 8192> buffer;
        for (int n; (n = SDL_AudioStreamGet(stream_, buffer.data(), int(buffer.size()))) > 0;)
            if (SDL_GetQueuedAudioSize(device_) < limit_) SDL_QueueAudio(device_, buffer.data(), std::uint32_t(n));
    }
private:
    SDL_AudioDeviceID device_ = 0;
    SDL_AudioStream* stream_ = nullptr;
    std::uint32_t limit_ = 0;
    std::vector<std::int16_t> pending_;
    void close() {
        if (stream_) SDL_FreeAudioStream(stream_);
        if (device_) SDL_CloseAudioDevice(device_);
        stream_ = nullptr; device_ = 0;
    }
};
int renderer_index(const std::string& name) {
    if (name.empty()) return -1;
    for (int i = 0; i < SDL_GetNumRenderDrivers(); ++i) {
        SDL_RendererInfo info{};
        if (SDL_GetRenderDriverInfo(i, &info) == 0 && name == info.name) return i;
    }
    throw std::runtime_error("SDL2 renderer unavailable: " + name);
}
// Smart Keyboard matrix by physical key position (MAME's US rows; the FR/DE
// keyboards share positions, so AZERTY/QWERTZ hosts type their own letters).
constexpr std::array<std::array<SDL_Scancode, 13>, 5> key_matrix = {{
    {SDL_SCANCODE_1, SDL_SCANCODE_2, SDL_SCANCODE_3, SDL_SCANCODE_4, SDL_SCANCODE_5, SDL_SCANCODE_6, SDL_SCANCODE_7,
     SDL_SCANCODE_8, SDL_SCANCODE_9, SDL_SCANCODE_0, SDL_SCANCODE_MINUS, SDL_SCANCODE_BACKSPACE, SDL_SCANCODE_UNKNOWN},
    {SDL_SCANCODE_TAB, SDL_SCANCODE_Q, SDL_SCANCODE_W, SDL_SCANCODE_E, SDL_SCANCODE_R, SDL_SCANCODE_T, SDL_SCANCODE_Y,
     SDL_SCANCODE_U, SDL_SCANCODE_I, SDL_SCANCODE_O, SDL_SCANCODE_P, SDL_SCANCODE_LEFTBRACKET, SDL_SCANCODE_RIGHTBRACKET},
    {SDL_SCANCODE_CAPSLOCK, SDL_SCANCODE_A, SDL_SCANCODE_S, SDL_SCANCODE_D, SDL_SCANCODE_F, SDL_SCANCODE_G, SDL_SCANCODE_H,
     SDL_SCANCODE_J, SDL_SCANCODE_K, SDL_SCANCODE_L, SDL_SCANCODE_SEMICOLON, SDL_SCANCODE_UNKNOWN, SDL_SCANCODE_UNKNOWN},
    {SDL_SCANCODE_LSHIFT, SDL_SCANCODE_Z, SDL_SCANCODE_X, SDL_SCANCODE_C, SDL_SCANCODE_V, SDL_SCANCODE_B, SDL_SCANCODE_N,
     SDL_SCANCODE_M, SDL_SCANCODE_COMMA, SDL_SCANCODE_PERIOD, SDL_SCANCODE_UP, SDL_SCANCODE_UNKNOWN, SDL_SCANCODE_UNKNOWN},
    {SDL_SCANCODE_KP_1, SDL_SCANCODE_KP_PLUS, SDL_SCANCODE_SPACE, SDL_SCANCODE_KP_2, SDL_SCANCODE_LEFT, SDL_SCANCODE_DOWN,
     SDL_SCANCODE_RIGHT, SDL_SCANCODE_UNKNOWN, SDL_SCANCODE_UNKNOWN, SDL_SCANCODE_UNKNOWN, SDL_SCANCODE_UNKNOWN,
     SDL_SCANCODE_UNKNOWN, SDL_SCANCODE_UNKNOWN}}};
struct Pen { int x = 160, y = 120; bool down = false; };
// Writes cheshire-YYYYMMDD-HHMMSS[-n].bmp in the current directory.
std::filesystem::path save_screenshot(const std::vector<std::uint32_t>& frame, int height) {
    const auto now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    char stamp[32];
    std::strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", std::localtime(&now));
    std::filesystem::path path = std::string("cheshire-") + stamp + ".bmp";
    for (unsigned n = 2; std::filesystem::exists(path); ++n) path = std::string("cheshire-") + stamp + "-" + std::to_string(n) + ".bmp";
    Handle<SDL_Surface, SDL_FreeSurface> surface(SDL_CreateRGBSurfaceWithFormatFrom(const_cast<std::uint32_t*>(frame.data()),
        320, height, 32, 320 * 4, SDL_PIXELFORMAT_ARGB8888), SDL_FreeSurface);
    if (!surface || SDL_SaveBMP(surface.get(), path.string().c_str()) < 0) throw std::runtime_error(SDL_GetError());
    return path;
}
cheshire::InputState read_input(SDL_GameController* controller, unsigned baby_mode, bool focused, bool keyboard, const Pen& pen) {
    cheshire::InputState input;
    input.baby_mode = std::uint8_t(baby_mode);
    if (!focused) return input;
    input.pen_x = std::uint16_t(pen.x); input.pen_y = std::uint8_t(pen.y); input.pen_down = pen.down;
    const auto* keys = SDL_GetKeyboardState(nullptr);
    if (keyboard) {
        for (unsigned r = 0; r < key_matrix.size(); ++r)
            for (unsigned c = 0; c < key_matrix[r].size(); ++c)
                if (key_matrix[r][c] != SDL_SCANCODE_UNKNOWN && keys[key_matrix[r][c]]) input.keys[r] |= std::uint16_t(1u << c);
        if (keys[SDL_SCANCODE_RSHIFT]) input.keys[3] |= 1;
        input.buttons = (keys[SDL_SCANCODE_RETURN] || keys[SDL_SCANCODE_KP_ENTER] ? 1 : 0) | (keys[SDL_SCANCODE_ESCAPE] ? 2 : 0)
            | (keys[SDL_SCANCODE_F1] ? 4 : 0);
    } else {
        input.directions = (keys[SDL_SCANCODE_UP] ? 1 : 0) | (keys[SDL_SCANCODE_DOWN] ? 2 : 0)
            | (keys[SDL_SCANCODE_LEFT] ? 4 : 0) | (keys[SDL_SCANCODE_RIGHT] ? 8 : 0);
        input.colors = (keys[SDL_SCANCODE_Z] ? 1 : 0) | (keys[SDL_SCANCODE_X] ? 2 : 0)
            | (keys[SDL_SCANCODE_C] ? 4 : 0) | (keys[SDL_SCANCODE_V] ? 8 : 0);
        input.buttons = (keys[SDL_SCANCODE_RETURN] ? 1 : 0) | (keys[SDL_SCANCODE_BACKSPACE] ? 2 : 0)
            | (keys[SDL_SCANCODE_H] ? 4 : 0) | (keys[SDL_SCANCODE_A] ? 8 : 0);
    }
    if (controller) {
        const auto button = [&](SDL_GameControllerButton b) { return SDL_GameControllerGetButton(controller, b) != 0; };
        input.directions |= (button(SDL_CONTROLLER_BUTTON_DPAD_UP) ? 1 : 0) | (button(SDL_CONTROLLER_BUTTON_DPAD_DOWN) ? 2 : 0)
            | (button(SDL_CONTROLLER_BUTTON_DPAD_LEFT) ? 4 : 0) | (button(SDL_CONTROLLER_BUTTON_DPAD_RIGHT) ? 8 : 0);
        input.colors |= (button(SDL_CONTROLLER_BUTTON_A) ? 1 : 0) | (button(SDL_CONTROLLER_BUTTON_B) ? 2 : 0)
            | (button(SDL_CONTROLLER_BUTTON_X) ? 4 : 0) | (button(SDL_CONTROLLER_BUTTON_Y) ? 8 : 0);
        input.buttons |= (button(SDL_CONTROLLER_BUTTON_START) ? 1 : 0) | (button(SDL_CONTROLLER_BUTTON_BACK) ? 2 : 0)
            | (button(SDL_CONTROLLER_BUTTON_LEFTSHOULDER) ? 4 : 0) | (button(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER) ? 8 : 0);
        const int x = SDL_GameControllerGetAxis(controller, SDL_CONTROLLER_AXIS_LEFTX);
        const int y = SDL_GameControllerGetAxis(controller, SDL_CONTROLLER_AXIS_LEFTY);
        const auto magnitude = [](int value) { return value < 0 ? -value : value; };
        if (!(input.directions & 12) && magnitude(x) >= 4096) {
            input.directions |= x < 0 ? 4 : 8;
            input.lr_level = std::uint8_t(std::min(7, 3 + magnitude(x) * 5 / 32768));
        }
        if (!(input.directions & 3) && magnitude(y) >= 4096) {
            input.directions |= y < 0 ? 1 : 2;
            input.ud_level = std::uint8_t(std::min(7, 3 + magnitude(y) * 5 / 32768));
        }
    }
    input.baby_buttons = ((input.colors & 4) || (input.directions & 4) ? 1 : 0)
        | ((input.colors & 2) || (input.directions & 1) ? 2 : 0) | (input.buttons & 1 ? 4 : 0)
        | ((input.colors & 1) || (input.directions & 2) ? 8 : 0)
        | ((input.colors & 8) || (input.directions & 8) ? 16 : 0)
        | (input.buttons & 4 ? 32 : 0) | (input.buttons & 8 ? 64 : 0) | (input.buttons & 2 ? 128 : 0);
    return input;
}
}
int main(int argc, char** argv) {
    try {
        const auto options = cheshire::parse_options(argc, argv);
        if (options.help) { cheshire::print_help(true); return 0; }
        if (!options.spu_log.empty()) throw std::runtime_error("--spu-log requires the headless tool");
        if (!options.load_state.empty() || !options.save_state.empty()) throw std::runtime_error("Use --state FILE with F5/F7 in the SDL frontend");
        cheshire::Machine machine(options.config);
        cheshire::initialize_machine(machine, options);
        std::unique_ptr<cheshire::TraceSession> trace;
        if (!options.trace.empty()) trace = std::make_unique<cheshire::TraceSession>(machine, options.trace, options.audit_io);
        Sdl sdl;
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");
        const int height = options.config.pal ? 288 : 240;
        Handle<SDL_Window, SDL_DestroyWindow> window(SDL_CreateWindow("Cheshire", SDL_WINDOWPOS_CENTERED,
            SDL_WINDOWPOS_CENTERED, 960, height * 3, SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI
            | (options.fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0)), SDL_DestroyWindow);
        if (!window) throw std::runtime_error(SDL_GetError());
        const int driver = renderer_index(options.renderer);
        Handle<SDL_Renderer, SDL_DestroyRenderer> renderer(SDL_CreateRenderer(window.get(), driver, SDL_RENDERER_ACCELERATED), SDL_DestroyRenderer);
        if (!renderer) renderer.reset(SDL_CreateRenderer(window.get(), driver, SDL_RENDERER_SOFTWARE));
        if (!renderer) throw std::runtime_error(SDL_GetError());
        SDL_RendererInfo renderer_info{};
        check(SDL_GetRendererInfo(renderer.get(), &renderer_info));
        std::clog << "SDL renderer: " << renderer_info.name << '\n';
        check(SDL_RenderSetLogicalSize(renderer.get(), 320, height));
        if (options.integer_scale) check(SDL_RenderSetIntegerScale(renderer.get(), SDL_TRUE));
        Handle<SDL_Texture, SDL_DestroyTexture> texture(SDL_CreateTexture(renderer.get(), SDL_PIXELFORMAT_ARGB8888,
            SDL_TEXTUREACCESS_STREAMING, 320, height), SDL_DestroyTexture);
        if (!texture) throw std::runtime_error(SDL_GetError());
        Handle<SDL_GameController, SDL_GameControllerClose> controller(nullptr, SDL_GameControllerClose);
        const auto open_controller = [&] {
            if (controller) return;
            for (int i = 0; i < SDL_NumJoysticks(); ++i)
                if (SDL_IsGameController(i)) { controller.reset(SDL_GameControllerOpen(i)); if (controller) break; }
        };
        open_controller();
        std::unique_ptr<AudioOutput> audio;
        if (!options.mute) audio = std::make_unique<AudioOutput>();
        std::unique_ptr<cheshire::WavWriter> wav;
        if (!options.wav.empty()) wav = std::make_unique<cheshire::WavWriter>(options.wav);
        bool fast = false; // fast-forward: the device is muted, the WAV keeps every sample
        machine.soc().spu().sample_sink = [&](std::int16_t left, std::int16_t right) {
            if (audio && !fast) audio->push(left, right);
            if (wav) wav->write(left, right);
        };
        // Keyboard carts take every typing key, so emulator hotkeys move to F9-F12 there.
        const bool keyboard = machine.peripheral() == cheshire::Peripheral::keyboard;
        const bool tablet = machine.peripheral() == cheshire::Peripheral::tablet;
        Pen pen;
        bool running = true, paused = false, finished = false;
        unsigned frames = 0, baby_mode = 0;
        std::uint64_t target_cycles = 0;
        auto deadline = std::chrono::steady_clock::now();
        const auto tick_frame = options.config.pal ? 539136u : options.config.reference_timing ? 450000u : 449592u;
        const auto frame_time = std::chrono::nanoseconds(std::uint64_t(tick_frame) * 1000000000 / cheshire::Soc::master_clock);
        const auto step = [&]() {
            if (options.instructions && machine.cpu().state().instructions >= *options.instructions) { finished = true; return; }
            if (trace) { if (!trace->step()) finished = true; }
            else machine.step();
        };
        while (running) {
            SDL_Event event;
            while (SDL_PollEvent(&event)) {
                if (event.type == SDL_QUIT) running = false;
                if (event.type == SDL_CONTROLLERDEVICEADDED) open_controller();
                if (event.type == SDL_CONTROLLERDEVICEREMOVED && controller && !SDL_GameControllerGetAttached(controller.get())) {
                    controller.reset(); open_controller();
                }
                // With a logical render size, SDL reports mouse positions in game pixels.
                if (tablet && event.type == SDL_MOUSEMOTION) {
                    pen.x = std::clamp(event.motion.x, 0, 319); pen.y = std::clamp(event.motion.y, 0, 239);
                }
                if (tablet && (event.type == SDL_MOUSEBUTTONDOWN || event.type == SDL_MOUSEBUTTONUP) && event.button.button == SDL_BUTTON_LEFT) {
                    pen.down = event.type == SDL_MOUSEBUTTONDOWN;
                    pen.x = std::clamp(event.button.x, 0, 319); pen.y = std::clamp(event.button.y, 0, 239);
                }
                if (event.type == SDL_WINDOWEVENT && event.window.event == SDL_WINDOWEVENT_FOCUS_LOST) pen.down = false;
                if (event.type == SDL_KEYDOWN && !event.key.repeat) {
                    auto key = event.key.keysym.sym;
                    const bool alt_enter = key == SDLK_RETURN && (event.key.keysym.mod & KMOD_ALT);
                    if (keyboard && !(key >= SDLK_F4 && key <= SDLK_F12 && key != SDLK_F8)) key = SDLK_UNKNOWN;
                    if (alt_enter && !keyboard) key = SDLK_F4;
                    switch (key) {
                    case SDLK_F4: {
                        const bool full = SDL_GetWindowFlags(window.get()) & SDL_WINDOW_FULLSCREEN_DESKTOP;
                        if (SDL_SetWindowFullscreen(window.get(), full ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP) < 0)
                            std::clog << "Fullscreen: " << SDL_GetError() << '\n';
                        break;
                    }
                    case SDLK_F6:
                        try { std::clog << "Screenshot: " << save_screenshot(cheshire::presented_frame(machine, options.demo), height).string() << '\n'; }
                        catch (const std::exception& e) { std::clog << "Screenshot: " << e.what() << '\n'; }
                        break;
                    case SDLK_ESCAPE: case SDLK_F12: running = false; break;
                    case SDLK_SPACE: case SDLK_F9: paused = !paused; break;
                    case SDLK_n: case SDLK_F10: paused = true; if (!finished) step(); break;
                    case SDLK_F5: case SDLK_F7:
                        if (trace || options.demo) std::clog << "Save states are not available in trace replay or the demo\n";
                        else if (options.state.empty()) std::clog << "Start with --state FILE to use F5/F7\n";
                        else try {
                            if (key == SDLK_F5) { machine.save_state(options.state); std::clog << "State saved\n"; }
                            else { machine.load_state(options.state); target_cycles = machine.cpu().state().cycles; finished = false; std::clog << "State loaded\n"; }
                        } catch (const std::exception& e) { std::clog << "Save state: " << e.what() << '\n'; }
                        break;
                    case SDLK_F1: baby_mode = 0; break;
                    case SDLK_F2: baby_mode = 1; break;
                    case SDLK_F3: baby_mode = 2; break;
                    case SDLK_r: case SDLK_F11:
                        if (!trace) { machine.reset(); if (options.demo) cheshire::setup_demo(machine); target_cycles = 0; finished = false; }
                        break;
                    default: break;
                    }
                }
            }
            if (!running) break;
            if (!trace) machine.set_input(read_input(controller.get(), baby_mode, SDL_GetWindowFlags(window.get()) & SDL_WINDOW_INPUT_FOCUS, keyboard, pen));
            // Holding F8 runs further frames until most of this presentation's time is used.
            fast = !options.demo && SDL_GetKeyboardState(nullptr)[SDL_SCANCODE_F8]
                && (SDL_GetWindowFlags(window.get()) & SDL_WINDOW_INPUT_FOCUS);
            const auto budget = std::chrono::steady_clock::now() + frame_time * 4 / 5;
            for (unsigned batch = 0; batch < (fast ? 16u : 1u) && !paused && !finished; ++batch) {
                if (batch && std::chrono::steady_clock::now() >= budget) break;
                if (options.demo) { for (unsigned i = 0; i < 4 && !finished; ++i) step(); }
                else {
                    target_cycles += tick_frame;
                    // Bound work so a stream of zero-cycle reference MULS cannot hang the UI.
                    for (unsigned i = 0; i < 1000000 && !finished && machine.cpu().state().cycles < target_cycles; ++i) step();
                }
            }
            if (audio) audio->flush();
            const auto frame = cheshire::presented_frame(machine, options.demo);
            check(SDL_UpdateTexture(texture.get(), nullptr, frame.data(), 320 * static_cast<int>(sizeof(std::uint32_t))));
            check(SDL_SetRenderDrawColor(renderer.get(), 0, 0, 0, 255));
            check(SDL_RenderClear(renderer.get())); check(SDL_RenderCopy(renderer.get(), texture.get(), nullptr, nullptr));
            SDL_RenderPresent(renderer.get());
            const auto title = std::string("Cheshire — ") + std::string(cheshire::system_name(machine.system()))
                + (trace ? " [reference replay]" : options.demo ? " [demo]" : "")
                + (paused ? " [paused]" : finished ? " [finished]" : fast ? " [fast-forward]" : "")
                + " PC=" + std::to_string(machine.cpu().pc());
            SDL_SetWindowTitle(window.get(), title.c_str());
            ++frames;
            if ((options.frames && frames >= *options.frames) || (finished && options.instructions)) running = false;
            deadline += frame_time;
            const auto now = std::chrono::steady_clock::now();
            if (deadline < now) deadline = now;
            std::this_thread::sleep_until(deadline);
        }
        if (!options.dump_frame.empty()) cheshire::write_ppm(options.dump_frame, cheshire::presented_frame(machine, options.demo));
        if (!options.save.empty()) machine.write_save(options.save);
        if (wav) wav->finish();
        std::cout << machine.cpu().state().instructions << " instructions, " << frames << " presentations\n";
        if (trace && options.audit_io) { trace->print_io_audit(std::cout); if (trace->io_mismatches()) return 1; }
        return 0;
    } catch (const std::exception& e) { std::cerr << "Cheshire: " << e.what() << '\n'; return 1; }
}
