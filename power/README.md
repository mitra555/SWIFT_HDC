# Power and energy estimate

Estimated from the Genus netlists in `synthesis/genus/` (no re-synthesis).

Logic: OpenSTA 3.1 on <run>/<top>_netlist.v + sky130_fd_sc_hd tt_025C_1v80. vcdact.py maps the RTL VCD
toggle rates onto flip-flop Q pins, SRAM dout pins and inputs (per operation window via T0/T1 env, in ps);
OpenSTA propagates them (pwr2.tcl). *.pwr = report_power; the "Macro" row is the OpenRAM liberty model,
which charges every clock edge, so it is NOT used.
SRAM: per-access energy = OpenRAM datasheet power at the 100 MHz event frequency / 100 MHz
(2KB 69.0 pJ, 4KB 128.8 pJ, 8KB 211.4 pJ, 1KB interpolated 39 pJ) x accesses counted in simulation
(*.json, binop.py gives accesses per operation).
power_model.txt: the relative figures used in the paper.
Cross-checks: baseline register power vs Genus within 6%; wide-SPM energy vs liberty model within 15%.
