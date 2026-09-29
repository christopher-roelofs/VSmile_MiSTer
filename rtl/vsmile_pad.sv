// V.Smile joystick (high-level model of the pad's microcontroller).
//
// Follows MAME vsmile_ctrl_device_base + vsmile_pad_device
// (src/devices/bus/vsmile/vsmile_ctrl.cpp, pad.cpp):
//   - bytes queue in a 32-entry FIFO and go out at 960 bytes/s while the
//     console asserts select; RTS is raised while there is data to send
//   - if the console does not select within 500 ms the queue is dropped and
//     a 0x55 keep-alive is queued instead (the pad goes inactive)
//   - 1 s without traffic queues a 0x55 keep-alive
//   - probe bytes 0x7x/0xBx from the console are answered with 0xBx
//   - input changes send 0x80/0x83-0x87/0x8B-0x8F (centre/up/down) and
//     0xC0/0xC3-0xC7/0xCB-0xCF (centre/right/left), 0x90|colours, 0xA0-0xA4
//     (buttons).  The real stick has five levels per direction (x3 slight
//     ... x7 full, vtech.pulkomandy.tk); MAME's pad only sends full, which
//     is what a level of 0 gives here.  The joystick state is compared as
//     these codes (MAME compares direction bits: the same for full levels).
//
// Structure: an event may want to queue up to eight bytes (MAME does it in
// one call).  They are staged in fixed slots and a drain writes one per step
// into the FIFO (the only FIFO write port).  Timers keep running while slots
// drain; input/console events wait, and a timer whose action would reuse a
// pending slot is held for a step (at most 8 steps against a 1 ms byte time).
//
// The model steps only on `ce` (the 27 MHz tick all its timers count), so
// its internal paths are 4-clk multicycle paths (see VSmile.sdc).  Inputs
// are resampled on `ce` and a console byte is held until the next step.

