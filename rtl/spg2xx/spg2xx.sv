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
    input  logic        pal,
    input  logic        mame_timing,    // MAME-exact 60 Hz frame (verification)

    // external bus (cart / system ROM), word addressed
    output logic        ext_req,
    output logic        ext_wr,
    output logic [21:0] ext_addr,
    output logic [15:0] ext_wdata,
    input  logic        ext_ack,        // one clk, with ext_rdata for reads
    input  logic [15:0] ext_rdata,
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

    // video timing
    output logic [8:0]  vpos,
    output logic [8:0]  hpos,
    output logic        vblank,

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
        .extint,
        .irq_timer, .irq_uart_adc, .irq_ext, .irq_hifreq, .irq_lofreq
    );

    logic        spr_dma_done;
    logic [15:0] vregs [0:255];

    spg2xx_vctl vctl (
        .clk, .reset, .ce, .pal, .mame_timing,
        .addr(reg_off), .rd(vc_rd), .wr(vc_wr), .wdata(reg_wdata), .rdata(vc_rdata),
        .spr_dma_start(), .spr_dma_src(), .spr_dma_dst(), .spr_dma_len(),
        .spr_dma_done,
        .vpos, .hpos, .vblank, .irq(irq_video),
        .regs(vregs)
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
        soc_irq[0] = irq_video && video_to_fiq;     // + audio channel IRQ (TODO)
        soc_irq[1] = irq_video && !video_to_fiq;
        soc_irq[3] = irq_timer;
        soc_irq[4] = irq_uart_adc;
        soc_irq[5] = 1'b0;                          // audio IRQ (TODO)
        soc_irq[6] = irq_ext;
        soc_irq[7] = irq_hifreq;
        soc_irq[8] = irq_lofreq;
    end
    assign cpu_irq = sim_irq_override ? sim_irq : soc_irq;

    // ------------------------------------------------------------------
    // Memories (single port each, owned by the bus unit for now; the PPU
    // and SPU will get second ports)
    // ------------------------------------------------------------------
    logic [15:0] ram  [0:10239];    // 0000-27FF
    logic [15:0] vram [0:2047];     // 2800-2FFF (2900-2FFF used)
    logic [15:0] aram [0:2047];     // 3000-37FF audio registers (stub)
    logic [15:0] ram_q, vram_q, aram_q;

    // ------------------------------------------------------------------
    // Bus unit: one access at a time for the CPU or a DMA engine
    // ------------------------------------------------------------------
    typedef enum logic [1:0] { A_IDLE, A_BRAM, A_EXT } astate_t;
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

    // current requester
    wire         dma_active = (dst != D_IDLE);
    wire         dma_skip   = dma_sprite && (dst == D_WR) && ({6'd0, dma_dst} + {6'd0, dma_j[9:0]} >= 16'h400);
    wire [21:0]  q_addr  = !dma_active ? cpu_addr
                         : (dst == D_RD) ? dma_src + 22'(dma_j)
                         : dma_sprite ? 22'h2c00 + 22'(dma_dst) + 22'(dma_j[9:0])
                         : {8'd0, 14'(dma_dst + dma_j[13:0])};
    wire         q_rd    = !dma_active ? cpu_rd : (dst == D_RD);
    wire         q_wr    = !dma_active ? cpu_wr : (dst == D_WR);
    wire [15:0]  q_wdata = !dma_active ? cpu_wdata : dma_data;
    wire         q_valid = !dma_active ? ((cpu_rd || cpu_wr) && !cpu_done)
                                       : (!dma_wait && (dst == D_RD || (dst == D_WR && !dma_skip)));
    wire         go      = (ast == A_IDLE) && q_valid;

    // address decode
    wire is_ext   = q_addr >= 22'h004000;
    wire is_ram   = !is_ext && q_addr[13:0] <  14'h2800;
    wire is_vreg  = !is_ext && q_addr[13:8] == 6'h28;
    wire is_vram  = !is_ext && q_addr[13:11] == 3'b101 && !is_vreg;   // 2900-2FFF
    wire is_audio = !is_ext && q_addr[13:11] == 3'b110;               // 3000-37FF
    wire is_io    = !is_ext && q_addr[13:8] == 6'h3d;
    wire is_dma   = !is_ext && q_addr[13:2] == 12'hf80;               // 3E00-3E03
    wire is_bram  = is_ram || is_vram || is_audio;
    // SoC register ranges MAME's trace logs (for the sim override)
    wire is_logged = is_vreg || is_audio || is_io || (!is_ext && q_addr[13:8] == 6'h3e);

    assign reg_off   = q_addr[7:0];
    assign reg_wdata = q_wdata;
    assign io_rd = go && q_rd && is_io;
    assign io_wr = go && q_wr && is_io;
    assign vc_rd = go && q_rd && is_vreg;
    assign vc_wr = go && q_wr && is_vreg;

    // BRAM ports
    always_ff @(posedge clk) begin
        if (go && q_wr && is_ram)   ram[q_addr[13:0]]   <= q_wdata;
        if (go && q_wr && is_vram)  vram[q_addr[10:0]]  <= q_wdata;
        if (go && q_wr && is_audio) aram[q_addr[10:0]]  <= q_wdata;
        ram_q  <= ram[q_addr[13:0] < 14'h2800 ? q_addr[13:0] : 14'd0];
        vram_q <= vram[q_addr[10:0]];
        aram_q <= aram[q_addr[10:0]];
    end
    logic [1:0] bram_sel;   // 0 ram, 1 vram, 2 audio

    // register read value (combinational in the accept cycle)
    logic [15:0] reg_rdata;
    always_comb begin
        reg_rdata = 16'd0;
        if (is_io)       reg_rdata = io_rdata;
        else if (is_vreg) reg_rdata = vc_rdata;
        else if (is_dma) reg_rdata = sysdma[q_addr[1:0]];
    end

    // sim hooks
    assign dbg_io_rd        = go && q_rd && is_logged && !dma_active;
    assign dbg_io_wr        = go && q_wr && is_logged && !dma_active;
    assign dbg_io_addr      = q_addr[15:0];
    assign dbg_io_wdata     = q_wdata;
    assign dbg_io_rtl_rdata = reg_rdata;    // audio registers: not modelled yet

    // ext bus
    assign ext_addr  = q_addr;
    assign ext_wdata = q_wdata;

    logic        owner_dma;
    logic        dma_ack;
    logic [15:0] acc_data;
    logic        audio_rd_q;     // audio read being overridden

    always_ff @(posedge clk) begin
        dma_ack      <= 1'b0;
        spr_dma_done <= 1'b0;
        cpu_done     <= 1'b0;

        if (reset) begin
            ast      <= A_IDLE;
            dst      <= D_IDLE;
            cpu_done <= 1'b0;
            ext_req  <= 1'b0;
            dma_wait <= 1'b0;
            sysdma <= '{default: 16'd0};
        end else begin

            case (ast)
            A_IDLE: if (go) begin
                owner_dma <= dma_active;
                if (dma_active) dma_wait <= 1'b1;
                if (is_bram) begin
                    bram_sel   <= is_ram ? 2'd0 : is_vram ? 2'd1 : 2'd2;
                    audio_rd_q <= is_audio && q_rd && sim_io_override && !dma_active;
                    ast        <= A_BRAM;
                end else if (is_ext) begin
                    ext_req <= 1'b1;
                    ext_wr  <= q_wr;
                    ast     <= A_EXT;
                end else begin
                    // registers / unmapped: complete now
                    logic [15:0] v;
                    v = reg_rdata;
                    if (is_logged && q_rd && sim_io_override && !dma_active) v = sim_io_rdata;
                    complete(v);
                    // register write side effects owned by the bus unit
                    if (q_wr && is_dma) begin
                        if (q_addr[1:0] != 2'd2) sysdma[q_addr[1:0]] <= q_wdata;
                        else if (q_wdata[15:14] == 2'b00) begin
                            dma_sprite <= 1'b0;
                            dma_src    <= {sysdma[1][5:0], sysdma[0]};
                            dma_dst    <= sysdma[3][13:0];
                            dma_len    <= q_wdata;
                            dma_j      <= 16'd0;
                            dst        <= (q_wdata == 16'd0) ? D_IDLE : D_RD;
                            sysdma[2]  <= 16'd0;
                            if (q_wdata == 16'd0) begin
                                // MAME still updates the registers
                                sysdma[3] <= {2'd0, sysdma[3][13:0]};
                            end
                        end
                    end
                    if (q_wr && is_vreg && q_addr[7:0] == 8'h72) begin
                        dma_sprite <= 1'b1;
                        dma_src    <= {8'd0, vregs[8'h70][13:0]};
                        dma_dst    <= {4'd0, vregs[8'h71][9:0]};
                        dma_len    <= (q_wdata[9:0] != 0) ? {6'd0, q_wdata[9:0]} : 16'h400;
                        dma_j      <= 16'd0;
                        dst        <= D_RD;
                    end
                end
            end
            A_BRAM: begin
                logic [15:0] v;
                v = (bram_sel == 2'd0) ? ram_q : (bram_sel == 2'd1) ? vram_q : aram_q;
                if (audio_rd_q) v = sim_io_rdata;
                complete(v);
                ast <= A_IDLE;
            end
            A_EXT: if (ext_ack) begin
                ext_req <= 1'b0;
                complete(ext_rdata);
                ast <= A_IDLE;
            end
            default: ast <= A_IDLE;
            endcase

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
        if (owner_dma_now()) begin
            dma_ack  <= 1'b1;
            acc_data <= v;
        end else begin
            cpu_done  <= 1'b1;
            cpu_rdata <= v;
        end
    endtask

    // In A_IDLE the owner is the current requester; afterwards it is latched.
    function automatic logic owner_dma_now();
        return (ast == A_IDLE) ? dma_active : owner_dma;
    endfunction

endmodule
