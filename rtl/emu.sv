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
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if master clock is stopped
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
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
    "V,v0.1.",`BUILD_DATE
};

///////////////////////////////////////////////////////////////////////
// Clocks

wire clk_sys;   // 108 MHz
wire clk_ram;   // 108 MHz, phase shifted for the SDRAM chip
wire pll_locked;

pll pll
(
    .refclk   (CLK_50M),
    .rst      (0),
    .outclk_0 (clk_sys),
    .outclk_1 (clk_ram),
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
// Downloads arrive as bytes; the ROM images are little-endian 16-bit
// words, so pairs are written as one word.  BIOS is index 0 (boot.rom
// auto-load) or 2 (OSD), cartridges index 1.

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
            dl_wdata   <= {ioctl_dout, dl_lo};
            dl_req     <= 1;
            ioctl_wait <= 1;
        end
    end
    if (sd_ready) ioctl_wait <= 0;
    if (ioctl_download) begin
        if (dl_is_bios) has_bios <= 1;
        else cart_bytes <= ioctl_addr + 1'd1;
    end
end

// cartridge size rounded up to a power of two (words - 1)
always @(posedge clk_sys) begin
    reg [24:0] n;
    n = 25'd1;
    while (n < cart_bytes[24:1]) n = n << 1;
    cart_mask <= 23'(n - 1'd1);
end

wire        mem_req, mem_ack;
wire [23:0] mem_addr;
wire [15:0] mem_rdata;
wire        sd_ready;
wire [15:0] sd_dout;
reg         mem_pending;

// the console reads; downloads write
reg  rd_req;
always @(posedge clk_sys) begin
    rd_req <= 0;
    if (mem_req && !mem_pending && !ioctl_download) begin
        rd_req      <= 1;
        mem_pending <= 1;
    end
    if (sd_ready) mem_pending <= 0;
    if (reset) mem_pending <= 0;
end
assign mem_ack   = sd_ready && mem_pending;
assign mem_rdata = sd_dout;

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

    .ch1_addr   (26'd0), .ch1_din(16'd0), .ch1_req(1'b0), .ch1_rnw(1'b1), .ch1_dout(), .ch1_ready(),
    .ch2_addr   (26'd0), .ch2_din(32'd0), .ch2_req(1'b0), .ch2_rnw(1'b1), .ch2_dout(), .ch2_ready(),

    // ch3: 16-bit words, byte address = word address << 1
    .ch3_addr   (ioctl_download ? {dl_waddr, 1'b0} : {mem_addr, 1'b0}),
    .ch3_din    (dl_wdata),
    .ch3_req    (ioctl_download ? dl_req : rd_req),
    .ch3_rnw    (~ioctl_download),
    .ch3_dout   (sd_dout),
    .ch3_ready  (sd_ready)
);

///////////////////////////////////////////////////////////////////////
// Console

wire reset = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;

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
// 8=OK 9=Quit 10=Help 11=ABC.  Pad bit order follows MAME's ports.
reg [3:0] joy_s, colors_s, buttons_s;
always @(posedge clk_sys) begin
    joy_s     <= {joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};  // right left down up
    colors_s  <= joystick_0[7:4];                                               // red yellow blue green
    buttons_s <= joystick_0[11:8];                                              // abc help quit ok
end

wire [10:0] hcnt;
wire [8:0]  vpos;
wire [8:0]  out_x;
wire [23:0] rgb888;
wire signed [15:0] audio_l, audio_r;
wire        audio_strobe;

vsmile console
(
    .clk        (clk_sys),
    .reset      (reset),
    .ce         (ce_27),
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
    .ppu_overrun(),

    .sim_io_override(1'b0),
    .sim_io_rdata(16'd0),
    .sim_irq_override(1'b0),
    .sim_irq    (9'd0),
    .dbg_io_rd(), .dbg_io_wr(), .dbg_io_addr(), .dbg_io_wdata(), .dbg_io_rtl_rdata(), .soc_irq(),
    .dbg_fetch(), .dbg_pc(), .dbg_op(), .dbg_r(), .dbg_illegal(), .dbg_irq_ack(), .dbg_irq_ack_line()
);

assign LED_USER = ioctl_download;

///////////////////////////////////////////////////////////////////////
// Video

wire        ce_pix;
wire [7:0]  r, g, b;
wire        hs, vs, hblank, vblank;

vsmile_video video
(
    .clk    (clk_sys),
    .reset  (reset),
    .ce     (ce_27),
    .pal    (status[2]),
    .hcnt   (hcnt),
    .vpos   (vpos),
    .out_x  (out_x),
    .rgb_in (rgb888),
    .ce_pix (ce_pix),
    .r(r), .g(g), .b(b),
    .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank)
);

assign CLK_VIDEO = clk_sys;

video_mixer #(.LINE_LENGTH(320), .GAMMA(1)) video_mixer
(
    .CLK_VIDEO   (clk_sys),
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
