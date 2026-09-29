// Glue between the console's memory port and the SDRAM controller
// (rtl/sdram.sv, channel 1): 16-bit writes from the ROM download, aligned
// 64-bit (four word) reads for the console.
//
//   word address W  ->  byte address 2W  ->  ch1_addr[26:1] = W
//
// Reads are issued as one-clk pulses and queued (up to four); a queued read
// is handed to the controller as soon as it has taken the previous one
// (ch1_taken), so two bursts overlap in the SDRAM: the controller can start
// the next ACTIVE while the last data of the previous burst is still coming.
// Data comes back in order.  The controller raises ch1_ready one clk before
// the last word of a burst is in ch1_dout[63:48], so a group is delivered
// one clk later.
//
// Writes (the download, and the console's cart RAM writes, posted) keep
// their place among the reads: a write waits for the reads queued before
// it, and reads queued after it wait for the write.

module vsmile_sdram (
    input  logic        clk,
    input  logic        reset,

    // console reads: mem_req is a one-clk pulse with mem_addr; mem_ack one
    // clk with mem_rdata, in issue order (ack_addr: the address it is for)
    input  logic        mem_req,
    input  logic [23:0] mem_addr,
    output logic        mem_ack,
    output logic [63:0] mem_rdata,
    output logic [23:0] ack_addr,

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
    input  logic        ch1_ready,
    input  logic        ch1_taken       // the controller took the last ch1_req
);

    logic [23:0] q [0:3];
    logic [2:0]  qh, qi, qt;            // next to complete / to issue / to fill
    logic        handed;                // ch1_req out, not yet taken
    logic [1:0]  inflight;              // taken by the controller, data not back
    logic        rd_ready_q, wr_pending, wr_want;
    logic [23:0] wr_addr_q;
    logic [2:0]  wr_bar;                // read queue tail when the write came
    logic [15:0] wr_data_q;
    wire  rd_queued = (qi != qt);

    always_ff @(posedge clk) begin
        logic issue, done;
        ch1_req    <= 1'b0;
        rd_ready_q <= ch1_ready && (inflight != 2'd0);
        issue = 1'b0;
        done  = rd_ready_q;
        if (reset) begin
            qh <= 3'd0; qi <= 3'd0; qt <= 3'd0;
            handed <= 1'b0; inflight <= 2'd0;
            rd_ready_q <= 1'b0;
            wr_pending <= 1'b0;
            wr_want    <= 1'b0;
        end else begin
            if (mem_req) begin
                q[qt[1:0]] <= mem_addr;
                qt <= qt + 3'd1;
            end
            if (ch1_taken) handed <= 1'b0;
            // a write is held until it can be issued (no reads out)
            if (wr_req) begin
                wr_want   <= 1'b1;
                wr_addr_q <= wr_addr;
                wr_data_q <= wr_data;
                wr_bar    <= qt;
            end
            if (wr_want && !wr_pending && qh == wr_bar && !handed) begin
                ch1_addr   <= {2'b00, wr_addr_q};
                ch1_din    <= wr_data_q;
                ch1_rnw    <= 1'b0;
                ch1_req    <= 1'b1;
                wr_pending <= 1'b1;
                wr_want    <= wr_req;       // (a new one arriving now waits)
            end else if (rd_queued && !handed && inflight != 2'd2 && !wr_pending && (!wr_want || qi != wr_bar)) begin
                ch1_addr <= {2'b00, q[qi[1:0]][23:2], 2'b00};
                ch1_rnw  <= 1'b1;
                ch1_req  <= 1'b1;
                handed   <= 1'b1;
                qi       <= qi + 3'd1;
                issue    = 1'b1;
            end
            if (ch1_ready && wr_pending) wr_pending <= 1'b0;
            if (done) qh <= qh + 3'd1;
            inflight <= inflight + 2'(issue) - 2'(done);
        end
    end

    assign wr_busy   = wr_pending || wr_want || wr_req;
    assign mem_ack   = rd_ready_q;
    assign mem_rdata = ch1_dout;
    assign ack_addr  = q[qh[1:0]];

endmodule
