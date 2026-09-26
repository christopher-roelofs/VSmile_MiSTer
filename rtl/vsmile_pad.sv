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
//   - input changes send 0x80/0x87/0x8F (up/down), 0xC0/0xC7/0xCF
//     (left/right), 0x90|colours, 0xA0-0xA4 (buttons)
//
// Each clk applies that clk's events in a fixed order to local copies of the
// state, calling the same helpers as MAME's C++ in the same sequence.

module vsmile_pad (
    input  logic       clk,
    input  logic       reset,
    input  logic       ce,              // 27 MHz tick (timer base)

    input  logic [3:0] joy,             // up, down, left, right
    input  logic [3:0] colors,          // green, blue, yellow, red
    input  logic [3:0] buttons,         // ok, quit, help, abc

    input  logic       select,          // from console (port C)
    input  logic       rx_valid,        // byte from the console UART
    input  logic [7:0] rx_data,
    output logic       tx_valid,        // byte to the console UART
    output logic [7:0] tx_data,
    output logic       rts,
    output logic       rts_evt          // rts_out() was called this clk
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
    logic [3:0]  sent_joy, sent_colors, sent_buttons;
    logic [6:0]  stale;
    logic        active;
    logic [7:0]  probe0, probe1;
    logic [24:0] tx_t, rts_t, idle_t;      // remaining ticks, 0 = not running
    logic [3:0]  joy_q, colors_q, buttons_q;

    // local working copies
    logic [7:0]  v_fifo [0:31];
    logic [4:0]  v_head, v_tail;
    logic        v_empty, v_tx_active, v_sel, v_rts, v_rts_evt;
    logic [3:0]  v_sent_joy, v_sent_colors, v_sent_buttons;
    logic [6:0]  v_stale;
    logic        v_active;
    logic [7:0]  v_probe0, v_probe1;
    logic [24:0] v_tx_t, v_rts_t, v_idle_t;
    logic        v_out_valid;
    logic [7:0]  v_out;

    // vsmile_ctrl_device_base::queue_tx
    task automatic queue_tx(input logic [7:0] d);
        logic was_empty;
        was_empty = v_empty;
        if (!was_empty && v_head == v_tail) return;    // overrun: drop
        v_fifo[v_tail] = d;
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
    endtask

    // vsmile_pad_device::uart_tx_fifo_push
    task automatic push(input logic [7:0] d);
        v_idle_t = 25'd0;
        queue_tx(d);
    endtask

    function automatic logic [7:0] ud_code(input logic [3:0] j);
        return j[0] ? 8'h87 : j[1] ? 8'h8f : 8'h80;
    endfunction
    function automatic logic [7:0] lr_code(input logic [3:0] j);
        return j[2] ? 8'hcf : j[3] ? 8'hc7 : 8'hc0;
    endfunction

    // vsmile_pad_device::tx_complete
    task automatic tx_complete;
        if ((v_stale & ST_JOY) != 0) begin
            v_sent_joy = joy;
            if ((v_stale & ST_UD) != 0) push(ud_code(joy));
            if ((v_stale & ST_LR) != 0) push(lr_code(joy));
        end
        if ((v_stale & ST_COLORS) != 0) begin
            v_sent_colors = colors;
            push({4'h9, colors});
        end
        if ((v_stale & ST_BUTTONS) != 0) begin
            v_sent_buttons = buttons;
            if ((v_stale & ST_OK)   != 0 && buttons[0]) push(8'ha1);
            if ((v_stale & ST_QUIT) != 0 && buttons[1]) push(8'ha2);
            if ((v_stale & ST_HELP) != 0 && buttons[2]) push(8'ha3);
            if ((v_stale & ST_ABC)  != 0 && buttons[3]) push(8'ha4);
            if (buttons == 4'd0) push(8'ha0);
        end
        v_idle_t = 25'(IDLE_PERIOD);
        v_active = 1'b1;
        v_stale  = 7'd0;
    endtask

    // vsmile_pad_device::tx_timeout
    task automatic tx_timeout;
        if (v_active) begin
            v_idle_t  = 25'd0;
            v_active  = 1'b0;
            v_stale   = ST_ALL;
            v_probe0  = 8'd0;
            v_probe1  = 8'd0;
        end
        push(8'h55);
    endtask

    always_ff @(posedge clk) begin
        tx_valid <= 1'b0;
        rts_evt  <= 1'b0;
        if (reset) begin
            head <= 0; tail <= 0; empty <= 1'b1; tx_active <= 1'b0; sel <= 1'b0; rts <= 1'b0;
            sent_joy <= 0; sent_colors <= 0; sent_buttons <= 0;
            stale <= ST_ALL; active <= 1'b0; probe0 <= 0; probe1 <= 0;
            tx_t <= 0; rts_t <= 0; idle_t <= 25'(IDLE_PERIOD);   // device_start
            joy_q <= 0; colors_q <= 0; buttons_q <= 0;
        end else begin
            v_fifo = fifo; v_head = head; v_tail = tail; v_empty = empty;
            v_tx_active = tx_active; v_sel = sel; v_rts = rts;
            v_sent_joy = sent_joy; v_sent_colors = sent_colors; v_sent_buttons = sent_buttons;
            v_stale = stale; v_active = active; v_probe0 = probe0; v_probe1 = probe1;
            v_tx_t = tx_t; v_rts_t = rts_t; v_idle_t = idle_t;
            v_out_valid = 1'b0; v_out = 8'd0; v_rts_evt = 1'b0;

            // ---- byte from the console: rx_complete ----
            if (rx_valid && v_sel && (rx_data[7:4] == 4'h7 || rx_data[7:4] == 4'hb)) begin
                v_probe0 = (rx_data[7:4] == 4'h7) ? 8'd0 : v_probe1;
                v_probe1 = rx_data;
                push({4'hb, (4'(v_probe0 + v_probe1 + 8'h0f)) ^ 4'h5});
            end

            // ---- select line: select_w ----
            if (select != v_sel) begin
                if (select && !v_empty && !v_tx_active) begin
                    v_rts_t     = 25'd0;
                    v_tx_active = 1'b1;
                    v_tx_t      = 25'(TX_PERIOD);
                end
                v_sel = select;
            end

            // ---- timers ----
            if (ce) begin
                if (v_tx_t != 0) begin
                    v_tx_t = v_tx_t - 25'd1;
                    if (v_tx_t == 0) begin   // tx_timer_expired
                        v_out_valid = 1'b1;
                        v_out       = v_fifo[v_head];
                        v_head      = v_head + 5'd1;
                        if (v_head == v_tail) v_empty = 1'b1;
                        if (v_empty) tx_complete();
                        if (v_empty) begin
                            v_tx_active = 1'b0;
                            v_rts       = 1'b0; v_rts_evt = 1'b1;
                        end else if (v_sel)
                            v_tx_t = 25'(TX_PERIOD);
                        else
                            v_tx_active = 1'b0;
                    end
                end
                if (v_rts_t != 0) begin
                    v_rts_t = v_rts_t - 25'd1;
                    if (v_rts_t == 0 && !v_empty) begin   // rts_timer_expired
                        v_head  = 5'd0;
                        v_tail  = 5'd0;
                        v_empty = 1'b1;
                        tx_timeout();
                        if (v_empty) begin v_rts = 1'b0; v_rts_evt = 1'b1; end
                    end
                end
                if (v_idle_t != 0) begin
                    v_idle_t = v_idle_t - 25'd1;
                    if (v_idle_t == 0) queue_tx(8'h55);   // handle_idle
                end
            end

            // ---- input changes (PORT_CHANGED_MEMBER handlers) ----
            if (joy != joy_q && v_active) begin
                if (!v_empty) begin
                    if ((joy ^ joy_q) & 4'b0011) v_stale = v_stale | ST_UD;
                    if ((joy ^ joy_q) & 4'b1100) v_stale = v_stale | ST_LR;
                end else begin
                    if ((joy ^ v_sent_joy) & 4'b0011) push(ud_code(joy));
                    if ((joy ^ v_sent_joy) & 4'b1100) push(lr_code(joy));
                    v_sent_joy = joy;
                end
            end
            if (colors != colors_q && v_active) begin
                if (!v_empty) v_stale = v_stale | ST_COLORS;
                else begin
                    v_sent_colors = colors;
                    push({4'h9, colors});
                end
            end
            if (buttons != buttons_q && v_active) begin
                if (!v_empty)
                    v_stale = v_stale | ({3'd0, buttons ^ buttons_q} << 3);
                else begin
                    logic [3:0] rise;
                    rise = (v_sent_buttons ^ buttons) & buttons;
                    if (rise[0]) push(8'ha1);
                    if (rise[1]) push(8'ha2);
                    if (rise[2]) push(8'ha3);
                    if (rise[3]) push(8'ha4);
                    if (buttons == 4'd0) push(8'ha0);
                    v_sent_buttons = buttons;
                end
            end
            joy_q <= joy; colors_q <= colors; buttons_q <= buttons;

            fifo <= v_fifo; head <= v_head; tail <= v_tail; empty <= v_empty;
            tx_active <= v_tx_active; sel <= v_sel; rts <= v_rts;
            sent_joy <= v_sent_joy; sent_colors <= v_sent_colors; sent_buttons <= v_sent_buttons;
            stale <= v_stale; active <= v_active; probe0 <= v_probe0; probe1 <= v_probe1;
            tx_t <= v_tx_t; rts_t <= v_rts_t; idle_t <= v_idle_t;
            tx_valid <= v_out_valid;
            rts_evt  <= v_rts_evt;
            tx_data  <= v_out;
        end
    end

endmodule
