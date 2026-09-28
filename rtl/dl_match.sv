// Watches a download byte stream for a string stored one character per
// 16-bit word, little-endian (character, then 0x00), as VTech ROMs keep their
// text.  found goes high on the match and stays high until the next start.
// The search restarts at a mismatch (enough for patterns whose first
// character does not repeat in them).
module dl_match #(
    parameter int N = 6,                // characters
    parameter logic [N*8-1:0] PAT = "DG_ML0"
) (
    input  logic       clk,
    input  logic       start,           // new download
    input  logic       wr,              // din valid
    input  logic [7:0] din,
    output logic       found
);
    localparam int W = $clog2(2 * N + 1);
    logic [W-1:0] pos;

    function automatic logic [7:0] expect_byte(input logic [W-1:0] p);
        return p[0] ? 8'h00 : PAT[(N - 1 - p / 2) * 8 +: 8];
    endfunction

    always_ff @(posedge clk) begin
        if (start) begin
            pos   <= '0;
            found <= 1'b0;
        end else if (wr) begin
            if (din == expect_byte(pos)) begin
                if (pos == W'(2 * N - 1)) begin
                    found <= 1'b1;
                    pos   <= '0;
                end else
                    pos <= pos + 1'd1;
            end else
                pos <= (din == PAT[(N - 1) * 8 +: 8]) ? W'(1) : '0;
        end
    end
endmodule
