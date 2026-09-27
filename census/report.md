# V.Smile feature census: 224 carts

## 1. Carts using features the core does not implement

- Care Bears - A Lesson in Caring 92180(US) [TWO CHIP] HIGH.bin: IO I2C, IO SPI, IO serial ROM (SIO), SATURATION 00
- Nalle Puhs Aeventyr i Sjumilaskogen (Sweden).bin: IO I2C, IO SPI
- Toy Story 3 (Italy) [b].bin: IO I2C, IO SPI, IO serial ROM (SIO), SATURATION 01

## 2. Implemented but never exercised by a MAME-verified cart

| feature | carts | examples |
|---|---|---|
| page 2bpp | 131 | Barney - Erlebnis-Reise (Germany).bin; Barney - The Land of Make Believe 92380(US).bin; Batman - Gotham City Rescue (CN).bin |
| blendlevel=1 | 53 | A Procura de Nemo - Nemo A Descoberta do Oceano (Port).bin; Adventures of Little Red Riding Hood (FR).bin; Adventures of Little Red Riding Hood 92020(US).bin |
| page 8bpp | 48 | ABC Land Aventure (France).bin; Abenteuer im ABC Park (Germany).bin; Adventures of Little Red Riding Hood (FR).bin |
| page rowscroll | 43 | A Procura de Nemo - Nemo A Descoberta do Oceano (Port).bin; ABC Land Aventure (France).bin; Abenteuer im ABC Park (Germany).bin |
| sprite 8bpp | 38 | Batman, The - Gotham City Rescue (SP).bin; Biler - Raes i Kolerkildekobing (Denmark).bin; Bob der Baumeister - Bobs Spannender Arbeitstag (Germany).bin |
| blendlevel=3 | 28 | Barrio Sesamo - El Mundo Fantastico de Epi y Blas (SP).bin; Bilar - Koer ikapp i Kylarkoeping (Sweden).bin; Biler - Raes i Kolerkildekobing (Denmark).bin |
| page blend | 13 | Shrek - Die Geschichte des Drachen (Germany).bin; Shrek - El Cuento de la Dragona (SP).bin; Shrek - Het verhaal van draakje (Netherlands).bin |
| page tile 64x64 | 13 | Aladdin (FR).bin; Aladdin - Aladdins Welt der Wunder (Germany).bin; Aladdin - De wonderwereld van Aladdin (NL).bin |
| page tile 64x32 | 4 | Toy Story 2 - Operation - Rescue Woody! (Europe) (En-GB).bin; Toy Story 2 - Operation-Raedda Woody! (Sweden).bin; Toy Story 2 - Operazione - Salvataggio di Woody (Italy).bin |
| page tile 64x16 | 3 | Micky - Mickys Magisches Abenteuer (Germany).bin; Musse Pigg - Musses Magiska Aeventyr (Sweden).bin; Topolino - Le Magiche Avventure di Topolino (Italy).bin |
| page tile 8x8 | 2 | Apprenti' Pilote (France).bin; Freds Zahlen Rallye (Germany).bin |
| fade used | 2 | Apprenti' Pilote (France).bin; Freds Zahlen Rallye (Germany).bin |
| audio adpcm36=1 | 2 | Kleine Einsteins (Germany).bin; Les Petits Einsteins (FR).bin |
| page tile 32x64 | 2 | Dora the Explorer - Dora's Fix-It Adventure (USA).bin; Dora_s Reparatie Avontuur (NL) (2005).bin |
| audio mode adpcm=0 pcm16=1 tone=2 | 2 | Adventures of Little Red Riding Hood (FR).bin; Entdecke die Welt von Rotkaeppchen (Germany).bin |
| audio mode adpcm=1 pcm16=1 tone=3 | 1 | Les Petits Einsteins (FR).bin |
| audio mode adpcm=1 pcm16=0 tone=2 | 1 | Kleine Einsteins (Germany).bin |
| audio mode adpcm=0 pcm16=1 tone=0 | 1 | Adventures of Little Red Riding Hood (FR).bin |
| audio mode adpcm=0 pcm16=1 tone=1 | 1 | Care Bears - A Lesson in Caring 92180(US) [TWO CHIP] LOW.bin |
| page tile 32x32 | 1 | Buscando a Nemo - Los Descubrimientos de Nemo (SP).bin |

## 3. All features by number of carts

| feature | carts | verified |
|---|---|---|
| blendlevel=0 | 224 | yes |
| audio adpcm36=0 | 221 | yes |
| audio mode adpcm=0 pcm16=0 tone=2 | 218 | yes |
| audio mode adpcm=1 pcm16=0 tone=1 | 218 | yes |
| page 6bpp | 218 | yes |
| page regattr | 218 | yes |
| page tile 16x16 | 218 | yes |
| page tilemap in RAM | 218 | yes |
| page wallpaper | 218 | yes |
| sprite 4bpp | 218 | yes |
| sprite 6bpp | 218 | yes |
| sprite ctrl42=0001 | 218 | yes |
| sprite size 16x16 | 218 | yes |
| sprite size 64x32 | 218 | yes |
| sprite size 64x64 | 218 | yes |
| sprite size 32x32 | 216 | yes |
| sprite size 32x16 | 214 | yes |
| sprite 2bpp | 213 | yes |
| page 4bpp | 212 | yes |
| sprite flipx | 208 | yes |
| sprite size 64x16 | 208 | yes |
| audio mode adpcm=0 pcm16=0 tone=1 | 205 | yes |
| sprite size 32x64 | 204 | yes |
| sprite size 16x32 | 199 | yes |
| sprite size 16x64 | 181 | yes |
| sprite size 64x8 | 146 | yes |
| sprite size 16x8 | 137 | yes |
| page 2bpp | 131 | no |
| sprite size 8x8 | 130 | yes |
| audio mode adpcm=1 pcm16=1 tone=2 | 127 | yes |
| sprite size 32x8 | 126 | yes |
| sprite flipy | 121 | yes |
| sprite size 8x32 | 117 | yes |
| sprite size 8x16 | 116 | yes |
| sprite size 8x64 | 116 | yes |
| page exattr | 96 | yes |
| blendlevel=2 | 76 | yes |
| sprite blend | 68 | yes |
| blendlevel=1 | 53 | no |
| audio mode adpcm=0 pcm16=0 tone=0 | 48 | yes |
| page 8bpp | 48 | no |
| page rowscroll | 43 | no |
| sprite 8bpp | 38 | no |
| blendlevel=3 | 28 | no |
| page blend | 13 | no |
| page tile 64x64 | 13 | no |
| page tile 64x32 | 4 | no |
| IO I2C | 3 | unsupported |
| IO SPI | 3 | unsupported |
| page tile 64x16 | 3 | no |
| IO serial ROM (SIO) | 2 | unsupported |
| audio adpcm36=1 | 2 | no |
| audio mode adpcm=0 pcm16=1 tone=2 | 2 | no |
| fade used | 2 | no |
| page tile 32x64 | 2 | no |
| page tile 8x8 | 2 | no |
| SATURATION 00 | 1 | unsupported |
| SATURATION 01 | 1 | unsupported |
| audio mode adpcm=0 pcm16=1 tone=0 | 1 | no |
| audio mode adpcm=0 pcm16=1 tone=1 | 1 | no |
| audio mode adpcm=1 pcm16=0 tone=2 | 1 | no |
| audio mode adpcm=1 pcm16=1 tone=3 | 1 | no |
| page tile 32x32 | 1 | no |
