RTL := ../../rtl/unsp/unsp_core.sv

obj_dir/Vunsp_core: $(RTL) cpu_tb.cpp
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-UNUSEDPARAM \
		--top-module unsp_core $(RTL) cpu_tb.cpp -CFLAGS -O2

clean:
	rm -rf obj_dir

.PHONY: clean
