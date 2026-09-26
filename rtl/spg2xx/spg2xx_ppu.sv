// SPG2xx picture processing unit: two tile layers + 256 sprites into a
// double-buffered 320-pixel line buffer.
//
// Follows MAME spg_renderer_device (src/devices/machine/spg_renderer.cpp)
// scanline for scanline: the line is cleared to transparent, then for each
// priority 0..3 page 1, page 2 and the sprites are drawn in that order, so
// later pixels overwrite earlier ones (or blend into them).  Pixel data is
// consumed as MAME's bitstream does: each word byte-swapped, pixels taken
// MSB-first.  Attribute/tile-map words and pixel data come over the system
// bus (`mem_*`); palette, sprite and scroll RAM are read on a dedicated port
// into the SoC's video RAM (`vram_*`, 1-clk latency).
//
// RAM timing: `vram_addr`/`lb_raddr` are registers and the RAMs have
// registered outputs, so data arrives two clks after the address is set.
//
// Line y is rendered during the previous scanline (`line_start` with
// `line_vpos` = y-1, or the last line of the frame for y = 0) into buffer
// y[0]; the other buffer is read by the scan-out through `out_*`.
//
// Not implemented (no V.Smile title uses them): bitmap/line-map mode,
// vertical compression, hi-colour, the saturation control (0x3C != 0x20).
// Fade (0x30) is applied at the output.

