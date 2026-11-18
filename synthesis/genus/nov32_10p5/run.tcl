set PDK_ROOT {/path/to/sky130A}
set TOP nov_top
set LANE 32
set CLK_NS 10.5
set OUT {<repo>/hw/synth/out/nov32_10p5}
set VCD {<repo>/hw/synth/vcd/nov32.vcd}
set VCD_SCOPE {tb_sw_flow/dut/u_nov}
source {<repo>/hw/synth/genus_synth.tcl}
exit
