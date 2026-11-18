foreach f [glob $::env(LIBDIR)/*.lib] { read_liberty $f }
read_verilog $::env(NET)
link_design $::env(TOP)
create_clock -name clk -period 10 [get_ports clk]
set_power_activity -input -activity 0.1 -duty 0.5
source $::env(ACT)
report_power -digits 5
