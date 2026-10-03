# Bring-up validation

Local checks on Linux, with GCC 13.3, CMake 3.28 and installed SDL2:

- Release build of the core, SDL2 frontend, headless tool, and tests.
- Core tests: flags, segmented PC and DS rollover, arithmetic shifts, signed
  multiply/FIR, call/return stack, interrupt priority/enables/RETI, unknown
  opcode rejection, ROM loading and mirroring, system detection, BIOS windows,
  16 MB cart chip selection, DMA, cartridge RAM persistence, reference trace
  mismatch rejection, and CPU writes affecting the rendered demo sprite.
- SDL2 smoke test: three presentations using the dummy video driver and
  software renderer, plus inspection of the emitted framebuffer.
- Three million instructions each matched against existing MAME captures for
  Finding Nemo (USA), A Day on the Farm (V.Smile Baby), and Toy Story 2
  (SmartBook). Both plain and gzip instruction traces were exercised.
- One million instructions matched a freshly captured V.Smile Motion run
  of Little Einsteins (US, revision 2), with the Motion BIOS loaded.
- Swedish Art Studio matched its first two million instructions; its longer
  capture diverged before instruction 2,753,482 at an external ROM read.
  The logged value was `0xffff`; Cheshire's FPGA-style ROM mirroring returned
  `0x0000`. This remains an explicit capture/board-mapping limitation.
- Headless build/tests with SDL2 disabled and zlib unavailable.
- Build/tests with SDL2 2.32.10 fetched and linked statically, exercising the
  same dependency path used by the hosted CI workflow.

## Timed SoC and input milestone

- Release build and all three CTest tests pass with the new scheduler and
  SDL controller frontend. The headless build without SDL2 or zlib also
  passes. Debug core/headless tests pass under AddressSanitizer and
  UndefinedBehaviorSanitizer.
- Deterministic device tests cover reference/hardware NTSC and PAL frame
  lengths, vblank/beam/FIQ routing, system/timebase timers, timer A/B overflow
  and preload, PRNG read effects, GPIO inversion, ADC completion, watchdog
  expiry/kick, and advancing in different-sized clock chunks.
- UART tests cover standard and Baby baud timing, TX/RX status and IRQ
  acknowledgement, FIFO overflow, Baby packets, joystick initial reports,
  probe replies, input changes, and the combined board/controller handshake.
- Finding Nemo matches 10 million CPU instructions and 133,368 register
  events against the existing capture. All 993 audited video/I/O reads
  match independently computed device values. This includes the corrected
  default English-US region/intro bits (`0x1f`).
- CPU replay regression checks still match three million Baby instructions
  and one million Motion instructions with the timed devices enabled.
- Independent Finding Nemo execution reaches its main menu at 600 hardware
  frame periods (269,755,201 charged cycles). A local harness then sends
  Down and OK through `Machine::set_input`, advancing the selection and
  opening the Learning Zone activity menu. Frames were visually inspected;
  they were not compared pixel-for-pixel to a reference.
- Independent A Day on the Farm execution reaches the V.Smile Baby console
  splash at 600 hardware frame periods. This is a boot check, not evidence
  of full game functionality.

The independent checks use no trace-supplied reads or interrupt boundaries.
ROMs and screenshots remain local build artifacts.

## Audio milestone

- Core tests cover SPU register masks, a 16-bit one-shot's mixed output and
  end (no STOP bit), IMA ADPCM decoding and nibble advance, channel FIQ and
  acknowledge, envelope clock/increment/next-entry load, and the beat IRQ
  on IRQ4 after exactly 384 master ticks.
- `cheshire_headless --spu-log PREFIX` records every audio register write
  and bank change with the sample it first affects, plus the output samples.
  Replaying those into the FPGA core's Verilated `spg2xx_spu.sv`
  (`sim/spu/spu_tb.cpp`, rebuilt from the current RTL) matched every sample:
  Finding Nemo 15 s, and Alphabet Park Adventure, Batman: Gotham City Rescue,
  Barney: The Land of Make Believe and Little Red Riding Hood 10 s each
  (4.17 M samples, 0 differences, 0 samples read from RAM). These runs
  exercised 8-bit PCM (one-shot, loop and software), IMA ADPCM one-shots,
  envelopes and ramp-down. Little Red Riding Hood made only 47 audio writes.
