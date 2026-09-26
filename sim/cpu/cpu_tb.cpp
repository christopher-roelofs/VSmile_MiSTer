// Lockstep testbench: µ'nSP RTL vs. a MAME golden trace (scripts/mame_trace.sh).
//
//   ./obj_dir/Vunsp_core <cart.bin> <tracedir> [max_insns]
//
// ROM is served from the cart image and RAM (0x0000-0x3FFF outside the SoC
// register ranges, incl. palette/sprite/scroll RAM) is modelled here, along
// with the system and sprite DMA engines.  SoC register accesses are replayed
// from <tracedir>/mem.log: reads return the logged value, writes must match
// the logged address/data.  This verifies the CPU in isolation before any
// SPG2xx peripheral exists.  Interrupts are injected at the instruction
// boundaries where MAME's trace shows them.
//
// Environment:
//   VERBOSE=1   print every retired instruction
#include "Vunsp_core.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>

struct TraceEntry {
    uint32_t pc;
    uint16_t r[7];      // r1 r2 r3 r4 sp bp sr
    int      irq_after; // MAME irq line taken after this instruction, or -1
    std::string text;
};

class TraceReader {
public:
    explicit TraceReader(const std::string& path) {
        f_ = fopen(path.c_str(), "r");
        if (!f_) { perror(path.c_str()); exit(1); }
    }
    // Next instruction entry, with any interrupt marker that follows it.
    bool next(TraceEntry& e) {
        if (!have_pending_ && !read_insn(pending_)) return false;
        e = pending_;
        have_pending_ = false;
        e.irq_after = -1;
        // Look ahead for an interrupt marker before the next instruction.
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
            // a capture killed by its timeout can end in a partial line
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

static std::vector<uint16_t> rom;
static uint32_t rom_mask;
static int cs_mode = 0;     // REG_EXT_MEMORY_CTRL (0x3D23) bits 7:6 -> vsmile chip_sel_w

// V.Smile external bus (MAME vsmile_state::banked_map with a cart present):
// cart ROM is linear, except chip-select modes 2/3 put the system ROM at
// 0x300000-0x3FFFFF.  No BIOS is loaded here, so that reads as 0xFFFF
// (matching the placeholder BIOS used for the MAME trace).
static uint16_t ext_read(uint32_t a) {
    if (cs_mode >= 2 && a >= 0x300000) return 0xffff;
    return rom[a & rom_mask];
}

static void load_rom(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint32_t words = 1;
    while (words < (uint32_t)(sz / 2)) words <<= 1;
    rom.assign(words, 0xffff);
    std::vector<uint8_t> b(sz);
    if (fread(b.data(), 1, sz, f) != (size_t)sz) { perror("read"); exit(1); }
    fclose(f);
    for (long i = 0; i + 1 < sz; i += 2) rom[i / 2] = b[i] | (b[i + 1] << 8);
    rom_mask = words - 1;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) {
        fprintf(stderr, "usage: %s <cart.bin> <tracedir> [max_insns]\n", argv[0]);
        return 2;
    }
    load_rom(argv[1]);
    std::string dir = argv[2];
    uint64_t max_insns = argc > 3 ? strtoull(argv[3], nullptr, 0) : ~0ull;
    bool verbose = getenv("VERBOSE") != nullptr;

    TraceReader trace(dir + "/cpu.tr");
    MemLog mem(dir + "/mem.log");

    Vunsp_core* top = new Vunsp_core;
    top->clk = 0; top->reset = 1; top->ce = 1; top->ready = 1; top->irq = 0;
    for (int i = 0; i < 4; i++) { top->clk = 1; top->eval(); top->clk = 0; top->eval(); }
    top->reset = 0;

    // SoC state the testbench must track to stay in step with MAME
    uint16_t dma[4] = {0, 0, 0, 0};     // system DMA 0x3E00-0x3E03
    uint16_t spr_src = 0, spr_dst = 0;  // sprite DMA 0x2870/0x2871
    std::vector<uint16_t> ram(0x4000, 0);
    uint64_t n = 0, cycles = 0;
    TraceEntry cur{};
    bool have_cur = false;
    int pending_irq = -1;
    uint16_t prev_op = 0; uint32_t prev_pc = 0;

    auto fail = [&](const char* why) {
        fprintf(stderr, "\n*** MISMATCH after %llu instructions (%llu cycles, %llu mem events): %s\n",
                (unsigned long long)n, (unsigned long long)cycles, (unsigned long long)mem.count(), why);
        fprintf(stderr, "    previous insn: %06X op %04X\n", prev_pc, prev_op);
        if (have_cur)
            fprintf(stderr, "    MAME:  %06X  R1=%04X R2=%04X R3=%04X R4=%04X SP=%04X BP=%04X SR=%04X  %s\n",
                    cur.pc, cur.r[0], cur.r[1], cur.r[2], cur.r[3], cur.r[4], cur.r[5], cur.r[6], cur.text.c_str());
        fprintf(stderr, "    RTL:   %06X  R1=%04X R2=%04X R3=%04X R4=%04X SP=%04X BP=%04X SR=%04X\n",
                top->dbg_pc, top->dbg_r[1], top->dbg_r[2], top->dbg_r[3], top->dbg_r[4],
                top->dbg_r[0], top->dbg_r[5], top->dbg_r[6]);
        exit(1);
    };

    // SoC register ranges whose reads are replayed from mem.log
    auto is_io = [](uint32_t a) {
        return (a >= 0x2800 && a <= 0x28ff) || (a >= 0x3000 && a <= 0x37ff) || (a >= 0x3d00 && a <= 0x3eff);
    };
    // A bus access made by a DMA engine rather than the CPU
    auto dma_read = [&](uint32_t a) -> uint16_t {
        if (is_io(a)) { MemEvent d; mem.peek(d); mem.pop(); return d.data; }
        return a < 0x4000 ? ram[a] : ext_read(a);
    };
    auto dma_write = [&](uint32_t a, uint16_t v) {
        if (is_io(a)) { MemEvent d; mem.peek(d); mem.pop(); return; }
        if (a < 0x4000) ram[a] = v;
    };
    // Side effects of CPU register writes that the testbench has to mirror
    auto io_write = [&](uint32_t a, uint16_t v) {
        if (a == 0x3d23) cs_mode = (v >> 6) & 3;
        if (a == 0x3d2f) { top->ds_we = 1; top->ds_wdata = v & 0x3f; }
        // video sprite DMA (MAME spg2xx_video::do_sprite_dma) -> spriteram 0x2C00
        if (a == 0x2870) spr_src = v & 0x3fff;
        if (a == 0x2871) spr_dst = v & 0x03ff;
        if (a == 0x2872) {
            uint32_t len = (v & 0x3ff) ? (v & 0x3ff) : 0x400;
            for (uint32_t j = 0; j < len; j++)
                if (spr_dst + j < 0x400) ram[0x2c00 + spr_dst + j] = dma_read(spr_src + j);
        }
        // system DMA (MAME spg2xx_sysdma::do_cpu_dma)
        if (a >= 0x3e00 && a <= 0x3e03) {
            dma[a & 3] = v;
            if ((a & 3) == 2 && !(v & 0xc000)) {
                uint32_t len = v;
                uint32_t src = ((dma[1] & 0x3f) << 16) | dma[0];
                uint32_t dst = dma[3] & 0x3fff;
                for (uint32_t j = 0; j < len; j++)
                    dma_write((dst + j) & 0x3fff, dma_read(src + j));
                src += len;
                dma[0] = src; dma[1] = (src >> 16) & 0x3f; dma[2] = 0; dma[3] = (dst + len) & 0x3fff;
            }
        }
    };

    bool done = false;
    while (n < max_insns && !done) {
        // --- combinational bus service before the rising edge ---
        top->clk = 0;
        top->eval();
        if (top->rd || top->wr) {
            uint32_t a = top->addr;
            if (is_io(a)) {
                MemEvent e;
                char want = top->rd ? 'R' : 'W';
                if (!mem.peek(e)) { printf("mem.log exhausted (end of capture)\n"); done = true; break; }
                if (e.kind != want || e.addr != a || (top->wr && e.data != top->wdata)) {
                    char buf[160];
                    snprintf(buf, sizeof buf, "bus %c %04X %04X, mem.log has %c %04X %04X",
                             want, a, top->wr ? top->wdata : 0, e.kind, e.addr, e.data);
                    fail(buf);
                }
                mem.pop();
                if (top->rd) top->rdata = e.data;
                if (top->wr) io_write(a, top->wdata);
            } else if (top->rd) {
                top->rdata = a < 0x4000 ? ram[a] : ext_read(a);
            } else if (a < 0x4000) {
                ram[a] = top->wdata;
            }
        }
        top->eval();
        top->clk = 1;
        top->eval();
        top->ds_we = 0;
        cycles++;

        if (top->dbg_illegal) fail("illegal opcode");

        if (top->irq_ack) {
            if (pending_irq < 0 || (int)top->irq_ack_line != pending_irq) {
                char buf[96];
                snprintf(buf, sizeof buf, "RTL took IRQ %d, MAME expected %d", top->irq_ack_line, pending_irq);
                fail(buf);
            }
            pending_irq = -1;
            top->irq = 0;
        }

        if (top->dbg_fetch) {
            if (!trace.next(cur)) { printf("trace exhausted (end of capture)\n"); break; }
            have_cur = true;
            if (pending_irq >= 0) fail("MAME took an interrupt the RTL did not");
            bool ok = top->dbg_pc == cur.pc
                   && top->dbg_r[1] == cur.r[0] && top->dbg_r[2] == cur.r[1]
                   && top->dbg_r[3] == cur.r[2] && top->dbg_r[4] == cur.r[3]
                   && top->dbg_r[0] == cur.r[4] && top->dbg_r[5] == cur.r[5]
                   && top->dbg_r[6] == cur.r[6];
            if (verbose)
                printf("%8llu %06X %04X  %s\n", (unsigned long long)n, top->dbg_pc, top->dbg_op, cur.text.c_str());
            if (!ok) fail("register/PC state differs");
            if (cur.irq_after >= 0) {
                pending_irq = cur.irq_after;
                top->irq = 1u << cur.irq_after;
            }
            prev_op = top->dbg_op; prev_pc = top->dbg_pc;
            n++;
            if ((n & 0xfffff) == 0) {
                printf("  %llu instructions OK (%llu cycles)\n", (unsigned long long)n, (unsigned long long)cycles);
                fflush(stdout);
            }
        }
    }

    printf("PASS: %llu instructions, %llu cycles, %llu mem events match MAME\n",
           (unsigned long long)n, (unsigned long long)cycles, (unsigned long long)mem.count());
    delete top;
    return 0;
}