module spg2xx_ppu (
    input  logic        clk,
    input  logic        reset,
    input  logic        clk_vid,        // scan-out clock (line buffer read port)

    input  logic [15:0] regs [0:255],   // video registers (spg2xx_vctl)
    input  logic        line_start,     // a new scanline begins
    input  logic [8:0]  line_vpos,      // ... this one
    input  logic        last_line,      // ... and it is the frame's last

    // system bus reads
    output logic        mem_req,
    output logic [21:0] mem_addr,
    input  logic        mem_ack,
    input  logic [15:0] mem_rdata,

    // video RAM read port (index = address - 0x2800)
    output logic [10:0] vram_addr,
    input  logic [15:0] vram_q,

    // line buffer output: RGB555 of pixel out_x of the last completed line
    input  logic [8:0]  out_x,
    output logic [14:0] out_rgb,
    output logic [23:0] out_rgb888,     // with fade applied

    output logic        line_done,      // render of `done_y` finished
    output logic [7:0]  done_y,
    output logic        overrun         // a line was still rendering at its start
);

    // ------------------------------------------------------------------
    // Line buffers: [buffer][x], 0x8000 = transparent
    // ------------------------------------------------------------------
    logic [15:0] lbuf [0:1023] /* verilator public_flat_rd */;
    logic        cur;                   // buffer being rendered
    logic [8:0]  lb_waddr;
    logic [15:0] lb_wdata;
    logic        lb_we;
    logic [8:0]  lb_raddr;              // renderer read (RMW)
    logic [15:0] lb_q;
    logic [15:0] lb_out_q;

    always_ff @(posedge clk) begin
        if (lb_we) lbuf[{cur, lb_waddr}] <= lb_wdata;
        lb_q     <= lbuf[{cur, lb_raddr}];
    end
    // scan-out reads the other buffer on the video clock; `cur` changes once
    // per line and is resynchronised there
    logic [1:0] cur_v;
    always_ff @(posedge clk_vid) begin
        cur_v    <= {cur_v[0], cur};
        lb_out_q <= lbuf[{~cur_v[1], out_x}];
    end

    wire [15:0] out_px = lb_out_q[15] ? 16'd0 : lb_out_q;
    assign out_rgb = out_px[14:0];

    // RGB555 -> 888 (MAME (i << 3) | (i >> 2)) then fade
    function automatic logic [7:0] c8(input logic [4:0] c);
        return {c, c[4:2]};
    endfunction
    function automatic logic [7:0] fade(input logic [7:0] c, input logic [7:0] f);
        logic [8:0] d;
        d = {1'b0, c} - {1'b0, f};
        return d[8] ? 8'd0 : d[7:0];
    endfunction
    wire [7:0] fade_off = regs[8'h30][7:0];
    assign out_rgb888 = {fade(c8(out_px[14:10]), fade_off), fade(c8(out_px[9:5]), fade_off), fade(c8(out_px[4:0]), fade_off)};

    // ------------------------------------------------------------------
    // Register views
    // ------------------------------------------------------------------
    logic        page;                  // 0: page 1, 1: page 2
    wire [15:0] pg_xscroll = regs[page ? 8'h16 : 8'h10];
    wire [15:0] pg_yscroll = regs[page ? 8'h17 : 8'h11];
    wire [15:0] pg_attr    = regs[page ? 8'h18 : 8'h12];
    wire [15:0] pg_ctrl    = regs[page ? 8'h19 : 8'h13];
    wire [15:0] pg_tilemap = regs[page ? 8'h1a : 8'h14];
    wire [15:0] pg_exattr  = regs[page ? 8'h1b : 8'h15];
    wire [21:0] pg_gfx     = {regs[page ? 8'h21 : 8'h20], 6'd0};
    wire [21:0] spr_gfx    = {regs[8'h22], 6'd0};
    wire [15:0] spr_ctrl   = regs[8'h42];
    wire [5:0]  blendlevel = {1'b0, regs[8'h2a][1:0], 3'b000} + 6'd8;   // 8,16,24,32

    // ------------------------------------------------------------------
    // Renderer state
    // ------------------------------------------------------------------
    typedef enum logic [4:0] {
        R_IDLE, R_CLEAR,
        R_SCAN,
        R_PRIO,
        R_PAGE, R_TILE, R_TILE_ISSUE, R_TILE_RD, R_EX_RD,
        R_SPR, R_SPR_RD, R_SPR_SETUP, R_SPR_SETUP2,
        R_ADDR1, R_ADDR2, R_FETCH, R_DRAW, R_DRAIN,
        R_DONE
    } rstate_t;
    rstate_t rs /* verilator public_flat_rd */, ret;   // ret: state to resume after a strip

    logic [7:0]  y /* verilator public_flat_rd */;     // scanline being rendered
    logic [1:0]  prio;
    logic [9:0]  cnt /* verilator public_flat_rd */;   // generic counter
    logic [8:0]  n /* verilator public_flat_rd */;     // sprite index / tile column

    // sprite candidates: valid + priority, from the once-per-line scan
    logic        cand_v [0:255];
    logic [1:0]  cand_p [0:255];
    logic [15:0] spr_w [0:3];           // tile, x, y, attr

    // page parameters
    logic [1:0]  tw_sh, th_sh;          // tile_w = 8 << tw_sh
    logic [6:0]  tile_w;
    logic [6:0]  tile_h;
    logic [3:0]  nc_bpp;                // 2,4,6,8
    logic [5:0]  bits_per_row;          // nc_bpp * tile_w / 16 (1..32)
    logic [11:0] words_per_tile;
    logic [8:0]  realxscroll;           // & 0x1ff (page maps are 512 wide)
    logic [15:0] xscroll_full;
    logic [7:0]  bitmap_y;
    logic [5:0]  tile_scanline;
    logic [15:0] tile_address;
    logic [5:0]  endpos;
    logic [15:0] tile;
    logic [15:0] tattr, tctrl;          // per-tile attribute/control (exattr)

    // strip parameters (shared by pages and sprites)
    logic [21:0] gfx_base;
    logic [21:0] row_addr /* verilator public_flat_rd */;
    logic [8:0]  drawx /* verilator public_flat_rd */;
    logic        flip_x /* verilator public_flat_rd */, flip_y, blend /* verilator public_flat_rd */;
    logic [7:0]  pal_off /* verilator public_flat_rd */;
    logic [6:0]  npix /* verilator public_flat_rd */;
    logic [5:0]  strip_line;            // tile_scanline for this strip
    logic [2:0]  s_bpp;                 // 1..4 : nc_bpp/2
    logic [5:0]  s_bpr;
    logic [11:0] s_wpt;

    // sprite geometry latched between R_SPR_SETUP and R_SPR_SETUP2
    logic [15:0] sp_attr;
    logic [6:0]  sp_tw, sp_th;
    logic [3:0]  sp_ncb;
    logic [8:0]  sp_ux;
    logic [5:0]  sp_line;
    logic        sp_draw;

    // strip address pipeline: row = gfx + wpt*tile + bpr*line
    logic [21:0] m_gfx;
    logic [15:0] m_tile;
    logic [5:0]  m_line, m_bpr;
    logic [11:0] m_wpt;
    logic [27:0] prod1;
    logic [11:0] prod2;

    // row buffer (pixel words of the strip's row)
    logic [15:0] rowbuf [0:31];
    logic [5:0]  rb_n /* verilator public_flat_rd */, rb_i;

    // bitstream
    logic [23:0] bits;
    logic [4:0]  nbits;
    logic [6:0]  px_i;

    // pixel pipeline: stage 1 (address visible), stage 2 (data visible)
    logic        p1_v, p2_v;
    logic [8:0]  p1_pos, p2_pos;
    logic        p1_blend, p2_blend;

    wire [3:0]  s_ncbpp = {s_bpp, 1'b0};

    // ------------------------------------------------------------------
    // Pixel extraction (MAME draw_tilestrip bitstream), one pixel per clk
    // ------------------------------------------------------------------
    logic [23:0] bits_n;
    logic [4:0]  nbits_n;
    logic [7:0]  pal_idx;
    logic        need_word;
    always_comb begin
        logic [15:0] w, ws;
        need_word = nbits < {1'b0, s_ncbpp};
        w  = rowbuf[rb_i[4:0]];
        ws = {w[7:0], w[15:8]};
        bits_n = bits << s_ncbpp;
        if (need_word) bits_n = bits_n | (24'(ws) << (s_ncbpp - nbits[3:0]));
        nbits_n = need_word ? nbits + 5'd16 - {1'b0, s_ncbpp} : nbits - {1'b0, s_ncbpp};
        pal_idx = pal_off + bits_n[23:16];
    end

    // draw position of pixel px_i (MAME: x runs backwards for flip_x)
    wire [6:0] xk      = flip_x ? (npix - 7'd1 - px_i) : px_i;
    wire [8:0] pos     = (drawx + 9'(xk)) & 9'h1ff;
    wire       pos_vis = pos < 9'd320;

    // blend (MAME mix_channel), stage 1
    function automatic logic [4:0] mixc(input logic [4:0] b, input logic [4:0] t, input logic [5:0] a);
        logic [10:0] r;
        r = (11'(6'd32 - a) * 11'(b)) + (11'(a) * 11'(t));
        return r[9:5];
    endfunction

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    // vram reads: palette at 0x300, scroll RAM at 0x100, sprites at 0x400
    logic [10:0] vram_addr_r;
    assign vram_addr = vram_addr_r;

    // page / sprite tile-strip setup helpers
    // latch a strip's parameters; the address is computed in R_ADDR1/2
    task automatic strip_start(input logic [21:0] gfx, input logic [15:0] t, input logic [5:0] line,
                               input logic [6:0] th, input logic [5:0] bpr, input logic [11:0] wpt,
                               input logic fx, input logic fy, input logic bl, input logic [7:0] po,
                               input logic [8:0] dx, input rstate_t back);
        m_gfx     <= gfx;
        m_tile    <= t;
        m_line    <= fy ? (line ^ (th[5:0] - 6'd1)) : line;
        m_bpr     <= bpr;
        m_wpt     <= wpt;
        flip_x    <= fx;
        blend     <= bl;
        pal_off   <= po;
        drawx     <= dx;
        rb_n      <= bpr;
        rb_i      <= 6'd0;
        ret       <= back;
        rs        <= R_ADDR1;
    endtask

    always_ff @(posedge clk) begin
        lb_we     <= 1'b0;
        line_done <= 1'b0;
        overrun   <= 1'b0;
        p1_v      <= 1'b0;
        p2_v      <= 1'b0;

        if (reset) begin
            rs      <= R_IDLE;
            cur     <= 1'b0;
            mem_req <= 1'b0;
        end else begin
            // ---- new line: start rendering the next one ----
            if (line_start) begin
                logic [8:0] ny;
                ny = last_line ? 9'd0 : line_vpos + 9'd1;
                if (ny < 9'd240) begin
                    if (rs != R_IDLE) overrun <= 1'b1;
                    y    <= ny[7:0];
                    cur  <= ~cur;
                    cnt  <= 10'd0;
                    rs   <= R_CLEAR;
                    mem_req <= 1'b0;
                end
            end else case (rs)

            R_IDLE: ;

            R_CLEAR: begin
                lb_we    <= 1'b1;
                lb_waddr <= cnt[8:0];
                lb_wdata <= 16'h8000;
                if (cnt == 10'd319) begin
                    cnt <= 10'd0;
                    rs  <= R_SCAN;
                end else cnt <= cnt + 10'd1;
            end

            // ---- sprite candidate scan ----
            // One vram read per clk: word c (sprite c>>1, tile or attr) is
            // issued at step c and arrives at step c+2.
            R_SCAN: begin
                if (cnt < 10'd512) vram_addr_r <= 11'h400 + {cnt[8:1], cnt[0] ? 2'd3 : 2'd0};
                if (cnt >= 10'd2) begin
                    if (!cnt[0]) cand_v[cnt[8:1] - 8'd1] <= (vram_q != 16'd0);   // word c-2 = tile of sprite (c-2)>>1
                    else         cand_p[cnt[8:1] - 8'd1] <= vram_q[13:12];
                end
                if (cnt == 10'd513) begin
                    prio <= 2'd0;
                    rs   <= R_PRIO;
                end else cnt <= cnt + 10'd1;
            end

            // ---- priority loop ----
            R_PRIO: begin
                page <= 1'b0;
                rs   <= R_PAGE;
            end

            R_PAGE: begin
                // MAME draw_page setup
                logic [1:0] tws, ths;
                logic [3:0] ncb;
                logic [6:0] tw, th;
                logic [15:0] xs;
                logic [8:0]  by;
                tws = pg_attr[5:4];
                ths = pg_attr[7:6];
                tw  = 7'd8 << tws;
                th  = 7'd8 << ths;
                ncb = {pg_attr[1:0] + 2'd1, 1'b0};
                if (!pg_ctrl[3] || pg_attr[13:12] != prio || pg_ctrl[0] || pg_ctrl[6]) begin
                    // disabled / other priority / linemap / vcmp (unsupported)
                    if (!page) page <= 1'b1;
                    else begin n <= 9'd0; rs <= R_SPR; end
                end else begin
                    tw_sh <= tws; th_sh <= ths;
                    tile_w <= tw; tile_h <= th;
                    nc_bpp <= ncb;
                    s_bpp  <= 3'(pg_attr[1:0]) + 3'd1;
                    s_bpr  <= 6'((12'(ncb) * 12'(tw)) >> 4);
                    s_wpt  <= 12'(((12'(ncb) * 12'(tw)) >> 4) * 12'(th));
                    by = 9'(8'(y + pg_yscroll[7:0]));
                    bitmap_y      <= by[7:0];
                    tile_scanline <= by[7:0] & (th[5:0] - 6'd1);
                    xscroll_full  <= pg_xscroll;
                    // row scroll: MAME adds scrollram[(line + yscroll) & 0xff]
                    vram_addr_r   <= 11'h100 + {3'd0, by[7:0]};
                    endpos <= 6'((10'd320 + 10'(tw)) >> ({1'b0, tws} + 3'd3));
                    n      <= 9'd0;
                    cnt    <= 10'd0;
                    rs     <= R_TILE;
                end
            end

            R_TILE: begin
                // cnt 0,1: scroll RAM read in flight; cnt 1: value arrives
                if (cnt < 10'd2) begin
                    logic [15:0] rx;
                    rx = xscroll_full + (pg_ctrl[4] ? vram_q : 16'd0);
                    if (cnt == 10'd1) realxscroll <= rx[8:0];
                    cnt <= cnt + 10'd1;
                end else if (n == 9'(endpos)) begin
                    if (!page) begin page <= 1'b1; rs <= R_PAGE; end
                    else begin n <= 9'd0; rs <= R_SPR; end
                end else begin
                    // tile index for column n
                    logic [8:0]  realx0;
                    logic [15:0] ta;
                    logic [5:0]  y0;
                    logic [6:0]  tcx;
                    tcx    = 7'd64 >> tw_sh;                       // 512 / tile_w
                    realx0 = (n + 9'(realxscroll >> ({1'b0, tw_sh} + 3'd3))) & 9'(tcx - 7'd1);
                    y0     = bitmap_y >> ({1'b0, th_sh} + 3'd3);
                    ta     = 16'(realx0) + 16'(tcx) * 16'(y0);
                    tile_address <= ta;
                    rs <= R_TILE_ISSUE;
                end
            end
            R_TILE_ISSUE: begin
                mem_req  <= 1'b1;
                mem_addr <= pg_ctrl[2] ? {6'd0, pg_tilemap} : {6'd0, pg_tilemap + tile_address};
                rs <= R_TILE_RD;
            end

            R_TILE_RD: if (mem_ack) begin
                mem_req <= 1'b0;
                tile  <= mem_rdata;
                tattr <= pg_attr;
                tctrl <= pg_ctrl;
                if (mem_rdata == 16'd0) begin
                    n  <= n + 9'd1;
                    rs <= R_TILE;
                end else if (!pg_ctrl[1]) begin
                    // attributes come from the extended attribute map
                    mem_req  <= 1'b1;
                    mem_addr <= pg_ctrl[2] ? {6'd0, pg_exattr} : {6'd0, pg_exattr + (tile_address >> 1)};
                    rs <= R_EX_RD;
                end else
                    page_strip(mem_rdata, pg_attr, pg_ctrl);
            end

            R_EX_RD: if (mem_ack) begin
                logic [7:0]  ex;
                logic [15:0] a, c;
                logic [8:0]  realx0;
                mem_req <= 1'b0;
                realx0 = (n + 9'(realxscroll >> ({1'b0, tw_sh} + 3'd3))) & 9'((7'd64 >> tw_sh) - 7'd1);
                ex = realx0[0] ? mem_rdata[15:8] : mem_rdata[7:0];
                a  = (tattr & ~16'h0f0c) | {4'd0, ex[3:0], 4'd0, ex[5:4], 2'b00};
                c  = (tctrl & ~16'h0100) | {7'd0, ex[6], 8'd0};
                page_strip(tile, a, c);
            end

            // ---- sprites ----
            R_SPR: begin
                if (!spr_ctrl[0] || n == 9'd256) begin
                    if (prio == 2'd3) rs <= R_DONE;
                    else begin prio <= prio + 2'd1; rs <= R_PRIO; end
                end else if (cand_v[n[7:0]] && cand_p[n[7:0]] == prio) begin
                    cnt <= 10'd0;
                    rs  <= R_SPR_RD;
                end else
                    n <= n + 9'd1;
            end

            R_SPR_RD: begin
                // word cnt issued at step cnt, arrives at step cnt+2
                if (cnt < 10'd4) vram_addr_r <= 11'h400 + {n[7:0], cnt[1:0]};
                if (cnt >= 10'd2) spr_w[cnt[1:0] - 2'd2] <= vram_q;
                if (cnt == 10'd5) rs <= R_SPR_SETUP;
                cnt <= cnt + 10'd1;
            end

            R_SPR_SETUP: begin
                // MAME draw_sprite
                logic [15:0] attr;
                logic signed [15:0] sx, sy;
                logic [6:0]  tw, th;
                logic [1:0]  tws, ths;
                logic [3:0]  ncb;
                logic [8:0]  ux, uy, firstline, lastline;
                logic signed [10:0] scanx;
                logic        draw;
                logic [5:0]  sl;
                attr = spr_w[3];
                tws = attr[5:4]; ths = attr[7:6];
                tw  = 7'd8 << tws; th = 7'd8 << ths;
                ncb = {attr[1:0] + 2'd1, 1'b0};
                sx  = signed'(spr_w[1]);
                sy  = signed'(spr_w[2]);
                if (!spr_ctrl[1]) begin
                    sx = 16'sd160 + sx - 16'(signed'({9'd0, tw})) / 16'sd2;
                    sy = 16'sd128 - sy - 16'(signed'({9'd0, th})) / 16'sd2;
                end
                ux = sx[8:0];
                uy = sy[8:0];
                firstline = uy;
                lastline  = (uy + 9'(th) - 9'd1) & 9'h1ff;
                draw = 1'b0; scanx = 11'sd0;
                if (firstline < lastline) begin
                    scanx = 11'(signed'({2'd0, y})) - 11'(signed'({2'd0, firstline}));
                    draw  = (scanx >= 0) && ({1'b0, y} <= lastline);
                end else begin
                    // clipped from the top
                    scanx = 11'(signed'({2'd0, y})) - (11'(signed'({2'd0, firstline})) - 11'sd512);
                    draw  = (scanx >= 0) && ({1'b0, y} <= lastline);
                    if (!draw) begin
                        // clipped against the bottom
                        scanx = 11'(signed'({2'd0, y})) - 11'(signed'({2'd0, firstline}));
                        draw  = (scanx >= 0) && ({1'b0, y} <= lastline + 9'd512);
                    end
                end
                sl = scanx[5:0];
                tile_w <= tw; tile_h <= th; tw_sh <= tws; th_sh <= ths;
                s_bpp  <= 3'(attr[1:0]) + 3'd1;
                n <= n + 9'd1;
                sp_attr <= attr; sp_tw <= tw; sp_th <= th; sp_ncb <= ncb;
                sp_ux <= ux; sp_line <= sl; sp_draw <= draw;
                rs <= R_SPR_SETUP2;
            end
            R_SPR_SETUP2: begin   // row geometry, then the strip
                logic [5:0]  bpr;
                logic [11:0] wpt;
                logic [7:0]  po;
                bpr = 6'((12'(sp_ncb) * 12'(sp_tw)) >> 4);
                wpt = 12'(12'(bpr) * 12'(sp_th));
                po  = {sp_attr[11:8], 4'd0} & ~(8'((8'd1 << sp_ncb) - 8'd1));
                s_bpr <= bpr;
                s_wpt <= wpt;
                npix  <= sp_tw;
                if (sp_draw)
                    strip_start(spr_gfx, spr_w[0], sp_line, sp_th, bpr, wpt, sp_attr[2], sp_attr[3], sp_attr[14], po, sp_ux, R_SPR);
                else
                    rs <= R_SPR;
            end

            // ---- strip: address, fetch the row's words, draw one pixel per clk ----
            R_ADDR1: begin
                prod1 <= 28'(m_wpt) * 28'(m_tile);
                prod2 <= 12'(m_bpr) * 12'(m_line);
                rs    <= R_ADDR2;
            end
            R_ADDR2: begin
                logic [21:0] a;
                a = m_gfx + prod1[21:0] + 22'(prod2);
                row_addr <= a;
                mem_addr <= a;
                mem_req  <= 1'b1;
                rs       <= R_FETCH;
            end

            R_FETCH: if (mem_ack) begin
                rowbuf[rb_i[4:0]] <= mem_rdata;
                if (rb_i + 6'd1 == rb_n) begin
                    mem_req <= 1'b0;
                    rb_i    <= 6'd0;
                    bits    <= 24'd0;
                    nbits   <= 5'd0;
                    px_i    <= 7'd0;
                    rs      <= R_DRAW;
                end else begin
                    rb_i     <= rb_i + 6'd1;
                    mem_addr <= mem_addr + 22'd1;
                end
            end

            R_DRAW: begin
                // stage 0: extract pixel, issue palette + line buffer reads
                bits  <= {8'd0, bits_n[15:0]};
                nbits <= nbits_n;
                if (need_word) rb_i <= rb_i + 6'd1;
                vram_addr_r <= 11'h300 + {3'd0, pal_idx};
                lb_raddr    <= pos;
                p1_v        <= pos_vis;
                p1_pos      <= pos;
                p1_blend    <= blend;
                if (px_i + 7'd1 == npix) begin rs <= R_DRAIN; cnt <= 10'd0; end
                px_i <= px_i + 7'd1;
            end

            R_DRAIN: begin
                cnt <= cnt + 10'd1;
                if (cnt[0]) rs <= ret;
            end

            R_DONE: begin
                line_done <= 1'b1;
                done_y    <= y;
                rs        <= R_IDLE;
            end

            default: rs <= R_IDLE;
            endcase

            // ---- pixel pipeline stage 2: palette + line buffer data ready ----
            p2_v     <= p1_v;
            p2_pos   <= p1_pos;
            p2_blend <= p1_blend;
            if (p2_v) begin
                logic [15:0] rgb;
                rgb = vram_q;
                if (!rgb[15]) begin
                    lb_we    <= 1'b1;
                    lb_waddr <= p2_pos;
                    if (p2_blend && !lb_q[15])
                        lb_wdata <= {1'b0, mixc(lb_q[14:10], rgb[14:10], blendlevel),
                                           mixc(lb_q[9:5],   rgb[9:5],   blendlevel),
                                           mixc(lb_q[4:0],   rgb[4:0],   blendlevel)};
                    else
                        lb_wdata <= rgb;
                end
            end
        end
    end

    // page tile strip (MAME draw_page inner loop after the tile info is known)
    task automatic page_strip(input logic [15:0] t, input logic [15:0] a, input logic [15:0] c);
        logic [7:0]  po;
        logic [8:0]  dx;
        po = {a[11:8], 4'd0} & ~(8'((8'd1 << nc_bpp) - 8'd1));
        dx = 9'(n << ({1'b0, tw_sh} + 3'd3)) - 9'(realxscroll & 9'(tile_w - 7'd1));
        npix <= tile_w;
        n    <= n + 9'd1;
        strip_start(pg_gfx, t, tile_scanline, tile_h, s_bpr, s_wpt, a[2], a[3], c[8], po, dx, R_TILE);
    endtask

endmodule
