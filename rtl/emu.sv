//============================================================================
//  VTech V.Smile for MiSTer
//
//  One 108 MHz clock domain: the console runs on a 27 MHz clock enable, the
//  SDRAM controller, hps_io and the 6.75 MHz pixel-enable video all share
//  clk_sys.  Cartridge (up to 16 MB) and system ROM (2 MB) live in SDRAM:
//    word 0x000000-0x7FFFFF  cartridge
//    word 0x800000-0x8FFFFF  system ROM (BIOS)
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS       = 'Z;
assign USER_OUT      = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_RD, DDRAM_DIN,
        DDRAM_BE, DDRAM_WE} = 0;

assign VGA_F1        = 0;
assign VGA_SCALER    = 0;
assign VGA_DISABLE   = 0;
assign VGA_SL        = 0;
assign HDMI_FREEZE   = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT= 0;

assign LED_POWER     = 0;
assign LED_DISK      = 0;
assign BUTTONS       = 0;

assign AUDIO_S       = 1;
assign AUDIO_MIX     = 0;

assign VIDEO_ARX     = 13'd4;
assign VIDEO_ARY     = 13'd3;

///////////////////////////////////////////////////////////////////////
// Configuration

`include "build_id.v"
localparam CONF_STR = {
    "VSmile;;",
    "F1,BIN,Load Cartridge;",
    "F2,BIN,Load BIOS;",
    "-;",
    "O[2],TV Mode,NTSC,PAL;",
    "O[6:3],Region,US,UK,French,German,Spanish,Italian,Dutch,Portuguese,Chinese;",
    "O[7],VTech Intro,On,Off;",
    "-;",
    "R0,Reset;",
    "J1,Green,Blue,Yellow,Red,OK,Quit,Help,ABC;",
    "jn,B,X,Y,L,A,Select,R,Start;",
    "V,v0.1.",`BUILD_DATE
};

///////////////////////////////////////////////////////////////////////
// Clocks

wire clk_sys;   // 108 MHz: console, SDRAM, hps_io
wire clk_vid;   // 54 MHz: scan-out and the framework's video path
wire pll_locked;

pll pll
(
    .refclk   (CLK_50M),
    .rst      (0),
    .outclk_0 (clk_sys),
    .outclk_1 (clk_vid),
    .locked   (pll_locked)
);

// 27 MHz console tick
reg [1:0] ce_div = 0;
always @(posedge clk_sys) ce_div <= ce_div + 2'd1;
wire ce_27 = (ce_div == 2'd3);

///////////////////////////////////////////////////////////////////////
// HPS

wire  [1:0] buttons;
wire [127:0] status;
wire [31:0] joystick_0;
wire [15:0] joystick_l_analog_0;      // {Y, X} signed, left stick
wire        forced_scandoubler;
wire [21:0] gamma_bus;

wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;
reg         ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
    .clk_sys         (clk_sys),
    .HPS_BUS         (HPS_BUS),
    .EXT_BUS         (),
    .gamma_bus       (gamma_bus),

    .buttons         (buttons),
    .status          (status),
    .forced_scandoubler(forced_scandoubler),

    .joystick_0      (joystick_0),
    .joystick_l_analog_0(joystick_l_analog_0),

    .ioctl_download  (ioctl_download),
    .ioctl_wr        (ioctl_wr),
    .ioctl_addr      (ioctl_addr),
    .ioctl_dout      (ioctl_dout),
    .ioctl_wait      (ioctl_wait),
    .ioctl_index     (ioctl_index)
);

///////////////////////////////////////////////////////////////////////
// SDRAM: cartridge and system ROM
//
// Downloads arrive as bytes and pairs are written as one word.  Cartridge
// dumps are little-endian words; the system ROM dump (MAME vsmile_v103.bin
// etc.) is big-endian, MAME loads it with ROM_REVERSE, so it is swapped.
// BIOS is index 0 (boot.rom auto-load) or 2 (OSD), cartridges index 1.

wire        dl_is_bios = (ioctl_index == 0) || (ioctl_index == 2);
reg  [7:0]  dl_lo;
reg         dl_req;
reg  [23:0] dl_waddr;
reg  [15:0] dl_wdata;
reg  [22:0] cart_mask = 23'h3fffff;   // words - 1 (default 8 MB)
reg         has_bios = 0;
reg  [24:0] cart_bytes;

