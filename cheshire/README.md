# Cheshire

A portable C++20 software emulator project for the V.Smile family, using
SDL2 for presentation. The implementation starts from the hardware behavior
and verification work in `mister_vtech`, rather than requiring an FPGA or
Verilator at runtime.

**This is an early emulator.** The CPU, board memory mapping, DMA, timed SoC
peripherals, 16-channel audio, joystick, Gym Mat, Smart Keyboard and Art
Studio tablet input, reference-trace comparison, and scanline-timed video
work. All 433 local carts (standard, Baby, Motion) boot to a picture with
sound in a 20-second check, except one bad dump and four carts that need the
system ROM; longer gameplay has only been spot-checked. See
[docs/validation.md](docs/validation.md).

## Build and run

Requirements: CMake 3.20+, a C++20 compiler, and SDL2 2.0.18+ development
files. Zlib is optional; it enables reading compressed reference traces.

```text
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release --parallel 4
ctest --test-dir build -C Release --output-on-failure
```

If SDL2 is not installed, add `-DCHESHIRE_FETCH_SDL=ON` to the configure
command. This downloads a pinned SDL2 2.32.10 revision and builds it
statically. Alternatively, supply `SDL2_DIR` pointing to an installed SDL2
CMake package. An installed shared SDL2 DLL is copied beside the Windows
executable when its package exposes a shared library target.

For a dependency-free headless build, use `-DCHESHIRE_BUILD_SDL=OFF`.
The build does not download anything unless fetching SDL is explicitly enabled.

```text
build/cheshire --demo
build/cheshire_headless --demo --instructions 10000
build/cheshire --rom "path/to/cart.bin" --system vsmile
build/cheshire --rom "path/to/motion.bin" --system motion --bios "path/to/motion-bios.bin"
```

Multi-configuration generators place executables under `build/Release/`;
Windows executables have the `.exe` suffix. Run `--help` for all options.

The built-in demo executes a small synthetic µ'nSP program that moves a
sprite through CPU memory writes. It requires no ROM or BIOS. Space pauses,
N executes one instruction while paused, R resets, and Escape exits.
Reset is disabled during trace playback.

In games, arrow keys control direction; Z/X/C/V are green/blue/yellow/red.
Enter is OK, Backspace is Quit, H is Help, and A is ABC. SDL2 game controllers
support the D-pad or left stick, A/B/X/Y for colors, Start/Back for OK/Quit,
and left/right shoulders for Help/ABC. Controllers can be connected while
running. F1/F2/F3 select the Baby activity mode. Losing window focus releases
input; trace playback ignores host input. F9 pauses, F10 steps, F11 resets
and F12 exits in every mode. F4 (or Alt+Enter outside keyboard carts)
toggles fullscreen, F6 saves a BMP screenshot named
`cheshire-YYYYMMDD-HHMMSS.bmp` in the current directory, and holding F8
fast-forwards with the audio device muted (`--wav` still records every
sample). `--fullscreen` starts fullscreen and `--integer-scale` scales only by
whole multiples.

