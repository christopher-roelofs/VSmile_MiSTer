// VTech V.Smile system: SPG24x SoC + cartridge slot + system ROM + board I/O.
//
// Follows MAME vsmile_state (src/mame/vtech/vsmile.cpp):
//   - external bus banking by the SoC chip-select mode (REG_EXT_MEMORY_CTRL):
//       mode 0/1: cart ROM linear over 000000-3FFFFF
//       mode 2/3: cart 000000-2FFFFF, system ROM at 300000-3FFFFF
//     port B bit 1 low selects the cart's second 4 MW (cs2, 16 MB carts)
//   - port B inputs: power/restart switches; port C: region/intro DIPs and
//     controller RTS lines; port C bits 8/9 are the controller selects
//
// Memory interface: a flat word address space
//   000000-7FFFFF  cart ROM (up to 16 MB)
//   800000-8FFFFF  system ROM (2 MB)
// served by the platform (SDRAM on MiSTer, an array in simulation).  A read
// returns the aligned group of four words containing mem_addr, word 0 in
// bits [15:0].

module vsmile (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,
    input  logic        clk_vid,        // scan-out clock (line buffer read)
    input  logic        pal,
    input  logic        mame_timing,
    input  logic [4:0]  region,         // [3:0] language, [4] VTech intro
    input  logic        has_bios,       // system ROM loaded
    input  logic        motion,         // V.Smile Motion: its system ROM, port A 0xC000
    input  logic        dummy_bios,     // no system ROM: veesem's dummy instead of 0xFFFF

    output logic        mem_req,        // one-clk issue pulse (up to four out)
    output logic [23:0] mem_addr,
    input  logic        mem_ack,        // one clk, with mem_rdata, in issue order
    input  logic [63:0] mem_rdata,
    input  logic [22:0] cart_mask,      // cart size in words - 1

    // joystick on controller port 1 (port 2 is empty, as MAME's default)
    input  logic [3:0]  joy,            // up, down, left, right
    input  logic [2:0]  ud_level,       // stick level 3..7 per axis (0: full)
    input  logic [2:0]  lr_level,
    input  logic [3:0]  colors,         // green, blue, yellow, red
    input  logic [3:0]  buttons,        // ok, quit, help, abc

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic        audio_strobe,

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

    // simulation hooks (see spg2xx)
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
    output logic        dbg_fetch,
    output logic [21:0] dbg_pc,
    output logic [15:0] dbg_op,
    output logic [15:0] dbg_r [0:7],
    output logic        dbg_illegal,
    output logic        dbg_irq_ack,
    output logic [63:0] dbg_pad,        // vsmile_pad state snapshot
    output logic        dbg_uart_tx_v,  // console -> pad byte
    output logic [7:0]  dbg_uart_tx_d,
    output logic        dbg_uart_rx_v,  // pad -> console byte
    output logic [7:0]  dbg_uart_rx_d,
    output logic        dbg_pad_sel,
    output logic [6:0]  dbg_pad_stale,
    output logic [3:0]  dbg_irq_ack_line
);

    logic        ext_req, ext_wr, ext_ack;
    logic [21:0] ext_addr;
    logic [15:0] ext_wdata;
    logic [63:0] ext_rdata;
    logic [1:0]  cs_mode /* verilator public_flat_rd */;
    logic [15:0] portb_out, portc_out, portb_oe, portc_oe;
    logic [2:0]  port_wr;
    logic        uart_tx_valid /* verilator public_flat_rd */, uart_rx_valid /* verilator public_flat_rd */;
    logic [7:0]  uart_tx_data /* verilator public_flat_rd */, uart_rx_data /* verilator public_flat_rd */;
    logic [1:0]  ctrl_rts, ctrl_rts_evt, ctrl_select /* verilator public_flat_rd */;

    assign dbg_uart_tx_v = uart_tx_valid; assign dbg_uart_tx_d = uart_tx_data;
    assign dbg_uart_rx_v = uart_rx_valid; assign dbg_uart_rx_d = uart_rx_data;
    assign dbg_pad_sel   = ctrl_select[0];

    // MAME vsmile_state::uart_rx sends console bytes to both ports; port 2
    // has no device (RTS low)
    vsmile_pad pad1 (
        .clk, .reset, .ce, .joy, .ud_level, .lr_level, .colors, .buttons,
        .select(ctrl_select[0]),
        .rx_valid(uart_tx_valid), .rx_data(uart_tx_data),
        .tx_valid(uart_rx_valid), .tx_data(uart_rx_data), .dbg(dbg_pad), .dbg_stale(dbg_pad_stale),
        .rts(ctrl_rts[0]), .rts_evt(ctrl_rts_evt[0])
    );
    assign ctrl_rts[1]     = 1'b0;
    assign ctrl_rts_evt[1] = 1'b0;

    // MAME portb_r: OFF (bit 7) / ON (bit 6) switches released, Restart off
    wire [15:0] portb_in = 16'h00c8;

    // MAME portc_r
    wire [15:0] portc_in = {2'b00,
                            (ctrl_rts[0] && ctrl_rts[1]) ? 1'b0 : 1'b1,   // 0x2000
                            ctrl_rts[1] ? 1'b0 : 1'b1,                     // 0x1000
                            1'b0,
                            ctrl_rts[0] ? 1'b0 : 1'b1,                     // 0x0400
                            4'b0000,
                            1'b1,                                          // 0x0020 test point
                            region};

    spg2xx soc (
        .clk, .reset, .ce, .clk_vid, .pal, .mame_timing,
        .ext_req, .ext_wr, .ext_addr, .ext_wdata, .ext_ack, .ext_rdata, .cs_mode,
        .porta_in(motion ? 16'hC000 : 16'h0000), .portb_in, .portc_in,   // MAME vsmilem porta_r
        .porta_out(), .portb_out, .portc_out,
        .porta_oe(), .portb_oe, .portc_oe, .port_wr,
        .uart_tx_valid, .uart_tx_data, .uart_rx_valid, .uart_rx_data,
        .extint(ctrl_rts), .extint_evt(ctrl_rts_evt),
        .audio_l, .audio_r, .audio_strobe,
        .vpos, .hpos, .hcnt, .vblank,
        .out_x, .out_rgb, .out_rgb888, .line_done, .done_y, .ppu_overrun,
        .sim_io_override, .sim_io_rdata, .sim_irq_override, .sim_irq,
        .dbg_io_rd, .dbg_io_wr, .dbg_io_addr, .dbg_io_wdata, .dbg_io_rtl_rdata, .soc_irq,
        .dbg_fetch, .dbg_pc, .dbg_op, .dbg_r, .dbg_illegal, .dbg_irq_ack, .dbg_irq_ack_line
    );

    // cart cs2 (MAME vsmile_state::portb_w -> set_cs2(!bit1)) and controller
    // selects (portc_w bits 8/9), latched when the port is written with the
    // bit configured as an output
    logic cs2 /* verilator public_flat_rd */;
    always_ff @(posedge clk) begin
        if (reset) begin
            cs2         <= 1'b0;
            ctrl_select <= 2'b00;
        end else begin
            if (port_wr[1] && portb_oe[1]) cs2 <= !portb_out[1];
            if (port_wr[2] && portc_oe[8]) ctrl_select[0] <= portc_out[8];
            if (port_wr[2] && portc_oe[9]) ctrl_select[1] <= portc_out[9];
        end
    end

    // external bus banking; reads go to the SDRAM (mem_*) except the system
    // ROM area without a BIOS, which is answered locally: 0xFFFF (MAME's
    // erased region, for the lockstep traces) or, with dummy_bios, the dummy
    // system ROM of veesem (github.com/sp1187/veesem, ISC licence): zeros,
    // but the resource pointer table's slots 0-13 (words 0xFFFC0-0xFFFDB)
    // hold 0x00310000, so games that look resources up find empty data
    // instead of following a 0xFFFFFFFF pointer.  Data comes back in issue
    // order, so local completions queue with the others.
    wire bios_sel  = cs_mode[1] && ext_addr[21:20] == 2'b11;
    wire ext_local = bios_sel && !has_bios;
    always_comb begin
        if (bios_sel) mem_addr = {3'b100, motion, ext_addr[19:0]};
        else          mem_addr = {1'b0, 23'({cs2, ext_addr}) & cart_mask};
    end
    logic [3:0] lq_local;
    logic [3:0] lq_d31 [0:3];           // per word of the group: dummy 0x0031
    logic [3:0] d31;                    // for the read being issued
    always_comb
        for (int k = 0; k < 4; k++) begin
            logic [19:0] w;
            w = {ext_addr[19:2], 2'(k)};
            d31[k] = (w >= 20'hFFFC0) && (w <= 20'hFFFDB) && w[0];
        end
    wire [3:0] head_d31 = lq_empty ? d31 : lq_d31[lq_h[1:0]];
    function automatic [15:0] local_word(input logic d);
        return !dummy_bios ? 16'hffff : d ? 16'h0031 : 16'h0000;
    endfunction
    logic [2:0] lq_h, lq_t;
    // (an answer may come in the clk of the issue itself with zero-latency
    // memory in simulation: the read being issued is then the head)
    wire lq_empty   = (lq_h == lq_t);
    wire head_local = lq_empty ? ext_local : lq_local[lq_h[1:0]];
    assign mem_req   = ext_req && !ext_local;
    assign ext_ack   = (!lq_empty || ext_req) && (head_local || mem_ack);
    assign ext_rdata = head_local ? {local_word(head_d31[3]), local_word(head_d31[2]),
                                     local_word(head_d31[1]), local_word(head_d31[0])} : mem_rdata;
    always_ff @(posedge clk) begin
        if (reset) begin
            lq_h <= 3'd0;
            lq_t <= 3'd0;
        end else begin
            if (ext_req) begin
                lq_local[lq_t[1:0]] <= ext_local;
                lq_d31[lq_t[1:0]]   <= d31;
                lq_t <= lq_t + 3'd1;
            end
            if (ext_ack) lq_h <= lq_h + 3'd1;
        end
    end

endmodule
