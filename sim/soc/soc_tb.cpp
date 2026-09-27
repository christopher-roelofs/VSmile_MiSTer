// V.Smile system testbench (rtl/vsmile.sv) against a MAME golden trace.
//
//   ./obj_dir/Vvsmile <cart.bin> <tracedir> [max_insns]
//
// Lockstep mode (default): the CPU receives MAME's values for SoC register
// reads and MAME's interrupt timing, so the trace stays comparable, while
// the RTL computes its own register values; every disagreement is tallied
// per register and reported at the end.  RAM, DMA, banking and all register
// writes are the RTL's own and must match MAME exactly.
//
// FREERUN=1: no overrides, the RTL drives register reads and interrupts
// itself.  The trace is compared until the first divergence (reported, not
// fatal), then the run continues and statistics are printed.
//
// Environment:
//   FREERUN=1   free-running mode
//   BIOS=path   system ROM (otherwise reads as 0xFFFF, like the traces)
//   VERBOSE=1   print every retired instruction
//   WAV=path    write the SPU output (stereo 16-bit, 70312 Hz) as a WAV file
//   SWEEP_INPUT=1 replay scripts/census.lua's button script (free-run only)
//   SWEEP_FRAMES=n stop after n frames
//   CENSUS_OUT=path write the video features the RTL uses (census.lua's
//               format, with the first frame each appeared)
//   DUMP_BAD=dir write rtl/ref images of the first 8 frames with differing lines
//   PRESS=f:m,... hold buttons mask m (1 ok, 2 quit, 4 help, 8 abc) for
//               eight frames from frame f (free-run only)
//   DUMP=dir    write every FRAMES-th frame (default 60) as dir/rtl_NNNN.ppm
//               and, when it differs, dir/ref_NNNN.ppm from the reference
//
// Video: every scanline the RTL renders is compared pixel for pixel with a
// C++ port of MAME's renderer (ppu_ref.h) drawing from the same memory at
// the same moment; mismatching lines are counted per frame.
// HW_TOP: build against sim/hw/vsmile_hw.sv, the console with the real
// SDRAM controller and a chip model; the cart is downloaded into it through
// the same write port the HPS uses.
#ifdef HW_TOP
#include "Vvsmile_hw.h"
#include "Vvsmile_hw___024root.h"
typedef Vvsmile_hw TopT;
#define H(x) vsmile_hw__DOT__console__DOT__##x
#else
#include "Vvsmile.h"
#include "Vvsmile___024root.h"
typedef Vvsmile TopT;
#define H(x) vsmile__DOT__##x
#endif
#include "verilated.h"
#include "ppu_ref.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <map>
#include <string>
#include <vector>
#include <deque>
#include <set>
#include <string>

struct TraceEntry {
    uint32_t pc;
    uint16_t r[7];      // r1 r2 r3 r4 sp bp sr
    int      irq_after;
    std::string text;
};

class TraceReader {
public:
    explicit TraceReader(const std::string& path) {
        f_ = fopen(path.c_str(), "r");
        if (!f_) { perror(path.c_str()); exit(1); }
    }
    bool next(TraceEntry& e) {
        if (!have_pending_ && !read_insn(pending_)) return false;
        e = pending_;
        have_pending_ = false;
        e.irq_after = -1;
        char line[512];
        while (fgets(line, sizeof line, f_)) {
            int irq;
            if (strstr(line, "(interrupted at") && sscanf(strstr(line, "IRQ"), "IRQ %d", &irq) == 1) {
                e.irq_after = irq;
                continue;
            }
            if (parse(line, pending_)) { have_pending_ = true; break; }
        }
        return true;
    }
private:
    bool read_insn(TraceEntry& e) {
        char line[512];
        while (fgets(line, sizeof line, f_))
            if (parse(line, e)) return true;
        return false;
    }
    static bool parse(const char* line, TraceEntry& e) {
        unsigned v[8];
        if (sscanf(line, "%x %x %x %x %x %x %x %x:", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) != 8)
            return false;
        for (int i = 0; i < 7; i++) e.r[i] = v[i];
        e.pc = v[7];
        const char* c = strchr(line, ':');
        e.text = c ? std::string(c + 2) : std::string();
        while (!e.text.empty() && (e.text.back() == '\n' || e.text.back() == '\r')) e.text.pop_back();
        return true;
    }
    FILE* f_;
    TraceEntry pending_{};
    bool have_pending_ = false;
};

struct MemEvent { char kind; uint32_t addr; uint16_t data; };

