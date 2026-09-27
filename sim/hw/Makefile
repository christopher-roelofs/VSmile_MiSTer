# The controller drives SDRAM_DQ with 'Z from inside an always block, which
# Verilator does not support: sdram_sim.sv is the same code with an explicit
# output enable, generated from rtl/sdram.sv.
all: obj_dir/Vvsmile_hw
.PHONY: all

RTL := ../../rtl/vsmile.sv ../../rtl/vsmile_pad.sv ../../rtl/vsmile_kbd.sv ../../rtl/vsmile_baby.sv ../../rtl/vsmile_sdram.sv $(wildcard ../../rtl/spg2xx/*.sv) ../../rtl/unsp/unsp_core.sv vsmile_hw.sv sdram_model.sv altddio_out.sv

sdram_sim.sv: ../../rtl/sdram.sv
	sed -e 's/inout  reg \[15:0\] SDRAM_DQ,/inout  wire [15:0] SDRAM_DQ,/' \
	    -e 's/^assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A\[12:11\];/&\nlogic [15:0] dq_o; logic dq_oe; assign SDRAM_DQ = dq_oe ? dq_o : 16'"'"'bz;/' \
	    -e 's/SDRAM_DQ <= 16'"'"'bZ;/dq_oe <= 1'"'"'b0;/' \
	    -e 's/SDRAM_DQ *<= saved_data\[15:0\];/begin dq_o <= saved_data[15:0]; dq_oe <= 1'"'"'b1; end/' \
	    -e 's/SDRAM_DQ *<= saved_data\[31:16\];/begin dq_o <= saved_data[31:16]; dq_oe <= 1'"'"'b1; end/' \
	    -e 's/reg  \[3:0\] state = STATE_STARTUP;/reg  [3:0] state;/' \
	    $< > $@

obj_dir/Vvsmile_hw: $(RTL) sdram_sim.sv ../soc/soc_tb.cpp ../soc/ppu_ref.h
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-lint -Wno-style \
		--top-module vsmile_hw $(RTL) sdram_sim.sv ../soc/soc_tb.cpp -CFLAGS "-O2 -DHW_TOP -I../../soc"

clean:
	rm -rf obj_dir sdram_sim.sv
.PHONY: clean
