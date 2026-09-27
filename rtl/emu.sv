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
assign AUDIO_MIX     = status[11] ? 2'd3 : 2'd0;   // 3: full mono mix (the Pocket's speaker)

assign VIDEO_ARX     = 13'd4;
assign VIDEO_ARY     = 13'd3;

///////////////////////////////////////////////////////////////////////
// Configuration

`include "build_id.v"
localparam CONF_STR = {
    "VSmile;;",
    "F1,BIN,Load Cartridge;",
    "F2,BIN,Load BIOS;",
    "F3,BIN,Load Motion BIOS;",
    "-;",
    "O[2],TV Mode,NTSC,PAL;",
    "O[6:3],Region,US,UK,French,German,Spanish,Italian,Dutch,Portuguese,Chinese;",
    "O[7],VTech Intro,On,Off;",
    "O[13:12],Console,Auto,V.Smile,V.Smile Motion,V.Smile Baby;",
    "O[17:16],Baby Switch,Play Time,Watch & Learn,Learn & Explore;",
    "O[15:14],Port 1,Joystick,Keyboard US,Keyboard FR,Keyboard DE;",
    "O[11],Audio,Stereo,Mono (Pocket);",
    "O[9:8],Debug,Off,SDRAM reads,Console;",
    "-;",
    "R0,Reset;",
    "J1,Green,Blue,Yellow,Red,OK/Orange,Quit/Exit,Help/Cloud,ABC/Ball;",
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
wire [10:0] ps2_key;          // {toggle, pressed, extended, set-2 scancode}
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
    .ps2_key         (ps2_key),
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
// Downloads arrive as bytes and pairs are written as one word, low byte
// first, for both the cartridge and the system ROM (MAME's ROM_REVERSE on
// the sysrom cancels against the CPU's big-endian region: the CPU sees the
// dump's bytes low first, as verified against a trace that reads it).
// Index (bootN.rom auto-loads as N * 64): system ROM 0 (boot0.rom) or 2
// (OSD), V.Smile Motion system ROM 0x80 (boot2.rom) or 3 (OSD), cartridge
// 0x40 (boot1.rom) or 1 (OSD).  Word addresses: cart 0x000000, system ROM
// 0x800000, Motion system ROM 0x900000.

wire        dl_is_motion = (ioctl_index == 8'h80) || (ioctl_index == 3);
wire        dl_is_bios   = (ioctl_index == 0) || (ioctl_index == 2) || dl_is_motion;
// Console: Auto picks the V.Smile Motion for a Motion cart when its system
// ROM is loaded.  Motion carts carry VTech's PC-software record
// "V.Smile\084nnn ...\Info.XML" (product numbers 80-084xxx), one character
// per 16-bit word; the download is scanned for it (like the Game Boy core's
// CGB-flag detection, the download holds the console in reset).
reg         cart_motion = 0;
// V.Smile Baby carts (SPG28x console): their reset vector (word 0xFFF7) is
// 0x4EE6-0x5B22 in every known Baby cart and 0xA425-0xF993 in every
// standard/Motion cart, so a vector below 0x8000 marks one; Console: Auto
// then runs the Baby.  Baby carts do not use the system ROM (they boot and
// run the same with an all-zero one in MAME), so the Baby needs no BIOS file.
reg         cart_baby = 0;
reg  [7:0]  vec_lo;
// (registered: a static mode that fans out across the SoC)
reg         baby = 0;
always @(posedge clk_sys) baby <= (status[13:12] == 2'd0) ? cart_baby : (status[13:12] == 2'd3);
wire        motion = (status[13:12] == 2'd0) ? (cart_motion && has_bios_motion && !cart_baby) : (status[13:12] == 2'd2);
reg  [7:0]  dl_lo;
reg         dl_req;
reg  [23:0] dl_waddr;
reg  [15:0] dl_wdata;
reg  [22:0] cart_mask = 23'h3fffff;   // words - 1 (default 8 MB)
reg         has_bios_std = 0, has_bios_motion = 0;

// "V.Smile\084" as little-endian 16-bit characters
function automatic [7:0] motion_pat(input [4:0] i);
    case (i)
        5'd0:  motion_pat = "V";   5'd2:  motion_pat = ".";  5'd4:  motion_pat = "S";
        5'd6:  motion_pat = "m";   5'd8:  motion_pat = "i";  5'd10: motion_pat = "l";
        5'd12: motion_pat = "e";   5'd14: motion_pat = 8'h5c; 5'd16: motion_pat = "0";
        5'd18: motion_pat = "8";   5'd20: motion_pat = "4";
        default: motion_pat = 8'h00;
    endcase
endfunction
reg [4:0] mpos;
reg       dl_q;
always @(posedge clk_sys) begin
    dl_q <= ioctl_download;
    if (ioctl_download && ioctl_wr && !dl_is_bios) begin
        if (ioctl_addr == 25'h1FFEE) vec_lo <= ioctl_dout;
        if (ioctl_addr == 25'h1FFEF) cart_baby <= ({ioctl_dout, vec_lo} >= 16'h4000) && ({ioctl_dout, vec_lo} < 16'h8000);
    end
    if (ioctl_download && !dl_q && !dl_is_bios) begin
        mpos        <= 0;
        cart_motion <= 0;
        cart_baby   <= 0;
    end else if (ioctl_download && ioctl_wr && !dl_is_bios) begin
        if (ioctl_dout == motion_pat(mpos)) begin
            if (mpos == 5'd21) cart_motion <= 1;
            mpos <= (mpos == 5'd21) ? 5'd0 : mpos + 1'd1;
        end else
            mpos <= (ioctl_dout == "V") ? 5'd1 : 5'd0;
    end
end
reg  [24:0] cart_bytes;

always @(posedge clk_sys) begin
    dl_req <= 0;
    if (ioctl_download && ioctl_wr) begin
        if (!ioctl_addr[0]) dl_lo <= ioctl_dout;
        else begin
            dl_waddr   <= dl_is_bios ? {3'b100, dl_is_motion, ioctl_addr[20:1]} : {1'b0, ioctl_addr[23:1]};
            dl_wdata   <= {ioctl_dout, dl_lo};    // BIOS and cart: low byte first
            dl_req     <= 1;
            ioctl_wait <= 1;
        end
    end
    // hold the HPS off until the word is in SDRAM (dl_req itself counts as
    // busy in the clk after it is raised)
    else if (ioctl_wait && !dl_req && !wr_busy) ioctl_wait <= 0;
    if (ioctl_download) begin
        if (dl_is_motion) has_bios_motion <= 1;
        else if (dl_is_bios) has_bios_std <= 1;
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
wire        ch1_req, ch1_rnw, ch1_ready, ch1_taken;
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
    .ch1_ready  (ch1_ready),
    .ch1_taken  (ch1_taken),
    .ack_addr   ()
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
    .ch1_taken  (ch1_taken),
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
    4'd1:    lang = motion ? 4'h5 : 4'hE;   // UK (the Motion has no 0xE: English 0x5)
    4'd2:    lang = 4'hD;   // French
    4'd3:    lang = 4'hB;   // German
    4'd4:    lang = 4'hC;   // Spanish
    4'd5:    lang = 4'h2;   // Italian
    4'd6:    lang = 4'h9;   // Dutch
    4'd7:    lang = 4'h8;   // Portuguese (Motion: Mexico)
    4'd8:    lang = 4'h7;   // Chinese
    default: lang = 4'hF;   // US
endcase

// MiSTer joystick: 0=R 1=L 2=D 3=U, then J1: 4=Green 5=Blue 6=Yellow 7=Red
// 8=OK 9=Quit 10=Help 11=ABC.  Pad bit order follows MAME's ports.  The
// left analog stick moves the V.Smile joystick as well as the d-pad does.
wire signed [7:0] ax = joystick_l_analog_0[7:0], ay = joystick_l_analog_0[15:8];
// The real V.Smile stick reports five levels per direction (codes x3..x7):
// the analog stick's tilt past a deadzone is graded into them; the d-pad
// sends full (level 0 = full in vsmile_pad).
wire [6:0] mx = ax[7] ? ((ax == -8'sd128) ? 7'd127 : 7'(-ax)) : 7'(ax);
wire [6:0] my = ay[7] ? ((ay == -8'sd128) ? 7'd127 : 7'(-ay)) : 7'(ay);
wire a_r = !ax[7] && mx >= 7'd24, a_l = ax[7] && mx >= 7'd24;
wire a_d = !ay[7] && my >= 7'd24, a_u = ay[7] && my >= 7'd24;
function automatic [2:0] stick_level(input [6:0] m);
    stick_level = (m < 7'd44) ? 3'd3 : (m < 7'd64) ? 3'd4 : (m < 7'd84) ? 3'd5 : (m < 7'd104) ? 3'd6 : 3'd7;
endfunction
reg [2:0] ud_level_s, lr_level_s;
always @(posedge clk_sys) begin
    ud_level_s <= (joystick_0[2] | joystick_0[3]) ? 3'd0 : (a_u | a_d) ? stick_level(my) : 3'd0;
    lr_level_s <= (joystick_0[0] | joystick_0[1]) ? 3'd0 : (a_l | a_r) ? stick_level(mx) : 3'd0;
end
// Smart Keyboard: USB keyboard keys (PS/2 set 2) by physical position onto
// MAME's US key matrix (rows ROW0-4, column = bit); the FR/DE keyboards
// have the same positions, so an AZERTY/QWERTZ keyboard with the matching
// layout types its own letters.  Enter / Esc / F1 are OK / Quit / Help.
reg  [12:0] kb_keys [0:4];
reg  [2:0]  kb_btn;           // help quit ok
reg         ps2_tog;
always @(posedge clk_sys) begin
    ps2_tog <= ps2_key[10];
    if (ps2_key[10] != ps2_tog) begin
        reg [2:0] r;
        reg [3:0] c;
        reg       v;
        v = 1'b1; r = 3'd7; c = 4'd0;
        case ({ps2_key[8], ps2_key[7:0]})
            9'h016: begin r = 0; c = 0;  end  9'h01E: begin r = 0; c = 1;  end  // 1 2
            9'h026: begin r = 0; c = 2;  end  9'h025: begin r = 0; c = 3;  end  // 3 4
            9'h02E: begin r = 0; c = 4;  end  9'h036: begin r = 0; c = 5;  end  // 5 6
            9'h03D: begin r = 0; c = 6;  end  9'h03E: begin r = 0; c = 7;  end  // 7 8
            9'h046: begin r = 0; c = 8;  end  9'h045: begin r = 0; c = 9;  end  // 9 0
            9'h04E: begin r = 0; c = 10; end  9'h066: begin r = 0; c = 11; end  // - backspace
            9'h00D: begin r = 1; c = 0;  end  9'h015: begin r = 1; c = 1;  end  // tab (typing time) q
            9'h01D: begin r = 1; c = 2;  end  9'h024: begin r = 1; c = 3;  end  // w e
            9'h02D: begin r = 1; c = 4;  end  9'h02C: begin r = 1; c = 5;  end  // r t
            9'h035: begin r = 1; c = 6;  end  9'h03C: begin r = 1; c = 7;  end  // y u
            9'h043: begin r = 1; c = 8;  end  9'h044: begin r = 1; c = 9;  end  // i o
            9'h04D: begin r = 1; c = 10; end  9'h054: begin r = 1; c = 11; end  // p [
            9'h05B: begin r = 1; c = 12; end                                    // ] (erase)
            9'h058: begin r = 2; c = 0;  end  9'h01C: begin r = 2; c = 1;  end  // caps a
            9'h01B: begin r = 2; c = 2;  end  9'h023: begin r = 2; c = 3;  end  // s d
            9'h02B: begin r = 2; c = 4;  end  9'h034: begin r = 2; c = 5;  end  // f g
            9'h033: begin r = 2; c = 6;  end  9'h03B: begin r = 2; c = 7;  end  // h j
            9'h042: begin r = 2; c = 8;  end  9'h04B: begin r = 2; c = 9;  end  // k l
            9'h04C: begin r = 2; c = 10; end                                    // ;
            9'h012, 9'h059: begin r = 3; c = 0; end                             // shift
            9'h01A: begin r = 3; c = 1;  end  9'h022: begin r = 3; c = 2;  end  // z x
            9'h021: begin r = 3; c = 3;  end  9'h02A: begin r = 3; c = 4;  end  // c v
            9'h032: begin r = 3; c = 5;  end  9'h031: begin r = 3; c = 6;  end  // b n
            9'h03A: begin r = 3; c = 7;  end  9'h041: begin r = 3; c = 8;  end  // m ,
            9'h049: begin r = 3; c = 9;  end  9'h175: begin r = 3; c = 10; end  // . up
            9'h069: begin r = 4; c = 0;  end  9'h079: begin r = 4; c = 1;  end  // kp1 (player 1) kp+ (symbol)
            9'h029: begin r = 4; c = 2;  end  9'h072: begin r = 4; c = 3;  end  // space kp2 (player 2)
            9'h16B: begin r = 4; c = 4;  end  9'h172: begin r = 4; c = 5;  end  // left down
            9'h174: begin r = 4; c = 6;  end                                    // right
            9'h05A, 9'h15A: kb_btn[0] <= ps2_key[9];                            // enter: OK
            9'h076: kb_btn[1] <= ps2_key[9];                                    // esc: Quit
            9'h005: kb_btn[2] <= ps2_key[9];                                    // F1: Help
            default: v = 1'b0;
        endcase
        if (v && r != 3'd7) kb_keys[r][c] <= ps2_key[9];
    end
    if (reset) begin
        kb_keys <= '{default: 13'd0};
        kb_btn  <= 3'd0;
    end
end

reg [3:0] joy_s, colors_s, buttons_s;
reg [7:0] baby_s;
always @(posedge clk_sys) begin
    joy_s     <= {joystick_0[0] | a_r, joystick_0[1] | a_l, joystick_0[2] | a_d, joystick_0[3] | a_u};  // right left down up
    colors_s  <= joystick_0[7:4];                                               // red yellow blue green
    buttons_s <= joystick_0[11:8] | {1'b0, kb_btn};                             // abc help quit ok
    // V.Smile Baby: exit ball cloud red green orange blue yellow
    baby_s    <= {joystick_0[9], joystick_0[11], joystick_0[10], joystick_0[7], joystick_0[4],
                  joystick_0[8], joystick_0[5], joystick_0[6]};
end

wire [10:0] hcnt;
wire [8:0]  vpos;
wire [8:0]  out_x;
wire [23:0] rgb888;
wire signed [15:0] audio_l, audio_r;
wire        audio_strobe;
wire        ppu_ovr;
wire        dbg_fetch, dbg_illegal, dbg_irq_ack, dbg_io_wr;
wire [63:0] dbg_pad;
wire        dbg_utx_v, dbg_urx_v, dbg_pad_sel;
wire [7:0]  dbg_utx_d, dbg_urx_d;
wire [6:0]  dbg_pad_stale;
wire [21:0] dbg_pc;
wire [15:0] dbg_io_addr, dbg_io_wdata;

vsmile console
(
    .clk        (clk_sys),
    .reset      (reset),
    .ce         (ce_27),
    .clk_vid    (clk_vid),
    .pal        (status[2]),
    .mame_timing(1'b0),
    .region     ({~status[7], lang}),
    .has_bios   (baby ? 1'b0 : motion ? has_bios_motion : has_bios_std),
    .motion     (motion),
    .baby       (baby),
    .baby_buttons(baby_s),
    .baby_mode  (status[17:16]),
    .dummy_bios (1'b1),

    .mem_req    (mem_req),
    .mem_addr   (mem_addr),
    .mem_ack    (mem_ack),
    .mem_rdata  (mem_rdata),
    .cart_mask  (cart_mask),

    .joy        (joy_s),
    .ud_level   (ud_level_s),
    .lr_level   (lr_level_s),
    .colors     (colors_s),
    .buttons    (buttons_s),
    .kbd        (status[15:14] != 2'd0),
    .kb_keys    (kb_keys),
    .kb_layout  ((status[15:14] == 2'd2) ? 8'h42 : (status[15:14] == 2'd3) ? 8'h44 : 8'h40),

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
    .dbg_io_rd(), .dbg_io_wr(dbg_io_wr), .dbg_io_addr(dbg_io_addr), .dbg_io_wdata(dbg_io_wdata), .dbg_io_rtl_rdata(), .soc_irq(),
    .dbg_fetch(dbg_fetch), .dbg_pc(dbg_pc), .dbg_op(), .dbg_r(), .dbg_illegal(dbg_illegal), .dbg_irq_ack(dbg_irq_ack), .dbg_irq_ack_line(),
    .dbg_pad(dbg_pad), .dbg_uart_tx_v(dbg_utx_v), .dbg_uart_tx_d(dbg_utx_d),
    .dbg_uart_rx_v(dbg_urx_v), .dbg_uart_rx_d(dbg_urx_d), .dbg_pad_sel(dbg_pad_sel), .dbg_pad_stale(dbg_pad_stale)
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

// Debug screens (OSD "Debug"), 16 rows of 64 bits, bit 63 at the left, 5 px
// per bit, 14 px per row from line 8; read back with scripts/dbg_decode.py.
//   SDRAM reads: per read (first four after reset) the word address, then
//     ch1_dout at ch1_ready (s0), one clk later (s1, what the console takes)
//     and two clks later (s2).
//   Console: row 0 {PC, instructions}, 1 {IRQ acks, illegal ops, SDRAM
//     reads}, 2 {frames, PPU overruns, I/O writes}, 3 PC[15:0] at the last
//     four frame starts, 4-11 last values written to 0x2810-0x282F (four per
//     row, lowest address in bits 15:0), 12 pad state (vsmile_pad dbg),
//     13 {bytes pad->console, bytes console->pad, select changes, {select,
//     stale}}, 14 last eight bytes pad->console (newest in bits 7:0), 15
//     last eight bytes console->pad.
reg  [23:0] dbg_addr [0:3];
reg  [63:0] dbg_s0 [0:3], dbg_s1 [0:3], dbg_s2 [0:3];
reg  [2:0]  dbg_n;          // reads issued since reset (saturates at 4)
reg  [2:0]  dbg_k;          // reads completed
reg  [2:0]  dbg_ph;         // one-hot: s0/s1/s2 capture in progress
always @(posedge clk_sys) begin
    dbg_ph <= {dbg_ph[1:0], 1'b0};
    if (reset) begin
        dbg_n <= 0; dbg_k <= 0; dbg_ph <= 0;
    end else begin
        if (ch1_req && ch1_rnw && !dbg_n[2]) begin
            dbg_addr[dbg_n[1:0]] <= ch1_addr[23:0];
            dbg_n <= dbg_n + 1'd1;
        end
        if (ch1_ready && ch1_rnw && !dbg_k[2] && dbg_k < dbg_n) begin
            dbg_s0[dbg_k[1:0]] <= ch1_dout;
            dbg_ph <= 3'b001;
        end
        if (dbg_ph[0]) dbg_s1[dbg_k[1:0]] <= ch1_dout;
        if (dbg_ph[1]) begin dbg_s2[dbg_k[1:0]] <= ch1_dout; dbg_k <= dbg_k + 1'd1; end
    end
end

reg  [31:0] st_insn, st_reads, st_iow;
reg  [15:0] st_irq, st_ill, st_frames, st_ovr;
reg  [63:0] st_pcs;
reg  [15:0] st_vr [0:31];
reg         st_vr_wr;
reg   [4:0] st_vr_a;
reg  [15:0] st_vr_d;
reg  [8:0]  st_vpos_q;
always @(posedge clk_sys) begin
    st_vpos_q <= vpos;
    if (reset) begin
        st_insn <= 0; st_reads <= 0; st_iow <= 0;
        st_irq <= 0; st_ill <= 0; st_frames <= 0; st_ovr <= 0;
    end else begin
        if (dbg_fetch)   st_insn  <= st_insn + 1'd1;
        if (ch1_req && ch1_rnw) st_reads <= st_reads + 1'd1;
        if (dbg_io_wr)   st_iow   <= st_iow + 1'd1;
        if (dbg_irq_ack) st_irq   <= st_irq + 1'd1;
        if (dbg_illegal) st_ill   <= st_ill + 1'd1;
        if (ppu_ovr)     st_ovr   <= st_ovr + 1'd1;
        if (vpos == 9'd0 && st_vpos_q != 9'd0) begin
            st_frames <= st_frames + 1'd1;
            st_pcs    <= {st_pcs[47:0], dbg_pc[15:0]};
        end
    end
    // (the bus write registered first: this is only a debug view)
    st_vr_wr <= dbg_io_wr && dbg_io_addr >= 16'h2810 && dbg_io_addr < 16'h2830;
    st_vr_a  <= 5'(dbg_io_addr - 16'h2810);
    st_vr_d  <= dbg_io_wdata;
    if (st_vr_wr) st_vr[st_vr_a] <= st_vr_d;
end

reg [15:0] st_ptx, st_prx, st_psel;
reg [63:0] st_txh, st_rxh;
reg        st_sel_q;
always @(posedge clk_sys) begin
    st_sel_q <= dbg_pad_sel;
    if (reset) begin
        st_ptx <= 0; st_prx <= 0; st_psel <= 0; st_txh <= 0; st_rxh <= 0;
    end else begin
        if (dbg_urx_v) begin st_ptx <= st_ptx + 1'd1; st_txh <= {st_txh[55:0], dbg_urx_d}; end
        if (dbg_utx_v) begin st_prx <= st_prx + 1'd1; st_rxh <= {st_rxh[55:0], dbg_utx_d}; end
        if (dbg_pad_sel != st_sel_q) st_psel <= st_psel + 1'd1;
    end
end

// the row being shown, copied into the video domain once per row (static
// enough for a debug picture)
reg  [63:0] dbg_row_sys;
reg  [3:0]  dbg_row_sel, dbg_row_s;
always @(posedge clk_sys) begin
    dbg_row_s <= dbg_row_sel;
    if (status[9]) case (dbg_row_s)
        4'd0: dbg_row_sys <= {10'd0, dbg_pc, st_insn};
        4'd1: dbg_row_sys <= {st_irq, st_ill, st_reads};
        4'd2: dbg_row_sys <= {st_frames, st_ovr, st_iow};
        4'd3: dbg_row_sys <= st_pcs;
        4'd12: dbg_row_sys <= dbg_pad;
        4'd13: dbg_row_sys <= {st_ptx, st_prx, st_psel, 8'd0, dbg_pad_sel, dbg_pad_stale};
        4'd14: dbg_row_sys <= st_txh;
        4'd15: dbg_row_sys <= st_rxh;
        default: dbg_row_sys <= {st_vr[{dbg_row_s - 4'd4, 2'd3}], st_vr[{dbg_row_s - 4'd4, 2'd2}],
                                 st_vr[{dbg_row_s - 4'd4, 2'd1}], st_vr[{dbg_row_s - 4'd4, 2'd0}]};
    endcase
    else case (dbg_row_s[1:0])
        2'd0: dbg_row_sys <= {40'd0, dbg_addr[dbg_row_s[3:2]]};
        2'd1: dbg_row_sys <= dbg_s0[dbg_row_s[3:2]];
        2'd2: dbg_row_sys <= dbg_s1[dbg_row_s[3:2]];
        default: dbg_row_sys <= dbg_s2[dbg_row_s[3:2]];
    endcase
end

// video side, pipelined: row/column, then the bit
reg  [23:0] dbg_rgb;
reg  [3:0]  dv_row;
reg  [5:0]  dv_bit;
reg         dv_on, dv_addr;
reg  [63:0] dv_v;
reg  [8:0]  dv_vpos, dv_x;
reg  [1:0]  dv_mode;
always @(posedge clk_vid) begin
    reg [8:0] y;
    dv_vpos <= vpos;
    dv_x    <= out_x;
    dv_mode <= status[9:8];
    y       = dv_vpos - 9'd8;
    dv_row  <= 4'(y / 9'd14);
    dv_bit  <= 6'd63 - 6'(dv_x / 9'd5);
    dv_on   <= (dv_vpos >= 9'd8) && (y < 9'd224) && (y % 9'd14 < 9'd11) && (dv_x < 9'd320) && (dv_x % 9'd5 != 9'd4);
    dv_addr <= !dv_mode[1] && (y % 9'd56 < 9'd14);
    dbg_row_sel <= dv_row;
    dv_v    <= dbg_row_sys;
    dbg_rgb <= !dv_on ? 24'h000040 : dv_v[dv_bit] ? (dv_addr ? 24'hFFFF00 : 24'hFFFFFF) : 24'h404040;
end

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
    .rgb_in (dv_mode != 0 ? dbg_rgb : rgb888),
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