always @(posedge clk_sys) begin
    dl_req <= 0;
    if (ioctl_download && ioctl_wr) begin
        if (!ioctl_addr[0]) dl_lo <= ioctl_dout;
        else begin
            dl_waddr   <= {dl_is_bios, ioctl_addr[23:1]};
            dl_wdata   <= dl_is_bios ? {dl_lo, ioctl_dout} : {ioctl_dout, dl_lo};
            dl_req     <= 1;
            ioctl_wait <= 1;
        end
    end
    // hold the HPS off until the word is in SDRAM (dl_req itself counts as
    // busy in the clk after it is raised)
    else if (ioctl_wait && !dl_req && !wr_busy) ioctl_wait <= 0;
    if (ioctl_download) begin
        if (dl_is_bios) has_bios <= 1;
        else cart_bytes <= ioctl_addr + 1'd1;
    end
end

// cartridge size rounded up to a power of two (words - 1): all ones below
// and including the highest set bit of (words - 1)
always @(posedge clk_sys) begin
    reg [23:0] wm1;
    reg [22:0] m;
    integer i;
    wm1 = cart_bytes[24:1] - 1'd1;
    m = 23'd0;
    for (i = 22; i >= 0; i = i - 1)
        if (wm1[i] && m == 0) m = (23'd2 << i) - 1'd1;
    cart_mask <= m;
end

wire        mem_req, mem_ack;
wire [23:0] mem_addr;
wire [63:0] mem_rdata;
wire        wr_busy;
wire [25:0] ch1_addr;
wire [15:0] ch1_din;
wire        ch1_req, ch1_rnw, ch1_ready;
wire [63:0] ch1_dout;

vsmile_sdram sdram_glue
(
    .clk        (clk_sys),
    .reset      (~pll_locked),
    .mem_req    (mem_req),
    .mem_addr   (mem_addr),
    .mem_ack    (mem_ack),
    .mem_rdata  (mem_rdata),
    .wr_req     (dl_req),
    .wr_addr    (dl_waddr),
    .wr_data    (dl_wdata),
    .wr_busy    (wr_busy),
    .ch1_addr   (ch1_addr),
    .ch1_din    (ch1_din),
    .ch1_req    (ch1_req),
    .ch1_rnw    (ch1_rnw),
    .ch1_dout   (ch1_dout),
    .ch1_ready  (ch1_ready)
);

sdram sdram
(
    .SDRAM_DQ   (SDRAM_DQ),
    .SDRAM_A    (SDRAM_A),
    .SDRAM_DQML (SDRAM_DQML),
    .SDRAM_DQMH (SDRAM_DQMH),
    .SDRAM_BA   (SDRAM_BA),
    .SDRAM_nCS  (SDRAM_nCS),
    .SDRAM_nWE  (SDRAM_nWE),
    .SDRAM_nRAS (SDRAM_nRAS),
    .SDRAM_nCAS (SDRAM_nCAS),
    .SDRAM_CKE  (SDRAM_CKE),
    .SDRAM_CLK  (SDRAM_CLK),

    .init       (~pll_locked),
    .clk        (clk_sys),

    .ch1_addr   (ch1_addr),
    .ch1_din    (ch1_din),
    .ch1_req    (ch1_req),
    .ch1_rnw    (ch1_rnw),
    .ch1_dout   (ch1_dout),
    .ch1_ready  (ch1_ready),
    .ch2_addr   (26'd0), .ch2_din(32'd0), .ch2_req(1'b0), .ch2_rnw(1'b1), .ch2_dout(), .ch2_ready(),
    .ch3_addr   (24'd0), .ch3_din(16'd0), .ch3_req(1'b0), .ch3_rnw(1'b1), .ch3_dout(), .ch3_ready()
);

///////////////////////////////////////////////////////////////////////
// Console

// registered: this net fans out to every flop in the design
reg [1:0] rst_sync = 2'b11;
always @(posedge clk_sys) rst_sync <= {rst_sync[0], RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download};
wire reset = rst_sync[1];

// region code on port C (MAME vsmile REGION dip)
reg [3:0] lang;
always @(*) case (status[6:3])
    4'd1:    lang = 4'hE;   // UK
    4'd2:    lang = 4'hD;   // French
    4'd3:    lang = 4'hB;   // German
    4'd4:    lang = 4'hC;   // Spanish
    4'd5:    lang = 4'h2;   // Italian
    4'd6:    lang = 4'h9;   // Dutch
    4'd7:    lang = 4'h8;   // Portuguese
    4'd8:    lang = 4'h7;   // Chinese
    default: lang = 4'hF;   // US
endcase

// MiSTer joystick: 0=R 1=L 2=D 3=U, then J1: 4=Green 5=Blue 6=Yellow 7=Red
// 8=OK 9=Quit 10=Help 11=ABC.  Pad bit order follows MAME's ports.  The
// left analog stick moves the V.Smile joystick as well as the d-pad does.
wire signed [7:0] ax = joystick_l_analog_0[7:0], ay = joystick_l_analog_0[15:8];
wire a_r = ax >  8'sd48, a_l = ax < -8'sd48, a_d = ay >  8'sd48, a_u = ay < -8'sd48;
reg [3:0] joy_s, colors_s, buttons_s;
always @(posedge clk_sys) begin
    joy_s     <= {joystick_0[0] | a_r, joystick_0[1] | a_l, joystick_0[2] | a_d, joystick_0[3] | a_u};  // right left down up
    colors_s  <= joystick_0[7:4];                                               // red yellow blue green
    buttons_s <= joystick_0[11:8];                                              // abc help quit ok
end

wire [10:0] hcnt;
wire [8:0]  vpos;
wire [8:0]  out_x;
wire [23:0] rgb888;
wire signed [15:0] audio_l, audio_r;
wire        audio_strobe;
wire        ppu_ovr;

vsmile console
(
    .clk        (clk_sys),
    .reset      (reset),
    .ce         (ce_27),
    .clk_vid    (clk_vid),
    .pal        (status[2]),
    .mame_timing(1'b0),
    .region     ({~status[7], lang}),
    .has_bios   (has_bios),

    .mem_req    (mem_req),
    .mem_addr   (mem_addr),
    .mem_ack    (mem_ack),
    .mem_rdata  (mem_rdata),
    .cart_mask  (cart_mask),

    .joy        (joy_s),
    .colors     (colors_s),
    .buttons    (buttons_s),

    .audio_l    (audio_l),
    .audio_r    (audio_r),
    .audio_strobe(audio_strobe),

    .vpos       (vpos),
    .hpos       (),
    .hcnt       (hcnt),
    .vblank     (),
    .out_x      (out_x),
    .out_rgb    (),
    .out_rgb888 (rgb888),
    .line_done  (),
    .done_y     (),
    .ppu_overrun(ppu_ovr),

    .sim_io_override(1'b0),
    .sim_io_rdata(16'd0),
    .sim_irq_override(1'b0),
    .sim_irq    (9'd0),
    .dbg_io_rd(), .dbg_io_wr(), .dbg_io_addr(), .dbg_io_wdata(), .dbg_io_rtl_rdata(), .soc_irq(),
    .dbg_fetch(), .dbg_pc(), .dbg_op(), .dbg_r(), .dbg_illegal(), .dbg_irq_ack(), .dbg_irq_ack_line()
);

// LED: download, or (diagnostic) the renderer missed a line deadline in the
// last ~0.6 s
reg [25:0] ovr_timer = 0;
always @(posedge clk_sys) begin
    if (ppu_ovr) ovr_timer <= 26'h3ffffff;
    else if (ovr_timer != 0) ovr_timer <= ovr_timer - 1'd1;
end
assign LED_USER = ioctl_download | (ovr_timer != 0);

///////////////////////////////////////////////////////////////////////
// Video

wire        ce_pix;
wire [7:0]  r, g, b;
wire        hs, vs, hblank, vblank;

reg [1:0] reset_vid;
always @(posedge clk_vid) reset_vid <= {reset_vid[0], reset};

vsmile_video video
(
    .clk    (clk_vid),
    .reset  (reset_vid[1]),
    .pal    (status[2]),
    .hcnt   (hcnt),
    .vpos   (vpos),
    .out_x  (out_x),
    .rgb_in (rgb888),
    .ce_pix (ce_pix),
    .r(r), .g(g), .b(b),
    .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank)
);

assign CLK_VIDEO = clk_vid;

video_mixer #(.LINE_LENGTH(320), .GAMMA(1)) video_mixer
(
    .CLK_VIDEO   (clk_vid),
    .CE_PIXEL    (CE_PIXEL),
    .ce_pix      (ce_pix),
    .scandoubler (forced_scandoubler),
    .hq2x        (0),
    .gamma_bus   (gamma_bus),
    .R(r), .G(g), .B(b),
    .HSync(hs), .VSync(vs), .HBlank(hblank), .VBlank(vblank),
    .HDMI_FREEZE (0),
    .freeze_sync (),
    .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
    .VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
);

///////////////////////////////////////////////////////////////////////
// Audio: latest SPU sample (70312.5 Hz), signed 16-bit

reg [15:0] aud_l, aud_r;
always @(posedge clk_sys) if (audio_strobe) begin
    aud_l <= audio_l;
    aud_r <= audio_r;
end
assign AUDIO_L = aud_l;
assign AUDIO_R = aud_r;

endmodule
