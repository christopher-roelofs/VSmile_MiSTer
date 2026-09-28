// SPG2xx I/O block: 0x3D00-0x3DFF
//   GPIO A/B/C, timebase + 4096 Hz system timer, timers A/B, I/O interrupt
//   controller, external memory control (chip select), watchdog, ADC, PRNG,
//   FIQ source select, DS alias, UART.
//
// Follows MAME spg2xx_io_device (src/devices/machine/spg2xx_io.cpp).
// SPI, SIO and I2C are not used by the V.Smile and are plain registers here.
// All timing runs on `ce` (27 MHz system clock ticks); MAME's attotime
// periodic timers become fractional-N rate generators.

module spg2xx_io (
    input  logic        clk,
    input  logic        reset,
    input  logic        spg28x,         // SPG28x UART baud (MAME spg28x_io_device)
    input  logic        ce,

    // register bus (offset = address - 0x3D00); rd/wr are one-clk strobes
    input  logic [7:0]  addr,
    input  logic        rd,
    input  logic        wr,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,      // valid with rd (combinational)

    // GPIO
    input  logic [15:0] porta_in, portb_in, portc_in,
    output logic [15:0] porta_out, portb_out, portc_out,
    output logic [15:0] porta_oe,  portb_oe,  portc_oe,   // push & ~special
    output logic [2:0]  port_wr,        // strobe: port A/B/C output written
    input  logic [1:0]  cpu_csb,        // LPC[21:20], for port A special bits

    // misc system signals
    output logic [1:0]  cs_mode,        // REG_EXT_MEMORY_CTRL[7:6]
    input  logic [8:0]  vpos,           // for REG_VERT_LINE
    input  logic        pal,
    input  logic [5:0]  cpu_ds,
    output logic        ds_we,
    output logic [5:0]  ds_wdata,
    output logic [2:0]  fiq_sel,
    output logic        fiq_sel_we,
    output logic        watchdog_reset,

    // UART
    output logic        uart_tx_valid,  // one-clk strobe
    output logic [7:0]  uart_tx_data,
    input  logic        uart_rx_valid,  // one-clk strobe
    input  logic [7:0]  uart_rx_data,

    input  logic [1:0]  extint,         // external interrupt levels (ctrl RTS)
    input  logic [1:0]  extint_evt,     // MAME extint_w() calls: status := level

    // interrupt outputs (levels), MAME spg2xx_device routing
    output logic        irq_timer,      // IRQ2
    output logic        irq_uart_adc,   // IRQ3
    output logic        irq_ext,        // IRQ5
    output logic        irq_hifreq,     // IRQ6
    output logic        irq_lofreq      // IRQ7
);

    // ------------------------------------------------------------------
    // Register indices (MAME enum)
    // ------------------------------------------------------------------
    localparam logic [7:0]
        R_IO_MODE = 8'h00,
        R_IOA_DATA = 8'h01, R_IOA_BUF = 8'h02, R_IOA_DIR = 8'h03, R_IOA_ATTR = 8'h04, R_IOA_MASK = 8'h05,
        R_IOB_DATA = 8'h06, R_IOC_MASK = 8'h0f,
        R_TMB_SETUP = 8'h10, R_TMB_CLEAR = 8'h11,
        R_TA_DATA = 8'h12, R_TA_CTRL = 8'h13, R_TA_ON = 8'h14, R_TA_IRQCLR = 8'h15,
        R_TB_DATA = 8'h16, R_TB_CTRL = 8'h17, R_TB_ON = 8'h18, R_TB_IRQCLR = 8'h19,
        R_VERT_LINE = 8'h1c,
        R_SYS_CTRL = 8'h20, R_INT_CTRL = 8'h21, R_INT_CLEAR = 8'h22, R_EXT_MEM = 8'h23,
        R_WDOG_CLR = 8'h24, R_ADC_CTRL = 8'h25, R_ADC_PAD = 8'h26, R_ADC_DATA = 8'h27,
        R_NTSC_PAL = 8'h2b, R_PRNG1 = 8'h2c, R_PRNG2 = 8'h2d, R_FIQ_SEL = 8'h2e, R_DS = 8'h2f,
        R_UART_CTRL = 8'h30, R_UART_STAT = 8'h31, R_UART_BAUD1 = 8'h33, R_UART_BAUD2 = 8'h34,
        R_UART_TXBUF = 8'h35, R_UART_RXBUF = 8'h36, R_UART_RXFIFO = 8'h37;

    localparam int unsigned SYSCLK = 27_000_000;

    // Generic register storage for everything without special handling
    // (MAME's m_io_regs[] default path).  Only 0x00-0x7F is kept.
    logic [15:0] regs [0:127];

    logic [15:0] int_en, int_st;            // 0x21 / 0x22
    logic [15:0] st_set, st_clr;            // per-clk status updates (set wins)
    logic [15:0] ta_data, ta_preload, tb_data, tb_preload;
    logic [15:0] ta_ctrl, tb_ctrl, tb_on;
    logic [15:0] sys_ctrl, ext_mem, tmb_setup;
    logic [15:0] adc_ctrl, adc_pad, adc_data;
    logic [15:0] prng1, prng2;
    logic [15:0] uart_ctrl, uart_stat, uart_baud1, uart_baud2, uart_txbuf, uart_rxbuf, uart_rxfifo;
    logic [15:0] gpio_data [0:2];

    wire [15:0] io_mode = regs[R_IO_MODE];

    assign cs_mode = ext_mem[7:6];

    // ------------------------------------------------------------------
    // Rate generators: tick when acc += inc crosses SYSCLK
    // ------------------------------------------------------------------
    function automatic logic [24:0] rate_step(input logic [24:0] acc, input logic [19:0] inc, output logic tick);
        logic [25:0] s;
        s = {1'b0, acc} + {6'd0, inc};
        if (s >= 26'(SYSCLK)) begin tick = 1'b1; return 25'(s - 26'(SYSCLK)); end
        tick = 1'b0;
        return s[24:0];
    endfunction

    logic [24:0] acc_4k, acc_rng, acc_tmb1, acc_tmb2, acc_ab, acc_c, acc_adc8k;
    logic        t_4k, t_rng, t_tmb1, t_tmb2, t_ab, t_c, t_adc8k;

    // tmb frequencies (MAME s_tmb1_freq / s_tmb2_freq)
    logic [19:0] tmb1_inc, tmb2_inc;
    always_comb begin
        case ({tmb_setup[4], tmb_setup[1:0]})
            3'b000: tmb1_inc = 20'd8;     3'b001: tmb1_inc = 20'd16;
            3'b010: tmb1_inc = 20'd32;    3'b011: tmb1_inc = 20'd64;
            3'b100: tmb1_inc = 20'd12000; 3'b101: tmb1_inc = 20'd24000;
            default: tmb1_inc = 20'd40000;
        endcase
        case ({tmb_setup[4], tmb_setup[3:2]})
            3'b000: tmb2_inc = 20'd128;    3'b001: tmb2_inc = 20'd256;
            3'b010: tmb2_inc = 20'd512;    3'b011: tmb2_inc = 20'd1024;
            3'b100: tmb2_inc = 20'd105000; 3'b101: tmb2_inc = 20'd210000;
            3'b110: tmb2_inc = 20'd420000; default: tmb2_inc = 20'd840000;
        endcase
    end
    logic tmb_armed;   // MAME timers tmb1/tmb2 start 'never' until setup is written

    // timer A source (ta_ctrl[2:0]) and B divisor (ta_ctrl[5:3])
    logic [19:0] ab_inc;
    always_comb case (ta_ctrl[2:0])
        3'd2: ab_inc = 20'd32768;
        3'd3: ab_inc = 20'd8192;
        3'd4: ab_inc = 20'd4096;
        default: ab_inc = 20'd0;
    endcase
    logic [15:0] tb_tick_rate;
    always_comb begin
        logic [15:0] ra;
        ra = 16'(ab_inc);   // 32768 fits in 16 bits
        case (ta_ctrl[5:3])
            3'd0: tb_tick_rate = ra >> 11;
            3'd1: tb_tick_rate = ra >> 10;
            3'd2: tb_tick_rate = ra >> 8;
            3'd4: tb_tick_rate = ra >> 2;
            3'd5: tb_tick_rate = ra >> 1;
            3'd6: tb_tick_rate = 16'd1;
            default: tb_tick_rate = 16'd0;
        endcase
    end
    logic [15:0] tb_divisor;

    logic [19:0] c_inc;
    always_comb case (tb_ctrl[2:0])
        3'd2: c_inc = 20'd32768;
        3'd3: c_inc = 20'd8192;
        3'd4: c_inc = 20'd4096;
        default: c_inc = 20'd0;
    endcase

    // system timer dividers
    logic [1:0] div_2k, div_1k;
    logic [8:0] div_4hz;

    // watchdog: 750 ms
    localparam int unsigned WDOG_TICKS = SYSCLK / 1000 * 750;
    logic [24:0] wdog_cnt;
    logic        wdog_run;

    // ADC one-shot conversion timer
    logic [7:0]  adc_cnt;
    logic        adc_busy, adc_auto;

    // UART
    logic [7:0]  rx_fifo [0:7];
    logic [2:0]  rx_start, rx_end;
    logic [3:0]  rx_count;
    logic        rx_available, rx_irq /* verilator public_flat_rd */, tx_irq;
    logic [23:0] tx_cnt, rx_cnt;
    logic        tx_busy, rx_busy;
    // frame = (10|11 bits) * 16 * (0x10000 - baud) system clocks
    // SPG28x: a BAUD1 write sets 27 MHz / (0x10000 - BAUD1) baud (no x16);
    // a later BAUD2 write goes back to the common formula
    logic        baud28;
    wire  [15:0] baud_lo    = spg28x ? uart_baud1 : {8'd0, uart_baud1[7:0]};
    wire  [16:0] uart_div   = 17'h10000 - {1'b0, 16'({uart_baud2[7:0], 8'd0} | baud_lo)};
    wire  [16:0] uart_div28 = 17'h10000 - {1'b0, uart_baud1};
    // two register stages (divisor, then the multiply: off the counters'
    // load path and the baud registers' fan-in); a baud or control write
    // takes effect two clks later, long before the CPU can start a byte
    logic [20:0] uart_bits;             // clocks per bit
    logic [23:0] uart_frame;
    always_ff @(posedge clk) begin
        uart_bits  <= (spg28x && baud28) ? {4'd0, uart_div28} : {uart_div, 4'd0};
        uart_frame <= 24'(uart_ctrl[5] ? 11 : 10) * {3'd0, uart_bits};
    end

    // ------------------------------------------------------------------
    // GPIO (MAME do_gpio)
    // ------------------------------------------------------------------
    function automatic logic [15:0] gpio_what(input int p);
        logic [15:0] buffer, dir, attr, special, w;
        buffer  = regs[5 * p + 2];
        dir     = regs[5 * p + 3];
        attr    = regs[5 * p + 4];
        special = regs[5 * p + 5];
        w = buffer ^ (dir & ~attr);
        return w & ~special;
    endfunction

    function automatic logic [15:0] gpio_special(input int p);
        if (p == 0 && (regs[R_IOA_MASK] & 16'he000) != 16'd0) begin
            logic [3:0] csel;
            csel = (4'd1 << cpu_csb) & 4'he;
            return {csel[3:1], 13'd0} & regs[R_IOA_MASK];
        end
        return 16'd0;
    endfunction

    logic [15:0] port_in [0:2];
    assign port_in[0] = porta_in;
    assign port_in[1] = portb_in;
    assign port_in[2] = portc_in;

    function automatic logic [15:0] gpio_read(input int p);
        logic [15:0] dir;
        dir = regs[5 * p + 3];
        return (gpio_what(p) & dir) | (port_in[p] & ~dir) | gpio_special(p);
    endfunction

    always_comb begin
        porta_out = gpio_what(0);  porta_oe = regs[R_IOA_DIR] & ~regs[R_IOA_MASK];
        portb_out = gpio_what(1);  portb_oe = regs[8'h08]     & ~regs[8'h0a];
        portc_out = gpio_what(2);  portc_oe = regs[8'h0d]     & ~regs[R_IOC_MASK];
    end

    // GPIO register writes that run do_gpio(write): data (redirected to
    // buffer), buffer, dir, attr, and port C's mask.  MAME also recomputes
    // the stored data register there; reads recompute it live (gpio_read),
    // so that value is never observed and is not kept.
    function automatic logic gpio_touch(input logic [7:0] a, output logic [1:0] p);
        case (a)
            8'h01, 8'h02, 8'h03, 8'h04: begin p = 2'd0; return 1'b1; end
            8'h06, 8'h07, 8'h08, 8'h09: begin p = 2'd1; return 1'b1; end
            8'h0b, 8'h0c, 8'h0d, 8'h0e, 8'h0f: begin p = 2'd2; return 1'b1; end
            default: begin p = 2'd0; return 1'b0; end
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Read mux
    // ------------------------------------------------------------------
    always_comb begin
        rdata = (addr < 8'h80) ? regs[addr[6:0]] : 16'd0;
        case (addr)
            R_IOA_DATA:   rdata = gpio_read(0);
            8'h06:        rdata = gpio_read(1);
            8'h0b:        rdata = gpio_read(2);
            R_TMB_SETUP:  rdata = tmb_setup;
            R_TA_DATA:    rdata = ta_data;
            R_TA_CTRL:    rdata = ta_ctrl;
            R_TB_DATA:    rdata = tb_data;
            R_TB_CTRL:    rdata = tb_ctrl;
            R_TB_ON:      rdata = tb_on;
            R_VERT_LINE:  rdata = {7'd0, vpos};
            R_SYS_CTRL:   rdata = sys_ctrl;
            R_INT_CTRL:   rdata = int_en;
            R_INT_CLEAR:  rdata = int_st;
            R_EXT_MEM:    rdata = ext_mem;
            R_ADC_CTRL:   rdata = adc_ctrl;
            R_ADC_PAD:    rdata = adc_pad;
            R_ADC_DATA:   rdata = adc_data;
            R_NTSC_PAL:   rdata = {15'd0, pal};
            R_PRNG1:      rdata = prng1;
            R_PRNG2:      rdata = prng2;
            R_DS:         rdata = {10'd0, cpu_ds};
            R_UART_CTRL:  rdata = uart_ctrl;
            R_UART_STAT:  rdata = uart_stat;
            R_UART_BAUD1: rdata = uart_baud1;
            R_UART_BAUD2: rdata = uart_baud2;
            R_UART_TXBUF: rdata = uart_txbuf;
            R_UART_RXBUF: rdata = (rx_available && rx_count != 0) ? {8'd0, rx_fifo[rx_start]} : uart_rxbuf;
            R_UART_RXFIFO: rdata = {uart_rxfifo[15:7], rx_available ? 3'd7 : 3'd0, uart_rxfifo[3:0]};
            default: ;
        endcase
    end

    function automatic logic [15:0] prng_next(input logic [15:0] v);
        return {1'b0, v[13:0], v[14] ^ v[13]};
    endfunction

    // ------------------------------------------------------------------
    // Interrupt outputs
    // ------------------------------------------------------------------
    wire [15:0] act = int_en & int_st;
    assign irq_timer    = |(act & 16'h0c00);
    assign irq_uart_adc = |(act & 16'h6100);
    assign irq_ext      = |(act & 16'h1200);
    assign irq_hifreq   = |(act & 16'h0070);
    assign irq_lofreq   = |(act & 16'h008b);

    // ------------------------------------------------------------------
    // Sequential
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        port_wr        <= 3'd0;
        ds_we          <= 1'b0;
        fiq_sel_we     <= 1'b0;
        uart_tx_valid  <= 1'b0;
        watchdog_reset <= 1'b0;

        if (reset) begin
            regs <= '{default: 16'd0};
            int_en <= 0; int_st <= 0;
            ta_data <= 0; ta_preload <= 0; tb_data <= 0; tb_preload <= 0;
            ta_ctrl <= 0; tb_ctrl <= 0; tb_on <= 0; tb_divisor <= 0;
            sys_ctrl <= 0; ext_mem <= 16'h0028; tmb_setup <= 0; tmb_armed <= 0;
            adc_ctrl <= 0; adc_pad <= 0; adc_data <= 0; adc_busy <= 0; adc_auto <= 0;
            prng1 <= 16'h1418; prng2 <= 16'h1658;
            uart_ctrl <= 0; uart_stat <= 0; uart_baud1 <= 0; uart_baud2 <= 0; baud28 <= 0;
            uart_txbuf <= 0; uart_rxbuf <= 0; uart_rxfifo <= 0;
            rx_start <= 0; rx_end <= 0; rx_count <= 0;
            rx_available <= 0; rx_irq <= 0; tx_irq <= 0; tx_busy <= 0; rx_busy <= 0;
            acc_4k <= 0; acc_rng <= 0; acc_tmb1 <= 0; acc_tmb2 <= 0; acc_ab <= 0; acc_c <= 0; acc_adc8k <= 0;
            div_2k <= 0; div_1k <= 0; div_4hz <= 0;
            wdog_run <= 0; wdog_cnt <= 0;
        end else begin
            st_set = 16'd0;
            st_clr = 16'd0;

            // ---------------- timers (27 MHz ticks) ----------------
            if (ce) begin
                acc_4k <= rate_step(acc_4k, 20'd4096, t_4k);
                if (t_4k) begin   // MAME system_timer_tick
                    st_set[6] = 1'b1;
                    if (div_2k == 2'd1) begin
                        div_2k <= 0;
                        st_set[5] = 1'b1;
                        if (div_1k == 2'd1) begin
                            div_1k <= 0;
                            st_set[4] = 1'b1;
                            if (div_4hz == 9'd255) begin
                                div_4hz <= 0;
                                st_set[3] = 1'b1;
                            end else div_4hz <= div_4hz + 9'd1;
                        end else div_1k <= div_1k + 2'd1;
                    end else div_2k <= div_2k + 2'd1;
                end

                acc_rng <= rate_step(acc_rng, 20'd1234, t_rng);
                if (t_rng) begin
                    prng1 <= prng_next(prng1);
                    prng2 <= prng_next(prng2);
                end

                if (tmb_armed) begin
                    acc_tmb1 <= rate_step(acc_tmb1, tmb1_inc, t_tmb1);
                    acc_tmb2 <= rate_step(acc_tmb2, tmb2_inc, t_tmb2);
                    if (t_tmb1) st_set[0] = 1'b1;
                    if (t_tmb2) st_set[1] = 1'b1;
                end

                if (ab_inc != 0) begin   // MAME timer_ab_tick
                    acc_ab <= rate_step(acc_ab, ab_inc, t_ab);
                    if (t_ab && tb_tick_rate != 0) begin
                        if (tb_divisor + 16'd1 >= tb_tick_rate) begin
                            tb_divisor <= 0;
                            if (ta_data == 16'hffff) begin
                                ta_data <= ta_preload;
                                st_set[11] = 1'b1;
                            end else ta_data <= ta_data + 16'd1;
                        end else tb_divisor <= tb_divisor + 16'd1;
                    end
                end

                if (tb_on[0] && c_inc != 0) begin   // MAME timer_c_tick
                    acc_c <= rate_step(acc_c, c_inc, t_c);
                    if (t_c) begin
                        if (tb_data == 16'hffff) begin
                            tb_data <= tb_preload;
                            st_set[10] = 1'b1;
                        end else tb_data <= tb_data + 16'd1;
                    end
                end

                if (wdog_run) begin
                    if (wdog_cnt == 25'(WDOG_TICKS - 1)) begin
                        wdog_run       <= 1'b0;
                        watchdog_reset <= 1'b1;
                    end else wdog_cnt <= wdog_cnt + 25'd1;
                end

                // ADC conversion done (MAME adc_convert_tick, adc_in = 0x0FFF)
                if (adc_busy) begin
                    if (adc_cnt == 8'd1) begin
                        adc_busy <= adc_auto;
                        adc_done();
                    end
                    adc_cnt <= adc_cnt - 8'd1;
                end
                if (adc_auto) begin
                    acc_adc8k <= rate_step(acc_adc8k, 20'd8000, t_adc8k);
                    if (t_adc8k) adc_done();
                end

                // UART transmit / receive frame timers
                if (tx_busy) begin
                    if (tx_cnt == 24'd1) begin   // MAME uart_transmit_tick
                        tx_busy       <= 1'b0;
                        uart_tx_valid <= 1'b1;
                        uart_tx_data  <= uart_txbuf[7:0];
                        uart_stat[1]  <= 1'b1;
                        uart_stat[6]  <= 1'b0;
                        if (uart_ctrl[1]) begin
                            st_set[8] = 1'b1;
                            tx_irq    <= 1'b1;
                        end
                    end
                    tx_cnt <= tx_cnt - 24'd1;
                end
                if (rx_busy) begin
                    if (rx_cnt == 24'd1) begin   // MAME uart_receive_tick
                        rx_busy      <= 1'b0;
                        uart_stat    <= uart_stat | 16'h0081;
                        rx_available <= 1'b1;
                        if (uart_ctrl[0]) begin
                            rx_irq    <= 1'b1;
                            st_set[8] = 1'b1;
                        end
                    end
                    rx_cnt <= rx_cnt - 24'd1;
                end
            end


            // UART receive from controller (MAME uart_rx)
            if (uart_rx_valid && uart_ctrl[6]) begin
                rx_fifo[rx_end] <= uart_rx_data;
                rx_end          <= rx_end + 3'd1;
                rx_count        <= rx_count + 4'd1;
                if (!rx_busy) begin
                    rx_busy <= 1'b1;
                    rx_cnt  <= uart_frame;
                end
            end

            // ---------------- register reads with side effects ----------------
            if (rd) begin
                case (addr)
                    R_IOA_DATA: regs[R_IOA_DATA] <= gpio_read(0);
                    8'h06:      regs[8'h06]      <= gpio_read(1);
                    8'h0b:      regs[8'h0b]      <= gpio_read(2);
                    R_PRNG1:    prng1 <= prng_next(prng1);
                    R_PRNG2:    prng2 <= prng_next(prng2);
                    R_UART_RXBUF: begin
                        if (rx_available) begin
                            uart_stat <= uart_stat & ~16'h0081;
                            if (rx_count != 0) begin
                                uart_rxbuf <= {8'd0, rx_fifo[rx_start]};
                                rx_start   <= rx_start + 3'd1;
                                rx_count   <= rx_count - 4'd1;
                                if (rx_count == 4'd1)
                                    rx_available <= 1'b0;
                                else if (!rx_busy) begin
                                    rx_busy <= 1'b1;
                                    rx_cnt  <= uart_frame;
                                end
                            end else
                                rx_available <= 1'b0;
                        end else
                            uart_rxfifo[13] <= 1'b1;
                    end
                    default: ;
                endcase
            end

            // ---------------- register writes ----------------
            if (wr) begin
                logic [1:0] p;
                // default path (MAME stores the value except for these strobes)
                if (addr < 8'h80 && addr != R_TMB_CLEAR && addr != R_TA_IRQCLR && addr != R_TB_IRQCLR
                    && addr != R_WDOG_CLR && addr != R_UART_STAT && addr != R_UART_RXBUF)
                    regs[addr[6:0]] <= wdata;
                if (gpio_touch(addr, p)) begin
                    // data writes go to the buffer register
                    if (addr == R_IOA_DATA || addr == 8'h06 || addr == 8'h0b)
                        regs[addr[6:0] + 7'd1] <= wdata;
                    port_wr[p] <= 1'b1;
                end
                case (addr)
                    R_TMB_SETUP: begin
                        tmb_setup <= wdata;
                        tmb_armed <= 1'b1;
                        acc_tmb1  <= 0;
                        acc_tmb2  <= 0;
                    end
                    R_TMB_CLEAR: begin div_2k <= 0; div_1k <= 0; div_4hz <= 0; end
                    R_TA_DATA:   begin ta_data <= wdata; ta_preload <= wdata; end
                    R_TA_CTRL:   begin ta_ctrl <= wdata; acc_ab <= 0; end
                    R_TA_IRQCLR: st_clr[11] = 1'b1;
                    R_TB_DATA:   begin tb_data <= wdata; tb_preload <= wdata; end
                    R_TB_CTRL:   begin tb_ctrl <= wdata; if (tb_on[0]) acc_c <= 0; end
                    R_TB_ON:     begin tb_on <= {15'd0, wdata[0]}; acc_c <= 0; end
                    R_TB_IRQCLR: st_clr[10] = 1'b1;
                    R_SYS_CTRL: begin
                        sys_ctrl <= wdata;
                        if (sys_ctrl[15] != wdata[15]) begin
                            wdog_run <= wdata[15];
                            wdog_cnt <= 0;
                        end
                    end
                    R_INT_CTRL:  int_en <= wdata;
                    R_INT_CLEAR: begin
                        st_clr = st_clr | wdata;
                        if (rx_irq || tx_irq) st_set[8] = 1'b1;
                    end
                    R_EXT_MEM:   ext_mem <= wdata;
                    R_WDOG_CLR:  if (wdata == 16'h55aa && sys_ctrl[15]) wdog_cnt <= 0;
                    R_ADC_CTRL:  adc_ctrl_write(wdata);
                    R_ADC_PAD: begin
                        adc_pad <= wdata;
                        if (!wdata[(adc_ctrl >> 4) & 2'd3]) begin adc_busy <= 0; adc_auto <= 0; end
                    end
                    R_PRNG1:     prng1 <= wdata & 16'h7fff;
                    R_PRNG2:     prng2 <= wdata & 16'h7fff;
                    R_FIQ_SEL: begin fiq_sel <= wdata[2:0]; fiq_sel_we <= 1'b1; end
                    R_DS:      begin ds_we <= 1'b1; ds_wdata <= wdata[5:0]; end
                    R_UART_CTRL: begin
                        uart_ctrl <= wdata;
                        if (!wdata[6]) begin rx_available <= 0; uart_rxbuf <= 0; end
                        if (uart_ctrl[7] != wdata[7]) begin
                            if (wdata[7]) uart_stat[1] <= 1'b1;
                            else begin
                                uart_stat <= uart_stat & ~16'h0042;
                                tx_busy   <= 1'b0;
                            end
                        end
                    end
                    R_UART_STAT: begin
                        logic nrx, ntx;
                        nrx = wdata[0] ? 1'b0 : rx_irq;
                        ntx = wdata[1] ? 1'b0 : tx_irq;
                        if (wdata[0]) uart_stat[0] <= 1'b0;
                        if (wdata[1]) uart_stat[1] <= 1'b0;
                        rx_irq <= nrx;
                        tx_irq <= ntx;
                        if (!nrx && !ntx) st_clr[8] = 1'b1;
                    end
                    R_UART_BAUD1: begin uart_baud1 <= wdata; baud28 <= 1'b1; end
                    R_UART_BAUD2: begin uart_baud2 <= wdata; baud28 <= 1'b0; end
                    R_UART_TXBUF: begin
                        uart_txbuf <= wdata;
                        if (uart_ctrl[7]) begin
                            tx_busy      <= 1'b1;
                            tx_cnt       <= uart_frame;
                            uart_stat[1] <= 1'b0;
                            uart_stat[6] <= 1'b1;
                        end
                    end
                    R_UART_RXBUF: ;
                    R_UART_RXFIFO: begin
                        if (wdata[15]) begin rx_available <= 0; uart_rxbuf <= 0; end
                        uart_rxfifo <= (uart_rxfifo & ~wdata & 16'h6000) | {13'd0, wdata[2:0]};
                    end
                    default: ;
                endcase
            end

            begin
                logic [15:0] ns;
                ns = (int_st & ~st_clr) | st_set;
                // MAME check_extint_irq: the status bit follows the line only
                // when the device drives it; the CPU may clear it in between
                if (extint_evt[0]) ns[9]  = extint[0];
                if (extint_evt[1]) ns[12] = extint[1];
                int_st <= ns;
            end
        end
    end

    task automatic adc_done;
        adc_data    <= 16'h8fff;          // (0x0FFF & 0x0FFF) | 0x8000
        adc_ctrl[13] <= 1'b1;
        if (adc_ctrl[9]) st_set[13] = 1'b1;
    endtask

    // MAME REG_ADC_CTRL write
    task automatic adc_ctrl_write(input logic [15:0] v);
        logic [15:0] c;
        c = v & ~16'h2000;
        if (adc_ctrl[13] && v[13]) st_clr[13] = 1'b1;
        if (c[0]) begin
            c[13] = 1'b1;
            if (!adc_ctrl[12] && c[12]) begin
                c = c & ~16'h3000;
                adc_busy <= 1'b1;
                adc_cnt  <= 8'(16 << c[3:2]);
                adc_data[15] <= 1'b0;
            end
            if (v[10]) begin
                adc_data[15] <= 1'b0;
                adc_auto  <= 1'b1;
                acc_adc8k <= 0;
            end
        end else begin
            adc_busy <= 1'b0;
            adc_auto <= 1'b0;
        end
        adc_ctrl <= c;
    endtask

endmodule