Smart Keyboard carts take the host keyboard by key position (MAME's matrix),
so an AZERTY or QWERTZ keyboard types its own letters with the French or
German cart. Tab is Typing Time, `]` is Erase, keypad 1/2 are Player 1/2 and
keypad + is Symbol. Enter, Esc and F1 are OK, Quit and Help; only F4-F12
remain emulator keys. The gamepad drives the keyboard's joystick and buttons.
For the Art Studio tablet, the mouse moves the pen over the picture and the
left button presses it; the other keys work as for the joystick.
`--controller auto|joystick|keyboard|mat|tablet` and
`--keyboard-layout us|fr|de` override cartridge detection.

`--state FILE` enables save states in the SDL frontend: F5 saves the whole
machine to FILE and F7 restores it (keyboard carts keep F5/F7 for this too).
The headless tool takes `--load-state FILE` before running and
`--save-state FILE` at the end. A state loads only with the same cartridge,
system ROM, system, controller, TV standard and timing; anything else, or a
damaged file, is refused and leaves the running machine unchanged. Files use
a fixed little-endian layout and move between Linux and Windows builds. They
are not a substitute for `--save`, which keeps the Art Studio's own storage.
Trace replay and the demo do not use states.

`cheshire_headless --autoplay` presses the FPGA census's button script
(after frame 300, one input every 90 frames, held for 8), so coverage runs
reach past title screens reproducibly.

`--frames N` stops the SDL frontend after N presentations; the headless tool
stops after N complete emulated frame periods. For example:

```text
build/cheshire_headless --rom "path/to/cart.bin" --frames 600 --dump-frame frame.ppm
```

`--wav FILE` records the SPU output as a 70,313 Hz stereo WAV with either
tool, and `--mute` stops the SDL frontend from opening an audio device. If no
audio device is available, the frontend runs silently.

SDL2 presents an ARGB8888 streaming texture with nearest-neighbor scaling.
Its default renderer chooses the platform backend. `--renderer software`
or `--renderer opengles2` selects an available SDL backend; no custom GLES
context is required. See the [SDL2 renderer API](https://wiki.libsdl.org/SDL2/SDL_CreateRenderer).

On Linux, when `WAYLAND_DISPLAY`
is nonempty and `SDL_VIDEODRIVER` is unset, it prefers native Wayland with X11
as a fallback (`wayland,x11`, supported by SDL 2.0.22+). Older SDL2 runtimes
use `wayland`. Otherwise SDL chooses its default video backend. An explicit
`SDL_VIDEODRIVER` is always preserved; set it to `x11` or `wayland` to force
that window-system backend, or `dummy` for display-free testing. Windows and
macOS retain their normal SDL selection. Startup prints the actual video
backend and renderer separately; `--renderer` controls frame presentation.

## Current implementation

| Component | Status |
| --- | --- |
| µ'nSP ISA 1.0 | Interpreter: ALU, addressing, branches, stack, far call/jump, multiply, FIR/MULS, IRQ/FIQ and RETI |
| Board | V.Smile, Motion and Baby profiles; auto detection follows the FPGA core |
| Memory | Little-endian ROM loading, 22-bit word bus, ROM mirroring, BIOS windows, 16 MB cartridge chip switching |
| Art Studio storage | 2 MB cartridge RAM mapping and explicit little-endian save loading/writing |
| DMA | System DMA and sprite DMA, immediate reference-compatible transfer effects |
| Video | Scanline-timed renderer: tiles, sprites, scrolling, extended attributes, blending, vertical compression, fade; 64 sprites for Baby |
| Timed SoC | 27 MHz scheduler; NTSC/PAL beam, vblank/position/DMA IRQs, system/timebase timers, timers A/B, GPIO masks/inversion, PRNG, watchdog and ADC completion |
| UART/input | Baud-derived TX/RX completion, FIFO/status/IRQs, joystick handshake/reports, Gym Mat remapping, Smart Keyboard (US/FR/DE), Art Studio tablet and Baby button packets |
| Verification | Headless CPU/register trace comparison and optional timed video/I/O read auditing, with in-process gzip when zlib is present |
| SPU | 16 channels: 8/16-bit PCM, IMA ADPCM, ADPCM36, loops, envelopes, ramp-down, beat IRQ, channel FIQs |
| SDL2 | Resizable window, framebuffer display, resampled audio, keyboard/mouse/gamepad input, pause/step/reset, finite presentation runs |
| Motion tilt, SmartBook | Not implemented (Motion carts play with the joystick, as on the FPGA core) |

PAL presentation has 288 lines, with 240 rendered game lines and a black
48-line remainder. As in the FPGA core, line y is drawn from the state at
the start of line y-1 (line 0 during the frame's last line), and the frame is
presented once line 240 begins, so register and memory writes made during
the frame affect only later lines. Pixels within a line still come from one
moment; the FPGA's mid-line reads are not reproduced. The fade offset
(0x2830) is applied when the line is drawn rather than at scan-out. Vertical
compression tables are rebuilt on writes to 0x281C-0x281E, as in MAME.
The demo, and output requested before any frame completes, use a whole-frame
snapshot of the current state. Unsupported
CPU instructions fail with the opcode and PC rather than silently continuing.
The reference's zero-cycle charge for MULS is retained and the UI bounds work
per presentation to remain responsive.

Cart content detection recognizes Baby reset vectors, Motion product records,
Smart Keyboard, Gym Mat, and Art Studio markers, including US/French/German
keyboard layouts, and plugs in the matching controller. The keyboard and
tablet follow the FPGA core's `vsmile_kbd.sv`. The tablet's device ID (0x54)
is the FPGA model's guess; the cart accepts any 0x5x. Auto chooses Motion only when a BIOS is supplied. Supply the
BIOS for the system you select; standard/Motion BIOS images must be 2 MB.
Baby currently uses the empty BIOS behavior from the FPGA core. As in the FPGA
core, the ON button reads as still held for the first 30 frames after reset;
Toy Story 2 (USA) checks it at boot and otherwise keeps powering itself off.
Trace replay reads it released, as MAME does. Some carts call into the system
ROM and stay black or stall without one: Adventures of Little Red Riding Hood
(US), Mes Premiers Clics, Mein erster Mausklick and PC Pal Island need `--bios`.

`--save FILE` loads an existing 2 MB Art Studio save, or starts with empty RAM
if the file is absent, then writes the RAM on a clean exit. Other cartridge
types reject the option. Save paths are explicit; no platform-specific home
directory conventions are used. Trace verification rejects saves to avoid
mixing reference initial memory with a user's stored drawing data.

## Reference verification

Reuse a capture generated by `mister_vtech/scripts/mame_trace.sh`:

```text
build/cheshire_headless --rom "path/to/cart.bin" --trace "path/to/capture" --instructions 3000000
build/cheshire_headless --rom "path/to/cart.bin" --trace "path/to/capture" --audit-io --instructions 3000000
build/cheshire --rom "path/to/cart.bin" --trace "path/to/capture"
```

The capture directory contains `cpu.tr` and `mem.log`, each optionally gzip
compressed. Without zlib, provide uncompressed files. No external gzip program
or shell is invoked. For a capture made with a real BIOS, pass that same BIOS
and system selection to Cheshire. Trace mode uses an erased missing BIOS,
matching the placeholder in the original trace workflow; ordinary execution
uses the core's empty BIOS with safe resource pointers.

CPU state is checked before every instruction in MAME's order
`R1 R2 R3 R4 SP BP SR PC`. Register read values and interrupt boundaries come
from the capture. Cheshire computes instructions, RAM writes, board banking,
and DMA effects; register writes are checked against the capture. The first
mismatch fails the run and reports the instruction number and differences.
A partial final trace line is ignored, as captures can end during a write.

**A successful trace replay verifies the CPU path, not game playability.**
Replay supplies captured register reads and interrupt boundaries even when
the corresponding device is implemented. `--audit-io` also compares the
device's own video/I/O register read values before replay overrides them,
reports differences per address, and returns failure if any differ. Audio
reads and independently generated interrupt boundaries are not audited.
Video in replay is rendered from the emulated memory at each scanline.

The core keeps FPGA-style cartridge mirroring. Captures made with different
ROM padding, cartridge chip order, BIOS images, or initial backup RAM can
diverge even when the CPU agrees. In particular, the existing Swedish Art
Studio capture agrees through two million instructions but later diverges at
a read beyond its 4 MB ROM image; that capture is not a full passing test.

No ROMs, BIOS images, or third-party game trace data are bundled. See
[docs/validation.md](docs/validation.md) for local checks and their limits.

## Architecture and next work

`cheshire_core` has no SDL dependency. `WordBus` uses word addresses;
`Unsp::step()` returns the instruction's cycle charge and accepted interrupt.
`Machine` owns board memory/banking, the CPU, and `Soc`. Every instruction
advances the deterministic scheduler by its charged cycles, then samples
interrupt lines. `TraceSession` installs a temporary register replay hook.
The frontend consumes frames without exposing window or renderer types to
the emulation library.

The scheduler uses a 64-bit 27 MHz tick clock and integer phases for
fractional timer periods. `--timing hardware` is the default: NTSC uses
1,716 ticks per line and 262 lines per frame; PAL uses 1,728 and 312.
`--timing reference` uses a 450,000-tick NTSC period for the existing MAME
captures; trace mode selects it automatically. PAL timing currently stays
at the hardware rate in either mode. CPU bus accesses and interrupt sampling
remain instruction-granular. ADC completion currently returns a fixed sample.
Host frame pacing never determines device timing.

The SPU is a sequential port of the FPGA core's `spg2xx_spu.sv`. It produces
one stereo sample per 384 master ticks (70,312.5 Hz), reading samples and
envelopes through the board bus. The SDL frontend resamples it to the host
device with `SDL_AudioStream`, keeping at most about 120 ms queued; host
pacing still follows the video frame clock. Like the FPGA core, the Baby's
fast ramp-down leaves manual-envelope channels alone. The equaliser,
compressor and soft-channel FIFO registers are stored but not modelled.

Remaining gaps: Motion tilt (the FPGA core has none either), the SmartBook
(its printed pages are not in the ROM), and the PPU's line-map, hi-colour and
saturation modes, which no V.Smile title is known to use.

The code uses standard C++ filesystem/streams/chrono plus SDL2. It contains
no POSIX-specific APIs, shell execution, or dependencies on MiSTer runtime
services. CI is configured for Linux, Windows and macOS, but the hosted jobs
have not run. Linux is tested natively; a 32-bit MinGW cross-build (core,
headless, tests and the SDL frontend with SDL2 built from source) has been
run under Wine. macOS has not been built.

V.Flash/V.Smile Pro uses a different ARM-based platform. SmartBook controller
support and the Dora plug-and-play systems remain unimplemented.

## License

GPL-2.0-or-later, matching the MAME-derived µ'nSP work. The scanline renderer
retains its BSD-3-Clause notice. See [COPYING](COPYING) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
