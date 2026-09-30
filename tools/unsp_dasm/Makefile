# Standalone build of MAME's uNSP disassembler (ref/mame/unsp, GPL-2.0+),
# with emu.h standing in for the MAME types it uses.
#   unsp_dasm ROM START COUNT [BASE]   (hex word addresses)
unsp_dasm: main.cpp emu.h $(wildcard ../../ref/mame/unsp/unspdasm*.cpp)
	g++ -O1 -std=c++17 -I. -I../../ref/mame/unsp -o $@ main.cpp ../../ref/mame/unsp/unspdasm*.cpp
