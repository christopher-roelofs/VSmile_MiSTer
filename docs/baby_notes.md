# V.Smile Baby

The V.Smile Baby is a V.Smile with an SPG28x SoC and its buttons built into
the console.  The core runs it when Console = V.Smile Baby, or on Auto for a
cart whose reset vector (word 0xFFF7) is below 0x8000 (every known Baby cart:
0x4EE6-0x5B22; every standard/Motion cart: 0xA425-0xF993).

## Differences from the V.Smile (MAME `vsmileb`)

| | V.Smile | V.Smile Baby |
|---|---|---|
| SoC | SPG24x, 256 sprites | SPG28x, 64 sprites |
| UART baud | 27 MHz / (16 × (0x10000 − BAUD2:BAUD1)) | a BAUD1 write: 27 MHz / (0x10000 − BAUD1) |
| Port A in | 0 (Motion 0xC000) | 0x0302, bit 7 = VTech intro |
| Port B in | 0x00C8 | 0x0080 |
| Port C | region, controller RTS | not connected (reads 0) |
| Port B writes | cart cs2 | not connected |
| Controllers | 2 ports, RTS/CTS handshake, ext IRQ | none: built-in buttons |
| System ROM | 2 MB, some carts use it | 8 MB, carts do not use it |

Cart banking (chip-select modes) is the same.

## Buttons

Every change sends two UART bytes, high byte first, with no handshake:
press = mode | button, release = mode | 0x0080, switch move = new mode | 0x0080.
mode: 0x0400 Play Time, 0x0800 Watch & Learn, 0x0C00 Learn & Explore (Play
Time after reset).  Buttons: yellow 0x01FE, blue 0x03EE, orange 0x03DE, green
0x03BE, red 0x02FE, cloud 0x03F6, ball 0x03FA, exit 0x03FC (`rtl/vsmile_baby.sv`).

MiSTer: Green/Blue/Yellow/Red are the pad's colour buttons, OK = Orange,
Quit = Exit, Help = Cloud, ABC = Ball.  The Baby has no directions, so the
d-pad doubles the colour buttons: up Blue, left Yellow, down Green, right Red
(where X, Y, B sit on a pad; Red is L).  The function switch is the OSD option
"Baby Switch" (changes are sent live).

## System ROM

Baby carts boot and run identically in MAME with an all-zero system ROM
(Barney: same frames to the title screen), so the core needs no Baby BIOS
file; the system ROM window reads as the dummy BIOS.

## UART rate: MAME bug

Baby carts write BAUD1 = 0xEA07, which the SPG28x formula makes exactly 4800
baud, the rate standard carts set with BAUD2:BAUD1 = 0xFEA0 (4794 baud).
MAME has the SPG28x formula (`spg28x_io_device`) but never instantiates it:
`spg24x_device::device_add_mconfig` creates an SPG24X_IO for the SPG28x too,
so MAME's Baby reads its buttons at 300 baud (~35 ms per byte).
`scripts/mame_spg28x_io.patch` gives the SPG28x its own I/O block; with it the
RTL matches MAME in lockstep with button input (Barney, 25 button/switch
events: every UART byte identical, IRQ status equal but for 4 reads of
sub-frame jitter).

## Fast ramp-down (narration)

MAME marks the Baby not working because narration clips are cut short,
blaming "Fast Rampdown".  Logging SPU writes in Barney (60 s, MAME):

* the game starts a sound effect by writing 0x4FDx to the ramp-down register
  (0x340A), which includes the narration channels;
* narration channels are ADPCM one-shots with a *manual* envelope
  (0x3415 bit set); 28 of 73 manual-envelope clips were ramped to silence within a
  few frames, the rest ended naturally;
* sound-effect channels (automatic envelope) are the ones the game means to
  fade.

In SPG28x mode the core's SPU leaves manual-envelope channels alone on a
ramp-down (fast ramp-down belongs to the automatic envelope generator).  This
is an inference from the games' behaviour, not from documentation.  The
standard V.Smile keeps MAME's behaviour: its carts do ramp down
manual-envelope channels (music notes, e.g. 0x0FF0 at a scene change), which
MAME plays correctly.

## Verification

* `MAME_SYSTEM=vsmileb scripts/mame_trace.sh` (0xFF placeholder system ROM),
  `BABY=1` in the testbenches; `scripts/baby_input.lua` scripts buttons and
  logs timed events for `KBD_EVENTS`.
* Barney: 11.5 M instructions lockstep, 0 of 29040 video lines differ,
  interrupts equal.
* Sweep (`scripts/baby_sweep.sh`, MAME 0.264, no input, 3 s each): all 23
  known Baby carts (20 .bin + the German Farm, German learndhge and Swedish
  Pooh .u4 dumps) run in lockstep, 0 differing video lines, interrupts equal.
