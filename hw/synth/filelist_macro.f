# Synthesis filelist WITH the sky130 SRAM macros. Read with SYNTHESIS defined
# (genus_synth.tcl does this): the memory wrappers below then instantiate the OpenRAM
# macros (sky130_sram_{1,2,4,8}kbyte_1rw1r_*), which come from the macro .lib files.
# filelist_logic.f is the older logic-only list (memories left as black boxes).
rtl/hdcu_pkg.sv
rtl/spm.sv
rtl/spm_bit_comb.sv
rtl/spm_wide.sv
rtl/soc_mem.sv
rtl/picorv32.v
rtl/binding_unit.sv
rtl/bundling_unit.sv
rtl/clipping_unit.sv
rtl/permutation_unit.sv
rtl/similarity_unit.sv
rtl/search_unit.sv
rtl/hdcu_ctrl.sv
rtl/hdcu_top.sv
rtl/sign_unit.sv
rtl/signed_mac_unit.sv
rtl/dot_accum_unit.sv
rtl/dot_search_unit.sv
rtl/norm_sq_accum_unit.sv
rtl/isqrt_seq_unit.sv
rtl/fixed_div_seq_unit.sv
rtl/nov_ctrl.sv
rtl/hv_gen_unit.sv
rtl/nov_top.sv
rtl/quantize_unit.sv
rtl/pcpi_hdc_bridge.sv
rtl/hdc_soc_top.sv
rtl/seq_divider.sv
rtl/fastatan2_unit.sv
rtl/angle_bin8_unit.sv
rtl/block_match_unit.sv
rtl/hof_unit.sv
rtl/hog_rom.sv
rtl/hog_gradient_unit.sv
rtl/hog_block_hist_unit.sv
rtl/l2hys_unit.sv
rtl/hog_top.sv
rtl/autocorr_unit.sv
rtl/percentile_unit.sv
rtl/meanstd_sums_unit.sv
rtl/vecnorm_unit.sv
rtl/cellnorm_unit.sv
rtl/video_frontend_top.sv
