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
   UART, system DMA; checked against the same traces with register reads
   produced by RTL instead of replayed.
3. **PPU** — tile layers + sprites + palette, line-based renderer; compared
   against MAME frame snapshots.
4. **SPU** — 16-channel audio.
5. **Controller** — V.Smile joystick UART protocol (MAME `bus/vsmile/pad.cpp`).
6. **MiSTer top** — `emu.sv` from Template_MiSTer, SDRAM for cart/BIOS,
   OSD cart loading, region/language DIP settings.
7. Real hardware testing.

## Status: the CPU matches MAME

`sim/cpu` runs the RTL in lockstep with a MAME trace: PC and all registers
are compared after every instruction, and interrupts are injected at the
exact instruction boundary where MAME took them.  RAM, both DMA engines and
cart banking are modelled in the testbench; SoC register reads are replayed
from MAME's bus log and every register write is checked against it.

Zayzoo (USA): **6,859,648 instructions (1 s of emulated time, 454
interrupts) bit-identical to MAME**, with cycle counts matching MAME's
per-instruction charges (27.45 M cycles at 27 MHz).

## Layout

    rtl/unsp/        µ'nSP CPU core
    sim/cpu/         Verilator lockstep testbench (vs. MAME trace)
    scripts/         mame_trace.sh: capture golden traces from MAME 0.264+
    ref/mame/        MAME reference sources (see MAME_REVISION)
    ROMS/            cart dumps (not in git)

## Running the CPU check

    scripts/mame_trace.sh "ROMS/Zayzoo - An Earth Adventure (USA).bin" /tmp/tr_zayzoo 1
    make -C sim/cpu
    sim/cpu/obj_dir/Vunsp_core "ROMS/Zayzoo - An Earth Adventure (USA).bin" /tmp/tr_zayzoo

`mame_trace.sh` needs MAME with the `vsmile` driver; it creates a
placeholder system ROM if `roms/mame/vsmile/vsmile_v103.bin` is absent.

## License

The µ'nSP core is derived from MAME's GPL-2.0+ µ'nSP implementation and is
GPL-2.0-or-later.
