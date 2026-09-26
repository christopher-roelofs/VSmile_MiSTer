// SunPlus µ'nSP (ISA 1.0) CPU core, as used in the SPG24x (VTech V.Smile).
//
// Behaviour follows MAME's unsp_device interpreter (src/devices/cpu/unsp,
// Segher Boessenkool / Ryan Holtz / David Haywood, GPL-2.0+), including its
// per-instruction cycle counts: every instruction occupies at least as many
// `ce` ticks as MAME charges for it.  Bus waits beyond that stretch it.
//
// Registers: r[0]=SP r[1..4]=R1..R4 r[5]=BP r[6]=SR r[7]=PC
// SR: [15:10] DS  [9] N  [8] Z  [7] S  [6] C  [5:0] CS (code segment)
// Address space: 22-bit word addresses ({CS,PC} for code, {DS,reg} for data).
//
// Bus: addr/rd/wr/wdata are held stable until a `ce` tick with `ready` high;
// rdata is sampled on that tick.  irq[0] = FIQ, irq[1..8] = IRQ0..IRQ7
// (level-sensitive, same numbering as MAME's UNSP_*_LINE inputs).
//
// License: GPL-2.0-or-later (derived from MAME's GPL-2.0+ µ'nSP core).

module unsp_core (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    output logic [21:0] addr,
    output logic        rd,
    output logic        wr,
    output logic [15:0] wdata,
    input  logic [15:0] rdata,
    input  logic        ready,

    // SoC register 0x3D2F aliases SR.DS (MAME spg2xx_io set_ds)
    input  logic        ds_we,
    input  logic [5:0]  ds_wdata,

    input  logic [8:0]  irq,
    output logic        irq_ack,        // pulses when an interrupt is taken
    output logic [3:0]  irq_ack_line,   // MAME line number taken

    // Debug / trace: `dbg_fetch` pulses on the tick an opcode is fetched, with
    // the registers as they were *before* that instruction (MAME trace order).
    output logic        dbg_fetch,
    output logic        dbg_ifetch,     // bus cycle is an opcode fetch
    output logic [21:0] dbg_pc,
    output logic [15:0] dbg_op,
    output logic [15:0] dbg_r [0:7],
    output logic        dbg_illegal
);

    // ------------------------------------------------------------------
    // Architectural state
    // ------------------------------------------------------------------
    localparam SP = 3'd0, R1 = 3'd1, R2 = 3'd2, R3 = 3'd3, R4 = 3'd4,
               BP = 3'd5, SR = 3'd6, PC = 3'd7;

    logic [15:0] r [0:7];
    logic [3:0]  sb;
    logic        irq_en, fiq_en, fir_move;
    logic        in_irq, in_fiq;

    assign dbg_r = r;
    assign dbg_ifetch = (state == S_FETCH);

    wire [21:0] lpc = {r[SR][5:0], r[PC]};
    wire [15:0] sr  = r[SR];
    wire        fN = sr[9], fZ = sr[8], fS = sr[7], fC = sr[6];

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_RESET,      // read reset vector
        S_FETCH,
        S_DECODE,
        S_IMM,        // fetch imm16 operand
        S_MRD,        // ALU operand read
        S_MWR,        // ALU store / [imm16] result write
        S_PUSH,
        S_POP,
        S_RETI_SR,
        S_RETI_PC,
        S_CALL_PC,
        S_CALL_SR,
        S_MUL,
        S_MULS_RD,    // muls: read [rd+i]
        S_MULS_RS,    // muls: read [rs+i]
        S_MULS_WR,    // muls: FIR shift write-back
        S_MULS_END,
        S_WAIT,       // pad to MAME cycle count
        S_INT_PC,
        S_INT_SR,
        S_INT_VEC
    } state_t;

    state_t      state;
    logic [15:0] ir;
    logic [15:0] imm;
    logic [5:0]  cyc;       // ce ticks spent in this instruction
    logic [5:0]  cost;      // MAME cycle cost of this instruction
    logic        no_irq;    // RETI: MAME skips the IRQ check after it

    // operand latches
    logic [15:0] op_a;      // MAME r0
    logic [15:0] op_b;      // MAME r1
    logic [21:0] ea;        // MAME r2 (effective address)
    logic [15:0] mwr_data;  // data for S_MWR
    logic [2:0]  cnt;       // push/pop remaining
    logic [2:0]  preg;      // push/pop current register
    logic [3:0]  int_line;

    // muls
    logic [4:0]  m_size, m_i;
    logic [15:0] m_vals [0:15];
    logic [15:0] m_cur;
    logic signed [47:0] m_acc;

    // ------------------------------------------------------------------
    // Decode (from ir)
    // ------------------------------------------------------------------
    wire [3:0] op0 = ir[15:12];
    wire [2:0] opa = ir[11:9];
    wire [2:0] op1 = ir[8:6];
    wire [2:0] opn = ir[5:3];
    wire [2:0] opb = ir[2:0];
    wire [5:0] imm6 = ir[5:0];

    wire is_fxxx  = (op0 == 4'hF);
    wire is_jump  = (op0 != 4'hF) && (opa == 3'd7) && (op1 < 3'd2);
    wire is_exxx  = (op0 == 4'hE) && !is_jump;
    wire is_push  = !is_fxxx && !is_jump && !is_exxx && op1 == 3'd2 && op0 == 4'hD;
    wire is_reti  = (ir == 16'h9a98);
    wire is_pop   = !is_fxxx && !is_jump && !is_exxx && op1 == 3'd2 && op0 == 4'h9 && !is_reti;
    wire is_store = (op0 == 4'hD);

    // Branch condition
    logic take;
    always_comb begin
        case (op0)
            4'h0: take = !fC;
            4'h1: take =  fC;
            4'h2: take = !fS;
            4'h3: take =  fS;
            4'h4: take = !fZ;
            4'h5: take =  fZ;
            4'h6: take = !fN;
            4'h7: take =  fN;
            4'h8: take = ({fZ, fC} != 2'b01);
            4'h9: take = ({fZ, fC} == 2'b01);
            4'hA: take = fZ | fS;
            4'hB: take = !(fZ | fS);
            4'hC: take = (fN == fS);
            4'hD: take = (fN != fS);
            default: take = 1'b1;   // JMP
        endcase
    end

    // Branch target: add_lpc(+/-imm6), 22-bit wrap into CS
    wire [21:0] br_target = (op1 == 3'd0) ? lpc + 22'(imm6) : lpc - 22'(imm6);

    // ------------------------------------------------------------------
    // ALU (MAME do_basic_alu_ops); a = r0, b = r1
    // ------------------------------------------------------------------
    logic [16:0] alu_res;
    logic        alu_write;       // result is written back (reg or [imm16])
    logic        alu_nzsc, alu_nz; // which flags to update
    logic [15:0] alu_b2;          // operand used for the S flag (b or ~b)

    function automatic void alu(input logic [3:0] f, input logic [15:0] a, input logic [15:0] b,
                                input logic c,
                                output logic [16:0] res, output logic wrt,
                                output logic nzsc, output logic nz, output logic [15:0] b2);
        res = 17'd0; wrt = 1'b0; nzsc = 1'b0; nz = 1'b0; b2 = b;
        case (f)
            4'h0: begin res = {1'b0, a} + {1'b0, b};                     wrt = 1; nzsc = 1; end
            4'h1: begin res = {1'b0, a} + {1'b0, b} + 17'(c);            wrt = 1; nzsc = 1; end
            4'h2: begin res = {1'b0, a} + {1'b0, ~b} + 17'd1; b2 = ~b;   wrt = 1; nzsc = 1; end
            4'h3: begin res = {1'b0, a} + {1'b0, ~b} + 17'(c); b2 = ~b;  wrt = 1; nzsc = 1; end
            4'h4: begin res = {1'b0, a} + {1'b0, ~b} + 17'd1; b2 = ~b;   wrt = 0; nzsc = 1; end
            4'h6: begin res = {1'b0, -b};                                wrt = 1; nz = 1; end
            4'h8: begin res = {1'b0, a ^ b};                             wrt = 1; nz = 1; end
            4'h9: begin res = {1'b0, b};                                 wrt = 1; nz = 1; end
            4'hA: begin res = {1'b0, a | b};                             wrt = 1; nz = 1; end
            4'hB: begin res = {1'b0, a & b};                             wrt = 1; nz = 1; end
            4'hC: begin res = {1'b0, a & b};                             wrt = 0; nz = 1; end
            default: ;  // 0xD store handled by caller; 5/7/E/F illegal: no effect
        endcase
    endfunction

    function automatic logic [15:0] flags(input logic [15:0] s, input logic [16:0] res,
                                          input logic [15:0] a, input logic [15:0] b2,
                                          input logic nzsc, input logic nz);
        logic [15:0] o;
        o = s;
        if (nzsc) begin
            o[9] = res[15];
            o[8] = (res[15:0] == 16'd0);
            o[7] = (res[16] != (a[15] ^ b2[15]));
            o[6] = res[16];
        end else if (nz) begin
            o[9] = res[15];
            o[8] = (res[15:0] == 16'd0);
        end
        return o;
    endfunction

    // ------------------------------------------------------------------
    // Shifter (op1 = 4 opn>=4, op1 = 5, op1 = 6), combinational on r[opb]
    // ------------------------------------------------------------------
    logic [15:0] sh_res;
    logic [3:0]  sh_sb;
    always_comb begin
        logic [19:0] s20;
        logic [27:0] s28;
        logic [2:0]  n;
        sh_res = 16'd0;
        sh_sb  = sb;
        s20 = 20'd0; s28 = 28'd0; n = 3'd0;
        case (op1)
            3'd4: begin // ASR by opn-3
                n = opn - 3'd3;
                s20 = {r[opb], sb};
                s20 = $signed(s20) >>> n;
                sh_sb  = s20[3:0];
                sh_res = s20[19:4];
            end
            3'd5: begin
                if (opn[2]) begin // LSR by opn-3
                    n = opn - 3'd3;
                    s20 = {r[opb], sb} >> n;
                    sh_sb  = s20[3:0];
                    sh_res = s20[19:4];
                end else begin    // LSL by opn+1
                    n = opn + 3'd1;
                    s20 = {sb, r[opb]} << n;
                    sh_sb  = s20[19:16];
                    sh_res = s20[15:0];
                end
            end
            3'd6: begin
                s28 = {4'd0, sb, r[opb], sb};
                if (opn[2]) begin // ROR by opn-3
                    n = opn - 3'd3;
                    s28 = s28 >> n;
                    sh_sb = s28[3:0];
                end else begin    // ROL by opn+1
                    n = opn + 3'd1;
                    s28 = s28 << n;
                    sh_sb = s28[23:20];
                end
                sh_res = s28[19:4];
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Cycle costs (MAME icount charges)
    // ------------------------------------------------------------------
    function automatic logic [5:0] alu_cost(input logic [2:0] o1, input logic [2:0] on, input logic pc_dst);
        case (o1)
            3'd0: return 6'd6;
            3'd1: return 6'd2;
            3'd3: return pc_dst ? 6'd7 : 6'd6;
            3'd4: case (on)
                      3'd0:    return pc_dst ? 6'd5 : 6'd3;
                      3'd1:    return pc_dst ? 6'd5 : 6'd4;
                      3'd2,
                      3'd3:    return pc_dst ? 6'd8 : 6'd7;
                      default: return pc_dst ? 6'd5 : 6'd3;
                  endcase
            3'd5, 3'd6: return pc_dst ? 6'd5 : 6'd3;
            3'd7: return pc_dst ? 6'd6 : 6'd5;
            default: return 6'd0;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Interrupt selection (MAME check_irqs): the lowest-numbered active
    // line wins; if it cannot be taken, nothing is taken.
    // ------------------------------------------------------------------
    // An interrupt-control instruction finishes in S_DECODE; MAME checks IRQs
    // after it with the enables it just wrote, so look through to them.
    logic eff_irq_en, eff_fiq_en;
    always_comb begin
        eff_irq_en = irq_en;
        eff_fiq_en = fiq_en;
        if (state == S_DECODE && is_fxxx && op1 == 3'd5)
            case (ir[5:0])
                6'h00: begin eff_irq_en = 0; eff_fiq_en = 0; end
                6'h01: begin eff_irq_en = 1; eff_fiq_en = 0; end
                6'h02: begin eff_irq_en = 0; eff_fiq_en = 1; end
                6'h03: begin eff_irq_en = 1; eff_fiq_en = 1; end
                6'h08: eff_irq_en = 0;
                6'h09: eff_irq_en = 1;
                6'h0c: eff_fiq_en = 0;
                6'h0e: eff_fiq_en = 1;
                default: ;
            endcase
    end

    logic       int_take;
    logic [3:0] int_sel;
    always_comb begin
        int_take = 1'b0;
        int_sel  = 4'd0;
        for (int i = 8; i >= 0; i--)
            if (irq[i]) int_sel = 4'(i);
        if (irq != 9'd0) begin
            if (int_sel == 4'd0) int_take = eff_fiq_en && !in_fiq;
            else                 int_take = eff_irq_en && !in_irq;
        end
    end

    // ------------------------------------------------------------------
    // Sequential
    // ------------------------------------------------------------------
    // End of instruction: pad to `cost`, then check interrupts / fetch.
    task automatic finish(input logic [5:0] c);
        if (cyc + 6'd1 < c) begin
            cost  <= c;
            state <= S_WAIT;
        end else if (!no_irq && int_take) begin
            int_line <= int_sel;
            state    <= S_INT_PC;
        end else begin
            state <= S_FETCH;
        end
    endtask

    // add_lpc(1) on r[PC]/CS
    task automatic lpc_inc;
        {r[SR][5:0], r[PC]} <= lpc + 22'd1;
    endtask

    always_ff @(posedge clk) begin
        dbg_fetch   <= 1'b0;
        dbg_illegal <= 1'b0;
        irq_ack     <= 1'b0;

        if (reset) begin
            for (int i = 0; i < 8; i++) r[i] <= 16'd0;
            sb       <= 4'd0;
            irq_en   <= 1'b0;
            fiq_en   <= 1'b0;
            fir_move <= 1'b1;
            in_irq   <= 1'b0;
            in_fiq   <= 1'b0;
            state    <= S_RESET;
            cyc      <= 6'd0;
            no_irq   <= 1'b0;
        end else if (ce) begin
            cyc <= cyc + 6'd1;

            case (state)
            // ----------------------------------------------------------
            S_RESET: if (ready) begin
                r[PC] <= rdata;
                state <= S_FETCH;
            end

            S_FETCH: if (ready) begin
                ir        <= rdata;
                dbg_fetch <= 1'b1;
                dbg_pc    <= lpc;
                dbg_op    <= rdata;
                lpc_inc();
                cyc       <= 6'd1;
                no_irq    <= 1'b0;
                state     <= S_DECODE;
            end

            // ----------------------------------------------------------
            S_DECODE: begin
                op_a <= r[opa];
                if (is_fxxx) begin
                    case (op1)
                    3'd0, 3'd4: begin // MUL us / MUL ss
                        if (op1 == 3'd4 && ir[5:3] != 3'd1) begin
                            dbg_illegal <= 1'b1;
                            finish(6'd0);
                        end else
                            state <= S_MUL;
                    end
                    3'd1: begin // CALL imm22
                        if ((ir & 16'hf3c0) == 16'hf040) state <= S_IMM;
                        else begin dbg_illegal <= 1'b1; finish(6'd0); end
                    end
                    3'd2: begin // GOTO imm22
                        if ((ir & 16'hffc0) == 16'hfe80) state <= S_IMM;
                        else begin dbg_illegal <= 1'b1; finish(6'd0); end
                    end
                    3'd5: begin // interrupt control
                        case (ir[5:0])
                            6'h00: begin irq_en <= 0; fiq_en <= 0; end
                            6'h01: begin irq_en <= 1; fiq_en <= 0; end
                            6'h02: begin irq_en <= 0; fiq_en <= 1; end
                            6'h03: begin irq_en <= 1; fiq_en <= 1; end
                            6'h04: fir_move <= 1'b1;
                            6'h05: fir_move <= 1'b0;
                            6'h08: irq_en <= 1'b0;
                            6'h09: irq_en <= 1'b1;
                            6'h0c: fiq_en <= 1'b0;
                            6'h0e: fiq_en <= 1'b1;
                            6'h25, 6'h2d, 6'h35, 6'h3d: ; // nop
                            default: dbg_illegal <= 1'b1;
                        endcase
                        finish(6'd2);
                    end
                    3'd6, 3'd7: begin // MULS ss [rd],[rs],size
                        m_size <= (op1 == 3'd6) ? ((opn != 3'd0) ? {2'b0, opn} : 5'd16)
                                                : {2'b0, opn} + 5'd8;
                        m_i    <= 5'd0;
                        m_acc  <= 48'sd0;
                        state  <= S_MULS_RD;
                    end
                    default: begin dbg_illegal <= 1'b1; finish(6'd0); end
                    endcase
                end else if (is_jump) begin
                    if (take) begin
                        {r[SR][5:0], r[PC]} <= br_target;
                        finish(6'd4);
                    end else
                        finish(6'd2);
                end else if (is_exxx) begin
                    dbg_illegal <= 1'b1;
                    finish(6'd0);
                end else if (is_push) begin
                    cnt   <= opn;
                    preg  <= opa;
                    if (opn == 3'd0) finish(6'd4);
                    else state <= S_PUSH;
                end else if (is_reti) begin
                    no_irq <= 1'b1;
                    state  <= S_RETI_SR;
                end else if (is_pop) begin
                    cnt   <= opn;
                    preg  <= opa;
                    if (opn == 3'd0) finish(6'd4);
                    else state <= S_POP;
                end else begin
                    // ALU group
                    case (op1)
                    3'd0: begin // [bp+imm6]
                        ea       <= {6'd0, r[BP] + 16'(imm6)};
                        mwr_data <= r[opa];
                        if (is_store) state <= S_MWR; else state <= S_MRD;
                    end
                    3'd1: begin // imm6
                        op_b <= 16'(imm6);
                        alu_exec(r[opa], 16'(imm6), 22'd0);
                    end
                    3'd2: begin // (non push/pop) MAME: r1 = 0, no cycles
                        op_b <= 16'd0;
                        alu_exec(r[opa], 16'd0, 22'd0);
                    end
                    3'd3: begin // indirect
                        logic [15:0] rb;
                        logic [21:0] a;
                        rb = r[opb];
                        case (opn[1:0])
                            2'd0, 2'd1, 2'd2: a = opn[2] ? {r[SR][15:10], rb} : {6'd0, rb};
                            default: begin
                                a = opn[2] ? {r[SR][15:10], 16'd0} + 22'(rb) + 22'd1
                                           : {6'd0, rb + 16'd1};
                            end
                        endcase
                        // pointer update (MAME order: before the ALU write-back)
                        if (opn[1:0] != 2'd0) begin
                            logic [15:0] nv;
                            logic [15:0] nsr;
                            nsr = r[SR];
                            nv  = (opn[1:0] == 2'd1) ? rb - 16'd1 : rb + 16'd1;
                            if (opn[2]) begin
                                if (opn[1:0] == 2'd1 && nv == 16'hffff) nsr = nsr - 16'h0400;
                                if (opn[1:0] != 2'd1 && nv == 16'h0000) nsr = nsr + 16'h0400;
                            end
                            r[opb] <= nv;
                            if (opn[2] && opb != SR) r[SR] <= nsr;
                        end
                        ea       <= a;
                        mwr_data <= r[opa];
                        if (is_store) state <= S_MWR; else state <= S_MRD;
                    end
                    3'd4: begin
                        case (opn)
                            3'd0: begin
                                op_b <= r[opb];
                                alu_exec(r[opa], r[opb], 22'd0);
                            end
                            3'd1, 3'd2, 3'd3: state <= S_IMM;
                            default: begin // ASR
                                op_b <= sh_res;
                                sb   <= sh_sb;
                                alu_exec(r[opa], sh_res, 22'd0);
                            end
                        endcase
                    end
                    3'd5, 3'd6: begin
                        op_b <= sh_res;
                        sb   <= sh_sb;
                        alu_exec(r[opa], sh_res, 22'd0);
                    end
                    3'd7: begin // [imm6]
                        ea    <= {16'd0, imm6};
                        state <= S_MRD;   // MAME reads even for store
                    end
                    endcase
                end
            end

            // ----------------------------------------------------------
            S_IMM: if (ready) begin
                imm <= rdata;
                lpc_inc();
                if (is_fxxx && op1 == 3'd1) begin       // CALL
                    state <= S_CALL_PC;
                end else if (is_fxxx) begin             // GOTO
                    r[PC] <= rdata;
                    r[SR] <= {r[SR][15:6], ir[5:0]};
                    finish(6'd5);
                end else begin
                    case (opn)
                        3'd1: begin // rA = rB op imm16
                            op_a <= r[opb];
                            op_b <= rdata;
                            alu_exec(r[opb], rdata, 22'd0);
                        end
                        3'd2: begin // rA = rB op [imm16]
                            op_a     <= r[opb];
                            ea       <= {6'd0, rdata};
                            mwr_data <= r[opb];
                            if (is_store) state <= S_MWR; else state <= S_MRD;
                        end
                        default: begin // [imm16] = rB op rA (result goes to memory)
                            logic [16:0] res;
                            logic        wrt, nzsc, nz;
                            logic [15:0] b2;
                            alu(op0, r[opb], r[opa], fC, res, wrt, nzsc, nz, b2);
                            if (opa != PC) r[SR] <= flags(r[SR], res, r[opb], b2, nzsc, nz);
                            ea <= {6'd0, rdata};
                            if (is_store) begin
                                mwr_data <= r[opb];
                                state    <= S_MWR;
                            end else if (wrt) begin
                                mwr_data <= res[15:0];
                                state    <= S_MWR;
                            end else
                                finish(alu_cost(op1, opn, opa == PC));
                        end
                    endcase
                end
            end

            S_MRD: if (ready) begin
                op_b <= rdata;
                if (is_store) begin   // [imm6] store: MAME reads, then writes
                    mwr_data <= op_a;
                    state    <= S_MWR;
                end else
                    alu_exec(op_a, rdata, ea);
            end

            S_MWR: if (ready) begin
                finish(alu_cost(op1, opn, opa == PC));
            end

            // ----------------------------------------------------------
            S_PUSH: if (ready) begin
                r[opb] <= r[opb] - 16'd1;
                preg   <= preg - 3'd1;
                cnt    <= cnt - 3'd1;
                if (cnt == 3'd1) finish(6'd4 + {2'd0, opn, 1'b0});
            end

            S_POP: if (ready) begin
                // r[opb] was pre-incremented by the address; the loaded value
                // wins if it targets the stack register itself.
                r[opb]        <= r[opb] + 16'd1;
                r[preg + 3'd1] <= rdata;
                preg <= preg + 3'd1;
                cnt  <= cnt - 3'd1;
                if (cnt == 3'd1) finish(6'd4 + {2'd0, opn, 1'b0});
            end

            S_RETI_SR: if (ready) begin
                r[SP] <= r[SP] + 16'd1;
                r[SR] <= rdata;
                state <= S_RETI_PC;
            end

            S_RETI_PC: if (ready) begin
                r[SP] <= r[SP] + 16'd1;
                r[PC] <= rdata;
                if (in_fiq)      in_fiq <= 1'b0;
                else if (in_irq) in_irq <= 1'b0;
                finish(6'd8);
            end

            S_CALL_PC: if (ready) begin
                r[SP] <= r[SP] - 16'd1;
                state <= S_CALL_SR;
            end

            S_CALL_SR: if (ready) begin
                r[SP] <= r[SP] - 16'd1;
                r[PC] <= imm;
                r[SR] <= {r[SR][15:6], ir[5:0]};
                finish(6'd9);
            end

            // ----------------------------------------------------------
            S_MUL: begin
                logic [31:0] p;
                p = r[opa] * r[opb];
                if (r[opb][15]) p = p - {r[opa], 16'd0};
                if (op1 == 3'd4 && r[opa][15]) p = p - {r[opb], 16'd0};
                r[R4] <= p[31:16];
                r[R3] <= p[15:0];
                finish(6'd12);
            end

            S_MULS_RD: if (ready) begin
                m_cur        <= rdata;
                m_vals[m_i[3:0]] <= rdata;
                state        <= S_MULS_RS;
            end

            S_MULS_RS: if (ready) begin
                logic [31:0] t;
                t = m_cur * rdata;
                if (m_cur[15]) t = t - {rdata, 16'd0};
                if (rdata[15]) t = t - {m_cur, 16'd0};
                m_acc <= m_acc + 48'($signed(t));
                if (m_i + 5'd1 == m_size) begin
                    sb <= 4'd0;
                    if (fir_move && m_size > 5'd1) begin
                        m_i   <= m_size - 5'd1;
                        state <= S_MULS_WR;
                    end else
                        state <= S_MULS_END;
                end else begin
                    m_i   <= m_i + 5'd1;
                    state <= S_MULS_RD;
                end
            end

            S_MULS_WR: if (ready) begin
                if (m_i == 5'd1) state <= S_MULS_END;
                m_i <= m_i - 5'd1;
            end

            S_MULS_END: begin
                r[opa] <= r[opa] + 16'(m_size);
                r[opb] <= r[opb] + 16'(m_size);
                r[R4]  <= m_acc[31:16];
                r[R3]  <= m_acc[15:0];
                finish(6'd0);
            end

            // ----------------------------------------------------------
            S_WAIT: begin
                if (cyc + 6'd1 >= cost) begin
                    if (!no_irq && int_take) begin
                        int_line <= int_sel;
                        state    <= S_INT_PC;
                    end else
                        state <= S_FETCH;
                end
            end

            S_INT_PC: if (ready) begin
                r[SP] <= r[SP] - 16'd1;
                state <= S_INT_SR;
            end

            S_INT_SR: if (ready) begin
                r[SP] <= r[SP] - 16'd1;
                state <= S_INT_VEC;
            end

            S_INT_VEC: if (ready) begin
                r[PC] <= rdata;
                r[SR] <= 16'd0;
                if (int_line == 4'd0) in_fiq <= 1'b1;
                else                  in_irq <= 1'b1;
                irq_ack      <= 1'b1;
                irq_ack_line <= int_line;
                state        <= S_FETCH;
            end

            default: state <= S_FETCH;
            endcase

            if (ds_we) r[SR][15:10] <= ds_wdata;
        end
    end

    // ALU execute + write-back for register destinations, and the
    // store-to-[imm16] form (op1=4 opn=3) which goes through S_MWR.
    task automatic alu_exec(input logic [15:0] a, input logic [15:0] b, input logic [21:0] e);
        logic [16:0] res;
        logic        wrt, nzsc, nz;
        logic [15:0] b2;
        if (is_store) begin
            // store with a non-memory operand form: MAME writes r0 to r2 (= 0)
            ea       <= e;
            mwr_data <= a;
            state    <= S_MWR;
        end else begin
            alu(op0, a, b, fC, res, wrt, nzsc, nz, b2);
            if (opa != PC) r[SR] <= flags(r[SR], res, a, b2, nzsc, nz);
            if (wrt) r[opa] <= res[15:0];
            finish(alu_cost(op1, opn, opa == PC));
        end
    endtask

    // ------------------------------------------------------------------
    // Bus
    // ------------------------------------------------------------------
    always_comb begin
        addr  = lpc;
        rd    = 1'b0;
        wr    = 1'b0;
        wdata = 16'd0;
        case (state)
            S_RESET:   begin addr = 22'h00fff7; rd = 1'b1; end
            S_FETCH,
            S_IMM:     begin addr = lpc; rd = 1'b1; end
            S_MRD:     begin addr = ea; rd = 1'b1; end
            S_MWR:     begin addr = ea; wr = 1'b1; wdata = mwr_data; end
            S_PUSH:    begin addr = {6'd0, r[opb]}; wr = 1'b1; wdata = r[preg]; end
            S_POP:     begin addr = {6'd0, r[opb] + 16'd1}; rd = 1'b1; end
            S_RETI_SR,
            S_RETI_PC: begin addr = {6'd0, r[SP] + 16'd1}; rd = 1'b1; end
            S_CALL_PC,
            S_INT_PC:  begin addr = {6'd0, r[SP]}; wr = 1'b1; wdata = r[PC]; end
            S_CALL_SR,
            S_INT_SR:  begin addr = {6'd0, r[SP]}; wr = 1'b1; wdata = r[SR]; end
            S_INT_VEC: begin addr = (int_line == 4'd0) ? 22'h00fff6 : 22'h00fff7 + 22'(int_line); rd = 1'b1; end
            S_MULS_RD: begin addr = 22'(r[opa]) + 22'(m_i); rd = 1'b1; end
            S_MULS_RS: begin addr = 22'(r[opb]) + 22'(m_i); rd = 1'b1; end
            S_MULS_WR: begin addr = 22'(r[opa]) + 22'(m_i); wr = 1'b1; wdata = m_vals[m_i[3:0] - 4'd1]; end
            default: ;
        endcase
    end

endmodule
