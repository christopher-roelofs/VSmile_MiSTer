// Scan-out of the PPU line buffer as a 320x240 (NTSC, 59.94 Hz) or 320x288
// (PAL, 50 Hz) progressive picture with a 6.75 MHz pixel clock: 429 (PAL:
// 432) pixel periods per line, matching the SoC's 1716 / 1728 system-clock
// line.  Runs in the SoC clock domain; `ce` is the 27 MHz tick.
//
// The PPU renders line y while the SoC's beam is on line y-1, into the
// buffer the scan-out is not reading, so the picture is one line behind
// the SoC's own line counter.

module vsmile_video (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,
    input  logic        pal,
    input  logic [10:0] hcnt,           // ticks into the line (spg2xx_vctl)
    input  logic [8:0]  vpos,

    output logic [8:0]  out_x,          // line buffer column to fetch
    input  logic [23:0] rgb_in,         // ... its colour, one clk later

    output logic        ce_pix,
    output logic [7:0]  r, g, b,
    output logic        hs, vs, hblank, vblank
);

    // pixel positions (in 4-tick pixel periods)
    localparam H_ACT_START = 9'd60;     // 320 active pixels from here
    localparam H_SYNC_START = 9'd8, H_SYNC_LEN = 9'd32;
    localparam V_SYNC_START_N = 9'd245, V_SYNC_START_P = 9'd290, V_SYNC_LEN = 9'd3;
    wire [8:0] v_act = pal ? 9'd288 : 9'd240;   // PAL games still render 240 lines

    wire [8:0] px      = hcnt[10:2];                        // pixel period in line
    wire       px_tick = ce && (hcnt[1:0] == 2'd0);         // start of a pixel period
    wire [8:0] vs_start = pal ? V_SYNC_START_P : V_SYNC_START_N;

    always_ff @(posedge clk) begin
        ce_pix <= 1'b0;
        if (reset) begin
            out_x <= 9'd0;
            hs <= 1'b0; vs <= 1'b0; hblank <= 1'b1; vblank <= 1'b1;
            {r, g, b} <= 24'd0;
        end else if (px_tick) begin
            ce_pix <= 1'b1;
            // fetch the next pixel's colour: out_x leads by one period
            out_x  <= (px + 9'd1 >= H_ACT_START) ? (px + 9'd1 - H_ACT_START) : 9'd0;
            hblank <= !(px >= H_ACT_START && px < H_ACT_START + 9'd320);
            vblank <= (vpos >= v_act);
            hs     <= (px >= H_SYNC_START && px < H_SYNC_START + H_SYNC_LEN);
            vs     <= (vpos >= vs_start && vpos < vs_start + V_SYNC_LEN);
            if (px >= H_ACT_START && px < H_ACT_START + 9'd320 && vpos < v_act)
                {r, g, b} <= rgb_in;
            else
                {r, g, b} <= 24'd0;
        end
    end

endmodule
