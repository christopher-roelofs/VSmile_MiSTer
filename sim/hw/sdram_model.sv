// Behavioural model of the MiSTer SDRAM (MT48LC16M16-class, 16M x 16) for
// simulation with rtl/sdram.sv: ACTIVE / READ (burst 4, CAS latency 3) /
// WRITE (single word, DQM byte masks) / PRECHARGE / REFRESH / LOAD MODE.
// The chip clocks on SDRAM_CLK, which the controller drives as the inverse
// of its own clock, so commands are sampled on the falling edge of `clk`.

module sdram_model (
    input  logic        clk,            // controller clock (chip clock is ~clk)
    input  logic        cke,
    input  logic        ncs, nras, ncas, nwe,
    input  logic [1:0]  ba,
    input  logic [12:0] a,
    input  logic        dqml, dqmh,
    inout  wire  [15:0] dq
);

    logic [15:0] mem [0:(1<<24)-1] /* verilator public_flat_rw */;
    logic [12:0] row [0:3];

    // read pipeline: word i of the burst is valid from CL (3) + i chip clocks
    // after the command edge (dq_oe/dq_out are registered, so the word is
    // placed in stage 2 + i)
    logic [23:0] rd_addr [0:6];
    logic        rd_v    [0:6];
    logic [15:0] dq_out;
    logic        dq_oe;

    assign dq = dq_oe ? dq_out : 16'bz;

    always_ff @(negedge clk) begin
        // shift the read pipeline
        for (int i = 0; i < 6; i++) begin rd_v[i] <= rd_v[i+1]; rd_addr[i] <= rd_addr[i+1]; end
        rd_v[6] <= 1'b0;
        dq_oe   <= rd_v[0];
        dq_out  <= mem[rd_addr[0]];

        if (cke && !ncs) begin
            case ({nras, ncas, nwe})
                3'b011: row[ba] <= a;                                   // ACTIVE
                3'b101: begin                                           // READ: burst of 4, CL 3
                    for (int i = 0; i < 4; i++) begin
                        rd_v[2 + i]    <= 1'b1;
                        rd_addr[2 + i] <= {ba, row[ba], a[8:2], 2'(a[1:0] + i[1:0])};
                    end
                end
                3'b100: begin                                           // WRITE: one word
                    if (!dqml) mem[{ba, row[ba], a[8:0]}][7:0]  <= dq[7:0];
                    if (!dqmh) mem[{ba, row[ba], a[8:0]}][15:8] <= dq[15:8];
                end
                default: ;                                              // PRECHARGE, REFRESH, LOAD MODE, NOP
            endcase
        end
    end

endmodule
