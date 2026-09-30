# V.Smile system ROM: how carts use it (towards an open BIOS)

Findings from scripts/bios_survey.sh (census/bios_report.md), MAME traces and
the cart code that reads the ROM.  No system ROM code or data is reproduced
here; addresses are word addresses as the CPU sees them.

## Carts never execute it

Over 224 carts (60 s each with the census button script) no cart fetched an
instruction from the system ROM.  209 read data from it: a pointer table at
the top, and the areas it points to (~94K words shared by nearly all carts,
plus outliers).  The console boots from the cartridge (MAME machine_start:
cart banked everywhere); a cart switches the chip select mode to 2/3
(REG_EXT_MEMORY_CTRL 0x3D23 bits 7:6) to see the system ROM at 0x300000.

## The pointer table

Words 0x3FFFC0-0x3FFFDB (slots 0-13) and 0x3FFFF0 (slot 24): 32-bit
pointers, low word first.  v102 contents, by what the pointed-to data looks
like:

| slot | v102 pointer | contents |
|---|---|---|
| 0, 1 | 0x31687D, 0x317241 | lists of pointers into 0x3A0000-0x3FFFFF |
| 2 | 0x002000 | a RAM address (work area), not ROM data |
| 3, 4, 7 | 0x319E24, 0x319FBE, 0x318AEA | tables of pointers into 0x31xxxx (resource directories) |
| 5, 6 | 0x31A3D4, 0x31A442 | identity lookup tables (0, 1, 2, ...) |
| 8-11 | 0x319357, 0x30FAE6, 0x319A5B, 0x310026 | data with 0x80xx words: the VTech music driver's note format (vtech.pulkomandy.tk), i.e. jingles |
| 12 | 0x31006A | table of values |
| 13 | 0x3198DA | system ID: "TVSYS " then a version string at +11 ("3.0" in v102) |
| 24 | 0x3199DC | read by carts right after the table (ABC Land) |

## The ID check

Cart code (e.g. ABC Land Aventure (France) at 0x075C4E) reads slot 13 and
compares up to 20 words at that address with a string of its own ("TV 1.0"
in that cart), returning 0xFFFF on a mismatch.  So carts identify the system
ROM before relying on its contents.

## A dummy that games accept

veesem (github.com/sp1187/veesem, ISC licence) runs games without a system
ROM using a dummy: all zeros, with slots 0-13 = 0x00310000.  The ID check
then fails (zeros match no ID) and games take their no-system-ROM path.
The core uses the same dummy when no BIOS is loaded (rtl/vsmile.sv
dummy_bios); ABC Land Aventure, which crashes with 0xFFFF there, then runs.

The table entries matter: with an all-zero ROM (every slot pointing to RAM
address 0) ABC Land Aventure crashes at frame 81 and Cars - Rev It Up at
frame 2807 in MAME, while the veesem dummy runs both (and four others) for
the full 60 s.

## Which games need the real system ROM

MAME census, 224 carts x 120 s with the button script, dummy vs real ROM
(census/nobios vs census/stamped): 217 run the whole time with the dummy.
Only Little Einsteins (SP) and (English) stop early with the dummy alone
(frame 1886, where the German/French Einsteins carts also stop even with
the real ROM); the other 5 early stops are bad/partial dumps, Baby carts
and dumps that also fail with the real ROM.  With the dummy, games lose the
VTech intro and the system ROM's sound effects.

## The intro library in the carts

Every cart links VTech's system library; the intro is a small script
interpreter in it that plays data from the system ROM.  Addresses below are
for Alphabet Park Adventure (USA) (Rev 1); tools/unsp_dasm builds MAME's uNSP
disassembler standalone (unsp_dasm ROM START COUNT) and find_calls.py finds
call sites.

Start-up (0x062030-0x062085, system init 0x06E926):
- ID check (0x06ED3E): slot 13 compared over 20 words with the cart's own
  "TV 1.0"; RAM [0x1A] = 0 on a match, 0xFFFF otherwise.  It picks which of
  two table layouts later lookups use (slot 8 based when 0, slot 14 based
  otherwise), so v102 ("TVSYS  ... 3.0") runs the slot 14 path.
- Pointer check (0x06EE65): the high words of slots 0, 1 and 3-13 must be
  0x30-0x3F (inside the system ROM window); otherwise RAM [0x0F] = 0xFFFF and
  the cart skips everything that uses the system ROM (the dummy's path).
- Slots 0/1 copied to RAM [8..11]; slot 2's value goes to the PPU tile and
  sprite segment registers 0x2820-0x2822 (0x2000: graphics addressed from
  word 0x80000, so tile numbers reach into the system ROM at 0x300000).
- The VTech Intro switch is port C bit 4 (0x07C997).

Slot 24 is the intro script table: {0, 0, N, N script pointers (intro on),
N (intro off), ...}.  RAM [0x26] rotates through the N variants (it survives
a reset).  Each script pointer leads to 16 per-language pointers, indexed by
the region nibble (port C bits 3:0, 0x07CA92).  v102 has N = 3 but all three
variants are the same script; the intro-off scripts are two ops that jump
(op 9) into the intro-on script past the VTech logo.

Script = (op, arg) word pairs, interpreted at 0x062633:
| op | meaning (as far as traced) |
|---|---|
| 1 | load a list of resources (ptr to list ending 0xFFFF) |
| 2 | two-word call (0x06EB6C) |
| 3, 4 | sequence helpers (0x062C07 / 0x062C7E) |
| 5 | image from the slot 0 table onto layer 2 (arg & 0x7FFF = index); 0xFFFF clears |
| 6 | image from the slot 0 table onto layer 1 (0x06E84F); 0xFFFF clears |
| 7 | 0x06287C (list of word pairs) |
| 8 | wait N frames; a button press may end it |
| 9 | jump (arg: 32-bit pointer to the next script word) |
| 0xA | sound/music (0x06C5A6; arg & 0x7FFF) |
| 0xB | wait until N frames have passed (frame counter 0x225C) |
| 0xC, 0xD, 0xE | state (0xE 0x7FFF at the start of each script) |
| 0xFFFF | end |

So the intro's content and length are entirely data: an open BIOS decides
both.

## System ROM data formats (v102, as reference only)

- Slot 0: 252 image entries of 10 words: {ptr to a 9-word header, ptr to a
  tile/character number, 4 x 0xFFFF, ptr to the pixel data}.  The header
  seen: {0x00F2, 64, 64, 0, 0x0F, 1, 1, 0, 0x600}: 64x64 at 6 bpp = 0x600
  words; the character number = (pixel address - 0x80000) / 0x600.
- Slot 1: {ptr, then 8 pointers to 256-colour RGB555 palettes 0x100 apart}.
- Sound: ADPCM samples at 0x84000-0x95xxx, played straight from the ROM by
  the SPU (channel mode 0x9038: ADPCM, address bits 21:16 = 0x38).
- Picture data streamed by the PPU: 0xA0000-0xE4FFF (image frames in 0x600
  and 0x200-word blocks), 0xF08C0-0xF13FF.

## For an open BIOS with our own intro

Same table shape and the TVSYS ID (an interface marker the carts test, not
content), valid pointers, and our own images, palettes, samples, jingles
and scripts in these formats; the scripts set how long the intro is.