class MemLog {
public:
    explicit MemLog(const std::string& path) {
        f_ = fopen(path.c_str(), "r");
        if (!f_) { perror(path.c_str()); exit(1); }
    }
    bool peek(MemEvent& e) {
        if (q_.empty()) {
            char line[64], k; unsigned a, d;
            if (!fgets(line, sizeof line, f_) || !strchr(line, '\n')) return false;
            if (sscanf(line, " %c %x %x", &k, &a, &d) != 3) return false;
            q_.push_back({k, a, (uint16_t)d});
            n_++;
        }
        e = q_.front();
        return true;
    }
    void pop() { q_.pop_front(); }
    uint64_t count() const { return n_; }
private:
    FILE* f_;
    std::deque<MemEvent> q_;
    uint64_t n_ = 0;
};

static std::vector<uint16_t> load_words(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> b(sz);
    if (fread(b.data(), 1, sz, f) != (size_t)sz) { perror("read"); exit(1); }
    fclose(f);
    std::vector<uint16_t> w(sz / 2);
    for (long i = 0; i + 1 < sz; i += 2) w[i / 2] = b[i] | (b[i + 1] << 8);
    return w;
}

// Minimal WAV writer (header patched on close)
struct Wav {
    FILE* f = nullptr;
    uint32_t n = 0;
    void open(const char* path) {
        f = fopen(path, "wb");
        if (!f) { perror(path); exit(1); }
        uint8_t h[44] = {0};
        fwrite(h, 1, 44, f);
    }
    void put(int16_t l, int16_t r) { if (f) { int16_t s[2] = {l, r}; fwrite(s, 2, 2, f); n++; } }
    void close() {
        if (!f) return;
        auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
        auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
        fseek(f, 0, SEEK_SET);
        fwrite("RIFF", 1, 4, f); w32(36 + n * 4); fwrite("WAVEfmt ", 1, 8, f);
        w32(16); w16(1); w16(2); w32(70312); w32(70312 * 4); w16(4); w16(16);
        fwrite("data", 1, 4, f); w32(n * 4);
        fclose(f);
    }
};

struct RegStat { uint64_t reads = 0, mismatches = 0; uint32_t pc = 0; uint16_t mame = 0, rtl = 0; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) {
        fprintf(stderr, "usage: %s <cart.bin> <tracedir> [max_insns]\n", argv[0]);
        return 2;
    }
    const bool freerun = getenv("FREERUN") != nullptr;
    const bool verbose = getenv("VERBOSE") != nullptr;
    std::string dir = argv[2];
    uint64_t max_insns = argc > 3 ? strtoull(argv[3], nullptr, 0) : ~0ull;

    std::vector<uint16_t> cart = load_words(argv[1]);
    uint32_t cart_words = 1;
    while (cart_words < cart.size()) cart_words <<= 1;
    cart.resize(cart_words, 0xffff);
    std::vector<uint16_t> bios;
    // the system ROM is loaded like the cart (low byte first)
    if (getenv("BIOS")) {
        bios = load_words(getenv("BIOS"));
    }

    TraceReader trace(dir + "/cpu.tr");
    MemLog mem(dir + "/mem.log");

    Wav wav;
    if (getenv("WAV")) wav.open(getenv("WAV"));
    const char* dump = getenv("DUMP");
    const int dump_every = getenv("FRAMES") ? atoi(getenv("FRAMES")) : 60;

    TopT* top = new TopT;
    top->pal = 0;
    top->mame_timing = 1;
    top->region = 0x1f;                 // English (US), VTech intro on
    top->has_bios = bios.empty() ? 0 : 1;
    // MOTION=1: V.Smile Motion (its system ROM in BIOS=, port A reads 0xC000)
    top->motion = getenv("MOTION") ? 1 : 0;
    // DUMMY_BIOS=1: without BIOS=, the system ROM area reads as veesem's dummy
    // (as on the MiSTer) instead of 0xFFFF (as in the MAME traces)
    top->dummy_bios = getenv("DUMMY_BIOS") ? 1 : 0;
    // STICK_LEVEL=n: joystick level 3..7 on both axes (0/unset: full, as MAME)
    top->ud_level = getenv("STICK_LEVEL") ? atoi(getenv("STICK_LEVEL")) : 0;
    top->lr_level = top->ud_level;
    // KBD=1: Smart Keyboard (US) on port 1; KBD_EVENTS=file replays
    // scripts/kbd_input.lua's log ("frame row col 1|0", row 5 = buttons)
    top->kbd = getenv("KBD") ? 1 : 0;
    top->kb_layout = 0x40;
    for (int r = 0; r < 5; r++) top->kb_keys[r] = 0;
    struct KbEv { uint32_t frame; int row, col, down; };
    std::vector<KbEv> kb_events;
    size_t kb_next = 0;
    int kb_buttons = 0;
    if (getenv("KBD_EVENTS")) {
        FILE* f = fopen(getenv("KBD_EVENTS"), "r");
        KbEv e;
        while (f && fscanf(f, "%u %d %d %d", &e.frame, &e.row, &e.col, &e.down) == 4) kb_events.push_back(e);
        if (f) fclose(f);
    }
    top->cart_mask = cart_words - 1;
