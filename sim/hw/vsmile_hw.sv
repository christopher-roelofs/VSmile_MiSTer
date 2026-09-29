// The console with its real memory path: vsmile_sdram glue -> rtl/sdram.sv
// controller -> SDRAM chip model.  Same ports as `vsmile` except that the
// memory port is replaced by a download port (wr_*), as the HPS would use.

module vsmile_hw (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,
    input  logic        clk_vid,
    input  logic        pal,
    input  logic        mame_timing,
    input  logic [4:0]  region,
    input  logic        has_bios,
    input  logic        motion,
    input  logic        baby,
    input  logic [7:0]  baby_buttons,
    input  logic [1:0]  baby_mode,
    input  logic        dummy_bios,
    input  logic [2:0]  ud_level, lr_level,
    input  logic        kbd,
    input  logic        mat,
    input  logic [12:0] kb_keys [0:4],
    input  logic [7:0]  kb_layout,
    input  logic [22:0] cart_mask,

    input  logic        sdram_init,
    input  logic        wr_req,
    input  logic [23:0] wr_addr,
    input  logic [15:0] wr_data,
    output logic        wr_busy,

    input  logic [3:0]  joy, colors, buttons,

    output logic signed [15:0] audio_l, audio_r,
    output logic        audio_strobe,

    output logic [8:0]  vpos, hpos,
    output logic [10:0] hcnt,
    output logic        vblank,
    input  logic [8:0]  out_x,
    output logic [14:0] out_rgb,
    output logic [23:0] out_rgb888,
    output logic        line_done,
    output logic [7:0]  done_y,
    output logic        ppu_overrun,

    input  logic        sim_io_override,
    input  logic [15:0] sim_io_rdata,
    input  logic        sim_irq_override,
    input  logic [8:0]  sim_irq,
    output logic        dbg_io_rd, dbg_io_wr,
    output logic [15:0] dbg_io_addr, dbg_io_wdata, dbg_io_rtl_rdata,
    output logic [8:0]  soc_irq,
    output logic        dbg_fetch,
    output logic [21:0] dbg_pc,
    output logic [15:0] dbg_op,
    output logic [15:0] dbg_r [0:7],
    output logic        dbg_illegal, dbg_irq_ack,
    output logic [3:0]  dbg_irq_ack_line,
    // memory port as seen by the console (for checking against the image)
    output logic        dbg_mem_ack,
    output logic [23:0] dbg_mem_addr,
    output logic [63:0] dbg_mem_rdata
);
    logic [23:0] ack_addr;
    assign dbg_mem_ack   = mem_ack;
    assign dbg_mem_addr  = ack_addr;    // the address the completing read is for
    assign dbg_mem_rdata = mem_rdata;

    logic        mem_req, mem_ack;
    logic [23:0] mem_addr;
    logic [63:0] mem_rdata;
    logic        mem_wr;
    logic [15:0] mem_wdata;

    vsmile console (
        .clk, .reset, .ce, .clk_vid, .pal, .mame_timing, .region, .has_bios, .motion, .baby, .baby_buttons, .baby_mode, .dummy_bios, .mat, .pen(1'b0), .pen_down(1'b0), .pen_x(10'd0), .pen_y(8'd0),
        .mem_req, .mem_addr, .mem_ack, .mem_rdata, .cart_mask,
        .cart_ram(1'b0), .mem_wr, .mem_wdata, .mem_wbusy(wr_busy),
        .joy, .ud_level, .lr_level, .kbd, .kb_keys, .kb_layout,
        .colors, .buttons,
        .audio_l, .audio_r, .audio_strobe,
        .vpos, .hpos, .hcnt, .vblank, .out_x, .out_rgb, .out_rgb888, .line_done, .done_y, .ppu_overrun,
        .sim_io_override, .sim_io_rdata, .sim_irq_override, .sim_irq,
        .dbg_io_rd, .dbg_io_wr, .dbg_io_addr, .dbg_io_wdata, .dbg_io_rtl_rdata, .soc_irq,
        .dbg_fetch, .dbg_pc, .dbg_op, .dbg_r, .dbg_illegal, .dbg_irq_ack, .dbg_irq_ack_line
    );

    logic [25:0] ch1_addr;
    logic [15:0] ch1_din;
    logic        ch1_req, ch1_rnw, ch1_ready, ch1_taken;
    logic [63:0] ch1_dout;

    vsmile_sdram glue (
        .clk, .reset(sdram_init),
        .mem_req, .mem_addr, .mem_ack, .mem_rdata,
        // as emu.sv: the download and the console's cart RAM writes share it
        .wr_req(wr_req || mem_wr), .wr_addr(mem_wr ? mem_addr : wr_addr),
        .wr_data(mem_wr ? mem_wdata : wr_data), .wr_busy,
        .ch1_addr, .ch1_din, .ch1_req, .ch1_rnw, .ch1_dout, .ch1_ready, .ch1_taken, .ack_addr
    );

    wire  [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic [1:0]  SDRAM_BA;
    logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;

    sdram ctrl (
        .SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
        .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK,
        .init(sdram_init), .clk,
        .ch1_addr, .ch1_din, .ch1_req, .ch1_rnw, .ch1_dout, .ch1_ready, .ch1_taken,
        .ch2_addr(26'd0), .ch2_din(32'd0), .ch2_req(1'b0), .ch2_rnw(1'b1), .ch2_dout(), .ch2_ready(),
        .ch3_addr(24'd0), .ch3_din(16'd0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_dout(), .ch3_ready()
    );

    sdram_model chip (
        .clk, .cke(SDRAM_CKE), .ncs(SDRAM_nCS), .nras(SDRAM_nRAS), .ncas(SDRAM_nCAS), .nwe(SDRAM_nWE),
        .ba(SDRAM_BA), .a(SDRAM_A), .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .dq(SDRAM_DQ)
    );

endmodule
