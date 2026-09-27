// V.Smile Smart Keyboard (high-level model of its microcontroller).
//
// Follows MAME vsmile_keyboard_device (src/devices/bus/vsmile/keyboard.cpp)
// on top of vsmile_ctrl_device_base, like vsmile_pad does for the joystick,
// cross-checked with vtech.pulkomandy.tk (Controllers):
//   - power-up: after 300 ms RTS is raised for 12.2 ms; if the console has
//     selected the keyboard by then it sends 52 52 52, reads the console's
//     02 02 E6 D6 60 and answers with its layout (0x40 US, 0x42 FR, 0x44
//     GE); otherwise it retries every 300 ms
//   - the key matrix (5 rows x up to 13 columns) is scanned one row per
//     1/2400 s; a change sends the key's code on press and code | 0xC0 on
//     release (Shift: 0xA9 / 0xAA)
//   - its joystick sends 0x87/0x8F/0x80 (up/down) and 0x7F/0x77/0x70
//     (left/right), its buttons 0xA1-0xA3 (OK, Quit, Help) and 0xA0
//   - bytes queue in a 32-entry FIFO and go out at 960 bytes/s while the
//     console selects the keyboard; probe bytes 0x7x/0xBx are answered with
//     0xBx; 1 s of silence sends a 0x55 keep-alive; unselected for 500 ms,
//     the queue is dropped and 0x55 sent
//
// Steps on `ce` (the 27 MHz tick), like vsmile_pad.

