derive_pll_clocks
derive_clock_uncertainty

# Console, SDRAM controller and hps_io run on the 108 MHz PLL output; the
# scan-out and the framework's video path on the 54 MHz output of the same
# PLL, so the crossings between them are timed as related clocks.

# The joystick model steps only on the 27 MHz tick: its internal paths have
# four clocks (the resampled inputs and the drain also update on that tick).
set_multicycle_path -setup 4 -from [get_registers {*vsmile_pad:pad1|*}] -to [get_registers {*vsmile_pad:pad1|*}]
set_multicycle_path -hold  3 -from [get_registers {*vsmile_pad:pad1|*}] -to [get_registers {*vsmile_pad:pad1|*}]

# The Smart Keyboard model steps the same way (vsmile_kbd, 27 MHz tick).
set_multicycle_path -setup 4 -from [get_registers {*vsmile_kbd:kbd1|*}] -to [get_registers {*vsmile_kbd:kbd1|*}]
set_multicycle_path -hold  3 -from [get_registers {*vsmile_kbd:kbd1|*}] -to [get_registers {*vsmile_kbd:kbd1|*}]

# The Port 1 device flags (keyboard / mat / tablet) are static settings that
# change only with the OSD option or a cart load, and the controller models
# are held in reset across a change: their paths get the models' 4 clocks.
set_multicycle_path -setup 4 -from [get_registers {emu:emu|kbd emu:emu|mat emu:emu|pen}]
set_multicycle_path -hold  3 -from [get_registers {emu:emu|kbd emu:emu|mat emu:emu|pen}]
