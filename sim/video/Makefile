obj_dir/Vvsmile_video: ../../rtl/vsmile_video.sv video_tb.cpp
	verilator --cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-style --top-module vsmile_video ../../rtl/vsmile_video.sv video_tb.cpp -CFLAGS -O2

clean:
	rm -rf obj_dir
.PHONY: clean