- Not exercised against the RTL by those games: 16-bit PCM (covered later,
  under census coverage runs), ADPCM36 and channel FIQs. On ADPCM36, Cheshire follows MAME's per-fetch header check;
  the RTL can repeat a header read when one sample tick fetches twice.
- This shows agreement with the FPGA port of MAME's SPU, not with hardware
  recordings. The Baby ramp-down exception is the FPGA core's, not MAME's.

External captures and game dumps stay outside source control. Reference
replay supplies register reads and IRQ boundaries. CPU replay alone does not
validate independent peripherals; the device tests, audited reads and
independent boots above provide narrower evidence for those implementations.
No claim of pixel-exact game video verification is made for Cheshire yet.

The GitHub Actions workflow builds SDL2 and runs tests on Linux, Windows,
and macOS. Those hosted jobs have not been run from this workspace.

## Scanline video milestone

- A core test moves the demo sprite between lines 116 and 117 being drawn
  and checks that earlier lines keep the old position and later lines show
  the new one, that the frame is published at vblank, and that the fade
  offset subtracts from each 8-bit channel.
- Finding Nemo's title screen at 600 frame periods renders as before.
  Over 1,200 frames, Finding Nemo, Alphabet Park Adventure, Batman and Barney
  each make 50 to 100 video register writes while lines are being drawn,
  around scene changes; none writes a nonzero fade in that time.
- The renderer is the same MAME port as before; lines were not compared
  pixel for pixel against the FPGA or MAME in this milestone.

## Keyboard and tablet milestone

- Core tests cover the Smart Keyboard hello ID, the five-byte console
  handshake and layout answer, key press/release codes, Shift's A9/AA,
  the keyboard joystick and OK button, the tablet's ID, its three-byte
  handshake without a layout byte, a pen packet's bit packing, and the probe answer.
- Smart Keyboard (US), Smart Key (German), Tip Tap (French), Teclado
  Interactivo (Spanish) and Art Studio (US) all complete the handshake
  within 600 frames and leave the device active.
- Smart Keyboard: OK leaves the title; two presses of the keyboard's own
  Down arrow (matrix row 4) move the menu cursor to Knowledge Area, and OK
  opens it.
- Art Studio: the cursor follows the pen (pen at (250, 180), cursor at
  about (255, 183)); pressing Free Draw opens the canvas, and a pen-down drag
  draws a matching line.
- The SDL frontend starts both carts under the dummy video and audio drivers.
  Host keyboard and mouse mapping have not been exercised interactively.
- Not compared against a MAME capture: MAME has a keyboard model but no
  tablet, and no keyboard capture was made for this milestone.

## Boot sweep

Every local cart was run headless for 1,200 frame periods (20 s) without
input, recording errors, the final picture, frame changes and audio level.

- 315 standard and 24 Baby carts with no system ROM; 94 Motion carts with
  the Motion system ROM (92 detected as Motion; two without the product
  record run as V.Smile and boot).
- Toy Story 3 (Italy) [b] hits an unsupported opcode at PC 0: a bad dump,
  also flagged by the FPGA census.
- Adventures of Little Red Riding Hood (US), Mes Premiers Clics, Mein erster
  Mausklick and PC Pal Island stay black without a system ROM. With
  `vsmile_v102.bin`, Red Riding Hood, Mes Premiers Clics and PC Pal Island
  draw and play sound; Mein erster Mausklick was not retried. MAME also
  stalls on Red Riding Hood (US) without the ROM, per the FPGA census.
- Toy Story 2 (USA) stayed black until the ON-button fix (FPGA core
  9f4eb4d); it now reaches its main menu.