module vsmile_kbd (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    input  logic [12:0] keys [0:4],     // matrix: rows as MAME's ROW0-4 ports
    input  logic [3:0]  joy,            // up, down, left, right
    input  logic [2:0]  buttons,        // ok, quit, help
    input  logic [7:0]  layout,         // 0x40 US, 0x42 FR, 0x44 GE

    input  logic        select,
    input  logic        rx_valid,
    input  logic [7:0]  rx_data,
    output logic        tx_valid,
    output logic [7:0]  tx_data,
    output logic        rts,
    output logic        rts_evt
);

    localparam int unsigned TX_PERIOD     = 27_000_000 / 960;    // 28125
    localparam int unsigned RTS_TIMEOUT   = 27_000_000 / 2;      // 500 ms
    localparam int unsigned IDLE_PERIOD   = 27_000_000;          // 1 s
    localparam int unsigned HELLO_PERIOD  = 27_000_000 * 3 / 10; // 300 ms
    localparam int unsigned HELLO_TIMEOUT = 329_400;             // 12.2 ms
    localparam int unsigned SCAN_PERIOD   = 27_000_000 / 2400;   // 11250

    // MAME states
    localparam logic [2:0] S_HELLO = 3'd1, S_RX1 = 3'd2, S_RX2 = 3'd3,
                           S_RP1 = 3'd4, S_RP2 = 3'd5, S_RP3 = 3'd6, S_RUN = 3'd7;

    logic [7:0]  fifo [0:31];
    logic [4:0]  head, tail;
    logic        empty, tx_active, sel, active;
    logic [2:0]  state;
    logic [7:0]  probe0, probe1;
    logic [24:0] tx_t, rts_t, idle_t, hello_t, hto_t;
    logic [13:0] scan_t;
    logic [2:0]  scan_row;
    logic [12:0] kstate [0:4];          // MAME m_key_states
    logic [3:0]  sent_joy, joy_q;
    logic [2:0]  sent_buttons, buttons_q;
    // bytes waiting to enter the FIFO (queue_tx), one per step
    logic [7:0]  pq [0:3];
    logic [2:0]  pq_n;

    logic        rx_seen;
    logic [7:0]  rx_seen_data;
    logic        sel_c;
    logic [3:0]  joy_c;
    logic [2:0]  buttons_c;

    always_ff @(posedge clk) begin
        if (reset) rx_seen <= 1'b0;
        else if (rx_valid) begin rx_seen <= 1'b1; rx_seen_data <= rx_data; end
        else if (ce) rx_seen <= 1'b0;
        if (ce) begin sel_c <= select; joy_c <= joy; buttons_c <= buttons; end
    end

    // MAME's translate(): matrix position -> code
    function automatic logic [7:0] kcode(input logic [2:0] r, input logic [3:0] c);
        case (r)
            3'd0: case (c)
                4'd0: return 8'h33; 4'd1: return 8'h34; 4'd2: return 8'h35; 4'd3: return 8'h37;
                4'd4: return 8'h36; 4'd5: return 8'h30; 4'd6: return 8'h31; 4'd7: return 8'h3e;
                4'd8: return 8'h3f; 4'd9: return 8'h38; 4'd10: return 8'h29; 4'd11: return 8'h39;
                default: return 8'h00; endcase
            3'd1: case (c)
                4'd0: return 8'h22; 4'd1: return 8'h23; 4'd2: return 8'h24; 4'd3: return 8'h25;
                4'd4: return 8'h27; 4'd5: return 8'h26; 4'd6: return 8'h20; 4'd7: return 8'h21;
                4'd8: return 8'h3a; 4'd9: return 8'h3b; 4'd10: return 8'h3c; 4'd11: return 8'h2a;
                4'd12: return 8'h3d; default: return 8'h00; endcase
            3'd2: case (c)
                4'd0: return 8'h1a; 4'd1: return 8'h1b; 4'd2: return 8'h1c; 4'd3: return 8'h1d;
                4'd4: return 8'h1f; 4'd5: return 8'h1e; 4'd6: return 8'h18; 4'd7: return 8'h19;
                4'd8: return 8'h0a; 4'd9: return 8'h0b; 4'd10: return 8'h01; default: return 8'h00; endcase
            3'd3: case (c)
                4'd0: return 8'ha9; 4'd1: return 8'h13; 4'd2: return 8'h14; 4'd3: return 8'h15;
                4'd4: return 8'h17; 4'd5: return 8'h16; 4'd6: return 8'h08; 4'd7: return 8'h11;
                4'd8: return 8'h0c; 4'd9: return 8'h2f; 4'd10: return 8'h12; default: return 8'h00; endcase
            3'd4: case (c)
                4'd0: return 8'h04; 4'd1: return 8'h2c; 4'd2: return 8'h05; 4'd3: return 8'h0e;
                4'd4: return 8'h06; 4'd5: return 8'h0f; 4'd6: return 8'h0d; default: return 8'h00; endcase
            default: return 8'h00;
        endcase
    endfunction

    always_ff @(posedge clk) begin
        tx_valid <= 1'b0;
        rts_evt  <= 1'b0;
        if (reset) begin
            head <= 0; tail <= 0; empty <= 1'b1; tx_active <= 1'b0; sel <= 1'b0; rts <= 1'b0;
            active <= 1'b0; state <= S_HELLO; probe0 <= 0; probe1 <= 0;
            tx_t <= 0; rts_t <= 0; idle_t <= 0;
            hello_t <= 25'(HELLO_PERIOD); hto_t <= 0;
            scan_t <= 0; scan_row <= 0;
            kstate <= '{default: 13'd0};
            sent_joy <= 0; joy_q <= 0; sent_buttons <= 0; buttons_q <= 0;
            pq_n <= 0;
        end else if (ce) begin
            logic [4:0]  v_head, v_tail;
            logic        v_empty, v_tx_active, v_sel, v_rts, v_rts_evt, v_active;
            logic [2:0]  v_state;
            logic [7:0]  v_probe0, v_probe1;
            logic [24:0] v_tx_t, v_rts_t, v_idle_t, v_hello_t, v_hto_t;
            logic [7:0]  v_pq [0:3];
            logic [2:0]  v_pq_n;
            logic        v_out_valid;
            logic [7:0]  v_out;
            logic [3:0]  v_sent_joy;
            logic [2:0]  v_sent_buttons;
            logic [12:0] v_ks;
            v_head = head; v_tail = tail; v_empty = empty; v_tx_active = tx_active; v_sel = sel;
            v_rts = rts; v_rts_evt = 1'b0; v_active = active; v_state = state;
            v_probe0 = probe0; v_probe1 = probe1;
            v_tx_t = tx_t; v_rts_t = rts_t; v_idle_t = idle_t; v_hello_t = hello_t; v_hto_t = hto_t;
            v_pq = pq; v_pq_n = pq_n; v_out_valid = 1'b0; v_out = 8'd0;
            v_sent_joy = sent_joy; v_sent_buttons = sent_buttons;

            // queue_tx of the oldest waiting byte
            if (v_pq_n != 0) begin
                logic was_empty;
                was_empty = v_empty;
                if (was_empty || v_head != v_tail) begin
                    fifo[v_tail] <= v_pq[0];
                    v_tail  = v_tail + 5'd1;
                    v_empty = 1'b0;
                    if (was_empty) begin
                        v_rts = 1'b1; v_rts_evt = 1'b1;
                        if (v_sel) begin v_tx_active = 1'b1; v_tx_t = 25'(TX_PERIOD); end
                        else v_rts_t = 25'(RTS_TIMEOUT);
                    end
                end
                v_pq[0] = v_pq[1]; v_pq[1] = v_pq[2]; v_pq[2] = v_pq[3];
                v_pq_n = v_pq_n - 3'd1;
            end

            begin : events
                // uart_tx_fifo_push: queue a byte, idle timer reset
                logic [7:0] push_b [0:3];
                logic [2:0] push_n;
                logic       push_idle_reset;
                push_n = 0; push_idle_reset = 1'b0;

                // console byte: rx_complete
                if (rx_seen) begin
                    if (v_state != S_RUN) begin
                        if (v_state >= S_RX1 && v_state <= S_RP2) v_state = v_state + 3'd1;
                        else if (v_state == S_RP3) begin
                            push_b[push_n] = layout; push_n = push_n + 1; push_idle_reset = 1'b1;
                            v_state  = S_RUN;
                            v_idle_t = 25'(IDLE_PERIOD);
                            v_active = 1'b1;
                            scan_t   <= 14'(SCAN_PERIOD);
                            scan_row <= 0;
                        end
                    end else if (v_sel && (rx_seen_data[7:4] == 4'h7 || rx_seen_data[7:4] == 4'hb)) begin
                        v_probe0 = (rx_seen_data[7:4] == 4'h7) ? 8'd0 : v_probe1;
                        v_probe1 = rx_seen_data;
                        push_b[push_n] = {4'hb, (4'(v_probe0 + v_probe1 + 8'h0f)) ^ 4'h5};
                        push_n = push_n + 1; push_idle_reset = 1'b1;
                    end
                end

                // select line
                if (sel_c != v_sel) begin
                    if (sel_c && !v_empty && !v_tx_active) begin
                        v_rts_t = 25'd0; v_tx_active = 1'b1; v_tx_t = 25'(TX_PERIOD);
                    end
                    v_sel = sel_c;
                end

                // hello timers
                if (v_hello_t != 0) begin
                    v_hello_t = v_hello_t - 25'd1;
                    if (v_hello_t == 0) begin
                        v_rts = 1'b1; v_rts_evt = 1'b1;
                        v_hto_t = 25'(HELLO_TIMEOUT);
                    end
                end
                if (v_hto_t != 0) begin
                    v_hto_t = v_hto_t - 25'd1;
                    if (v_hto_t == 0) begin
                        v_rts = 1'b0; v_rts_evt = 1'b1;
                        if (!v_sel) v_hello_t = 25'(HELLO_PERIOD);
                        else begin
                            push_b[push_n] = 8'h52; push_n = push_n + 1;
                            push_b[push_n] = 8'h52; push_n = push_n + 1;
                            push_b[push_n] = 8'h52; push_n = push_n + 1;
                            push_idle_reset = 1'b1;
                            v_state = S_RX1;
                        end
                    end
                end

                // transmit timer
                if (v_tx_t != 0) begin
                    v_tx_t = v_tx_t - 25'd1;
                    if (v_tx_t == 0) begin
                        v_out_valid = 1'b1;
                        v_out       = fifo[v_head];
                        v_head      = v_head + 5'd1;
                        if (v_head == v_tail) v_empty = 1'b1;
                        if (v_empty && v_state == S_RUN) begin    // tx_complete: enter_active_state
                            v_idle_t = 25'(IDLE_PERIOD);
                            v_active = 1'b1;
                        end
                        if (v_empty) begin
                            v_tx_active = 1'b0;
                            v_rts = 1'b0; v_rts_evt = 1'b1;
                        end else if (v_sel) v_tx_t = 25'(TX_PERIOD);
                        else v_tx_active = 1'b0;
                    end
                end
                // RTS timeout: flush and tx_timeout
                if (v_rts_t != 0) begin
                    v_rts_t = v_rts_t - 25'd1;
                    if (v_rts_t == 0 && !v_empty) begin
                        v_head = 5'd0; v_tail = 5'd0; v_empty = 1'b1;
                        if (v_active) begin
                            v_idle_t = 25'd0; v_active = 1'b0; v_probe0 = 8'd0; v_probe1 = 8'd0;
                        end
                        push_b[push_n] = 8'h55; push_n = push_n + 1; push_idle_reset = 1'b1;
                        v_rts = 1'b0; v_rts_evt = 1'b1;
                    end
                end
                // idle keep-alive (queue_tx directly: no idle reset)
                if (v_idle_t != 0) begin
                    v_idle_t = v_idle_t - 25'd1;
                    if (v_idle_t == 0) begin push_b[push_n] = 8'h55; push_n = push_n + 1; end
                end

                // joystick / buttons (only when active and running)
                if (v_active && v_state == S_RUN && v_empty && push_n == 0 && v_pq_n == 0) begin
                    if (joy_c != joy_q) begin
                        if ((joy_c ^ v_sent_joy) & 4'b0011) begin
                            push_b[push_n] = joy_c[0] ? 8'h87 : joy_c[1] ? 8'h8f : 8'h80;
                            push_n = push_n + 1; push_idle_reset = 1'b1;
                        end
                        if ((joy_c ^ v_sent_joy) & 4'b1100) begin
                            push_b[push_n] = joy_c[2] ? 8'h7f : joy_c[3] ? 8'h77 : 8'h70;
                            push_n = push_n + 1; push_idle_reset = 1'b1;
                        end
                        v_sent_joy = joy_c;
                    end else if (buttons_c != buttons_q) begin
                        logic [2:0] rise;
                        rise = (v_sent_buttons ^ buttons_c) & buttons_c;
                        if (rise[0]) begin push_b[push_n] = 8'ha1; push_n = push_n + 1; end
                        if (rise[1]) begin push_b[push_n] = 8'ha2; push_n = push_n + 1; end
                        if (rise[2]) begin push_b[push_n] = 8'ha3; push_n = push_n + 1; end
                        if (buttons_c == 3'd0) begin push_b[push_n] = 8'ha0; push_n = push_n + 1; end
                        if (push_n != 0) push_idle_reset = 1'b1;
                        v_sent_buttons = buttons_c;
                    end
                end
                joy_q <= joy_c; buttons_q <= buttons_c;

                // matrix scan: one row per tick, first changed column (a
                // second change in the same row is taken on the next pass)
                if (v_state == S_RUN) begin
                    if (scan_t == 14'd1) begin
                        logic [12:0] ch;
                        v_ks = kstate[scan_row];
                        ch = v_ks ^ keys[scan_row];
                        if (ch != 0 && push_n < 3'd4) begin
                            logic [3:0] c;
                            c = 4'd0;
                            for (int i = 12; i >= 0; i--) if (ch[i]) c = 4'(i);
                            v_ks[c] = keys[scan_row][c];
                            if (kcode(scan_row, c) != 8'h00) begin
                                push_b[push_n] = !keys[scan_row][c] ? ((kcode(scan_row, c) == 8'ha9) ? 8'haa : (kcode(scan_row, c) | 8'hc0))
                                                                    : kcode(scan_row, c);
                                push_n = push_n + 1; push_idle_reset = 1'b1;
                            end
                            kstate[scan_row] <= v_ks;
                        end
                        scan_row <= (scan_row == 3'd4) ? 3'd0 : scan_row + 3'd1;
                        scan_t   <= 14'(SCAN_PERIOD);
                    end else if (scan_t != 0) scan_t <= scan_t - 14'd1;
                end

                if (push_idle_reset) v_idle_t = 25'd0;
                for (int i = 0; i < 4; i++)
                    if (i < push_n && v_pq_n + 3'(i) < 3'd4) v_pq[v_pq_n + 3'(i)] = push_b[i];
                v_pq_n = (v_pq_n + push_n > 3'd4) ? 3'd4 : v_pq_n + push_n;
            end

            head <= v_head; tail <= v_tail; empty <= v_empty; tx_active <= v_tx_active; sel <= v_sel;
            rts <= v_rts; rts_evt <= v_rts_evt; active <= v_active; state <= v_state;
            probe0 <= v_probe0; probe1 <= v_probe1;
            tx_t <= v_tx_t; rts_t <= v_rts_t; idle_t <= v_idle_t; hello_t <= v_hello_t; hto_t <= v_hto_t;
            pq <= v_pq; pq_n <= v_pq_n;
            sent_joy <= v_sent_joy; sent_buttons <= v_sent_buttons;
            tx_valid <= v_out_valid; tx_data <= v_out;
        end
    end

endmodule
