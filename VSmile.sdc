derive_pll_clocks
derive_clock_uncertainty

# Everything (console, SDRAM controller, hps_io, video) runs on the single
# 108 MHz PLL output; the second PLL output is unused.

# The joystick model steps only on the 27 MHz tick: its internal paths have
# four clocks (the resampled inputs and the drain also update on that tick).
set_multicycle_path -setup 4 -from [get_registers {*vsmile_pad:pad1|*}] -to [get_registers {*vsmile_pad:pad1|*}]
set_multicycle_path -hold  3 -from [get_registers {*vsmile_pad:pad1|*}] -to [get_registers {*vsmile_pad:pad1|*}]
