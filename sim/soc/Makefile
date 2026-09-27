RTL := ../../rtl/vsmile.sv ../../rtl/vsmile_pad.sv ../../rtl/vsmile_kbd.sv $(wildcard ../../rtl/spg2xx/*.sv) ../../rtl/unsp/unsp_core.sv

obj_dir/Vvsmile: $(RTL) soc_tb.cpp
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-lint -Wno-style \
		--top-module vsmile $(RTL) soc_tb.cpp -CFLAGS -O2

clean:
	rm -rf obj_dir

.PHONY: clean
