// SPU replay against MAME: rtl/spg2xx/spg2xx_spu.sv alone, driven by the
// register writes MAME's SPU received and compared sample for sample with
// MAME's output (both from a MAME built with the SPU_DUMP hook in
// src/devices/machine/spg2xx_audio.cpp; see scripts/spu_replay.sh).
//
//   ./obj_dir/Vspg2xx_spu <cart.bin> <dump prefix> [max samples] [rtl out.s]
//
// <prefix>.w: "samples_so_far address data" per write (hex address/data):
//   MAME applies a write to its registers at once but generates samples
//   lazily, so a write logged at k first affects sample k.  Here the write is
//   performed once the RTL has output k samples, before it starts sample k.
// <prefix>.s: int16 L/R per sample at 70312.5 Hz.
//
// Sample memory, as the console's bus maps it after boot (chip-select mode
// with the system ROM at 0x300000, which MAME uses with -bios): 0x300000-
// 0x3FFFFF from BIOS=<file> if given, the rest of >= 0x4000 from the cart;
// reads below 0x4000 (RAM) are counted and answered 0: the dump has no RAM.
#include "Vspg2xx_spu.h"
#include "Vspg2xx_spu___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <string>
#include <algorithm>

struct Write { uint64_t k; uint32_t addr; uint16_t data; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s <cart.bin> <dump prefix> [max samples]\n", argv[0]); return 1; }
    const uint64_t max_samples = argc > 3 ? strtoull(argv[3], nullptr, 0) : ~0ull;

    std::vector<uint16_t> cart;
    {
        FILE* f = fopen(argv[1], "rb");
        if (!f) { perror(argv[1]); return 1; }
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        cart.resize(sz / 2);
        if (fread(cart.data(), 2, cart.size(), f) != cart.size()) { perror("read"); return 1; }
        fclose(f);
    }
    uint32_t cart_mask = 1;
    while (cart_mask < cart.size()) cart_mask <<= 1;
    cart.resize(cart_mask, 0xffff);
    cart_mask -= 1;

    std::vector<uint16_t> bios;
    if (getenv("BIOS")) {
        FILE* f = fopen(getenv("BIOS"), "rb");
        if (!f) { perror("BIOS"); return 1; }
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        bios.resize(sz / 2);
        if (fread(bios.data(), 2, bios.size(), f) != bios.size()) { perror("read"); return 1; }
        fclose(f);
    }
    std::vector<Write> writes;
    {
        std::string p = std::string(argv[2]) + ".w";
        FILE* f = fopen(p.c_str(), "r");
        if (!f) { perror(p.c_str()); return 1; }
        unsigned long long k; unsigned a, d;
        while (fscanf(f, "%llu %x %x", &k, &a, &d) == 3) writes.push_back({k, a, (uint16_t)d});
        fclose(f);
    }
    FILE* ref = fopen((std::string(argv[2]) + ".s").c_str(), "rb");
    FILE* rtl_out = argc > 4 ? fopen(argv[4], "wb") : nullptr;
    // optional <prefix>.c (MAME SPU_DUMP_CH): per sample status mask + 16 WAVE_DATA
    FILE* chf = fopen((std::string(argv[2]) + ".c").c_str(), "rb");
    int ch_reports = 0;
    if (!ref) { perror("ref samples"); return 1; }

    Vspg2xx_spu* top = new Vspg2xx_spu;
    uint64_t clk_n = 0;
    auto tick = [&]() {
        top->ce = (clk_n & 3) == 3;
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        clk_n++;
    };

    top->reset = 1; top->req = 0; top->we = 0; top->mem_ack = 0;
    for (int i = 0; i < 16; i++) tick();
    top->reset = 0;

    size_t wi = 0;
    uint64_t samples = 0, bad = 0, first_bad = ~0ull, ram_reads = 0, late = 0;
    uint64_t big = 0, first_big = ~0ull;   // off by more than 1 (1: MAME's float interpolation)
    int mem_wait = -1;
    enum { W_IDLE, W_REQ, W_ACK } wst = W_IDLE;
    int16_t first_rtl[2] = {0, 0}, first_ref[2] = {0, 0};
    uint64_t max_diff = 0;

