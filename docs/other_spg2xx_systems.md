# Other VTech systems on the V.Smile's SPG2xx chip

Candidates for this core later: same SunPlus SPG2xx SoC (µ'nSP 1.0 CPU,
PPU, SPU) as the V.Smile, with a built-in ROM instead of cartridges.  All
are `MACHINE_NOT_WORKING` in MAME (src/mame/tvgames/spg2xx.cpp), so MAME is
a weaker reference for them than for the V.Smile.

Dumps must come from hardware you own.  The file names and checksums below
are MAME's, for checking a dump; MAME loads them `ROM_LOAD16_WORD_SWAP`
(big-endian words).

| MAME set | System | ROM file | Size | CRC32 | SHA1 |
|---|---|---|---|---|---|
| genitvp | Genius TV Progress (France) | vtechtvstation_fr.bin | 8 MB | 71c2c5f4 | cc81f67ec1888b40a735383dae09408f9c877314 |
| vtechtvssp | TV Station (Spain) | vtechtvstation_sp.bin | 8 MB | 4a2e91eb | 1ff9cc0360b670cc0ad7efa9de0edd2c68d4d8e3 |
| vtechtvsgr | TV Learning Station (Germany) | vtechtvstation_gr.bin | 8 MB | 879f1b12 | c14d52bead2c190130ce88cbdd4f5e93145f13f9 |
| doraphon | Dora TV Explorer Phone (US) | doraphone.bin | 8 MB | a79c154b | f5b9bf63ea52d058252ab6702508b519fbdee0cc |
| doraphonf | Dora TV Explorer Phone (France) | doraphone_fr.u4 | 8 MB | 216632a1 | b2bd81656a261e09814792f52428eead2ea7ce1f |
| doraglob | Dora TV Adventure Globe (US) | doraglobe.bin | 8 MB | 6f454c50 | 201e2de3d90abe017a8dc141613cbf6383423d13 |
| doraglobuk | Dora TV Adventure Globe (UK) | doraglobeuk.u4 | 8 MB | b20a22b8 | f7e42a86479e68092b27068535cff90ca686f361 |
| doraglobf | Dora TV Globe-Trotter (France) | doraglobefrance.bin | 8 MB | 7124edc1 | b144fc1f13a28299ef14f1d01f7acd2677e4ebb9 |
| doraglobg | Doras Abenteuer-Globus (Germany) | doraglobegerman.bin | 8 MB | 538aa197 | e97e0641df04074a0e45d02cecb43fbec91a4ce6 |
| dvlaptop | Double Vision Laptop (Germany) | u3-main.u3-1 + u8-slave.u8-1 | 2 x 8 MB | 0457c902, d0627571 | a0f49627e1e099262b92c2655d42090f32fb1d21, 029cb3b5d8b9e565c822c0705782770715b4fb53 |

Notes (from https://vtech.pulkomandy.tk):

- The Genius TV Progress / TV Station ("Nitro Vision") is a V.Smile-family
  computer with an infrared keyboard and mouse; it also runs V.Smile carts
  (they don't fit its slot).  Its own "cartridges" hold no ROM: they short
  SENSE / RAM_CSB / ROM_CSB2 to VDD to select a program in the console ROM.
- These toys keep their ROM on-board (a TSOP flash or a blob), so a dump
  needs a chip programmer or in-circuit reading; the V.Smile cart dumpers
  (V.Kart, Disco-Cart) only read cartridges.

Newer GeneralPlus systems (MobiGo, MobiGo 2, V.Baby, Tivi Boo: GPL162xx,
µ'nSP 2.0, NAND) share the CPU family but are a different, larger SoC.

## Dora TV toys: moved to a future plug-and-play core

The Dora TV Adventure Globe and Explorer Phone ran in this core for a while
(September 2026) and were taken out again: this core is for the V.Smile
family only; the SPG2xx plug-and-play systems (these toys and MAME's other
~235 `tvgames/spg2xx*.cpp` sets) are meant for a core of their own.  The
work is on the local branch `dora-toys` (commits 3631c29, 3c18ade).  What it
found, for that core:

* the toys are SPG24x boards like MAME's `spg2xx_game_doraphone_state`: the
  8 MB ROM linear (chip-select mode 0), no system ROM, no controllers;
* port A = MAME P1 bits 15-4 with a 4-bit key matrix in bits 0-3 (active
  low), rows selected by port B bits 1-6 going low; port B in 0x0080
  (battery OK), port C 0xFFFF;
* Globe P1: 0xFEE0 (On/Off slider "Play on TV" 0x0060; 0x0200 must be set or
  it resets; 0x0100 clear = US NTSC).  With the V.Smile's port A (0) it runs
  but never turns its display on.  Phone P1: 0xFE60 with the handset (bit 7,
  active high) and a joystick (bits 12-15, active low), keys in 6 rows;
* the ROM files load as MAME has them, no byte swap; the Globes (US, UK,
  French, German) carry resource names "DG_ML0nn" (16-bit characters), the
  Phones (US, French) no text, but a 16-byte run of code
  (c3d24092c8d27296c8d64292c8d2c294) found in both and in no other ROM;
* Globe: 3 s MAME trace in lockstep; the sim reaches the title menu like
  MAME (`MAME_SYSTEM=doraglob MAME_ROM=other scripts/mame_trace.sh`).
