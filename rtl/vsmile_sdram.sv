// Glue between the console's memory port and the SDRAM controller
// (rtl/sdram.sv, channel 1): 16-bit writes from the ROM download, aligned
// 64-bit (four word) reads for the console.
//
//   word address W  ->  byte address 2W  ->  ch1_addr[26:1] = W
//
// The controller raises ch1_ready one clk before the last word of a read
// burst is in ch1_dout[63:48], so the group is delivered one clk later; the
// request stays marked pending until then so it is not issued twice.

module vsmile_sdram (
    input  logic        clk,
    input  logic        reset,

    // console reads (mem_req held until mem_ack)
    input  logic        mem_req,
    input  logic [23:0] mem_addr,
    output logic        mem_ack,
    output logic [63:0] mem_rdata,

    // download writes (one-clk pulse; wr_busy while it is in flight)
    input  logic        wr_req,
    input  logic [23:0] wr_addr,
    input  logic [15:0] wr_data,
    output logic        wr_busy,

    // SDRAM controller channel 1
    output logic [25:0] ch1_addr,       // [26:1]
    output logic [15:0] ch1_din,
    output logic        ch1_req,
    output logic        ch1_rnw,
    input  logic [63:0] ch1_dout,
    input  logic        ch1_ready
);

    logic rd_pending, rd_ready_q, wr_pending, wr_want;
    logic [23:0] wr_addr_q;
    logic [15:0] wr_data_q;

    always_ff @(posedge clk) begin
        ch1_req    <= 1'b0;
        rd_ready_q <= ch1_ready && rd_pending;
        if (reset) begin
            rd_pending <= 1'b0;
            wr_pending <= 1'b0;
            wr_want    <= 1'b0;
            rd_ready_q <= 1'b0;
        end else begin
            // a write is held until it can be issued
            if (wr_req) begin
                wr_want   <= 1'b1;
                wr_addr_q <= wr_addr;
                wr_data_q <= wr_data;
            end
            if (wr_want && !wr_pending && !rd_pending) begin
                ch1_addr   <= {2'b00, wr_addr_q};
                ch1_din    <= wr_data_q;
                ch1_rnw    <= 1'b0;
                ch1_req    <= 1'b1;
                wr_pending <= 1'b1;
                wr_want    <= wr_req;       // (a new one arriving now waits)
            end else if (mem_req && !rd_pending && !wr_pending && !wr_want && !rd_ready_q) begin
                ch1_addr   <= {2'b00, mem_addr[23:2], 2'b00};
                ch1_rnw    <= 1'b1;
                ch1_req    <= 1'b1;
                rd_pending <= 1'b1;
            end
            if (ch1_ready && wr_pending) wr_pending <= 1'b0;
            if (rd_ready_q) rd_pending <= 1'b0;     // held until the ack is out
        end
    end

    assign wr_busy   = wr_pending || wr_want || wr_req;
    assign mem_ack   = rd_ready_q;
    assign mem_rdata = ch1_dout;

endmodule
