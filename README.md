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
3. **PPU** — tile layers + sprites + palette, line-based renderer; compared
   against MAME frame snapshots.
4. **SPU** — 16-channel audio.
5. **Controller** — V.Smile joystick UART protocol (MAME `bus/vsmile/pad.cpp`);
   also the audio *registers* (status bits the game polls) ahead of the SPU.
6. **MiSTer top** — `emu.sv` from Template_MiSTer, SDRAM for cart/BIOS,
   OSD cart loading, region/language DIP settings.
7. Real hardware testing.

## Status: the SoC runs in lockstep with MAME

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

## Layout

    rtl/unsp/        µ'nSP CPU core
    rtl/spg2xx/      SoC: top/bus/DMA (spg2xx.sv), I/O (spg2xx_io.sv),
                     video control + timing (spg2xx_vctl.sv)
    rtl/vsmile.sv    board: cart/BIOS banking, DIP switches, controller lines
    sim/cpu/         CPU lockstep testbench (vs. MAME trace)
    sim/soc/         system lockstep / free-run testbench
    scripts/         mame_trace.sh: capture golden traces from MAME 0.264+
                     cpu_sweep.sh, soc_sweep.sh: run testbenches over traces
    ref/mame/        MAME reference sources (see MAME_REVISION)
    ROMS/            cart dumps (not in git)

## Running the CPU check

    scripts/mame_trace.sh "ROMS/Zayzoo - An Earth Adventure (USA).bin" /tmp/tr_zayzoo 1
    scripts/cpu_sweep.sh /tmp/tr_zayzoo
    scripts/soc_sweep.sh /tmp/tr_zayzoo
    FREERUN=1 sim/soc/obj_dir/Vvsmile "ROMS/Zayzoo - An Earth Adventure (USA).bin" /tmp/tr_zayzoo 7000000

`mame_trace.sh` needs MAME with the `vsmile` driver; it creates a
placeholder system ROM if `roms/mame/vsmile/vsmile_v103.bin` is absent.

## License

The µ'nSP core is derived from MAME's GPL-2.0+ µ'nSP implementation and is
GPL-2.0-or-later.