- Cars and SpongeBob carts flagged by the heuristics were on their
  trademark and title screens.
- Every other cart showed a picture and produced sound. This is a boot check
  only; gameplay beyond the first 20 s was not exercised.

## Census coverage runs

`--autoplay` replays `scripts/census.lua`'s inputs, with the v102 system ROM.

- Fade: Freds Zahlen Rallye first writes a nonzero fade at frame 623, the
  frame the FPGA census recorded in MAME. It ramps 0x04 to 0x60 in steps of
  four; captured frames peak at 255 minus the offset (187 at 0x44, 179 at
  0x4C), an even dim of the whole picture.
- ADPCM36: neither Kleine Einsteins nor Les Petits Einsteins wrote an
  ADPCM36 select bit in 2 minutes. The census's only ADPCM36 hits for them
  are stamped at frame 1886, the frame its Kleine Einsteins run ended early,
  which suggests a write made as the run broke down rather than real use.
  No cart is known to use ADPCM36; it remains covered by MAME semantics only.
- Red Riding Hood (FR) first plays 16-bit looping PCM at 55 s; Kleine
  Einsteins plays ADPCM with the 16-bit bit set from 11 s. Both, with the
  v102 system ROM, match the FPGA core's Verilated SPU on every sample:
  Red Riding Hood (FR) for 62 s (4.36 M samples) and Kleine Einsteins for
  20 s (1.41 M samples), 0 differences. With the earlier runs, 16-bit PCM is
  now exercised against the RTL; ADPCM36 and channel FIQs are not.

## Windows cross-build

- i686-w64-mingw32 GCC 13, static, Release: core, headless tool and tests
  build without warnings (zlib and SDL off), and so does the SDL frontend with
  SDL2 2.32.10 built from source via `CHESHIRE_FETCH_SDL`.
- Under Wine: core tests pass; the headless demo runs. Finding Nemo for 600
  frames, loaded from a path with spaces and an apostrophe, gives a frame
  and a WAV byte-identical to the Linux build (702,487 samples). The SDL
  frontend runs the demo and the Smart Keyboard cart for 60 frames with the
  dummy video and audio drivers and exits cleanly.
- Cross-building needs `-DCMAKE_DISABLE_FIND_PACKAGE_SDL2=ON` (and ZLIB)
  so CMake does not pick up the Linux host's packages.
- Not covered: 64-bit Windows, MSVC, a real Windows desktop, macOS.

## Sanitized cart runs

The Debug AddressSanitizer/UndefinedBehaviorSanitizer headless build ran
900 frame periods each, with `--autoplay`, the v102 system ROM, WAV and frame
output: Finding Nemo, Smart Keyboard (keyboard model), Art Studio (tablet
model and cart RAM), A Day on the Farm (Baby) and Red Riding Hood (FR). No
sanitizer reports; about 86-92 million instructions and 1.05 million audio
samples per cart. (The autoplay script drives joystick buttons, so the Baby
run sent no input packets.)

## Save states

- Core tests: restoring a state brings back CPU registers and video; running
  on from it repeats the same cycles, registers and audio samples as the
  original run; a truncated state, a state for another cartridge, and one
  for another TV standard are refused, and a refused load leaves the machine
  byte-for-byte unchanged.
- Finding Nemo with `--autoplay`: saved at frame 300 and resumed to 600, the
  instruction count, final frame and all 351,244 audio samples after the
  save equal an uninterrupted 600-frame run. The same holds saving at frame
  417 for Smart Keyboard (keyboard protocol state), Art Studio (tablet and
  2 MB cart RAM; 2.75 MB state), A Day on the Farm (Baby) and Little
  Einsteins (Motion, with its system ROM).
- The Linux-saved Nemo state, resumed by the Windows (MinGW, Wine) build,
  produces a byte-identical frame and WAV.
- The SDL F5/F7 keys were not pressed in a test; the frontend starts with
  `--state` under the dummy drivers.
