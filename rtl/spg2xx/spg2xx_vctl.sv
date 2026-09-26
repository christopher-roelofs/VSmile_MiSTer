// SPG2xx video control: registers 0x2800-0x28FF, beam timing, video IRQs.
//
// Follows MAME spg2xx_video_device's register/IRQ behaviour.  The renderer
// (tile layers, sprites, palette) is a separate block that reads `regs`.
//
// Timing: MAME models a 320x262 screen at exactly 60 Hz with no blanking in
// the horizontal axis.  Here a line is 1716 system clocks at 27 MHz (NTSC,
// 262 lines, 59.94 Hz) or 1728 clocks (PAL, 312 lines); `hpos` is MAME's
// 0-319 horizontal position scaled over the whole line.  `mame_timing`
// instead stretches NTSC lines to 1717/1718 clocks so a frame is exactly
// 450,000 clocks, as in MAME (used for lockstep verification).
// Like MAME, the beam starts at the beginning of vblank (line 240).

module spg2xx_vctl (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,
    input  logic        pal,
    input  logic        mame_timing,

    // register bus (offset = address - 0x2800); rd/wr are one-clk strobes
    input  logic [7:0]  addr,
    input  logic        rd,
    input  logic        wr,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,

    // sprite DMA: request to the bus unit, and its completion
    output logic        spr_dma_start,
    output logic [13:0] spr_dma_src,
    output logic [9:0]  spr_dma_dst,
    output logic [10:0] spr_dma_len,
    input  logic        spr_dma_done,

    output logic [8:0]  vpos,
    output logic [8:0]  hpos,
    output logic [10:0] hcnt_out,       // 27 MHz ticks into the line (scan-out)
    output logic        vblank,
    output logic        line_start,     // one clk, vpos holds the new line
    output logic        last_line,      // vpos is the frame's last line
    output logic        irq,            // to IRQ0 or FIQ (FIQ select)

    // register file for the renderer
    output logic [15:0] regs [0:255] /* verilator public_flat_rd */
);

    logic [15:0] irq_en, irq_st;   // 0x62 / 0x63

    // writes are applied one clk after the strobe (shorter decode path)
    logic        wr_q;
    logic [7:0]  addr_q;
    logic [15:0] wdata_q;
    always_ff @(posedge clk) begin
        wr_q    <= wr && !reset;
        addr_q  <= addr;
        wdata_q <= wdata;
    end

    // ------------------------------------------------------------------
    // Beam timing
    // ------------------------------------------------------------------
    // MAME 60 Hz: 450000 = 262 * 1717 + 146, so 146 of 262 lines are 1718
    logic [8:0]  lfrac;
    wire         long_line = lfrac + 9'd146 >= 9'd262;
    wire [10:0] line_len  = pal ? 11'd1728 : mame_timing ? (long_line ? 11'd1718 : 11'd1717) : 11'd1716;
    wire [8:0]  num_lines = pal ? 9'd312 : 9'd262;

    logic [10:0] hcnt;         // system clocks within the line
    logic [10:0] hacc;         // hpos fraction: hpos = hcnt * 320 / line_len
    logic        pos_hit;

    assign last_line = (vpos == num_lines - 9'd1);
    assign hcnt_out  = hcnt;

    always_ff @(posedge clk) begin
        pos_hit    <= 1'b0;
        line_start <= 1'b0;
        if (reset) begin
            hcnt <= 0; hacc <= 0; hpos <= 0; vpos <= 9'd240; vblank <= 1'b1; lfrac <= 0;
        end else if (ce) begin
            if (hcnt == line_len - 11'd1) begin
                hcnt <= 0; hacc <= 0; hpos <= 0;
                line_start <= 1'b1;
                lfrac <= long_line ? lfrac + 9'd146 - 9'd262 : lfrac + 9'd146;
                if (vpos == num_lines - 9'd1) vpos <= 0;
                else                          vpos <= vpos + 9'd1;
            end else begin
                hcnt <= hcnt + 11'd1;
                if (hacc + 11'd320 >= line_len) begin
                    hacc <= hacc + 11'd320 - line_len;
                    hpos <= hpos + 9'd1;
                end else
                    hacc <= hacc + 11'd320;
            end
            // MAME screenpos_hit: fires at (v = reg36, h = reg37 * 2)
            if (vpos == regs[8'h36][8:0] && hpos == {regs[8'h37][7:0], 1'b0} && hacc < 11'd320
                && regs[8'h37] < 16'd160 && regs[8'h36] <= 16'd240)
                pos_hit <= 1'b1;
        end
        // vblank: line 240 to the end of the frame
        vblank <= (vpos >= 9'd240);
    end

    wire vblank_rise = (vpos >= 9'd240) && !vblank;
    wire vblank_fall = (vpos <  9'd240) &&  vblank;

    // pos_hit is high for one clk; only count it once per position
    logic pos_hit_q;
    always_ff @(posedge clk) pos_hit_q <= pos_hit;
    wire pos_evt = pos_hit && !pos_hit_q;

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    always_comb begin
        rdata = regs[addr];
        case (addr)
            8'h38: rdata = {7'd0, vpos};       // current line
            8'h3e, 8'h3f: rdata = 16'd0;       // light pen
            8'h62: rdata = irq_en;
            8'h63: rdata = irq_st;
            default: ;
        endcase
    end

    assign irq = |(irq_en & irq_st);

    assign spr_dma_src = regs[8'h70][13:0];
    assign spr_dma_dst = regs[8'h71][9:0];

    always_ff @(posedge clk) begin
        spr_dma_start <= 1'b0;
        if (reset) begin
            regs <= '{default: 16'd0};
            regs[8'h36] <= 16'hffff;
            regs[8'h37] <= 16'hffff;
            irq_en <= 0;
            irq_st <= 0;
        end else begin
            logic [15:0] set, clr;
            set = 16'd0;
            clr = 16'd0;

            if (vblank_rise && irq_en[0]) set[0] = 1'b1;
            if (vblank_fall)              clr[0] = 1'b1;
            if (pos_evt && irq_en[1])     set[1] = 1'b1;
            if (spr_dma_done && irq_en[2]) set[2] = 1'b1;
            if (spr_dma_done) regs[8'h72] <= 16'd0;

            if (wr_q) begin
                case (addr_q)
                    8'h10, 8'h16: regs[addr_q] <= wdata_q & 16'h01ff;
                    8'h11, 8'h17: regs[addr_q] <= wdata_q & 16'h00ff;
                    8'h2a:        regs[addr_q] <= wdata_q & 16'h0003;
                    8'h30:        regs[addr_q] <= wdata_q & 16'h00ff;
                    8'h36, 8'h37: regs[addr_q] <= wdata_q & 16'h01ff;
                    8'h39:        regs[addr_q] <= wdata_q & 16'h0001;
                    8'h3d:        regs[addr_q] <= wdata_q & 16'h000f;
                    8'h3e, 8'h3f: ;
                    8'h62:        irq_en <= wdata_q & 16'h0007;
                    8'h63:        clr = clr | wdata_q;
                    8'h70:        regs[addr_q] <= wdata_q & 16'h3fff;
                    8'h71:        regs[addr_q] <= wdata_q & 16'h03ff;
                    8'h72: begin
                        spr_dma_len   <= (wdata_q[9:0] != 0) ? {1'b0, wdata_q[9:0]} : 11'h400;
                        spr_dma_start <= 1'b1;
                    end
                    default:      regs[addr_q] <= wdata_q;
                endcase
            end

            irq_st <= (irq_st & ~clr) | set;
        end
    end

endmodule
