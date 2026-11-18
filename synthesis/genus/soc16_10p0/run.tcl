set PDK_ROOT {/path/to/sky130A}
set TOP hdc_soc_top
set LANE 16
set CLK_NS 10.0
set OUT {<repo>/hw/synth/out/soc16_10p0}
set VCD {<repo>/hw/synth/vcd/busy16.vcd}
set VCD_SCOPE {tb_sw_flow/dut}
source {<repo>/hw/synth/genus_synth.tcl}
exit
