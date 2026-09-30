// Cart RAM save file (the Art Studio carts' 2 MB, MAME vsmile_nvram): moves
// SDRAM words C00000-CFFFFF to and from the save image MiSTer mounts for the
// cart (hps_io sd_* with WIDE = 0: bytes, 512-byte sectors).  The file holds
// the words little-endian.
//
// 16 KB chunks (32 sectors, one HPS request each: the HPS round trip, not the
// data, is what a request costs) through a 8 K-word buffer (two byte halves):
//   save: 2048 group reads from the SDRAM glue's second read client (one out
//         at a time, so the console keeps its queue slots), then sd_wr and
//         the HPS reads the buffer.  Only chunks written since the last save
//         are saved (dirty bits from the console's cart RAM writes), except
//         that a file shorter than 2 MB is written whole first;
//   load: sd_rd, the HPS writes the buffer, then 8192 word writes through the
//         shared SDRAM write port (the console is held in reset meanwhile).
module vsmile_save #(
    parameter logic [23:0] BASE   = 24'hC00000,
    parameter int          CHUNKS = 128            // 16 KB each
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        load,           // one-clk pulses
    input  logic        save,
    input  logic        file_full,      // the mounted file already holds all chunks
    input  logic        new_cart,       // a cart is loading: forget dirty bits / full save
    input  logic        mark,           // the console wrote cart RAM word mark_addr
    input  logic [23:0] mark_addr,
    output logic        busy,
    output logic        loading,

    output logic [31:0] sd_lba,
    output logic [5:0]  sd_blk_cnt,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [13:0] sd_buff_addr,
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
    localparam int CW = $clog2(CHUNKS);

    logic [7:0] lo [0:8191], hi [0:8191];
    logic [CHUNKS-1:0] dirty;
    logic              full_done;       // a whole-file save has been done

    typedef enum logic [2:0] {S_IDLE, S_NEXT, S_FILL, S_UNPACK, S_SDREQ, S_SDACK, S_WRITE, S_WRITE2} st_t;
    st_t          st;
    logic         is_load;
    logic [CW-1:0] chunk;
    logic [10:0]  grp;                  // group being read (save)
    logic [63:0]  g;                    // group being unpacked
    logic [1:0]   gw;                   // word of it
    logic [12:0]  wi;                   // word being written (load)
    logic         waiting;              // a group read is out
    logic [7:0]   rlo, rhi;

    assign busy       = (st != S_IDLE);
    assign loading    = busy && is_load;
    assign rd_addr    = BASE + {chunk, grp, 2'b00};
    assign sd_blk_cnt = 6'd31;

    // buffer writes, one port per half: HPS bytes (load) or unpacked SDRAM
    // words (save, S_UNPACK); reads: HPS bytes (registered) and the word
    // being written to SDRAM (load)
    wire        unpack = (st == S_UNPACK);
    wire        hps_w  = sd_ack && sd_buff_wr;
    wire [12:0] b_addr = unpack ? {grp, gw} : sd_buff_addr[13:1];
    wire        lo_we  = unpack || (hps_w && !sd_buff_addr[0]);
    wire        hi_we  = unpack || (hps_w &&  sd_buff_addr[0]);
    wire [7:0]  lo_d   = unpack ? g[gw * 16 +: 8]     : sd_buff_dout;
    wire [7:0]  hi_d   = unpack ? g[gw * 16 + 8 +: 8] : sd_buff_dout;
    always_ff @(posedge clk) begin
        if (lo_we) lo[b_addr] <= lo_d;
        if (hi_we) hi[b_addr] <= hi_d;
        sd_buff_din <= sd_buff_addr[0] ? hi[sd_buff_addr[13:1]] : lo[sd_buff_addr[13:1]];
        rlo <= lo[wi];
        rhi <= hi[wi];
    end

    // the chunk a save should do next: the first dirty one from `chunk` on
    // (all of them until a whole-file save is done)
    wire want = !(file_full || full_done) || dirty[chunk];

    always_ff @(posedge clk) begin
        wr_req <= 1'b0;
        if (mark && mark_addr >= BASE && mark_addr < BASE + 24'(CHUNKS * 8192))
            dirty[mark_addr[12 + CW:13]] <= 1'b1;
        if (reset || new_cart) begin
            st <= S_IDLE; rd_req <= 1'b0; sd_rd <= 1'b0; sd_wr <= 1'b0; waiting <= 1'b0;
            dirty <= '0; full_done <= 1'b0;
        end else case (st)
            S_IDLE: begin
                if (load || save) begin
                    is_load <= load;
                    chunk   <= '0;
                    st      <= load ? S_SDREQ : S_NEXT;
                end
            end
            // save: skip clean chunks
            S_NEXT: begin
                if (want) begin
                    dirty[chunk] <= 1'b0;       // written again from here on: saved next time
                    grp <= '0;
                    st  <= S_FILL;
                end else if (chunk == CW'(CHUNKS - 1)) begin
                    full_done <= 1'b1;
                    st <= S_IDLE;
                end else chunk <= chunk + 1'd1;
            end
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
                    grp <= grp + 11'd1;
                    st  <= (grp == 11'd2047) ? S_SDREQ : S_FILL;
                end
            end
            // the chunk to or from the SD image
            S_SDREQ: begin
                sd_lba <= 32'({chunk, 5'd0});
                sd_rd  <= is_load;
                sd_wr  <= !is_load;
                if (sd_ack) begin sd_rd <= 1'b0; sd_wr <= 1'b0; st <= S_SDACK; end
            end
            S_SDACK: begin
                if (!sd_ack) begin
                    wi <= '0;
                    if (is_load) st <= S_WRITE;
                    else if (chunk == CW'(CHUNKS - 1)) begin full_done <= 1'b1; st <= S_IDLE; end
                    else begin chunk <= chunk + 1'd1; st <= S_NEXT; end
                end
            end
            // load: write the chunk's 8192 words (rlo/rhi hold word wi)
            S_WRITE: st <= S_WRITE2;        // buffer read of word wi
            S_WRITE2: begin
                if (!wr_busy && !wr_req) begin
                    wr_req  <= 1'b1;
                    wr_addr <= BASE + {chunk, wi};
                    wr_data <= {rhi, rlo};
                    wi      <= wi + 13'd1;
                    if (wi == 13'd8191) begin
                        if (chunk == CW'(CHUNKS - 1)) begin
                            dirty <= '0; full_done <= 1'b1;   // RAM == file now
                            st <= S_IDLE;
                        end else begin chunk <= chunk + 1'd1; st <= S_SDREQ; end
                    end else st <= S_WRITE;
                end
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
