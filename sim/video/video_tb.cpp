// Checks vsmile_video's timing: drives hcnt/vpos like spg2xx_vctl does and
// counts pixels, sync widths and lines for NTSC and PAL.
#include "Vvsmile_video.h"
#include "verilated.h"
#include <cstdio>

static int run(bool pal) {
    Vvsmile_video* v = new Vvsmile_video;
    const int line_len = pal ? 1728 : 1716, lines = pal ? 312 : 262;
    v->pal = pal; v->reset = 1; v->ce = 0; v->rgb_in = 0x123456;
    for (int i = 0; i < 8; i++) { v->clk = 0; v->eval(); v->clk = 1; v->eval(); }
    v->reset = 0;
    int hcnt = 0, vpos = 240, fails = 0;
    int px_line = 0, act_line = 0, hs_line = 0, vs_lines = 0, act_lines = 0, frames = 0;
    int prev_hs = 0, prev_vs = 0;
    long clk = 0;
    int max_x = -1, min_x = 9999;
    for (long t = 0; t < (long)line_len * lines * 4 * 3; t++) {
        bool ce = (clk & 3) == 3;
        v->ce = ce;
        v->clk = 0; v->eval(); v->clk = 1; v->eval();
        clk++;
        if (v->ce_pix) {
            px_line++;
            if (!v->hblank && !v->vblank) { act_line++; if (v->out_x > max_x) max_x = v->out_x; if (v->out_x < min_x) min_x = v->out_x; }
            if (v->hs) hs_line++;
            if (!v->hblank && !v->vblank && ((v->r != 0x12) || (v->g != 0x34) || (v->b != 0x56))) fails++;
            if ((v->hblank || v->vblank) && (v->r | v->g | v->b)) fails++;
        }
        if (ce) {
            if (hcnt == line_len - 1) {
                hcnt = 0;
                if (frames >= 1) {
                    int exp_px = pal ? 432 : 429;
                    if (px_line != exp_px) { printf("line %d: %d pixel periods (expected %d)\n", vpos, px_line, exp_px); fails++; }
                    if (act_line != 0 && act_line != 320) { printf("line %d: %d active pixels\n", vpos, act_line); fails++; }
                    if (hs_line != 32) { printf("line %d: hsync %d px\n", vpos, hs_line); fails++; }
                    if (act_line) act_lines++;
                    if (v->vs) vs_lines++;
                }
                px_line = act_line = hs_line = 0;
                vpos = (vpos == lines - 1) ? 0 : vpos + 1;
                if (vpos == 0) {
                    if (frames >= 1) {
                        int exp_act = pal ? 288 : 240;
                        if (act_lines != exp_act) { printf("frame: %d active lines (expected %d)\n", act_lines, exp_act); fails++; }
                        if (vs_lines != 3) { printf("frame: vsync %d lines\n", vs_lines); fails++; }
                    }
                    frames++; act_lines = vs_lines = 0;
                }
            } else hcnt++;
            v->hcnt = hcnt; v->vpos = vpos;
        }
    }
    // out_x leads the displayed pixel by one period, so it spans 1..320
    if (min_x != 1 || max_x != 320) { printf("out_x range %d..%d (expected 1..320)\n", min_x, max_x); fails++; }
    printf("%s: %d frames, %d failures\n", pal ? "PAL " : "NTSC", frames, fails);
    delete v;
    return fails;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    return run(false) + run(true) ? 1 : 0;
}
