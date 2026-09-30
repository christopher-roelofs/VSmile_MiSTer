# List setup paths within 0.3 ns of failing on the main clock, grouped by
# source and destination (instance path without bit indices):
#   ~/intelFPGA_lite/17.0/quartus/bin/quartus_sta -t scripts/near_critical.tcl
project_open VSmile
create_timing_netlist
read_sdc
update_timing_netlist
set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set paths [get_timing_paths -setup -to_clock $clk -npaths 20000 -less_than_slack 0.3]
array set grp {}
foreach_in_collection p $paths {
    set f [get_node_info -name [get_path_info -from $p]]
    set t [get_node_info -name [get_path_info -to $p]]
    regsub -all {\[[0-9]+\]|~DUPLICATE|~[0-9_A-Z]+$} $f {} f
    regsub -all {\[[0-9]+\]|~DUPLICATE|~[0-9_A-Z]+$} $t {} t
    set s [get_path_info -slack $p]
    set k "$f -> $t"
    if {![info exists grp($k)] || $s < [lindex $grp($k) 0]} { set grp($k) [list $s [expr {[info exists grp($k)] ? [lindex $grp($k) 1] + 1 : 1}]] } else { set grp($k) [list [lindex $grp($k) 0] [expr {[lindex $grp($k) 1] + 1}]] }
}
set out {}
foreach k [array names grp] { lappend out [list [lindex $grp($k) 0] [lindex $grp($k) 1] $k] }
foreach e [lsort -real -index 0 $out] { puts [format "%7.3f %5d  %s" [lindex $e 0] [lindex $e 1] [lindex $e 2]] }
project_close
