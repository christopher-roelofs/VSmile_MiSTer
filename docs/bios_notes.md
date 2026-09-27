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

## For an open BIOS with our own intro

Needed per slot: the structure the carts' intro/sound code expects (the
directories in 3/4/7, the graphics lists in 0/1, the music data in 8-11),
and an ID string in slot 13 that makes carts use them.  Next step: trace a
cart's intro path with the real ROM and map which fields it reads from each
slot, then build original assets in those structures.
