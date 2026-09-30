// unsp_dasm FILE START COUNT [BASE]: disassemble COUNT instructions from word
// address START (hex) of a little-endian 16-bit ROM image loaded at word
// address BASE (hex, default 0).
#include "emu.h"
#include "unspdasm.h"
#include <sstream>
#include <cstdlib>
int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: unsp_dasm FILE START COUNT [BASE]\n"); return 1; }
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
    std::vector<u16> w; unsigned char b[2];
    while (fread(b, 1, 2, f) == 2) w.push_back(b[0] | b[1] << 8);
    offs_t pc = strtoul(argv[2], 0, 16), base = argc > 4 ? strtoul(argv[4], 0, 16) : 0;
    long n = strtol(argv[3], 0, 0);
    unsp_20_disassembler d;
    util::disasm_interface::data_buffer buf{&w, base};
    for (long i = 0; i < n; i++) {
        std::ostringstream s;
        offs_t len = d.disassemble(s, pc, buf, buf) & 0xffff;
        if (!len) len = 1;
        char imm[8] = "    ";
        if (len > 1) snprintf(imm, sizeof imm, "%04X", buf.r16(pc + 1));
        printf("%06X  %04X %s  %s\n", pc, buf.r16(pc), imm, s.str().c_str());
        pc += len;
    }
}