#ifdef HW_TOP
    // bring up the SDRAM controller, then download the cart (and BIOS)
    top->sdram_init = 1; top->wr_req = 0; top->reset = 1; top->clk_vid = 0;
    for (int i = 0; i < 40; i++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
    top->sdram_init = 0;
    for (int i = 0; i < 20000; i++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
    // as emu.sv drives it: one wr_req pulse per word, then the next word
    // only once wr_busy has dropped (HPS honours ioctl_wait) plus a few clks
    auto dl_word = [&](uint32_t waddr, uint16_t v) {
        top->wr_req = 1; top->wr_addr = waddr; top->wr_data = v;
        top->clk = 0; top->eval(); top->clk = 1; top->eval();
        top->wr_req = 0;
        do { top->clk = 0; top->eval(); top->clk = 1; top->eval(); } while (top->wr_busy);
        for (int i = 0; i < 3; i++) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
    };
    for (uint32_t i = 0; i < cart.size(); i++) dl_word(i, cart[i]);
    for (uint32_t i = 0; i < bios.size(); i++) dl_word((getenv("MOTION") ? 0x900000 : 0x800000) + i, bios[i]);
    while (top->wr_busy) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); }
    printf("downloaded %u cart words into the SDRAM model\n", (unsigned)cart.size());
#endif
    top->joy = 0;
    top->colors = 0;
    top->buttons = 0;
    std::vector<std::pair<uint32_t, int>> presses;
    if (getenv("PRESS")) {
        std::string ps = getenv("PRESS");
        size_t i = 0;
        while (i < ps.size()) {
            size_t c = ps.find(',', i); if (c == std::string::npos) c = ps.size();
            std::string t = ps.substr(i, c - i);
            size_t k = t.find(':');
            if (k != std::string::npos) presses.push_back({(uint32_t)atoi(t.substr(0, k).c_str()), atoi(t.substr(k + 1).c_str())});
            i = c + 1;
        }
    }
    top->sim_io_override = freerun ? 0 : 1;
    top->sim_irq_override = freerun ? 0 : 1;
    top->sim_irq = 0;
    top->reset = 1;
    top->ce = 0;
#ifndef HW_TOP
    top->mem_ack = 0;
