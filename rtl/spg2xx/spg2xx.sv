// SunPlus SPG24x SoC (as used in the VTech V.Smile)
//
//   µ'nSP CPU + 10 KW RAM + video control/RAMs + audio registers + I/O
//   + system DMA + sprite DMA, with an external bus for cart/system ROM.
//
// Internal map (word addresses, MAME spg2xx_device::internal_map):
//   0000-27FF RAM            2800-28FF video regs   2900-2FFF video RAMs
//   3000-37FF audio          3D00-3DFF I/O          3E00-3E03 system DMA
//   4000-3FFFFF external bus
//
// Clocking: `clk` is the system clock, `ce` the 27 MHz CPU/peripheral tick
// (e.g. clk = 108 MHz, ce = clk/4).  The bus unit runs on every clk; internal
// accesses take 1-2 clks.  DMA runs at the bus unit's pace while the CPU
// waits; the CPU's cycle credit (see unsp_core) lets it catch up afterwards,
// so on average it keeps MAME's timing, where DMAs take no time at all.
//
// sim_* ports (tie to 0 in hardware) let a testbench feed MAME's values for
// SoC register reads and MAME's interrupt timing into the CPU, while the RTL
// still computes its own values for comparison (dbg_io_*).

module spg2xx (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,
    input  logic        clk_vid,        // scan-out clock for the line buffer
    input  logic        pal,
    input  logic        mame_timing,    // MAME-exact 60 Hz frame (verification)

    // external bus (cart / system ROM): reads return the aligned group of
    // four words containing ext_addr (word 0 in [15:0]); writes are ignored
    // by the board (ROM) but still handshaken
    output logic        ext_req,
    output logic        ext_wr,
    output logic [21:0] ext_addr,
    output logic [15:0] ext_wdata,
    input  logic        ext_ack,        // one clk, with ext_rdata for reads
    input  logic [63:0] ext_rdata,
    output logic [1:0]  cs_mode,

    // GPIO
    input  logic [15:0] porta_in, portb_in, portc_in,
    output logic [15:0] porta_out, portb_out, portc_out,
    output logic [15:0] porta_oe,  portb_oe,  portc_oe,
    output logic [2:0]  port_wr,

    // UART (controllers)
    output logic        uart_tx_valid,
    output logic [7:0]  uart_tx_data,
    input  logic        uart_rx_valid,
    input  logic [7:0]  uart_rx_data,
    input  logic [1:0]  extint,
    input  logic [1:0]  extint_evt,

    // audio (70312.5 Hz)
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic        audio_strobe,

    // video timing and pixel output
    output logic [8:0]  vpos,
    output logic [8:0]  hpos,
    output logic [10:0] hcnt,
    output logic        vblank,
    input  logic [8:0]  out_x,
    output logic [14:0] out_rgb,
    output logic [23:0] out_rgb888,
    output logic        line_done,
    output logic [7:0]  done_y,
    output logic        ppu_overrun,

    // simulation hooks
    input  logic        sim_io_override,
    input  logic [15:0] sim_io_rdata,
    input  logic        sim_irq_override,
    input  logic [8:0]  sim_irq,
    output logic        dbg_io_rd,
    output logic        dbg_io_wr,
    output logic [15:0] dbg_io_addr,
    output logic [15:0] dbg_io_wdata,
    output logic [15:0] dbg_io_rtl_rdata,
    output logic [8:0]  soc_irq,

    // CPU trace
    output logic        dbg_fetch,
    output logic [21:0] dbg_pc,
    output logic [15:0] dbg_op,
    output logic [15:0] dbg_r [0:7],
    output logic        dbg_illegal,
    output logic        dbg_irq_ack,
    output logic [3:0]  dbg_irq_ack_line
);

    // ------------------------------------------------------------------
    // CPU
    // ------------------------------------------------------------------
    logic [21:0] cpu_addr;
    logic        cpu_rd, cpu_wr;
    logic [15:0] cpu_wdata;
    logic        cpu_done;          // one-clk acknowledge of the CPU's access
    logic [15:0] cpu_rdata;
    logic [8:0]  cpu_irq;
    logic        io_ds_we;
    logic [5:0]  io_ds_wdata;
    logic        watchdog_reset;
    wire         cpu_reset = reset | watchdog_reset;

    unsp_core cpu (
        .clk, .reset(cpu_reset), .ce,
        .addr(cpu_addr), .rd(cpu_rd), .wr(cpu_wr), .wdata(cpu_wdata),
        .rdata(cpu_rdata), .ready(cpu_done),
        .ds_we(io_ds_we), .ds_wdata(io_ds_wdata),
        .irq(cpu_irq), .irq_ack(dbg_irq_ack), .irq_ack_line(dbg_irq_ack_line),
        .dbg_fetch, .dbg_ifetch(), .dbg_pc, .dbg_op, .dbg_r, .dbg_illegal
    );

    // ------------------------------------------------------------------
    // Peripherals
    // ------------------------------------------------------------------
    logic [7:0]  reg_off;
    logic        io_rd, io_wr, vc_rd, vc_wr;
    logic [15:0] reg_wdata;
    logic [15:0] io_rdata, vc_rdata;

    logic        irq_timer, irq_uart_adc, irq_ext, irq_hifreq, irq_lofreq, irq_video;
    logic [2:0]  fiq_sel;
    logic        fiq_sel_we;
    logic [2:0]  fiq_vector;        // MAME m_fiq_vector (reset 0xFF: video -> IRQ0)
    logic        fiq_vector_set;

    spg2xx_io io (
        .clk, .reset, .ce,
        .addr(reg_off), .rd(io_rd), .wr(io_wr), .wdata(reg_wdata), .rdata(io_rdata),
        .porta_in, .portb_in, .portc_in, .porta_out, .portb_out, .portc_out,
        .porta_oe, .portb_oe, .portc_oe, .port_wr,
        .cpu_csb(dbg_pc[21:20]),
        .cs_mode, .vpos, .pal, .cpu_ds(dbg_r[6][15:10]),
        .ds_we(io_ds_we), .ds_wdata(io_ds_wdata),
        .fiq_sel, .fiq_sel_we, .watchdog_reset,
        .uart_tx_valid, .uart_tx_data, .uart_rx_valid, .uart_rx_data,
        .extint, .extint_evt,
        .irq_timer, .irq_uart_adc, .irq_ext, .irq_hifreq, .irq_lofreq
    );

    logic        spr_dma_done;
    logic [15:0] vregs [0:255];
    logic        line_start, last_line;

    spg2xx_vctl vctl (
        .clk, .reset, .ce, .pal, .mame_timing,
        .addr(reg_off), .rd(vc_rd), .wr(vc_wr), .wdata(reg_wdata), .rdata(vc_rdata),
        .spr_dma_start(), .spr_dma_src(), .spr_dma_dst(), .spr_dma_len(),
        .spr_dma_done,
        .vpos, .hpos, .hcnt_out(hcnt), .vblank, .line_start, .last_line, .irq(irq_video),
        .regs(vregs)
    );

    // ------------------------------------------------------------------
    // PPU
    // ------------------------------------------------------------------
    logic        ppu_mem_req, ppu_mem_ack;
    logic [21:0] ppu_mem_addr;
    logic [15:0] ppu_mem_rdata;
    logic [10:0] ppu_vram_addr;
    logic [15:0] ppu_vram_q;

    spg2xx_ppu ppu (
        .clk, .reset, .clk_vid,
        .regs(vregs), .line_start, .line_vpos(vpos), .last_line,
        .mem_req(ppu_mem_req), .mem_addr(ppu_mem_addr), .mem_ack(ppu_mem_ack), .mem_rdata(ppu_mem_rdata),
        .vram_addr(ppu_vram_addr), .vram_q(ppu_vram_q),
        .out_x, .out_rgb, .out_rgb888,
        .line_done, .done_y, .overrun(ppu_overrun)
    );

    always_ff @(posedge clk) begin
        if (cpu_reset) begin
            fiq_vector_set <= 1'b0;
            fiq_vector     <= 3'd7;
        end else if (fiq_sel_we) begin
            fiq_vector_set <= 1'b1;
            fiq_vector     <= fiq_sel;
        end
    end
    wire video_to_fiq = fiq_vector_set && fiq_vector == 3'd0;

    // MAME input lines: 0 FIQ, 1..8 IRQ0..IRQ7
    always_comb begin
        soc_irq    = 9'd0;
        soc_irq[0] = (irq_video && video_to_fiq) || spu_fiq;
        soc_irq[1] = irq_video && !video_to_fiq;
        soc_irq[3] = irq_timer;
        soc_irq[4] = irq_uart_adc;
        soc_irq[5] = spu_irq;
        soc_irq[6] = irq_ext;
        soc_irq[7] = irq_hifreq;
        soc_irq[8] = irq_lofreq;
    end
    assign cpu_irq = sim_irq_override ? sim_irq : soc_irq;

    // ------------------------------------------------------------------
    // Memories (single port each, owned by the bus unit for now; the PPU
    // and SPU will get second ports)
    // ------------------------------------------------------------------
    logic [15:0] ram  [0:10239] /* verilator public_flat_rd */;    // 0000-27FF
    logic [15:0] vram [0:2047]  /* verilator public_flat_rd */;    // 2800-2FFF (2900-2FFF used)
    logic [15:0] ram_q, vram_q;

    // ------------------------------------------------------------------
    // SPU (3000-37FF)
    // ------------------------------------------------------------------
    logic        spu_req, spu_ack, spu_idle, spu_irq, spu_fiq;
    logic [15:0] spu_rdata;
    logic        spu_mem_req, spu_mem_ack;
    logic [21:0] spu_mem_addr;
    logic [15:0] spu_mem_rdata;

    spg2xx_spu spu (
        .clk, .reset, .ce,
        .req(spu_req), .we(q_wr), .addr(q_addr[10:0]), .wdata(q_wdata),
        .ack(spu_ack), .rdata(spu_rdata), .idle(spu_idle),
        .mem_req(spu_mem_req), .mem_addr(spu_mem_addr), .mem_ack(spu_mem_ack), .mem_rdata(spu_mem_rdata),
        .irq(spu_irq), .fiq(spu_fiq),
        .out_l(audio_l), .out_r(audio_r), .out_strobe(audio_strobe)
    );

    // ------------------------------------------------------------------
    // Bus unit: one access at a time for the CPU or a DMA engine
    // ------------------------------------------------------------------
    typedef enum logic [2:0] { A_IDLE, A_BRAM, A_EXT, A_REG, A_REG2, A_AUD } astate_t;
    astate_t ast;

    // DMA engine
    typedef enum logic [1:0] { D_IDLE, D_RD, D_WR } dstate_t;
    dstate_t dst;
    logic        dma_sprite;        // 1: sprite DMA, 0: system DMA
    logic [21:0] dma_src;
    logic [13:0] dma_dst;
    logic [15:0] dma_len, dma_j;
    logic [15:0] dma_data;
    logic        dma_wait;
    logic [15:0] sysdma [0:3];

    // The CPU's request is combinational from its state: take a registered
    // copy so the address/decode path starts at a flop.  The copy lags by a
    // clk, so the clk after an acknowledge (when it still shows the finished
    // request) is masked out.
    logic [21:0] c_addr;
    logic        c_rd, c_wr, cpu_done_q;
    logic [15:0] c_wdata;
    always_ff @(posedge clk) begin
        c_addr     <= cpu_addr;
        c_rd       <= cpu_rd;
        c_wr       <= cpu_wr;
        c_wdata    <= cpu_wdata;
        cpu_done_q <= cpu_done;
    end
    wire cpu_want = (c_rd || c_wr) && !cpu_done && !cpu_done_q;

    // current requester: real-time units first (SPU > PPU), then DMA, then CPU
    wire         dma_active = (dst != D_IDLE);
    wire         dma_skip   = dma_sprite && (dst == D_WR) && ({6'd0, dma_dst} + {6'd0, dma_j[9:0]} >= 16'h400);
    wire         sel_spu = spu_mem_req && !spu_mem_ack;
    wire         sel_ppu = !sel_spu && ppu_mem_req && !ppu_mem_ack;
    wire         sel_rt  = sel_spu || sel_ppu;
    wire         sel_dma = !sel_rt && dma_active;
    wire         sel_cpu = !sel_rt && !dma_active;
    wire [21:0]  q_addr  = sel_spu ? spu_mem_addr
                         : sel_ppu ? ppu_mem_addr
                         : !dma_active ? c_addr
                         : (dst == D_RD) ? dma_src + 22'(dma_j)
                         : dma_sprite ? 22'h2c00 + 22'(dma_dst) + 22'(dma_j[9:0])
                         : {8'd0, 14'(dma_dst + dma_j[13:0])};
    wire         q_rd    = sel_rt ? 1'b1 : !dma_active ? c_rd : (dst == D_RD);
    wire         q_wr    = sel_rt ? 1'b0 : !dma_active ? c_wr : (dst == D_WR);
    wire [15:0]  q_wdata = !dma_active ? c_wdata : dma_data;
    wire         q_want  = sel_rt ? 1'b1
                         : sel_cpu ? cpu_want
                         : (!dma_wait && (dst == D_RD || (dst == D_WR && !dma_skip)));
    // audio registers are only accessed while the SPU engine is idle; they
    // then complete in one clk
    // an ext miss waits while a prefetch occupies the bus (it may even be
    // fetching the wanted group); hits and internal accesses never wait
    wire         q_valid = q_want && !(is_audio && !spu_idle) && !(is_ext && !(q_rd && rl_hit) && pf_active);
    wire         go      = (ast == A_IDLE) && q_valid;

    // address decode
    wire is_ext   = q_addr >= 22'h004000;
    wire is_ram   = !is_ext && q_addr[13:0] <  14'h2800;
    wire is_vreg  = !is_ext && q_addr[13:8] == 6'h28;
    wire is_vram  = !is_ext && q_addr[13:11] == 3'b101 && !is_vreg;   // 2900-2FFF
    wire is_audio = !is_ext && q_addr[13:11] == 3'b110;               // 3000-37FF
    wire is_io    = !is_ext && q_addr[13:8] == 6'h3d;
    wire is_dma   = !is_ext && q_addr[13:2] == 12'hf80;               // 3E00-3E03
    wire is_bram  = is_ram || is_vram;
    // SoC register ranges MAME's trace logs (for the sim override)
    wire is_logged = is_vreg || is_audio || is_io || (!is_ext && q_addr[13:8] == 6'h3e);

    // Register accesses are latched at accept and performed one clk later
    // (A_REG): keeps the CPU-address -> peripheral logic path short.
    logic [15:0] rq_addr, rq_wdata, rq_rdata;
    logic        rq_rd, rq_wr, rq_cpu;
    wire rq_is_vreg = rq_addr[13:8] == 6'h28;
    wire rq_is_io   = rq_addr[13:8] == 6'h3d;
    wire rq_is_dma  = rq_addr[13:2] == 12'hf80;
    wire rq_logged  = rq_is_vreg || rq_is_io || rq_addr[13:8] == 6'h3e;
    wire in_reg     = (ast == A_REG);

    assign reg_off   = rq_addr[7:0];
    assign reg_wdata = rq_wdata;
    assign io_rd = in_reg && rq_rd && rq_is_io;
    assign io_wr = in_reg && rq_wr && rq_is_io;
    assign vc_rd = in_reg && rq_rd && rq_is_vreg;
    assign vc_wr = in_reg && rq_wr && rq_is_vreg;

    // BRAM ports
    always_ff @(posedge clk) begin
        if (go && q_wr && is_ram)   ram[q_addr[13:0]]   <= q_wdata;
        if (go && q_wr && is_vram)  vram[q_addr[10:0]]  <= q_wdata;
        ram_q  <= ram[q_addr[13:0] < 14'h2800 ? q_addr[13:0] : 14'd0];
        vram_q <= vram[q_addr[10:0]];
        ppu_vram_q <= vram[ppu_vram_addr];
    end
    logic [1:0] bram_sel;   // 0 ram, 1 vram, 2 audio

    // register read value (in A_REG)
    logic [15:0] reg_rdata;
    always_comb begin
        reg_rdata = 16'd0;
        if (rq_is_io)        reg_rdata = io_rdata;
        else if (rq_is_vreg) reg_rdata = vc_rdata;
        else if (rq_is_dma)  reg_rdata = sysdma[rq_addr[1:0]];
    end

    // sim hooks
    // (audio register reads complete, and are reported, a clk later)
    logic [15:0] audio_addr_q;
    assign spu_req          = go && is_audio;
    wire   aud_done         = (ast == A_AUD) && spu_ack;
    assign dbg_io_rd        = (in_reg && rq_rd && rq_logged && rq_cpu) || (aud_done && audio_rd_q);
    assign dbg_io_wr        = (in_reg && rq_wr && rq_logged && rq_cpu) || (go && q_wr && is_audio && sel_cpu);
    assign dbg_io_addr      = (ast == A_AUD) ? audio_addr_q : in_reg ? rq_addr : q_addr[15:0];
    assign dbg_io_wdata     = in_reg ? rq_wdata : q_wdata;
    assign dbg_io_rtl_rdata = (ast == A_AUD) ? spu_rdata : reg_rdata;

    // ext bus: address/data latched when the access is accepted (another
    // requester may be selected while it is in flight).  A two-line cache
    // holds groups of four words: consecutive reads (pixel rows, code) are
    // served from it in one clk, and after a miss the following group is
    // prefetched into the other line while the bus is otherwise idle.
    logic        rl_valid [0:1];
    logic [19:0] rl_tag [0:1];          // addr[21:2]
    logic [63:0] rl_data [0:1];
    logic        rl_fill;               // line the current fetch goes to
    logic [1:0]  ext_sel;               // word of the group wanted
    logic        pf_pending, pf_active;   // prefetch wanted / in flight on the ext bus
    logic [19:0] pf_tag;
    wire         hit0 = rl_valid[0] && (q_addr[21:2] == rl_tag[0]);
    wire         hit1 = rl_valid[1] && (q_addr[21:2] == rl_tag[1]);
    wire         rl_hit = hit0 || hit1;
    wire [63:0]  rl_hit_data = hit0 ? rl_data[0] : rl_data[1];

    logic [1:0]  owner;             // 0 CPU, 1 DMA, 2 SPU, 3 PPU
    logic        dma_ack;
    logic [15:0] acc_data;
    logic        audio_rd_q;     // audio read being overridden

    always_ff @(posedge clk) begin
        dma_ack      <= 1'b0;
        spr_dma_done <= 1'b0;
        cpu_done     <= 1'b0;
        spu_mem_ack  <= 1'b0;
        ppu_mem_ack  <= 1'b0;

        if (reset) begin
            ast      <= A_IDLE;
            dst      <= D_IDLE;
            cpu_done <= 1'b0;
            ext_req  <= 1'b0;
            rl_valid[0] <= 1'b0;
            rl_valid[1] <= 1'b0;
            pf_pending  <= 1'b0;
            pf_active   <= 1'b0;
            dma_wait <= 1'b0;
            sysdma <= '{default: 16'd0};
        end else begin

            case (ast)
            A_IDLE: if (go) begin
                owner <= sel_spu ? 2'd2 : sel_ppu ? 2'd3 : sel_dma ? 2'd1 : 2'd0;
                if (sel_dma) dma_wait <= 1'b1;
                if (is_audio) begin
                    audio_rd_q   <= q_rd && sel_cpu;
                    audio_addr_q <= q_addr[15:0];
                    ast          <= A_AUD;
                end else if (is_bram) begin
                    bram_sel     <= is_ram ? 2'd0 : 2'd1;
                    ast          <= A_BRAM;
                end else if (is_ext && q_rd && rl_hit) begin
                    complete(rl_hit_data[q_addr[1:0] * 16 +: 16]);
                end else if (is_ext) begin
                    ext_req   <= 1'b1;
                    ext_wr    <= q_wr;
                    ext_addr  <= q_addr;
                    ext_wdata <= q_wdata;
                    ext_sel   <= q_addr[1:0];
                    // replace the line that does not hold the previous group
                    rl_fill   <= (rl_valid[0] && rl_tag[0] == q_addr[21:2] - 20'd1) ? 1'b1 : 1'b0;
                    ast       <= A_EXT;
                end else begin
                    // registers / unmapped: latch, perform next clk
                    rq_addr  <= q_addr[15:0];
                    rq_wdata <= q_wdata;
                    rq_rd    <= q_rd;
                    rq_wr    <= q_wr;
                    rq_cpu   <= sel_cpu;
                    ast      <= A_REG;
                end
            end
            A_REG: begin
                // reads: value latched here (side effects of the read strobe
                // happen now too), delivered next clk
                rq_rdata <= (rq_logged && rq_rd && sim_io_override && rq_cpu) ? sim_io_rdata : reg_rdata;
                ast <= A_REG2;
                // register write side effects owned by the bus unit
                if (rq_wr && rq_is_dma) begin
                    if (rq_addr[1:0] != 2'd2) sysdma[rq_addr[1:0]] <= rq_wdata;
                    else if (rq_wdata[15:14] == 2'b00) begin
                        dma_sprite <= 1'b0;
                        dma_src    <= {sysdma[1][5:0], sysdma[0]};
                        dma_dst    <= sysdma[3][13:0];
                        dma_len    <= rq_wdata;
                        dma_j      <= 16'd0;
                        dst        <= (rq_wdata == 16'd0) ? D_IDLE : D_RD;
                        sysdma[2]  <= 16'd0;
                    end
                end
                if (rq_wr && rq_is_vreg && rq_addr[7:0] == 8'h72) begin
                    dma_sprite <= 1'b1;
                    dma_src    <= {8'd0, vregs[8'h70][13:0]};
                    dma_dst    <= {4'd0, vregs[8'h71][9:0]};
                    dma_len    <= (rq_wdata[9:0] != 0) ? {6'd0, rq_wdata[9:0]} : 16'h400;
                    dma_j      <= 16'd0;
                    dst        <= D_RD;
                end
            end
            A_BRAM: begin
                complete((bram_sel == 2'd0) ? ram_q : vram_q);
                ast <= A_IDLE;
            end
            A_REG2: begin
                complete(rq_rdata);
                ast <= A_IDLE;
            end
            A_AUD: if (spu_ack) begin
                logic [15:0] v;
                v = spu_rdata;
                if (audio_rd_q && sim_io_override) v = sim_io_rdata;
                complete(v);
                ast <= A_IDLE;
            end
            A_EXT: if (ext_ack) begin
                ext_req <= 1'b0;
                complete(ext_rdata[ext_sel * 16 +: 16]);
                if (!ext_wr) begin
                    rl_valid[rl_fill] <= 1'b1;
                    rl_tag[rl_fill]   <= ext_addr[21:2];
                    rl_data[rl_fill]  <= ext_rdata;
                    pf_pending        <= 1'b1;
                    pf_tag            <= ext_addr[21:2] + 20'd1;
                end
                ast <= A_IDLE;
            end
            default: ast <= A_IDLE;
            endcase

            // prefetch of the group after the last miss: issued when the ext
            // bus is free and nobody wants it; completes in the background
            if (pf_active) begin
                if (ext_ack) begin
                    ext_req <= 1'b0;
                    pf_active <= 1'b0;
                    rl_valid[rl_fill] <= 1'b1;
                    rl_tag[rl_fill]   <= ext_addr[21:2];
                    rl_data[rl_fill]  <= ext_rdata;
                end
            end else if (pf_pending && ast == A_IDLE && !(go && is_ext)) begin
                pf_pending <= 1'b0;
                pf_active  <= 1'b1;
                ext_req    <= 1'b1;
                ext_wr     <= 1'b0;
                ext_addr   <= {pf_tag, 2'b00};
                rl_fill    <= (rl_valid[0] && rl_tag[0] == pf_tag - 20'd1) ? 1'b1 : 1'b0;
            end

            // DMA sequencing
            if (dma_ack || (dst == D_WR && dma_skip)) begin
                dma_wait <= 1'b0;
                if (dst == D_RD) begin
                    dma_data <= acc_data;
                    dst      <= D_WR;
                end else if (dst == D_WR) begin
                    if (dma_j + 16'd1 == dma_len) begin
                        dst <= D_IDLE;
                        if (dma_sprite) spr_dma_done <= 1'b1;
                        else begin
                            logic [21:0] ns;
                            ns = dma_src + 22'(dma_len);
                            sysdma[0] <= ns[15:0];
                            sysdma[1] <= {10'd0, ns[21:16]};
                            sysdma[3] <= {2'd0, 14'(dma_dst + dma_len[13:0])};
                        end
                    end else begin
                        dma_j <= dma_j + 16'd1;
                        dst   <= D_RD;
                    end
                end
            end
        end
    end

    // access completion: to the CPU or to the DMA engine
    task automatic complete(input logic [15:0] v);
        logic [1:0] o;
        // in A_IDLE the owner is the current requester; afterwards latched
        o = (ast == A_IDLE) ? (sel_spu ? 2'd2 : sel_ppu ? 2'd3 : sel_dma ? 2'd1 : 2'd0) : owner;
        case (o)
            2'd3: begin ppu_mem_ack <= 1'b1; ppu_mem_rdata <= v; end
            2'd2: begin spu_mem_ack <= 1'b1; spu_mem_rdata <= v; end
            2'd1: begin dma_ack     <= 1'b1; acc_data      <= v; end
            default: begin cpu_done <= 1'b1; cpu_rdata     <= v; end
        endcase
    endtask

endmodule
