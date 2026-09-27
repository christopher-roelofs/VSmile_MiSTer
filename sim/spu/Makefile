RTL := ../../rtl/spg2xx/spg2xx_spu.sv

obj_dir/Vspg2xx_spu: $(RTL) spu_tb.cpp
	verilator --cc --exe --build -O3 -j 0 -Wno-fatal -Wno-lint -Wno-style \
		--top-module spg2xx_spu $(RTL) spu_tb.cpp -CFLAGS -O2

clean:
	rm -rf obj_dir

.PHONY: clean
