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
#include "Vvsmile.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <map>
#include <string>
#include <vector>
#include <deque>

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
    if (getenv("BIOS")) bios = load_words(getenv("BIOS"));

    TraceReader trace(dir + "/cpu.tr");
    MemLog mem(dir + "/mem.log");

    Vvsmile* top = new Vvsmile;
    top->pal = 0;
    top->mame_timing = 1;
    top->region = 0x1f;                 // English (US), VTech intro on
    top->has_bios = bios.empty() ? 0 : 1;
    top->cart_mask = cart_words - 1;
    top->joy = 0;
    top->colors = 0;
    top->buttons = 0;
    top->sim_io_override = freerun ? 0 : 1;
    top->sim_irq_override = freerun ? 0 : 1;
    top->sim_irq = 0;
    top->reset = 1;
    top->ce = 0;
    top->mem_ack = 0;

    uint64_t clk_n = 0;
    int mem_lat = 0;
    std::map<uint32_t, RegStat> stats;
    uint64_t irq_taken[9] = {0}, irq_mame[9] = {0};

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
        // clk = 108 MHz, ce = 27 MHz
        const bool ce = (clk_n & 3) == 3;
        top->ce = ce;
        if (clk_n == 16) top->reset = 0;

        top->clk = 0;
        top->eval();

        // external memory: fixed latency
        // MEMLAT: clks before mem_ack (default 0: answer in the request clk)
        static const int memlat = getenv("MEMLAT") ? atoi(getenv("MEMLAT")) : 0;
        if (top->mem_req && !top->mem_ack) {
            if (mem_lat++ >= memlat) {
                uint32_t a = top->mem_addr;
                uint16_t v = 0xffff;
                if (a < 0x800000) v = cart[a & (cart_words - 1)];
                else if (!bios.empty()) v = bios[(a - 0x800000) % bios.size()];
                top->mem_rdata = v;
                top->mem_ack = 1;
                mem_lat = 0;
            }
        } else top->mem_ack = 0;
        top->eval();

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
                           && top->dbg_r[6] == cur.r[6];
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
    delete top;
    return 0;
}