#endif

    uint64_t clk_n = 0;
    int mem_lat = 0;
    std::map<uint32_t, RegStat> stats;
    uint64_t irq_taken[9] = {0}, irq_mame[9] = {0};

    // ---- video reference ----
    auto& rp = *top->rootp;
    PpuRef ref;
    // ---- sweep: census of the video features in use, input script ----
    FILE* census = getenv("CENSUS_OUT") ? fopen(getenv("CENSUS_OUT"), "w") : nullptr;
    std::set<std::string> census_seen;
    uint32_t census_frame = 0;
    auto cnote = [&](const std::string& k) {
        if (census && census_seen.insert(k).second) { fprintf(census, "%s\t@%u\n", k.c_str(), census_frame); fflush(census); }
    };
    const bool sweep_input = getenv("SWEEP_INPUT") != nullptr;
    const uint32_t sweep_frames = getenv("SWEEP_FRAMES") ? (uint32_t)atoi(getenv("SWEEP_FRAMES")) : 0;
    const char* dump_bad = getenv("DUMP_BAD");
    int dump_bad_n = 0;
    // census.lua's script: {port 0 joy / 1 colours / 2 buttons, bit}
    static const int sweep_script[16][2] = {
        {2, 0}, {0, 3}, {2, 0}, {0, 1}, {2, 0}, {1, 0}, {0, 2}, {2, 0},
        {1, 3}, {0, 0}, {2, 0}, {1, 1}, {2, 0}, {1, 2}, {2, 3}, {2, 0}};
    int sweep_held = -1;
    ref.regs = (const uint16_t*)&rp.H(soc__DOT__vctl__DOT__regs)[0];
    ref.vram = (const uint16_t*)&rp.H(soc__DOT__vram)[0];
    ref.read = [&](uint32_t a) -> uint16_t {
        if (a < 0x2800) return rp.H(soc__DOT__ram)[a];
        if (a < 0x3000) return rp.H(soc__DOT__vram)[a - 0x2800];
        if (a < 0x4000) return 0;
        bool bios_sel = (rp.H(cs_mode) & 2) && ((a >> 20) & 3) == 3;
        if (bios_sel) {
            if (!bios.empty()) return bios[(a & 0xfffff) % bios.size()];
            if (!top->dummy_bios) return 0xffff;
            uint32_t w = a & 0xfffff;
            return (w >= 0xfffc0 && w <= 0xfffdb && (w & 1)) ? 0x0031 : 0x0000;
        }
        uint32_t ca = ((rp.H(cs2) ? 0x400000u : 0u) | a) & (cart_words - 1);
        return cart[ca];
    };
    static uint16_t ref_lines[240][320];
    static uint8_t rtl_frame[240][320][3], ref_frame[240][320][3];
    uint32_t frame = 0, frame_bad_lines = 0, frame_bad_px = 0;
    uint64_t total_bad_lines = 0, total_lines = 0, overruns = 0, race_lines = 0, pal_lines = 0, mem_lines = 0;
    static uint16_t pal_at_start[240][256];
    static uint16_t vram_at_start[2048], ram_at_start[10240];
    int snap_y = -1;
    int prev_vpos = -1;
    int prev_rs = 0;
    int dbg_frame = -1, dbg_line = -1;
    if (getenv("PPU_DEBUG")) sscanf(getenv("PPU_DEBUG"), "%d:%d", &dbg_frame, &dbg_line);
    auto to888 = [](uint16_t p, uint8_t* o) {
        p = (p & 0x8000) ? 0 : p;
        uint8_t r = (p >> 10) & 31, g = (p >> 5) & 31, b = p & 31;
        o[0] = (r << 3) | (r >> 2); o[1] = (g << 3) | (g >> 2); o[2] = (b << 3) | (b >> 2);
    };
    auto write_ppm = [&](const char* kind, uint8_t (*img)[320][3]) {
        char path[512];
        snprintf(path, sizeof path, "%s/%s_%04u.ppm", dump, kind, frame);
        FILE* f = fopen(path, "wb");
        if (!f) return;
        fprintf(f, "P6\n320 240\n255\n");
        fwrite(img, 1, 240 * 320 * 3, f);
        fclose(f);
    };

    uint64_t n = 0;
    TraceEntry cur{};
    bool have_cur = false, trace_ok = true, trace_done = false;
    int pending_irq = -1;
    uint16_t prev_op = 0; uint32_t prev_pc = 0;
    uint64_t diverged_at = 0;

    auto report_state = [&](FILE* o) {
        if (have_cur)
            fprintf(o, "    MAME:  %06X  R1=%04X R2=%04X R3=%04X R4=%04X SP=%04X BP=%04X SR=%04X  %s\n",
                    cur.pc, cur.r[0], cur.r[1], cur.r[2], cur.r[3], cur.r[4], cur.r[5], cur.r[6], cur.text.c_str());
        fprintf(o, "    RTL:   %06X  R1=%04X R2=%04X R3=%04X R4=%04X SP=%04X BP=%04X SR=%04X\n",
                top->dbg_pc, top->dbg_r[1], top->dbg_r[2], top->dbg_r[3], top->dbg_r[4],
                top->dbg_r[0], top->dbg_r[5], top->dbg_r[6]);
    };
    auto diverge = [&](const char* why) {
        fprintf(stderr, "\n*** %s after %llu instructions (%llu clks, %llu mem events): %s\n",
                freerun ? "DIVERGED" : "MISMATCH",
                (unsigned long long)n, (unsigned long long)clk_n, (unsigned long long)mem.count(), why);
        fprintf(stderr, "    previous insn: %06X op %04X\n", prev_pc, prev_op);
        report_state(stderr);
        if (!freerun) exit(1);
        trace_ok = false;
        diverged_at = n;
    };

    bool done = false;
    while (n < max_insns && !done) {
        // clk = 108 MHz, ce = 27 MHz, clk_vid = 54 MHz (toggles every clk)
        const bool ce = (clk_n & 3) == 3;
        top->ce = ce;
        top->clk_vid = clk_n & 1;
        if (clk_n == 16) top->reset = 0;

        top->clk = 0;
        top->eval();

#ifndef HW_TOP
        // external memory: reads are issued as one-clk pulses and answered
        // in order.  MEMLAT: clks from issue to data (default 0: the next
        // clk); MEMGAP: minimum clks between two answers (default 1), which
        // models the SDRAM's burst spacing when reads overlap
        static const int memlat = getenv("MEMLAT") ? atoi(getenv("MEMLAT")) : 0;
        static const int memgap = getenv("MEMGAP") ? atoi(getenv("MEMGAP")) : 1;
        static std::deque<std::pair<uint32_t, uint64_t>> mq;
        static uint64_t last_ack = 0;
        top->mem_ack = 0;
        if (top->mem_req) mq.push_back({top->mem_addr, clk_n});
        if (!mq.empty() && clk_n >= mq.front().second + (uint64_t)memlat
            && clk_n >= last_ack + (uint64_t)memgap) {
            uint32_t base = mq.front().first & ~3u;
            uint64_t g = 0;
            for (int i = 3; i >= 0; i--) {
                uint32_t a = base + i;
                uint16_t v = 0xffff;
                if (a < 0x800000) v = cart[a & (cart_words - 1)];
                else if (!bios.empty()) v = bios[(a - 0x800000) % bios.size()];
                g = (g << 16) | v;
            }
            top->mem_rdata = g;
            top->mem_ack = 1;
            last_ack = clk_n;
            mq.pop_front();
        }
        top->eval();

#endif
        // SoC register traffic vs. MAME's bus log
        if (trace_ok && (top->dbg_io_rd || top->dbg_io_wr)) {
            MemEvent e;
            char want = top->dbg_io_rd ? 'R' : 'W';
            uint32_t a = top->dbg_io_addr;
            if (!mem.peek(e)) {
                printf("mem.log exhausted (end of capture)\n");
                if (!freerun) { done = true; }
                trace_ok = false;
            } else {
                if (e.kind != want || e.addr != a || (top->dbg_io_wr && e.data != top->dbg_io_wdata)) {
                    char buf[160];
                    snprintf(buf, sizeof buf, "bus %c %04X %04X, mem.log has %c %04X %04X",
                             want, a, top->dbg_io_wr ? top->dbg_io_wdata : 0, e.kind, e.addr, e.data);
                    diverge(buf);
                } else {
                    mem.pop();
                    static const char* dbg_w = getenv("DEBUG_WR");
                    if (dbg_w && top->dbg_io_wr && (a >> 8) == strtoul(dbg_w, nullptr, 16))
                        printf("  [%llu] W %04X %04X pc=%06X\n", (unsigned long long)n, a, top->dbg_io_wdata, top->dbg_pc);
                    if (top->dbg_io_rd) {
                        static const char* dbg_addr = getenv("DEBUG_IO");
                        if (dbg_addr && strtoul(dbg_addr, nullptr, 16) == a)
                            printf("  [%llu] R %04X mame=%04X rtl=%04X  vpos=%u hpos=%u pc=%06X\n",
                                   (unsigned long long)n, a, e.data, top->dbg_io_rtl_rdata, top->vpos, top->hpos, top->dbg_pc);
                        top->sim_io_rdata = e.data;
                        RegStat& s = stats[a];
                        s.reads++;
                        if (top->dbg_io_rtl_rdata != e.data) {
                            if (s.mismatches == 0) { s.pc = top->dbg_pc; s.mame = e.data; s.rtl = top->dbg_io_rtl_rdata; }
                            s.mismatches++;
                        }
                    }
                }
            }
            top->eval();
        }

        top->clk = 1;
        top->eval();
        clk_n++;

        if (top->audio_strobe) wav.put((int16_t)top->audio_l, (int16_t)top->audio_r);
#ifdef HW_TOP
        {
            // MEM_DEBUG=n: check the first n memory groups against the image
            static int mem_dbg = getenv("MEM_DEBUG") ? atoi(getenv("MEM_DEBUG")) : 0;
            static uint64_t mem_seen = 0, mem_bad = 0;
            if (top->dbg_mem_ack) {
                uint32_t base = top->dbg_mem_addr & ~3u;
                uint64_t exp = 0;
                for (int i = 3; i >= 0; i--) {
                    uint32_t a = base + i;
                    uint16_t v = (a < 0x800000) ? cart[a & (cart_words - 1)] : (bios.empty() ? 0xffff : bios[(a - 0x800000) % bios.size()]);
                    exp = (exp << 16) | v;
                }
                mem_seen++;
                if (exp != top->dbg_mem_rdata) mem_bad++;
                if (mem_dbg > 0 && (mem_seen <= (uint64_t)mem_dbg || (exp != top->dbg_mem_rdata && mem_bad <= 8)))
                    printf("  mem group %06X: got %016llX expected %016llX%s\n", base,
                           (unsigned long long)top->dbg_mem_rdata, (unsigned long long)exp, exp != top->dbg_mem_rdata ? "  <-- WRONG" : "");
                if (done || n + 1 >= max_insns) {}
            }
            static bool reported = false;
            if (!reported && (n + 1 >= max_insns)) { reported = true; printf("memory groups checked: %llu, wrong: %llu\n", (unsigned long long)mem_seen, (unsigned long long)mem_bad); }
        }
#endif
        {
            static const bool pad_dbg = getenv("PAD_DEBUG") != nullptr;
            if (pad_dbg) {
                auto& r = *top->rootp;
                if (r.H(uart_rx_valid)) printf("  [%llu] pad->console %02X\n", (unsigned long long)n, r.H(uart_rx_data));
                if (r.H(uart_tx_valid)) printf("  [%llu] console->pad %02X sel=%d\n", (unsigned long long)n, r.H(uart_tx_data), r.H(ctrl_select) & 1);
            }
        }

        // reference renders line y when the RTL starts it (previous line's start)
        if (top->vpos != prev_vpos) {
            prev_vpos = top->vpos;
            int y = (top->vpos == 261) ? 0 : top->vpos + 1;
            if (y < 240) {
                ref.dbg = ((int)frame == dbg_frame && y == dbg_line);
                memcpy(pal_at_start[y], ref.vram + 0x300, 512);
                memcpy(vram_at_start, ref.vram, sizeof vram_at_start);
                memcpy(ram_at_start, &rp.H(soc__DOT__ram)[0], sizeof ram_at_start);
                snap_y = y;
                ref.line(y);
                memcpy(ref_lines[y], ref.linebuf, sizeof ref.linebuf);
            }
        }
        if (top->ppu_overrun) overruns++;
        {
            int rs = rp.H(soc__DOT__ppu__DOT__rs);
            static const bool ppu_trace = getenv("PPU_TRACE") != nullptr;
            if (ppu_trace && rs != prev_rs && (int)frame == dbg_frame && rp.H(soc__DOT__ppu__DOT__y) == dbg_line)
                printf("  RTL rs=%d n=%d cnt=%d\n", rs, rp.H(soc__DOT__ppu__DOT__n), rp.H(soc__DOT__ppu__DOT__cnt));
            if (rs == 16 && prev_rs != 16 && (int)frame == dbg_frame && rp.H(soc__DOT__ppu__DOT__y) == dbg_line)   // R_FETCH
                printf("  RTL strip row=%06X drawx=%3d w=%2d bpr=%2d pal=%02X fx=%d bl=%d (tile %04X)\n",
                       rp.H(soc__DOT__ppu__DOT__row_addr), rp.H(soc__DOT__ppu__DOT__drawx),
                       rp.H(soc__DOT__ppu__DOT__npix), rp.H(soc__DOT__ppu__DOT__rb_n),
                       rp.H(soc__DOT__ppu__DOT__pal_off), rp.H(soc__DOT__ppu__DOT__flip_x),
                       rp.H(soc__DOT__ppu__DOT__blend), rp.H(soc__DOT__ppu__DOT__m_tile));
            prev_rs = rs;
        }
        if (top->line_done) {
            int y = top->done_y;
            int buf = rp.H(soc__DOT__ppu__DOT__cur);
            int bad = 0;
            for (int x = 0; x < 320; x++) {
                uint16_t r = rp.H(soc__DOT__ppu__DOT__lbuf)[buf * 512 + x];
                uint16_t e = ref_lines[y][x];
                to888(r, rtl_frame[y][x]);
                to888(e, ref_frame[y][x]);
                if ((r & 0x8000 ? 0 : r) != (e & 0x8000 ? 0 : e)) bad++;
            }
            total_lines++;
            if (bad) {
                // the CPU may have changed sprite/tile data while the line
                // was drawn: accept if the end-of-line state renders the same
                ref.line(y);
                int bad2 = 0;
                for (int x = 0; x < 320; x++) {
                    uint16_t r = rp.H(soc__DOT__ppu__DOT__lbuf)[buf * 512 + x];
                    uint16_t e = ref.linebuf[x];
                    if ((r & 0x8000 ? 0 : r) != (e & 0x8000 ? 0 : e)) bad2++;
                }
                if (bad2 == 0) { race_lines++; bad = 0; }
                // palette written while the line was drawn: the RTL sees a
                // mix of old and new entries, as real hardware would
                else if (memcmp(pal_at_start[y], ref.vram + 0x300, 512) != 0) { pal_lines++; bad = 0; }
                // likewise sprite/scroll RAM or RAM (tile maps) written mid-line
                else if (snap_y == y && (memcmp(vram_at_start, ref.vram, sizeof vram_at_start) != 0 ||
                                         memcmp(ram_at_start, &rp.H(soc__DOT__ram)[0], sizeof ram_at_start) != 0)) { mem_lines++; bad = 0; }
            }
            if (bad) {
                frame_bad_lines++; frame_bad_px += bad; total_bad_lines++;
                static int detail = 0;
                if (detail < 6) {
                    detail++;
                    printf("  frame %u line %d: %d px differ:", frame, y, bad);
                    int shown = 0;
                    for (int x = 0; x < 320 && shown < 6; x++) {
                        uint16_t r = rp.H(soc__DOT__ppu__DOT__lbuf)[buf * 512 + x];
                        uint16_t e = ref_lines[y][x];
                        if ((r & 0x8000 ? 0 : r) != (e & 0x8000 ? 0 : e)) { printf(" x%d rtl=%04X ref=%04X", x, r, e); shown++; }
                    }
                    printf("\n");
                }
            }
            if (y == 239) {
                if (frame_bad_lines)
                    printf("  frame %u: %u lines differ from the reference (%u pixels)\n", frame, frame_bad_lines, frame_bad_px);
                if (frame_bad_lines && dump_bad && dump_bad_n < 8) {
                    char path[512];
                    snprintf(path, sizeof path, "%s/rtl_%05u.ppm", dump_bad, frame);
                    { FILE* f = fopen(path, "wb"); fprintf(f, "P6 320 240 255\n"); fwrite(rtl_frame, 1, sizeof rtl_frame, f); fclose(f); }
                    snprintf(path, sizeof path, "%s/ref_%05u.ppm", dump_bad, frame);
                    { FILE* f = fopen(path, "wb"); fprintf(f, "P6 320 240 255\n"); fwrite(ref_frame, 1, sizeof ref_frame, f); fclose(f); }
                    dump_bad_n++;
                }
                if (dump && (frame % dump_every) == 0) {
                    write_ppm("rtl", rtl_frame);
                    if (frame_bad_lines) write_ppm("ref", ref_frame);
                }
                frame++;
                {
                    int m = 0;
                    for (auto& pr : presses) if (frame >= pr.first && frame < pr.first + 8) m |= pr.second;
                    top->buttons = m;
                }
                while (kb_next < kb_events.size() && kb_events[kb_next].frame <= frame) {
                    const KbEv& e = kb_events[kb_next++];
                    if (e.row < 5) {
                        if (e.down) top->kb_keys[e.row] |= (1u << e.col); else top->kb_keys[e.row] &= ~(1u << e.col);
                    } else {
                        if (e.down) kb_buttons |= (1 << e.col); else kb_buttons &= ~(1 << e.col);
                        top->buttons = kb_buttons;
                    }
                }
                if (sweep_input) {
                    if (sweep_held >= 0 && frame % 90 == 8) sweep_held = -1;
                    if (frame > 300 && frame % 90 == 0) sweep_held = (frame / 90) % 16;
                    int v[3] = {0, 0, 0};
                    if (sweep_held >= 0) v[sweep_script[sweep_held][0]] = 1 << sweep_script[sweep_held][1];
                    top->joy = v[0]; top->colors = v[1]; top->buttons = v[2];
                }
                if (census) {
                    census_frame = frame;
                    const uint16_t* R = ref.regs;
                    auto bpp = [](uint16_t a) { return ((a & 3) + 1) * 2; };
                    for (int p = 0; p < 2; p++) {
                        uint16_t attr = R[0x12 + 6 * p], ctrl = R[0x13 + 6 * p];
                        if (!(ctrl & 8)) continue;
                        std::string fl;
                        auto add = [&](const char* x) { if (!fl.empty()) fl += ","; fl += x; };
                        if (ctrl & 0x001) add("LINEMAP");
                        add((ctrl & 0x002) ? "regattr" : "exattr");
                        if (ctrl & 0x004) add("wallpaper");
                        if (ctrl & 0x010) add("rowscroll");
                        if (ctrl & 0x040) add("VCMP");
                        if (ctrl & 0x080) add("HICOLOR");
                        if (ctrl & 0x100) add("blend");
                        char b[128];
                        snprintf(b, sizeof b, "page bpp=%d tile=%dx%d %s", bpp(attr), 8 << ((attr >> 4) & 3), 8 << ((attr >> 6) & 3), fl.c_str());
                        cnote(b);
                    }
                    if ((frame % 6) == 0 && (R[0x42] & 1)) {
                        for (int i = 0; i < 256; i++) {
                            uint16_t tile = ref.vram[0x400 + i * 4], attr = ref.vram[0x400 + i * 4 + 3];
                            if (!tile) continue;
                            std::string fl;
                            auto add = [&](const char* x) { if (!fl.empty()) fl += ","; fl += x; };
                            if (attr & 0x4000) add("blend");
                            if (attr & 0x0004) add("flipx");
                            if (attr & 0x0008) add("flipy");
                            char b[128];
                            snprintf(b, sizeof b, "sprite bpp=%d size=%dx%d %s", bpp(attr), 8 << ((attr >> 4) & 3), 8 << ((attr >> 6) & 3), fl.c_str());
                            cnote(b);
                        }
                    }
                    char b[64];
                    snprintf(b, sizeof b, "blendlevel=%d", R[0x2a] & 3); cnote(b);
                    if (R[0x30]) cnote("fade used");
                    if ((R[0x3c] & 0xff) != 0x20) { snprintf(b, sizeof b, "SATURATION %02X", R[0x3c] & 0xff); cnote(b); }
                }
                if (sweep_frames && frame >= sweep_frames) done = true;
                frame_bad_lines = frame_bad_px = 0;
            }
        }

        if (top->dbg_illegal) {
            fprintf(stderr, "illegal opcode at %06X\n", top->dbg_pc);
            report_state(stderr);
            break;
        }

        if (top->dbg_irq_ack) {
            irq_taken[top->dbg_irq_ack_line]++;
            if (!freerun) {
                if (pending_irq < 0 || (int)top->dbg_irq_ack_line != pending_irq) {
                    char buf[96];
                    snprintf(buf, sizeof buf, "RTL took IRQ %d, MAME expected %d", top->dbg_irq_ack_line, pending_irq);
                    diverge(buf);
                }
                pending_irq = -1;
                top->sim_irq = 0;
            }
        }

        if (top->dbg_fetch) {
            if (trace_ok && !trace_done) {
                if (!trace.next(cur)) {
                    printf("trace exhausted (end of capture)\n");
                    trace_done = true;
                    if (!freerun) break;
                } else {
                    have_cur = true;
                    if (!freerun && pending_irq >= 0) diverge("MAME took an interrupt the RTL did not");
                    bool ok = top->dbg_pc == cur.pc
                           && top->dbg_r[1] == cur.r[0] && top->dbg_r[2] == cur.r[1]
                           && top->dbg_r[3] == cur.r[2] && top->dbg_r[4] == cur.r[3]
                           && top->dbg_r[0] == cur.r[4] && top->dbg_r[5] == cur.r[5]
                           // SR is sampled after the fetch's add_lpc(1); MAME's is
                           // before it, so CS is taken from the fetch address
                           && ((top->dbg_r[6] & 0xffc0) | (top->dbg_pc >> 16)) == cur.r[6];
                    if (!ok) diverge("register/PC state differs");
                    if (cur.irq_after >= 0) {
                        irq_mame[cur.irq_after]++;
                        if (!freerun) {
                            pending_irq = cur.irq_after;
                            top->sim_irq = 1u << cur.irq_after;
                        }
                    }
                }
            }
            if (verbose)
                printf("%8llu %06X %04X  %s\n", (unsigned long long)n, top->dbg_pc, top->dbg_op,
                       trace_ok ? cur.text.c_str() : "");
            prev_op = top->dbg_op; prev_pc = top->dbg_pc;
            n++;
            if ((n & 0x3fffff) == 0) {
                printf("  %llu instructions (%.2f s emulated)\n", (unsigned long long)n, clk_n / 108e6);
                fflush(stdout);
            }
        }
    }

    printf("\n%s: %llu instructions, %.3f s emulated\n", freerun ? "FREERUN" : "LOCKSTEP",
           (unsigned long long)n, clk_n / 108e6);
    if (freerun)
        printf("trace %s\n", trace_ok ? "matched until its end" : "diverged (see above)");
    printf("video: %u frames, %llu/%llu lines differ from the reference renderer (%llu more matched the end-of-line state, %llu had palette and %llu other memory writes mid-line), %llu overruns\n",
           frame, (unsigned long long)total_bad_lines, (unsigned long long)total_lines, (unsigned long long)race_lines,
           (unsigned long long)pal_lines, (unsigned long long)mem_lines, (unsigned long long)overruns);
    printf("\ninterrupts taken      RTL      MAME(trace)\n");
    const char* names[9] = {"FIQ", "IRQ0 video", "IRQ1", "IRQ2 timer", "IRQ3 uart/adc", "IRQ4 audio", "IRQ5 ext", "IRQ6 1-4kHz", "IRQ7 tmb/4Hz"};
    for (int i = 0; i < 9; i++)
        if (irq_taken[i] || irq_mame[i])
            printf("  %-16s %8llu %8llu\n", names[i], (unsigned long long)irq_taken[i], (unsigned long long)irq_mame[i]);

    printf("\nSoC register reads: RTL value vs MAME\n");
    printf("  addr    reads  mismatch   first mismatch (pc: mame / rtl)\n");
    for (auto& [a, s] : stats) {
        if (s.mismatches)
            printf("  %04X %8llu %8llu     %06X: %04X / %04X\n", a, (unsigned long long)s.reads,
                   (unsigned long long)s.mismatches, s.pc, s.mame, s.rtl);
        else
            printf("  %04X %8llu        -\n", a, (unsigned long long)s.reads);
    }
    wav.close();
    delete top;
    return 0;
}
