// SPG2xx sound unit (SPU): 16 wavetable channels, 0x3000-0x37FF.
//
// Follows MAME spg2xx_audio_device (src/devices/machine/spg2xx_audio.cpp):
//   0x3000-0x31FF channel registers   (16 per channel; MAME m_audio_regs)
//   0x3200-0x33FF channel phase regs  (MAME m_audio_phase_regs)
//   0x3400-0x37FF control registers   (MAME m_audio_ctrl_regs)
//
// Output rate 70312.5 Hz = 27 MHz / 384.  MAME's channel rate
// phase * 281250 / 2^19 Hz is exact integer arithmetic here: per output
// sample each channel adds 4*phase to a 19-bit accumulator and fetches one
// sample per overflow; MAME's lerp factor is accumulator >> 11.
//
// Structure: channel and phase registers live in dual-port RAMs (port A for
// the CPU, port B for the engine).  Every output sample the engine walks the
// playing channels one at a time: load registers, advance/fetch samples
// (from the bus), mix, envelope/ramp-down, write back.  CPU writes whose
// side effects touch channel registers (channel start/stop, ramp-down
// start) set the status bits immediately and queue the rest as engine
// commands, run before the next CPU access or engine pass.  The CPU and the
// engine never run at the same time.
//
// Not modelled: the equaliser, compressor and soft-channel FIFO (MAME only
// stores those registers too).

