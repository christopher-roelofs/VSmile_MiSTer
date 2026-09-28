# VTech V.Smile — FPGA core for MiSTer (early)

An FPGA recreation of the VTech V.Smile (2005) for the MiSTer DE10-Nano.
No FPGA implementation of the V.Smile (or of its SunPlus µ'nSP CPU) existed
when this started.  MAME's `vsmile` driver is the reference throughout.

## The hardware

| Part | What it is |
|---|---|
| SoC | SunPlus **SPG24x** (MAME `SPG24X`), 27 MHz XTAL |
| CPU | SunPlus **µ'nSP ISA 1.0**: 16-bit, 8 registers (SP R1-R4 BP SR PC), 22-bit word address space |
| RAM | 10 KW internal (0x0000-0x27FF) + palette/sprite/scroll RAM |
| Video | 2 tile layers + 256 sprites, 320x240, 15-bit colour, NTSC 60 Hz / PAL 50 Hz |
| Audio | 16-channel wavetable (PCM/ADPCM, envelopes), samples read from ROM |
| Carts | 4-8 MB ROM (some with NVRAM), little-endian 16-bit words |
| Controllers | joystick / keyboard / mat, talking to the SoC over a UART protocol |
| System ROM | 2 MB BIOS (optional: carts boot directly, the cart is banked over the BIOS at reset) |

The **V.Flash / V.Smile Pro is different hardware** (LSI Zevio 1020, ARM926
@150 MHz + 3D GPU + DSP, CD-ROM) and is not emulated by MAME beyond a
skeleton; it is out of scope.

SoC memory map (word addresses, MAME `spg2xx_device::internal_map`):

    000000-0027FF  RAM
    002800-0028FF  video registers        002900-0029FF  scroll RAM
    002A00-002AFF  hcomp RAM              002B00-002BFF  palette RAM
    002C00-002FFF  sprite RAM             003000-0037FF  audio
    003D00-003DFF  I/O, timers, IRQ, UART, ADC ...    003E00-003E03  system DMA
    004000-3FFFFF  external bus: cart ROM (chip-select modes 2/3 map the
                   system ROM at 300000-3FFFFF)

## Plan

1. **µ'nSP CPU** — `rtl/unsp/unsp_core.sv`, verified instruction-by-instruction
   against MAME golden traces.  ✅
2. **SoC skeleton** — RAM, interrupt controller, timers, GPIO/chip-select,
   UART, system + sprite DMA, video timing/IRQs, board-level banking.  ✅
3. **PPU** — tile layers + sprites + palette + blending, line-based renderer,
   pixel-exact against a C++ port of MAME's renderer.  ✅
4. **SPU** — 16-channel wavetable audio (PCM/ADPCM, envelopes, beat timer),
   registers verified against MAME 0.289.  ✅
5. **Controller** — V.Smile joystick UART protocol (MAME `bus/vsmile/pad.cpp`).  ✅
6. **MiSTer top** — `rtl/emu.sv`: SDRAM for cart/BIOS, OSD cart loading,
   TV mode / region / intro options, joystick.  ✅ bitstream built with
   timing closure (see below)
7. Real hardware testing.  ⏳ untested

## Status: the whole console runs in lockstep with MAME

Everything below the MiSTer top level exists and is verified:

**Video** (`rtl/spg2xx/spg2xx_ppu.sv`): every scanline the RTL renders is
compared pixel for pixel with a C++ port of MAME's renderer (`sim/soc/
ppu_ref.h`) drawing from the same memory at the same moment.  7 carts,
135,000 lines: **0 unexplained differences**.  The 19 lines that differ are
ones where the game wrote the palette or sprite RAM while the line was
being drawn (the RTL sees a mix of old and new data, as hardware would;
the reference sees only one state).  Not implemented: bitmap/line-map
mode, vertical compression, hi-colour, saturation (no title uses them).

**Audio** (`rtl/spg2xx/spg2xx_spu.sv`): the 16-channel wavetable unit
(8/16-bit PCM, IMA ADPCM, ADPCM36, envelopes, ramp-down, beat timer,
channel FIQs), ported from *current* MAME.  MAME 0.264's SPU has different
channel start/stop semantics, so audio register reads are verified against
a trace from MAME 0.289 (`MAME=<path> scripts/mame_trace.sh`): all reads
match except a few channel-status reads, where MAME notices a sample's
end only at its next sound update while the RTL clears the bit on the
exact sample.

**Controller** (`rtl/vsmile_pad.sv`): the joystick's UART protocol (probe
responses, keep-alives, RTS timing), so games see a controller exactly
as in MAME.

### Earlier milestones

**CPU** (`sim/cpu`): the RTL runs in lockstep with a MAME trace — PC and all
registers compared after every instruction, interrupts injected at the exact
instruction boundary where MAME took them.  7 carts, ~60 M instructions,
bit-identical; 27,450,003 cycles for Zayzoo's first 1.017 s vs. MAME's
27,450,000.

**SoC** (`sim/soc`, `rtl/vsmile.sv`): the whole system — RAM, video RAMs,
system and sprite DMA, cart/BIOS banking, I/O block, video timing — in
lockstep with the same traces.  Register reads are fed from MAME's log so
the trace stays comparable, while the RTL computes its own value for every
read and each disagreement is reported:

* all 7 carts pass (every RAM/DMA effect and every register write matches)
* every I/O, timer, interrupt-status and video register read matches MAME,
  except those that depend on the controller (not implemented yet: RTS
  line, UART receive) and ±1 jitter in beam-position reads
* free-running (RTL generates its own interrupts and register values),
  Zayzoo follows MAME's exact instruction stream for 888,759 instructions,
  until it reads an audio register (SPU not implemented yet), and then keeps
  running with MAME's interrupt rates

Timing model: the CPU keeps a cycle credit (+1 per 27 MHz tick, minus MAME's
charge per instruction) and only starts an instruction when it is not ahead
of real time; within an instruction it runs at the system clock.  Bus
stalls, DMA and interrupt entry are absorbed by catching up, so instruction
k starts at the same 27 MHz tick as in MAME.  The beam starts at line 240
like MAME's screen; `mame_timing` selects MAME's exact 60 Hz frame
(450,000 clocks) instead of true NTSC (449,592).

## MiSTer

`releases/VSmile_20260926.rbf` compiles for the DE10-Nano with timing
closure (setup slack +0.11 ns at 108 MHz, hold +0.25 ns; 39% ALMs, 14%
block RAM, 47% DSPs).  Getting there took eleven Quartus iterations, mostly
adding pipeline stages: the MAME-derived code was written as one step per
state and several of those steps (GPIO write with `/5`, ADPCM decode,
32-bit mixer products, strip address multiplies, the CPU's decode+ALU) were
15-40 ns long.  Every change was re-verified against the MAME traces, and
the audio output stayed bit-identical throughout.  **Untested on hardware
as of this build.**

    /media/fat/_Console/VSmile_<date>.rbf
    /media/fat/games/VSmile/boot.rom        <- optional system ROM (vsmile_v103.bin)
    /media/fat/games/VSmile/boot2.rom       <- optional V.Smile Motion system ROM

System ROMs load from these files when the core starts; games boot without
them.  Cartridges load from the OSD (`Load Cartridge`, plain `.bin` dumps as
in MAME's `vsmile_cart` list).  Console Auto picks the system per cart:
V.Smile Baby (reset vector below 0x8000), V.Smile Motion (its "V.Smile\084"
product record, with boot2.rom present), otherwise V.Smile.  Port 1 Auto plugs in the Smart
Keyboard for the four keyboard carts (a key table only they carry; model US,
or French/German by product number 80-091445/80-091444), otherwise the
joystick.  Both can be forced in the OSD.  Options: TV mode (NTSC/PAL), region (sets the
language the system ROM and games use), VTech intro on/off.  Controls:
d-pad, Green/Blue/Yellow/Red, OK/Quit/Help/ABC on joystick 1 (a V.Smile
joystick has exactly these).

Video is 320x240 progressive at 59.94 Hz (PAL: 320x288 at 50 Hz), 6.75 MHz
pixel rate, through the framework's scaler.  Audio is the SPU's 70,312.5 Hz
stereo stream.  The console, SDRAM controller and hps_io run on a 108 MHz
clock (4x the console's 27 MHz); the scan-out and the framework's video path
on 54 MHz from the same PLL.  The CPU's cycle credit absorbs SDRAM latency.

## Layout

    rtl/unsp/        µ'nSP CPU core
    rtl/spg2xx/      SoC: top/bus/DMA (spg2xx.sv), I/O (spg2xx_io.sv),
                     video control + timing (spg2xx_vctl.sv), renderer
                     (spg2xx_ppu.sv), sound (spg2xx_spu.sv)
    rtl/vsmile.sv    board: cart/BIOS banking, DIP switches, controller port
    rtl/vsmile_pad.sv joystick
    rtl/vsmile_video.sv scan-out timing;  rtl/emu.sv MiSTer top;  rtl/sdram.sv
    sys/             MiSTer framework;  VSmile.qsf/.qpf/.sdc Quartus 17.0 project
    sim/cpu/         CPU lockstep testbench (vs. MAME trace)
    sim/soc/         system lockstep / free-run testbench
    sim/video/       scan-out timing check
    scripts/         mame_trace.sh: capture golden traces from MAME 0.264+
                     cpu_sweep.sh, soc_sweep.sh: run testbenches over traces
    ref/mame/        MAME reference sources (see MAME_REVISION)
    ROMS/            cart dumps (not in git)

## Running the CPU check

    scripts/mame_trace.sh "ROMS/Zayzoo - An Earth Adventure (USA).bin" /tmp/tr_zayzoo 1
    scripts/cpu_sweep.sh /tmp/tr_zayzoo
    scripts/soc_sweep.sh /tmp/tr_zayzoo
    FREERUN=1 sim/soc/obj_dir/Vvsmile "ROMS/Zayzoo - An Earth Adventure (USA).bin" /tmp/tr_zayzoo 7000000

`mame_trace.sh` needs MAME with the `vsmile` driver (0.289 or later for
the audio registers to match; `MAME=<binary>` selects it); it creates a
placeholder system ROM if `roms/mame/vsmile/vsmile_v103.bin` is absent.
The system testbench takes `DUMP=<dir>` to write frames as PPM, `WAV=<file>`
to record the audio output and `FREERUN=1` to run without MAME's help.

Building a MAME 0.289 `vsmile`-only binary from source (`make SUBTARGET=vsmile
SOURCES=src/mame/vtech/vsmile.cpp USE_QTDEBUG=0 TOOLS=0`) took ~30 min on 8
cores; on this machine the generated makefiles wrongly carried
`-D_WIN64`, MSVC `/wd` flags and the `bx/include/compat/msvc` include path,
which had to be stripped from `build/projects/sdl/mamevsmile/gmake-linux/*.make`.

## License

The µ'nSP core is derived from MAME's GPL-2.0+ µ'nSP implementation and is
GPL-2.0-or-later.
