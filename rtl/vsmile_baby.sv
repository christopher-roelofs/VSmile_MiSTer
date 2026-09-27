// V.Smile Baby console buttons (MAME vsmileb_state).
//
// The Baby has no controller port: its eight buttons and the three-position
// function switch send two UART bytes to the SoC for every change, high byte
// first, without a handshake:
//   - a button press:   mode | button code
//   - a button release: mode | 0x0080
//   - a switch move:    new mode | 0x0080
// mode is 0x0400 (Play Time), 0x0800 (Watch & Learn) or 0x0C00 (Learn &
// Explore); MAME starts in Play Time after reset.  Changes go out one at a
// time, the two bytes on consecutive clks (MAME pushes both at once).
module vsmile_baby (
    input  logic        clk,
    input  logic        reset,
    // yellow, blue, orange, green, red, cloud, ball, exit (MAME BUTTONS bits 0-7)
    input  logic [7:0]  buttons,
    input  logic [1:0]  mode,           // 0 Play Time, 1 Watch & Learn, 2 Learn & Explore

    output logic        tx_valid,       // one-clk strobe per byte
    output logic [7:0]  tx_data
);
    function automatic logic [15:0] bcode(input logic [2:0] b);
        case (b)
            3'd0: return 16'h01fe;  // yellow
            3'd1: return 16'h03ee;  // blue
            3'd2: return 16'h03de;  // orange
            3'd3: return 16'h03be;  // green
            3'd4: return 16'h02fe;  // red
            3'd5: return 16'h03f6;  // cloud
            3'd6: return 16'h03fa;  // ball
            default: return 16'h03fc; // exit
        endcase
    endfunction

    function automatic logic [15:0] mcode(input logic [1:0] m);
        return (m == 2'd2) ? 16'h0c00 : (m == 2'd1) ? 16'h0800 : 16'h0400;
    endfunction

    logic [7:0]  btn_q, sent;           // synchronised input, state already sent
    logic [1:0]  mode_q, mode_sent;
    logic [7:0]  lo;                    // second byte, pending
    logic        lo_pending;

    always_ff @(posedge clk) begin
        tx_valid <= 1'b0;
        btn_q    <= buttons;
        mode_q   <= (mode == 2'd3) ? 2'd2 : mode;
        if (reset) begin
            sent       <= 8'd0;
            mode_sent  <= 2'd0;
            lo_pending <= 1'b0;
        end else if (lo_pending) begin
            tx_valid   <= 1'b1;
            tx_data    <= lo;
            lo_pending <= 1'b0;
        end else if (mode_q != mode_sent) begin
            logic [15:0] v;
            v = mcode(mode_q) | 16'h0080;
            mode_sent  <= mode_q;
            tx_valid   <= 1'b1;
            tx_data    <= v[15:8];
            lo         <= v[7:0];
            lo_pending <= 1'b1;
        end else if (btn_q != sent) begin
            logic [2:0]  b;
            logic [15:0] v;
            b = 3'd0;
            for (int i = 7; i >= 0; i--)
                if (btn_q[i] != sent[i]) b = 3'(i);
            v = mcode(mode_sent) | (btn_q[b] ? bcode(b) : 16'h0080);
            sent[b]    <= btn_q[b];
            tx_valid   <= 1'b1;
            tx_data    <= v[15:8];
            lo         <= v[7:0];
            lo_pending <= 1'b1;
        end
    end
endmodule