module spg2xx_spu (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    // register access (offset = address - 0x3000), held until ack
    input  logic        req,
    input  logic        we,
    input  logic [10:0] addr,
    input  logic [15:0] wdata,
    output logic        ack,
    output logic [15:0] rdata,
    output logic        idle,           // accepts a register access now

    // sample / envelope reads from the system bus, held until mem_ack
    output logic        mem_req,
    output logic [21:0] mem_addr,
    input  logic        mem_ack,
    input  logic [15:0] mem_rdata,

    output logic        irq,            // beat IRQ -> IRQ4
    output logic        fiq,            // channel IRQs -> FIQ

    output logic signed [15:0] out_l,
    output logic signed [15:0] out_r,
    output logic        out_strobe      // new sample (70312.5 Hz)
);

    // ------------------------------------------------------------------
    // Register offsets (MAME enums)
    // ------------------------------------------------------------------
    localparam logic [3:0] C_WAVE_ADDR = 4'h0, C_MODE = 4'h1, C_LOOP_ADDR = 4'h2, C_PAN_VOL = 4'h3,
                           C_ENV0 = 4'h4, C_ENV_DATA = 4'h5, C_ENV1 = 4'h6, C_EADDR_HIGH = 4'h7,
                           C_EADDR = 4'h8, C_WDATA_PREV = 4'h9, C_ELOOP = 4'ha, C_WDATA = 4'hb,
                           C_ADPCM_SEL = 4'hd;
    localparam logic [3:0] P_PHASE_HIGH = 4'h0, P_RAMP_CLK = 4'h3, P_PHASE = 4'h4;

    localparam logic [4:0] X_ENABLE = 5'h00, X_MAINVOL = 5'h01, X_FIQ_EN = 5'h02, X_FIQ_ST = 5'h03,
                           X_BEAT_BASE = 5'h04, X_BEAT_CNT = 5'h05, X_ENVCLK0 = 5'h06, X_ENVCLK0H = 5'h07,
                           X_ENVCLK1 = 5'h08, X_ENVCLK1H = 5'h09, X_RAMPDOWN = 5'h0a, X_STOP = 5'h0b,
                           X_ZC = 5'h0c, X_CONTROL = 5'h0d, X_STATUS = 5'h0f, X_WIN_L = 5'h10,
                           X_WIN_R = 5'h11, X_REPEAT = 5'h14, X_ENV_MODE = 5'h15, X_TONE_REL = 5'h16,
                           X_ENV_IRQ = 5'h17, X_EQ_C10 = 5'h1b, X_EQ_C32 = 5'h1c, X_EQ_G10 = 5'h1d,
                           X_EQ_G32 = 5'h1e;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------
    logic [15:0] creg [0:511];
    logic [15:0] preg [0:511];
    logic [15:0] xmisc [0:1023];          // control regs >= 0x20 (plain storage)
    logic [15:0] x [0:31];                // control regs 0x00-0x1F

    // engine-private per-channel state
    logic [18:0] acc     [0:15];          // rate accumulator (MAME m_channel_rate_accum)
    logic [3:0]  shift   [0:15];          // MAME m_sample_shift
    logic signed [16:0] ad_sig [0:15];    // IMA ADPCM signal
    logic [6:0]  ad_step [0:15];
    logic [26:0] envclk_frame [0:15];
    logic [16:0] ramp_frame   [0:15];
    logic [21:0] env_addr     [0:15];
    logic [3:0]  a36_rem [0:15];
    logic [15:0] a36_hdr [0:15];
    logic signed [15:0] a36_prev [0:15];
    logic [15:0] fiq_timer_on;
    logic [10:0] beat_curr;

    // pending engine commands (MAME start_channel / stop_channel register work)
    logic [15:0] pend_start, pend_stop, pend_ramp;

    // ------------------------------------------------------------------
    // Tables
    // ------------------------------------------------------------------
    // IMA step sizes, as MAME's ima_adpcm_state::compute_tables builds them
    localparam logic [14:0] IMA_STEP [0:88] = '{
        15'd7, 15'd8, 15'd9, 15'd10, 15'd11, 15'd12, 15'd13, 15'd14, 15'd16, 15'd17,
        15'd19, 15'd21, 15'd23, 15'd25, 15'd28, 15'd31, 15'd34, 15'd37, 15'd41, 15'd45,
        15'd50, 15'd55, 15'd60, 15'd66, 15'd73, 15'd80, 15'd88, 15'd97, 15'd107, 15'd118,
        15'd130, 15'd143, 15'd157, 15'd173, 15'd190, 15'd209, 15'd230, 15'd253, 15'd279, 15'd307,
        15'd337, 15'd371, 15'd408, 15'd449, 15'd494, 15'd544, 15'd598, 15'd658, 15'd724, 15'd796,
        15'd876, 15'd963, 15'd1060, 15'd1166, 15'd1282, 15'd1411, 15'd1552, 15'd1707, 15'd1878, 15'd2066,
        15'd2272, 15'd2499, 15'd2749, 15'd3024, 15'd3327, 15'd3660, 15'd4026, 15'd4428, 15'd4871, 15'd5358,
        15'd5894, 15'd6484, 15'd7132, 15'd7845, 15'd8630, 15'd9493, 15'd10442, 15'd11487, 15'd12635, 15'd13899,
        15'd15289, 15'd16818, 15'd18500, 15'd20350, 15'd22385, 15'd24623, 15'd27086, 15'd29794, 15'd32767
    };
    function automatic logic [14:0] ima_step(input logic [6:0] s);
        return IMA_STEP[(s > 7'd88) ? 7'd88 : s];
    endfunction

    function automatic logic [16:0] ramp_count(input logic [2:0] c);
        case (c)
            3'd0: return 17'd52;    3'd1: return 17'd208;   3'd2: return 17'd832;   3'd3: return 17'd3328;
            3'd4: return 17'd13312; default: return (c == 3'd5) ? 17'd53248 : 17'd106496;
        endcase
    endfunction

    function automatic logic [26:0] envclk_count(input logic [3:0] c);
        return (c >= 4'd11) ? 27'd8192 : 27'd4 << c;
    endfunction

    // MAME get_envelope_clock(channel)
    function automatic logic [3:0] env_clock(input logic [3:0] ch);
        logic [15:0] r;
        r = (ch < 4) ? x[X_ENVCLK0] : (ch < 8) ? x[X_ENVCLK0H] : (ch < 12) ? x[X_ENVCLK1] : x[X_ENVCLK1H];
        return 4'(r >> {ch[1:0], 2'b00});
    endfunction

    // ------------------------------------------------------------------
    // Engine
    // ------------------------------------------------------------------
    typedef enum logic [4:0] {
        E_IDLE, E_CMD, E_CMD_LOAD, E_CMD_APPLY,
        E_TICK, E_CH, E_LOAD, E_ADV, E_FETCH, E_RD_HDR, E_RD_RAW, E_FETCH2,
        E_MIX1, E_MIX1B, E_MIX2, E_MIX3, E_MIX3B, E_ENV, E_ENV_RD, E_WB, E_OUT, E_OUT2
    } estate_t;
    estate_t es;

    logic [3:0]  ch;
    logic [4:0]  li;                      // load index
    logic [2:0]  wi;                      // write-back index
    logic        load_cmd;                // E_LOAD returns to E_CMD_APPLY
    logic signed [31:0] ms;               // mixer pipeline sample
    logic signed [31:0] mp, mq;           // mixer partial products
    logic signed [31:0] pan_l, pan_r;
    logic signed [31:0] ml, mr;
    logic [2:0]  nfetch;                  // samples still to fetch this tick
    logic        playing;
    logic [15:0] raw;
    logic [1:0]  env_rd_i;                // envelope reload read index
    logic        env_rd_three;            // repeat-count reload reads 3 words
    logic signed [31:0] mix_l, mix_r;
    logic [8:0]  tick_div;
    logic        tick_pending;

    // working copies of the current channel's registers
    logic [15:0] w [0:15];
    logic [15:0] w_phase_hi, w_phase, w_ramp_clk;

    wire [15:0] w_mode = w[C_MODE];
    wire [21:0] w_waddr = {w[C_MODE][5:0], w[C_WAVE_ADDR]};
    wire [21:0] w_laddr = {w[C_MODE][11:6], w[C_LOOP_ADDR]};
    wire [1:0]  w_tone  = w[C_MODE][13:12];
    wire        w_16bit = w[C_MODE][14];
    wire        w_adpcm = w[C_MODE][15];
    wire        w_a36   = w[C_ADPCM_SEL][15];
    wire [6:0]  w_edd   = w[C_ENV_DATA][6:0];

    // port B (engine)
    logic [8:0]  pb_addr;
    logic        pb_cwe, pb_pwe;
    logic [15:0] pb_wdata, pb_cq, pb_pq;
    always_ff @(posedge clk) begin
        if (pb_cwe) creg[pb_addr] <= pb_wdata;
        if (pb_pwe) preg[pb_addr] <= pb_wdata;
        pb_cq <= creg[pb_addr];
        pb_pq <= preg[pb_addr];
    end

    // port A (CPU)
    logic [15:0] pa_cq, pa_pq, pa_xq;
    assign idle  = es == E_IDLE && pend_start == 0 && pend_stop == 0 && pend_ramp == 0 && !ack;
    wire  pa_go  = req && idle;
    always_ff @(posedge clk) begin
        if (pa_go && we && addr[10:9] == 2'b00) creg[addr[8:0]] <= cpu_creg_value(addr[8:0], wdata);
        if (pa_go && we && addr[10:9] == 2'b01) preg[addr[8:0]] <= cpu_preg_value(addr[8:0], wdata);
        if (pa_go && we && addr[10] && addr[9:5] != 5'd0) xmisc[addr[9:0]] <= wdata;
        pa_cq <= creg[addr[8:0]];
        pa_pq <= preg[addr[8:0]];
        pa_xq <= xmisc[addr[9:0]];
    end

    // MAME audio_w / audio_phase_w masks (only for channels 0-15: the
    // switch is on offset & 0xF0F)
    function automatic logic [15:0] cpu_creg_value(input logic [8:0] a, input logic [15:0] d);
        if (a[8]) return d;
        case (a[3:0])
            C_PAN_VOL:   return d & 16'h7f7f;
            C_ENV_DATA:  return d & 16'hff7f;
            C_ADPCM_SEL: return d & 16'hfe00;
            default:     return d;
        endcase
    endfunction
    function automatic logic [15:0] cpu_preg_value(input logic [8:0] a, input logic [15:0] d);
        if (a[8]) return d;
        case (a[3:0])
            4'h0, 4'h1, 4'h2, 4'h3: return d & 16'h0007;
            default:                return d;
        endcase
    endfunction

    logic [1:0] ack_src;   // 0 creg, 1 preg, 2 x, 3 xmisc
    always_comb begin
        case (ack_src)
            2'd0: rdata = pa_cq;
            2'd1: rdata = pa_pq;
            2'd2: rdata = x_q;
            default: rdata = pa_xq;
        endcase
    end
    logic [15:0] x_q;

    assign irq = (x[X_BEAT_CNT] & 16'hc000) == 16'hc000;
    assign fiq = x[X_FIQ_ST] != 16'd0;

    // ------------------------------------------------------------------
    // Sample processing helpers (operate on the working copy)
    // ------------------------------------------------------------------
    // stop_channel's effect on the engine-held state
    task automatic eng_stop(input logic [3:0] c, input logic set_stop_bit);
        x[X_STATUS][c]   <= 1'b0;
        x[X_TONE_REL][c] <= 1'b0;
        x[X_RAMPDOWN][c] <= 1'b0;
        if (set_stop_bit) x[X_STOP][c] <= 1'b1;
        fiq_timer_on[c]  <= 1'b0;
    endtask

    always_ff @(posedge clk) begin
        ack        <= 1'b0;
        out_strobe <= 1'b0;
        pb_cwe     <= 1'b0;
        pb_pwe     <= 1'b0;

        if (reset) begin
            es <= E_IDLE;
            x <= '{default: 16'd0};
            x[X_REPEAT]   <= 16'h003f;
            x[X_ENV_MODE] <= 16'h003f;
            beat_curr <= 0;
            tick_div <= 0;
            tick_pending <= 0;
            pend_start <= 0; pend_stop <= 0; pend_ramp <= 0;
            fiq_timer_on <= 0;
            mem_req <= 1'b0;
            out_l <= 0; out_r <= 0;
            acc <= '{default: 19'd0}; shift <= '{default: 4'd0};
            ad_sig <= '{default: 17'sd0}; ad_step <= '{default: 7'd0};
            envclk_frame <= '{default: 27'h4040404};    // MAME memset(..., 4, ...)
            ramp_frame <= '{default: 17'd0}; env_addr <= '{default: 22'd0};
            a36_rem <= '{default: 4'd0}; a36_hdr <= '{default: 16'd0}; a36_prev <= '{default: 16'sd0};
        end else begin
            // 70312.5 Hz output / beat tick
            if (ce) begin
                if (tick_div == 9'd383) begin
                    tick_div     <= 0;
                    tick_pending <= 1'b1;
                end else
                    tick_div <= tick_div + 9'd1;
            end

            // ---------------- CPU register access ----------------
            if (pa_go) begin
                ack <= 1'b1;
                ack_src <= addr[10] ? ((addr[9:5] == 0) ? 2'd2 : 2'd3) : {1'b0, addr[9]};
                x_q <= x[addr[4:0]];
                if (we) begin
                    if (addr[10:9] == 2'b01 && !addr[8] && (addr[3:0] == P_PHASE_HIGH || addr[3:0] == P_PHASE))
                        acc[addr[7:4]] <= 19'd0;      // MAME: m_channel_rate_accum = 0
                    if (addr[10] && addr[9:5] == 5'd0) ctrl_write(addr[4:0], wdata);
                end
            end

            // ---------------- engine ----------------
            case (es)
            E_IDLE: begin
                if (pend_start != 0 || pend_stop != 0 || pend_ramp != 0) begin
                    ch <= 0;
                    es <= E_CMD;
                end else if (tick_pending && !(req && !ack)) begin
                    tick_pending <= 1'b0;
                    es <= E_TICK;
                end
            end

            // ---- queued start/stop/ramp-down commands ----
            E_CMD: begin
                if (pend_start[ch] || pend_stop[ch] || pend_ramp[ch]) begin
                    li <= 0;
                    load_cmd <= 1'b1;
                    pb_addr <= {1'b0, ch, 4'h0};
                    es <= E_LOAD;
                end else if (ch == 4'd15) es <= E_IDLE;
                else ch <= ch + 4'd1;
            end
            E_CMD_APPLY: begin
                if (pend_stop[ch]) begin                        // stop_channel
                    pb_addr  <= {1'b0, ch, C_MODE};
                    pb_wdata <= w[C_MODE] & 16'h7fff;
                    pb_cwe   <= 1'b1;
                    pend_stop[ch] <= 1'b0;
                end else if (pend_start[ch]) begin              // start_channel
                    env_addr[ch] <= {w[C_EADDR_HIGH][5:0], w[C_EADDR]};
                    ad_sig[ch]   <= 0;
                    ad_step[ch]  <= 0;
                    shift[ch]    <= 0;
                    if (w[C_ADPCM_SEL][15]) begin
                        a36_rem[ch] <= 0; a36_hdr[ch] <= 0; a36_prev[ch] <= 0;
                    end
                    pb_addr  <= {1'b0, ch, C_ENV_DATA};
                    pb_wdata <= {w[C_ENV1][7:0], 1'b0, w[C_ENV_DATA][6:0]};
                    pb_cwe   <= 1'b1;
                    pend_start[ch] <= 1'b0;
                end
                if (pend_ramp[ch] && !pend_stop[ch] && !pend_start[ch]) begin
                    ramp_frame[ch] <= ramp_count(w_ramp_clk[2:0]);
                    pend_ramp[ch]  <= 1'b0;
                end
                es <= E_CMD;
            end

            // ---- output sample tick ----
            E_TICK: begin
                beat_tick();
                mix_l <= 0;
                mix_r <= 0;
                ch <= 0;
                es <= E_CH;
            end
            E_CH: begin
                if (x[X_STATUS][ch]) begin
                    li <= 0;
                    load_cmd <= 1'b0;
                    pb_addr <= {1'b0, ch, 4'h0};
                    es <= E_LOAD;
                end else if (ch == 4'd15) es <= E_OUT;
                else ch <= ch + 4'd1;
            end
            E_LOAD: begin
                // creg 0..15 -> w[], preg PHASE_HIGH/RAMP_CLK/PHASE via the
                // same index stream (preg index = li for li in {0,3,4})
                if (li != 0) begin
                    w[li[3:0] - 4'd1] <= pb_cq;
                    case (li[3:0] - 4'd1)
                        P_PHASE_HIGH: w_phase_hi <= pb_pq;
                        P_RAMP_CLK:   w_ramp_clk <= pb_pq;
                        P_PHASE:      w_phase    <= pb_pq;
                        default: ;
                    endcase
                end
                if (li == 5'd16) es <= load_cmd ? E_CMD_APPLY : E_ADV;
                else pb_addr <= {1'b0, ch, li[3:0] + 4'd1};
                li <= li + 5'd1;
            end
            E_ADV: begin    // MAME advance_channel
                logic [21:0] s;
                s = {3'd0, acc[ch]} + {1'b0, w_phase_hi[2:0], w_phase, 2'b00};
                acc[ch] <= s[18:0];
                nfetch  <= s[21:19];
                playing <= 1'b1;
                wi      <= 3'd0;
                es <= (s[21:19] == 3'd0) ? E_MIX1 : E_FETCH;
            end

            E_FETCH: begin  // MAME fetch_sample, part 1
                w[C_WDATA_PREV] <= w[C_WDATA];
                if (fiq_timer_on[ch]) x[X_FIQ_ST][ch] <= 1'b1;
                if (w_a36 && w_tone != 0 && a36_rem[ch] == 0) begin
                    mem_req  <= 1'b1;
                    mem_addr <= w_waddr;
                    es <= E_RD_HDR;
                end else if (w_tone != 0) begin
                    mem_req  <= 1'b1;
                    mem_addr <= w_waddr;
                    es <= E_RD_RAW;
                end else begin
                    raw <= w[C_WDATA];
                    es  <= E_FETCH2;
                end
            end
            E_RD_HDR: if (mem_ack) begin
                logic [21:0] na;
                mem_req <= 1'b0;
                a36_hdr[ch] <= mem_rdata;
                a36_rem[ch] <= 4'd8;
                na = w_waddr + 22'd1;
                w[C_MODE][5:0]    <= na[21:16];
                w[C_WAVE_ADDR]    <= na[15:0];
                // raw sample at the incremented address
                mem_req  <= 1'b1;
                mem_addr <= na;
                es <= E_RD_RAW;
            end
            E_RD_RAW: if (mem_ack) begin
                mem_req <= 1'b0;
                raw <= mem_rdata;
                es  <= E_FETCH2;
            end
            E_FETCH2: begin  // MAME fetch_sample, part 2 + address advance
                logic stop_now, do_loop, clr_adpcm, advance_addr;
                logic [15:0] v;
                stop_now = 1'b0; do_loop = 1'b0; clr_adpcm = 1'b0; advance_addr = 1'b0;
                if (w_adpcm || w_a36) begin
                    if (w_tone != 0 && raw == 16'hffff) begin
                        if (w_tone == 2'd1) stop_now = 1'b1;
                        else begin do_loop = 1'b1; clr_adpcm = 1'b1; end
                    end else begin
                        logic [3:0]  nib;
                        logic [15:0] dec;
                        v   = raw >> shift[ch];
                        nib = v[3:0];
                        if (w_a36) adpcm36(ch, nib, dec);
                        else       ima(ch, nib, dec);
                        w[C_WDATA] <= dec;
                    end
                end else if (w_16bit) begin
                    if (w_tone != 0 && raw == 16'hffff) begin
                        if (w_tone == 2'd1) stop_now = 1'b1;
                        else do_loop = 1'b1;
                    end else
                        w[C_WDATA] <= raw;
                end else if (w_tone != 0) begin   // 8-bit
                    v = (shift[ch] != 0) ? (raw & 16'hff00) : (raw << 8);
                    v = v | (v >> 8);
                    if (v == 16'hffff) begin
                        if (w_tone == 2'd1) stop_now = 1'b1;
                        else do_loop = 1'b1;
                    end else
                        w[C_WDATA] <= v;
                end

                if (stop_now) begin
                    // ADPCM and 8-bit one-shots set the STOP bit; 16-bit doesn't
                    eng_stop(ch, !w_16bit || w_adpcm || w_a36);
                    w[C_MODE][15] <= 1'b0;
                    playing <= 1'b0;
                    es <= E_WB;
                end else begin
                    logic [21:0] a;
                    logic [4:0]  sh;
                    logic [15:0] m;
                    a  = do_loop ? w_laddr : w_waddr;
                    sh = do_loop ? 5'd0 : {1'b0, shift[ch]};
                    m  = w[C_MODE];
                    if (clr_adpcm) m[15] = 1'b0;
                    // advance (uses the mode after a loop cleared ADPCM)
                    if (m[15] || w_a36) begin
                        sh = sh + 5'd4;
                        if (sh >= 5'd16) begin
                            sh = 0; a = a + 22'd1;
                            if (w_a36) a36_rem[ch] <= a36_rem[ch] - 4'd1;
                        end
                    end else if (m[14]) begin
                        a = a + 22'd1;
                    end else begin
                        sh = sh + 5'd8;
                        if (sh >= 5'd16) begin sh = 0; a = a + 22'd1; end
                    end
                    shift[ch] <= sh[3:0];
                    m[5:0] = a[21:16];
                    w[C_MODE]      <= m;
                    w[C_WAVE_ADDR] <= a[15:0];
                    if (nfetch == 3'd1) es <= E_MIX1;
                    else begin
                        nfetch <= nfetch - 3'd1;
                        es <= E_FETCH;
                    end
                end
            end

            // MAME sound_stream_update, per channel, in three stages
            E_MIX1: begin   // interpolation: the two products
                logic signed [31:0] sm, p, lerp;
                sm   = 32'(signed'(w[C_WDATA] ^ 16'h8000));
                p    = 32'(signed'(w[C_WDATA_PREV] ^ 16'h8000));
                lerp = x[X_CONTROL][9] ? 32'sd256 : $signed({24'd0, acc[ch][18:11]});
                mp <= p * (32'sd256 - lerp);
                mq <= sm * lerp;
                es <= E_MIX1B;
            end
            E_MIX1B: begin
                ms <= (mq >>> 8) + (mp >>> 8);
                es <= E_MIX2;
            end
            E_MIX2: begin   // envelope level; pan factors
                logic signed [31:0] vol, pan;
                ms  <= (ms * $signed({25'd0, w_edd})) >>> 7;
                vol = $signed({25'd0, w[C_PAN_VOL][6:0]});
                pan = $signed({25'd0, w[C_PAN_VOL][14:8]});
                if (pan < 32'sd64) begin
                    pan_l <= 32'sd127 * vol;
                    pan_r <= pan * 32'sd2 * vol;
                end else begin
                    pan_l <= (32'sd127 - pan) * 32'sd2 * vol;
                    pan_r <= 32'sd127 * vol;
                end
                es <= E_MIX3;
            end
            E_MIX3: begin   // pan / volume products
                logic signed [31:0] s16;
                s16 = 32'(signed'(ms[15:0]));
                mp <= s16 * 32'(signed'(pan_l[15:0]));
                mq <= s16 * 32'(signed'(pan_r[15:0]));
                es <= E_MIX3B;
            end
            E_MIX3B: begin  // accumulate
                mix_l <= mix_l + (mp >>> 14);
                mix_r <= mix_r + (mq >>> 14);
                es <= E_ENV;
            end

            E_ENV: begin
                if (x[X_RAMPDOWN][ch]) begin
                    logic [16:0] f;
                    f = (ramp_frame[ch] > 0) ? ramp_frame[ch] - 17'd1 : 17'd0;
                    ramp_frame[ch] <= f;
                    if (f == 0) begin      // audio_rampdown_tick
                        logic [7:0] ne;
                        ne = {1'b0, w_edd} - {1'b0, w[C_ELOOP][15:9]};
                        if (ne > {1'b0, w_edd}) ne = 0;
                        if (ne != 0) begin
                            w[C_ENV_DATA][6:0] <= ne[6:0];
                            ramp_frame[ch] <= ramp_count(w_ramp_clk[2:0]);
                        end else begin
                            eng_stop(ch, 1'b1);
                            w[C_MODE][15] <= 1'b0;
                        end
                    end
                    es <= E_WB;
                end else if (!x[X_ENV_MODE][ch]) begin
                    logic [26:0] f;
                    f = (envclk_frame[ch] > 0) ? envclk_frame[ch] - 27'd1 : 27'd0;
                    envclk_frame[ch] <= f;
                    if (f == 0) begin
                        envclk_frame[ch] <= envclk_count(env_clock(ch));
                        env_tick();
                    end else
                        es <= E_WB;
                end else
                    es <= E_WB;
            end

            E_ENV_RD: if (mem_ack) begin
                mem_req <= 1'b0;
                case (env_rd_i)
                    2'd0: w[C_ENV0]  <= mem_rdata;
                    2'd1: w[C_ENV1]  <= mem_rdata;
                    default: w[C_ELOOP] <= mem_rdata;
                endcase
                if (env_rd_i == (env_rd_three ? 2'd2 : 2'd1)) begin
                    logic [15:0] env1;
                    env1 = (env_rd_i == 2'd1) ? mem_rdata : w[C_ENV1];
                    if (env_rd_three)
                        env_addr[ch] <= {w[C_EADDR_HIGH][5:0], w[C_EADDR]} + 22'(mem_rdata[8:0]);
                    else
                        env_addr[ch] <= env_addr[ch] + 22'd2;
                    // new_count = get_envelope_load() of the reloaded ENV1
                    w[C_ENV_DATA][15:8] <= env1[7:0];
                    es <= E_WB;
                end else begin
                    env_rd_i <= env_rd_i + 2'd1;
                    mem_req  <= 1'b1;
                    mem_addr <= env_addr[ch] + 22'(env_rd_i) + 22'd1;
                end
            end

            E_WB: begin     // write back the channel registers the engine modifies
                logic [3:0] r;
                case (wi)
                    3'd0: r = C_WAVE_ADDR;  3'd1: r = C_MODE;       3'd2: r = C_ENV0;  3'd3: r = C_ENV_DATA;
                    3'd4: r = C_ENV1;       3'd5: r = C_WDATA_PREV; 3'd6: r = C_ELOOP; default: r = C_WDATA;
                endcase
                pb_addr  <= {1'b0, ch, r};
                pb_wdata <= w[r];
                pb_cwe   <= 1'b1;
                wi <= wi + 3'd1;
                if (wi == 3'd7) begin
                    if (ch == 4'd15) es <= E_OUT;
                    else begin ch <= ch + 4'd1; es <= E_CH; end
                end
            end

            E_OUT: begin
                logic signed [31:0] l, r;
                l = mix_l;
                r = mix_r;
                if (x[X_WIN_L] != 0) l = l + 32'(x[X_WIN_L]) - 32'sd32768;
                if (x[X_WIN_R] != 0) r = r + 32'(x[X_WIN_R]) - 32'sd32768;
                if (x[X_CONTROL][7:6] == 2'd0) begin l = l >>> 4; r = r >>> 4; end
                else                            begin l = l >>> 2; r = r >>> 2; end
                ml <= l;
                mr <= r;
                es <= E_OUT2;
            end
            E_OUT2: begin
                logic signed [31:0] l, r;
                l = (ml * 32'(signed'(x[X_MAINVOL]))) >>> 7;
                r = (mr * 32'(signed'(x[X_MAINVOL]))) >>> 7;
                out_l <= l[15:0];
                out_r <= r[15:0];
                out_strobe <= 1'b1;
                es <= E_IDLE;
            end

            default: es <= E_IDLE;
            endcase
        end
    end

    // MAME audio_envelope_tick (reached with envclk_frame expired)
    task automatic env_tick;
        logic [15:0] cnt, ne, tgt, inc, curr;
        logic stopped;
        stopped = 1'b0;
        cnt  = {8'd0, w[C_ENV_DATA][15:8]};
        curr = {9'd0, w_edd};
        if (cnt > 0) begin
            cnt = cnt - 16'd1;
            w[C_ENV_DATA][15:8] <= cnt[7:0];
        end
        es <= E_WB;
        if (cnt == 0) begin
            tgt = {9'd0, w[C_ENV0][14:8]};
            inc = {9'd0, w[C_ENV0][6:0]};
            ne  = curr;
            if (ne != tgt) begin
                if (w[C_ENV0][7]) begin
                    ne = ne - inc;
                    if (ne > curr)     ne = 0;
                    else if (ne < tgt) ne = tgt;
                    if (ne == 0) begin
                        eng_stop(ch, 1'b1);
                        w[C_MODE][15] <= 1'b0;
                        stopped = 1'b1;
                    end
                end else begin
                    ne = ne + inc;
                    if (ne >= tgt) ne = tgt;
                end
            end
            if (!stopped) begin
                if (ne == tgt) begin
                    if (w[C_ENV1][8]) begin
                        logic [15:0] rc;
                        rc = {9'd0, w[C_ENV1][15:9]} - 16'd1;
                        if (rc == 0) begin
                            env_rd_i     <= 0;
                            env_rd_three <= 1'b1;
                            mem_req      <= 1'b1;
                            mem_addr     <= env_addr[ch];
                            es <= E_ENV_RD;
                        end else begin
                            w[C_ENV1][15:9]     <= rc[6:0];
                            w[C_ENV_DATA][15:8] <= w[C_ENV1][7:0];
                        end
                    end else begin
                        env_rd_i     <= 0;
                        env_rd_three <= 1'b0;
                        mem_req      <= 1'b1;
                        mem_addr     <= env_addr[ch];
                        es <= E_ENV_RD;
                    end
                end else
                    w[C_ENV_DATA][15:8] <= w[C_ENV1][7:0];
                w[C_ENV_DATA][6:0] <= ne[6:0];
            end
        end
    endtask

    // MAME ima_adpcm_state::clock; `o` is the sample ^ 0x8000
    task automatic ima(input logic [3:0] c, input logic [3:0] nib, output logic [15:0] o);
        logic [14:0] sv;
        logic signed [17:0] d, s;
        logic signed [7:0] st;
        sv = ima_step(ad_step[c]);
        d  = 18'(sv >> 3);
        if (nib[2]) d = d + 18'(sv);
        if (nib[1]) d = d + 18'(sv >> 1);
        if (nib[0]) d = d + 18'(sv >> 2);
        if (nib[3]) d = -d;
        s = 18'(ad_sig[c]) + d;
        if (s > 18'sd32767)       s = 18'sd32767;
        else if (s < -18'sd32768) s = -18'sd32768;
        ad_sig[c] <= 17'(s);
        st = 8'(ad_step[c]) + (nib[2] ? (nib[1:0] == 2'd0 ? 8'sd2 : nib[1:0] == 2'd1 ? 8'sd4 : nib[1:0] == 2'd2 ? 8'sd6 : 8'sd8) : -8'sd1);
        if (st > 8'sd88)     st = 8'sd88;
        else if (st < 8'sd0) st = 8'sd0;
        ad_step[c] <= st[6:0];
        o = s[15:0] ^ 16'h8000;
    endtask

    // MAME decode_adpcm36_nybble
    task automatic adpcm36(input logic [3:0] c, input logic [3:0] nib, output logic [15:0] o);
        logic [3:0]  sh;
        logic signed [15:0] f0, sd;
        logic signed [31:0] acc36;
        sh = a36_hdr[c][3:0];
        f0 = 16'(signed'(a36_hdr[c][9:4]));
        sd = signed'({nib, 12'd0});
        acc36 = (32'(signed'(a36_prev[c])) * 32'(f0) + 32'sd32) >>> 12;
        sd = 16'((32'(sd) >>> sh) + acc36);
        a36_prev[c] <= sd;
        o = sd ^ 16'h8000;
    endtask

    // MAME audio_beat_tick
    task automatic beat_tick;
        logic [10:0] cur;
        cur = beat_curr;
        if (cur > 0) cur = cur - 11'd1;
        if (cur == 0) begin
            logic [13:0] bc;
            cur = x[X_BEAT_BASE][10:0];
            bc  = x[X_BEAT_CNT][13:0];
            if (bc > 0) begin
                bc = bc - 14'd1;
                x[X_BEAT_CNT][13:0] <= bc;
            end
            if (bc == 0 && x[X_BEAT_CNT][15]) x[X_BEAT_CNT][14] <= 1'b1;
        end
        beat_curr <= cur;
    endtask

    // MAME audio_ctrl_w (control regs 0x00-0x1F)
    task automatic ctrl_write(input logic [4:0] o, input logic [15:0] d);
        logic [26:0] tmp [0:15];
        case (o)
            X_ENABLE: begin
                logic [15:0] chg, st, sp;
                chg = x[X_ENABLE] ^ d;
                st  = chg &  d & ~x[X_STOP] & ~x[X_STATUS];     // start_channel
                sp  = chg & ~d &  x[X_STATUS];                  // stop_channel
                x[X_ENABLE] <= d;
                start(st);
                x[X_STATUS]   <= (x[X_STATUS] | st) & ~sp;
                x[X_TONE_REL] <= x[X_TONE_REL] & ~sp;
                x[X_RAMPDOWN] <= x[X_RAMPDOWN] & ~sp;
                fiq_timer_on  <= (fiq_timer_on & ~sp & ~st) | (st & x[X_FIQ_EN]);
                pend_stop     <= (pend_stop | sp) & ~st;
            end
            X_MAINVOL:   x[o] <= d & 16'h007f;
            X_FIQ_ST:    x[o] <= x[o] & ~d;
            X_BEAT_BASE: begin x[o] <= d & 16'h07ff; beat_curr <= d[10:0]; end
            X_BEAT_CNT:  x[o] <= ((x[o] & ~(d & 16'h4000)) & 16'h4000) | (d & ~16'h4000);
            X_ENVCLK0, X_ENVCLK1: begin
                logic [15:0] chg;
                logic [3:0]  base;
                chg  = x[o] ^ d;
                base = (o == X_ENVCLK0) ? 4'd0 : 4'd8;
                x[o] <= d;
                tmp = envclk_frame;
                for (int i = 0; i < 4; i++)
                    if (chg[i*4 +: 4] != 0) tmp[base + 4'(i)] = envclk_count(d[i*4 +: 4]);
                envclk_frame <= tmp;
            end
            X_ENVCLK0H, X_ENVCLK1H: begin
                // MAME sets frame[ch + 4] from the clock of channel ch (the
                // low register): reproduced as-is
                logic [15:0] chg, lo;
                logic [3:0]  base;
                chg  = x[o] ^ d;
                base = (o == X_ENVCLK0H) ? 4'd0 : 4'd8;
                lo   = (o == X_ENVCLK0H) ? x[X_ENVCLK0] : x[X_ENVCLK1];
                x[o] <= d;
                tmp = envclk_frame;
                for (int i = 0; i < 4; i++)
                    if (chg[i*4 +: 4] != 0) tmp[base + 4'(i) + 4'd4] = envclk_count(lo[i*4 +: 4]);
                envclk_frame <= tmp;
            end
            X_RAMPDOWN: begin
                logic [15:0] nv, chg;
                nv  = d & x[X_STATUS];
                chg = x[o] ^ nv;
                x[o] <= nv;
                pend_ramp <= pend_ramp | (chg & d);
            end
            X_STOP: begin
                logic [15:0] nv, chg, st;
                nv  = x[o] & ~d;
                chg = x[o] ^ nv;
                st  = chg & x[X_ENABLE] & ~x[X_STATUS];
                x[o] <= nv;
                start(st);
                x[X_STATUS]  <= x[X_STATUS] | st;
                fiq_timer_on <= (fiq_timer_on & ~st) | (st & x[X_FIQ_EN]);
            end
            X_CONTROL:   x[o] <= d & 16'h9fe8;
            X_STATUS:    ;
            X_ENV_IRQ:   x[o] <= x[o] & ~d;
            X_EQ_C10, X_EQ_C32, X_EQ_G10, X_EQ_G32: x[o] <= d & 16'h7f7f;
            default:     x[o] <= d;
        endcase
    endtask

    // start_channel (for a mask of channels): the status bits are set by the
    // caller, the register work is queued for the engine
    task automatic start(input logic [15:0] m);
        pend_start <= pend_start | m;
    endtask

endmodule
