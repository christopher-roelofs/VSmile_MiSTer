# List the worst setup paths of the compiled design (run after a build):
#   ~/intelFPGA_lite/17.0/quartus/bin/quartus_sta -t scripts/worst_paths.tcl
project_open VSmile
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 12 -detail summary -panel_name "Worst setup" -stdout
project_close
