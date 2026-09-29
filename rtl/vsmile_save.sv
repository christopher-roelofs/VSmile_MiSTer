// Cart RAM save file (the Art Studio carts' 2 MB, MAME vsmile_nvram): moves
// SDRAM words C00000-CFFFFF to and from the save image MiSTer mounts for the
// cart (hps_io sd_* with WIDE = 0: 512-byte blocks, bytes).  The file holds
// the words little-endian, 4096 blocks.
//
// One block at a time through a 256-word buffer (two byte halves):
//   save: 64 group reads from the SDRAM glue's second read client (one out
//         at a time, so the console keeps its queue slots), then sd_wr and
//         the HPS reads the buffer;
//   load: sd_rd, the HPS writes the buffer, then 256 word writes through the
//         shared SDRAM write port (the console is held in reset meanwhile).
module vsmile_save #(
    parameter logic [23:0] BASE   = 24'hC00000,
    parameter int          BLOCKS = 4096
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        load,           // one-clk pulses
    input  logic        save,
    output logic        busy,
    output logic        loading,

    output logic [31:0] sd_lba,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [8:0]  sd_buff_addr,
    input  logic [7:0]  sd_buff_dout,
    output logic [7:0]  sd_buff_din,
    input  logic        sd_buff_wr,

    output logic        rd_req,         // held until rd_take
    output logic [23:0] rd_addr,
    input  logic        rd_take,
    input  logic        rd_ack,
    input  logic [63:0] rd_data,

    output logic        wr_req,         // one-clk pulse, only when !wr_busy
    output logic [23:0] wr_addr,
    output logic [15:0] wr_data,
    input  logic        wr_busy
);
    logic [7:0] lo [0:255], hi [0:255];

    typedef enum logic [2:0] {S_IDLE, S_FILL, S_UNPACK, S_SDREQ, S_SDACK, S_WRITE, S_WRITE2} st_t;
    st_t         st;
    logic        is_load;
    logic [11:0] blk;
    logic [5:0]  grp;                   // group being read (save)
    logic [63:0] g;                     // group being unpacked
    logic [1:0]  gw;                    // word of it
    logic [7:0]  wi;                    // word being written (load)
    logic        waiting;               // a group read is out
    logic [7:0]  rlo, rhi;

    assign busy    = (st != S_IDLE);
    assign loading = busy && is_load;
    assign rd_addr = BASE + {blk, grp, 2'b00};

    // buffer writes, one port per half: HPS bytes (load) or unpacked
    // SDRAM words (save, S_UNPACK); reads: HPS bytes (registered) and the
    // word being written to SDRAM (load)
    wire       unpack = (st == S_UNPACK);
    wire       hps_w  = sd_ack && sd_buff_wr;
    wire [7:0] b_addr = unpack ? {grp, gw} : sd_buff_addr[8:1];
    wire       lo_we  = unpack || (hps_w && !sd_buff_addr[0]);
    wire       hi_we  = unpack || (hps_w &&  sd_buff_addr[0]);
    wire [7:0] lo_d   = unpack ? g[gw * 16 +: 8]     : sd_buff_dout;
    wire [7:0] hi_d   = unpack ? g[gw * 16 + 8 +: 8] : sd_buff_dout;
    always_ff @(posedge clk) begin
        if (lo_we) lo[b_addr] <= lo_d;
        if (hi_we) hi[b_addr] <= hi_d;
        sd_buff_din <= sd_buff_addr[0] ? hi[sd_buff_addr[8:1]] : lo[sd_buff_addr[8:1]];
        rlo <= lo[wi];
        rhi <= hi[wi];
    end

    always_ff @(posedge clk) begin
        wr_req <= 1'b0;
        if (reset) begin
            st <= S_IDLE; rd_req <= 1'b0; sd_rd <= 1'b0; sd_wr <= 1'b0; waiting <= 1'b0;
        end else case (st)
            S_IDLE: begin
                if (load || save) begin
                    is_load <= load;
                    blk     <= 12'd0;
                    grp     <= 6'd0;
                    st      <= load ? S_SDREQ : S_FILL;
                end
            end
            // save: read the block's 64 groups
            S_FILL: begin
                if (!waiting && !rd_req) rd_req <= 1'b1;
                if (rd_take) begin rd_req <= 1'b0; waiting <= 1'b1; end
                if (rd_ack) begin
                    waiting <= 1'b0;
                    g  <= rd_data;
                    gw <= 2'd0;
                    st <= S_UNPACK;
                end
            end
            S_UNPACK: begin                 // (buffer write above)
                gw <= gw + 2'd1;
                if (gw == 2'd3) begin
                    grp <= grp + 6'd1;
                    st  <= (grp == 6'd63) ? S_SDREQ : S_FILL;
                end
            end
            // the block to or from the SD image
            S_SDREQ: begin
                sd_lba <= {20'd0, blk};
                sd_rd  <= is_load;
                sd_wr  <= !is_load;
                if (sd_ack) begin sd_rd <= 1'b0; sd_wr <= 1'b0; st <= S_SDACK; end
            end
            S_SDACK: begin
                if (!sd_ack) begin
                    wi <= 8'd0;
                    if (is_load) st <= S_WRITE;
                    else if (blk == 12'(BLOCKS - 1)) st <= S_IDLE;
                    else begin blk <= blk + 12'd1; grp <= 6'd0; st <= S_FILL; end
                end
            end
            // load: write the block's 256 words (rlo/rhi hold word wi)
            S_WRITE: st <= S_WRITE2;        // buffer read of word wi
            S_WRITE2: begin
                if (!wr_busy && !wr_req) begin
                    wr_req  <= 1'b1;
                    wr_addr <= BASE + {blk, wi};
                    wr_data <= {rhi, rlo};
                    wi      <= wi + 8'd1;
                    if (wi == 8'd255) begin
                        if (blk == 12'(BLOCKS - 1)) st <= S_IDLE;
                        else begin blk <= blk + 12'd1; st <= S_SDREQ; end
                    end else st <= S_WRITE;
                end
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