module vsmile_pad (
    input  logic       clk,
    input  logic       reset,
    input  logic       ce,              // 27 MHz tick (timer base)

    input  logic [3:0] joy,             // up, down, left, right
    input  logic [2:0] ud_level,        // 3..7 (0: full, 7) for up/down
    input  logic [2:0] lr_level,        // 3..7 (0: full, 7) for left/right
    input  logic [3:0] colors,          // green, blue, yellow, red
    input  logic [3:0] buttons,         // ok, quit, help, abc
    input  logic       lr_first,        // Gym Mat: its left/right byte goes before up/down

    input  logic       select,          // from console (port C)
    input  logic       rx_valid,        // byte from the console UART
    input  logic [7:0] rx_data,
    output logic       tx_valid,        // byte to the console UART
    output logic [7:0] tx_data,
    output logic       rts,
    output logic       rts_evt,         // rts_out() was called this clk
    output logic [63:0] dbg,            // state snapshot for the OSD debug screen
    output logic [6:0]  dbg_stale
);

    localparam int unsigned TX_PERIOD   = 27_000_000 / 960;  // 28125
    localparam int unsigned RTS_TIMEOUT = 27_000_000 / 2;    // 500 ms
    localparam int unsigned IDLE_PERIOD = 27_000_000;        // 1 s

    localparam logic [6:0] ST_LR = 7'h01, ST_UD = 7'h02, ST_COLORS = 7'h04,
                           ST_OK = 7'h08, ST_QUIT = 7'h10, ST_HELP = 7'h20, ST_ABC = 7'h40,
                           ST_JOY = 7'h03, ST_BUTTONS = 7'h78, ST_ALL = 7'h7f;

    // ------------------------------------------------------------------
    // State (MAME member variables)
    // ------------------------------------------------------------------
    logic [7:0]  fifo [0:31];
    logic [4:0]  head, tail;
    logic        empty, tx_active, sel;
    logic [7:0]  sent_ud, sent_lr;
    logic [3:0]  sent_colors, sent_buttons;
    logic [6:0]  stale;
    logic        active;
    logic [7:0]  probe0, probe1;
    logic [24:0] tx_t, rts_t, idle_t;      // remaining ticks, 0 = not running
    logic [7:0]  ud_q, lr_q;
    logic [3:0]  colors_q, buttons_q;

    // staged bytes: slot 0 up/down, 1 left/right, 2 colours, 3-6 buttons
    // A1..A4, 7 A0 / probe reply / keep-alive
    logic [7:0]  slot [0:7];
    logic [7:0]  slot_v;
    wire         busy = (slot_v != 8'd0);

    // console byte: caught on any clk, presented on the next step
    logic        rx_seen, rx_pend;
    logic [7:0]  rx_seen_data, rx_pend_data;
    // inputs resampled on ce
    logic        sel_c;
    logic [3:0]  joy_c, colors_c, buttons_c;
    logic [2:0]  udl_c, lrl_c;

    // working copies for the event block
    logic [4:0]  v_head, v_tail;
    logic        v_empty, v_tx_active, v_sel, v_rts, v_rts_evt;
    logic [7:0]  v_sent_ud, v_sent_lr;
    logic [3:0]  v_sent_colors, v_sent_buttons;
    logic [6:0]  v_stale;
    logic        v_active;
    logic [7:0]  v_probe0, v_probe1;
    logic [24:0] v_tx_t, v_rts_t, v_idle_t;
    logic        v_out_valid;
    logic [7:0]  v_out;
    logic [7:0]  s_v;                       // slots set this step
    logic [7:0]  v_slot;                    // pending slots after this step's drain
    logic [7:0]  s_d [0:7];
    logic        s_idle_reset;              // uart_tx_fifo_push resets the idle timer

    // MAME uart_tx_fifo_push: stage a byte (slot k), idle timer reset
    task automatic push(input int k, input logic [7:0] d);
        s_v[k] = 1'b1;
        s_d[k] = d;
        s_idle_reset = 1'b1;
    endtask

    function automatic logic [7:0] ud_code(input logic [3:0] j, input logic [2:0] l);
        logic [2:0] v;
        v = (l == 3'd0) ? 3'd7 : l;
        return j[0] ? {5'b10000, v} : j[1] ? {5'b10001, v} : 8'h80;
    endfunction
    function automatic logic [7:0] lr_code(input logic [3:0] j, input logic [2:0] l);
        logic [2:0] v;
        v = (l == 3'd0) ? 3'd7 : l;
        return j[2] ? {5'b11001, v} : j[3] ? {5'b11000, v} : 8'hc0;
    endfunction
    wire [7:0] cur_ud = ud_code(joy_c, udl_c);
    wire [7:0] cur_lr = lr_code(joy_c, lrl_c);

    // vsmile_pad_device::tx_complete
    task automatic tx_complete;
        if ((v_stale & ST_JOY) != 0) begin
            v_sent_ud = cur_ud;
            v_sent_lr = cur_lr;
            if ((v_stale & ST_UD) != 0) push(lr_first ? 1 : 0, cur_ud);
            if ((v_stale & ST_LR) != 0) push(lr_first ? 0 : 1, cur_lr);
        end
        if ((v_stale & ST_COLORS) != 0) begin
            v_sent_colors = colors_c;
            push(2, {4'h9, colors_c});
        end
        if ((v_stale & ST_BUTTONS) != 0) begin
            v_sent_buttons = buttons_c;
            if ((v_stale & ST_OK)   != 0 && buttons_c[0]) push(3, 8'ha1);
            if ((v_stale & ST_QUIT) != 0 && buttons_c[1]) push(4, 8'ha2);
            if ((v_stale & ST_HELP) != 0 && buttons_c[2]) push(5, 8'ha3);
            if ((v_stale & ST_ABC)  != 0 && buttons_c[3]) push(6, 8'ha4);
            if (buttons_c == 4'd0) push(7, 8'ha0);
        end
        v_idle_t = 25'(IDLE_PERIOD);
        v_active = 1'b1;
        v_stale  = 7'd0;
    endtask

    // vsmile_pad_device::tx_timeout
    task automatic tx_timeout;
        if (v_active) begin
            v_idle_t = 25'd0;
            v_active = 1'b0;
            v_stale  = ST_ALL;
            v_probe0 = 8'd0;
            v_probe1 = 8'd0;
        end
        push(7, 8'h55);
    endtask

    assign dbg_stale = stale;
    assign dbg = {idle_t[24:9], rts_t[24:9], tx_t[24:9],
                  active, sel, empty, tx_active, rts, 1'b0, head[4:0], tail[4:0]};

    always_ff @(posedge clk) begin
        if (reset) rx_seen <= 1'b0;
        else if (rx_valid) begin rx_seen <= 1'b1; rx_seen_data <= rx_data; end
        else if (ce) rx_seen <= 1'b0;
        if (ce) begin
            sel_c <= select; joy_c <= joy; colors_c <= colors; buttons_c <= buttons;
            udl_c <= ud_level; lrl_c <= lr_level;
        end
    end

    always_ff @(posedge clk) begin
        tx_valid <= 1'b0;   // one-clk pulses, set on a step
        rts_evt  <= 1'b0;
        if (reset) begin
            head <= 0; tail <= 0; empty <= 1'b1; tx_active <= 1'b0; sel <= 1'b0; rts <= 1'b0;
            sent_ud <= 8'h80; sent_lr <= 8'hc0; sent_colors <= 0; sent_buttons <= 0;
            stale <= ST_ALL; active <= 1'b0; probe0 <= 0; probe1 <= 0;
            tx_t <= 0; rts_t <= 0; idle_t <= 25'(IDLE_PERIOD);   // device_start
            ud_q <= 8'h80; lr_q <= 8'hc0; colors_q <= 0; buttons_q <= 0;
            slot_v <= 8'd0; rx_pend <= 1'b0;
            tx_valid <= 1'b0; rts_evt <= 1'b0;
        end else if (!ce) begin
            // step only on the 27 MHz tick
        end else begin
            // ---- one step: drain a staged byte, then the events ----
            logic        rxv;
            logic [7:0]  rxd;
            v_head = head; v_tail = tail; v_empty = empty;
            v_tx_active = tx_active; v_sel = sel; v_rts = rts; v_rts_evt = 1'b0;
            v_sent_ud = sent_ud; v_sent_lr = sent_lr; v_sent_colors = sent_colors; v_sent_buttons = sent_buttons;
            v_stale = stale; v_active = active; v_probe0 = probe0; v_probe1 = probe1;
            v_tx_t = tx_t; v_rts_t = rts_t; v_idle_t = idle_t;
            v_out_valid = 1'b0; v_out = 8'd0;
            s_v = 8'd0; s_idle_reset = 1'b0;
            for (int i = 0; i < 8; i++) s_d[i] = 8'd0;
            v_slot = slot_v;

            // drain one staged byte into the FIFO (MAME queue_tx)
            if (v_slot != 8'd0) begin
                int k;
                logic was_empty;
                k = 0;
                for (int i = 7; i >= 0; i--) if (v_slot[i]) k = i;
                v_slot[k] = 1'b0;
                was_empty = v_empty;
                if (was_empty || v_head != v_tail) begin      // else overrun: drop
                    fifo[v_tail] <= slot[k];
                    v_tail  = v_tail + 5'd1;
                    v_empty = 1'b0;
                    if (was_empty) begin
                        v_rts = 1'b1; v_rts_evt = 1'b1;
                        if (v_sel) begin
                            v_tx_active = 1'b1;
                            v_tx_t      = 25'(TX_PERIOD);
                        end else
                            v_rts_t = 25'(RTS_TIMEOUT);
                    end
                end
            end

            // console byte / inputs wait while slots are pending
            rxv = (rx_seen || rx_pend) && v_slot == 8'd0;
            rxd = rx_pend ? rx_pend_data : rx_seen_data;
            if (v_slot == 8'd0) rx_pend <= 1'b0;
            else if (rx_seen) begin rx_pend <= 1'b1; rx_pend_data <= rx_seen_data; end

            // byte from the console: rx_complete
            if (rxv && v_sel && (rxd[7:4] == 4'h7 || rxd[7:4] == 4'hb)) begin
                v_probe0 = (rxd[7:4] == 4'h7) ? 8'd0 : v_probe1;
                v_probe1 = rxd;
                push(7, {4'hb, (4'(v_probe0 + v_probe1 + 8'h0f)) ^ 4'h5});
            end

            // select line: select_w
            if (sel_c != v_sel && v_slot == 8'd0) begin
                if (sel_c && !v_empty && !v_tx_active) begin
                    v_rts_t     = 25'd0;
                    v_tx_active = 1'b1;
                    v_tx_t      = 25'(TX_PERIOD);
                end
                v_sel = sel_c;
            end

            // timers (one tick per step)
            begin
                if (v_tx_t != 0 && !(v_tx_t == 25'd1 && v_slot != 8'd0)) begin
                    v_tx_t = v_tx_t - 25'd1;
                    if (v_tx_t == 0) begin   // tx_timer_expired
                        v_out_valid = 1'b1;
                        v_out       = fifo[v_head];
                        v_head      = v_head + 5'd1;
                        if (v_head == v_tail) v_empty = 1'b1;
                        if (v_empty) tx_complete();
                        if (v_empty && s_v == 8'd0 && v_slot == 8'd0) begin
                            v_tx_active = 1'b0;
                            v_rts       = 1'b0; v_rts_evt = 1'b1;
                        end else if (v_sel)
                            v_tx_t = 25'(TX_PERIOD);
                        else
                            v_tx_active = 1'b0;
                    end
                end
                if (v_rts_t != 0 && !(v_rts_t == 25'd1 && v_slot[7])) begin
                    v_rts_t = v_rts_t - 25'd1;
                    if (v_rts_t == 0 && !v_empty) begin   // rts_timer_expired
                        v_head  = 5'd0;
                        v_tail  = 5'd0;
                        v_empty = 1'b1;
                        tx_timeout();
                        if (v_empty && s_v == 8'd0 && v_slot == 8'd0) begin v_rts = 1'b0; v_rts_evt = 1'b1; end
                    end
                end
                if (v_idle_t != 0 && !(v_idle_t == 25'd1 && v_slot[7])) begin
                    v_idle_t = v_idle_t - 25'd1;
                    if (v_idle_t == 0) begin s_v[7] = 1'b1; s_d[7] = 8'h55; end   // handle_idle: queue_tx
                end
            end

            // input changes (PORT_CHANGED_MEMBER handlers)
            if (v_slot == 8'd0) begin
            if ((cur_ud != ud_q || cur_lr != lr_q) && v_active) begin
                if (!v_empty) begin
                    if (cur_ud != ud_q) v_stale = v_stale | ST_UD;
                    if (cur_lr != lr_q) v_stale = v_stale | ST_LR;
                end else begin
                    if (cur_ud != v_sent_ud) push(lr_first ? 1 : 0, cur_ud);
                    if (cur_lr != v_sent_lr) push(lr_first ? 0 : 1, cur_lr);
                    v_sent_ud = cur_ud;
                    v_sent_lr = cur_lr;
                end
            end
            if (colors_c != colors_q && v_active) begin
                if (!v_empty) v_stale = v_stale | ST_COLORS;
                else begin
                    v_sent_colors = colors_c;
                    push(2, {4'h9, colors_c});
                end
            end
            if (buttons_c != buttons_q && v_active) begin
                if (!v_empty)
                    v_stale = v_stale | ({3'd0, buttons_c ^ buttons_q} << 3);
                else begin
                    logic [3:0] rise;
                    rise = (v_sent_buttons ^ buttons_c) & buttons_c;
                    if (rise[0]) push(3, 8'ha1);
                    if (rise[1]) push(4, 8'ha2);
                    if (rise[2]) push(5, 8'ha3);
                    if (rise[3]) push(6, 8'ha4);
                    if (buttons_c == 4'd0) push(7, 8'ha0);
                    v_sent_buttons = buttons_c;
                end
            end
            ud_q <= cur_ud; lr_q <= cur_lr; colors_q <= colors_c; buttons_q <= buttons_c;
            end

            if (s_idle_reset) v_idle_t = 25'd0;

            head <= v_head; tail <= v_tail; empty <= v_empty;
            tx_active <= v_tx_active; sel <= v_sel; rts <= v_rts; rts_evt <= v_rts_evt;
            sent_ud <= v_sent_ud; sent_lr <= v_sent_lr; sent_colors <= v_sent_colors; sent_buttons <= v_sent_buttons;
            stale <= v_stale; active <= v_active; probe0 <= v_probe0; probe1 <= v_probe1;
            tx_t <= v_tx_t; rts_t <= v_rts_t; idle_t <= v_idle_t;
            tx_valid <= v_out_valid;
            tx_data  <= v_out;
            slot_v   <= v_slot | s_v;
            if (s_v[0]) slot[0] <= s_d[0];
            if (s_v[1]) slot[1] <= s_d[1];
            if (s_v[2]) slot[2] <= s_d[2];
            if (s_v[3]) slot[3] <= s_d[3];
            if (s_v[4]) slot[4] <= s_d[4];
            if (s_v[5]) slot[5] <= s_d[5];
            if (s_v[6]) slot[6] <= s_d[6];
            if (s_v[7]) slot[7] <= s_d[7];
        end
    end

endmodule
