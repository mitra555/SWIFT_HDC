set PDK_ROOT {/path/to/sky130A}
set TOP nov_top
set LANE 16
set CLK_NS 10.0
set OUT {<repo>/hw/synth/out/nov16_10p0}
set VCD {<repo>/hw/synth/vcd/nov16.vcd}
set VCD_SCOPE {tb_sw_flow/dut/u_nov}
source {<repo>/hw/synth/genus_synth.tcl}
exit