    while (samples < max_samples) {
        // register writes due before sample `samples`
        top->req = 0;
        if (wst == W_IDLE && wi < writes.size() && writes[wi].k <= samples && top->idle) {
            if (writes[wi].k < samples) late++;
            top->req = 1; top->we = 1;
            top->addr = (writes[wi].addr - 0x3000) & 0x7ff;
            top->wdata = writes[wi].data;
            wst = W_ACK;
        }
        // sample memory: answer 2 clks after the request
        top->mem_ack = 0;
        if (top->mem_req && mem_wait < 0) mem_wait = 2;
        if (mem_wait == 0) {
            uint32_t a = top->mem_addr;
            uint16_t v = 0;
            if (a >= 0x300000 && !bios.empty()) v = bios[(a - 0x300000) % bios.size()];
            else if (a >= 0x4000) v = cart[a & cart_mask];
            else ram_reads++;
            top->mem_rdata = v;
            top->mem_ack = 1;
            mem_wait = -1;
        } else if (mem_wait > 0) mem_wait--;

        tick();

        if (wst == W_ACK && top->ack) { wst = W_IDLE; wi++; }
        if (top->out_strobe) {
            int16_t lr[2];
            if (fread(lr, sizeof lr, 1, ref) != 1) break;       // end of MAME's stream
            int16_t l = (int16_t)top->out_l, r = (int16_t)top->out_r;
            if (chf) {
                uint16_t c[17];
                if (fread(c, sizeof c, 1, chf) == 1 && ch_reports < 12) {
                    auto* rp = top->rootp;
                    uint16_t st = rp->spg2xx_spu__DOT__x[15];
                    if (st != c[0]) {
                        printf("sample %llu: channel status RTL %04X MAME %04X\n", (unsigned long long)samples, st, c[0]);
                        ch_reports++;
                    }
                    for (int ch = 0; ch < 16 && ch_reports < 12; ch++) {
                        uint16_t wd = rp->spg2xx_spu__DOT__creg[ch * 16 + 11];
                        if ((c[0] >> ch & 1) && wd != c[1 + ch]) {
                            printf("sample %llu: channel %d wave data RTL %04X MAME %04X\n", (unsigned long long)samples, ch, wd, c[1 + ch]);
                            ch_reports++;
                        }
                    }
                }
            }
            if (rtl_out) { int16_t o[2] = {l, r}; fwrite(o, sizeof o, 1, rtl_out); }
            if (l != lr[0] || r != lr[1]) {
                if (!bad) { first_bad = samples; first_rtl[0] = l; first_rtl[1] = r; first_ref[0] = lr[0]; first_ref[1] = lr[1]; }
                bad++;
                uint64_t d = (uint64_t)std::max(std::abs(l - lr[0]), std::abs(r - lr[1]));
                if (d > max_diff) max_diff = d;
                if (d > 1) { if (!big) first_big = samples; big++; }
            }
            samples++;
            if ((samples % 703125) == 0)
                fprintf(stderr, "%.0f s: %llu differing samples\n", samples / 70312.5, (unsigned long long)bad);
        }
    }

    printf("spu replay: %llu samples (%.2f s), %llu differ", (unsigned long long)samples, samples / 70312.5,
           (unsigned long long)bad);
    if (bad)
        printf(" (first at %llu = %.3f s: RTL %d,%d MAME %d,%d; max diff %llu)", (unsigned long long)first_bad,
               first_bad / 70312.5, first_rtl[0], first_rtl[1], first_ref[0], first_ref[1], (unsigned long long)max_diff);
    printf("; %llu off by more than 1", (unsigned long long)big);
    if (big) printf(" (first at %llu = %.3f s)", (unsigned long long)first_big, first_big / 70312.5);
    printf("; %zu/%zu writes replayed, %llu late, %llu RAM sample reads\n", wi, writes.size(),
           (unsigned long long)late, (unsigned long long)ram_reads);
    delete top;
    return big ? 2 : 0;
}
