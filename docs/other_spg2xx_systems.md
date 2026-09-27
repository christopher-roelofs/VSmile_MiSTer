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
