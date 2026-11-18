# filelist.f — compile/elaboration order for the HDC video pipeline SoC.
# Usage: most tools accept this directly, e.g.
#   genus -files filelist.f          (Cadence Genus)
#   read_verilog -sv -f filelist.f   (Synopsys DC, inside a script)
#   vlog -f filelist.f               (Questa/ModelSim)
# Paths are relative to this file's directory (the package root).
#
# hdcu_pkg.sv MUST be compiled first: every other file does `import hdcu_pkg::*;`
# at file scope, and single-pass compilers (Icarus in particular) fail if the
# package isn't already elaborated when the import is seen.

rtl/hdcu_pkg.sv

# ---- RISC-V core (3rd-party, PicoRV32) ----
rtl/picorv32.v

# ---- HDC core (paper baseline) ----
rtl/binding_unit.sv
rtl/bundling_unit.sv
rtl/clipping_unit.sv
rtl/permutation_unit.sv
rtl/similarity_unit.sv
rtl/search_unit.sv
rtl/spm.sv
rtl/spm_bit_comb.sv
rtl/spm_wide.sv
rtl/hdcu_ctrl.sv
rtl/hdcu_top.sv

# ---- Novelty: non-binary / weighted / retrainable extension ----
rtl/sign_unit.sv
rtl/signed_mac_unit.sv
rtl/dot_accum_unit.sv
rtl/dot_search_unit.sv
rtl/norm_sq_accum_unit.sv
rtl/isqrt_seq_unit.sv
rtl/fixed_div_seq_unit.sv
rtl/hv_gen_unit.sv
rtl/nov_ctrl.sv
rtl/nov_top.sv

# ---- RISC-V integration ----
rtl/quantize_unit.sv
rtl/pcpi_hdc_bridge.sv
rtl/soc_mem.sv             # main memory model (replace with SRAM macro in synthesis)
rtl/hdc_soc_top.sv

# ---- Video front end: shared arithmetic primitives ----
rtl/seq_divider.sv
rtl/fastatan2_unit.sv
rtl/angle_bin8_unit.sv

# ---- Video front end: feature blocks ----
rtl/block_match_unit.sv
rtl/hof_unit.sv
rtl/hog_rom.sv
rtl/hog_gradient_unit.sv
rtl/hog_block_hist_unit.sv
rtl/l2hys_unit.sv
rtl/hog_top.sv
rtl/autocorr_unit.sv
rtl/percentile_unit.sv
rtl/meanstd_sums_unit.sv   # streaming mean/std (rtl/meanstd_unit.sv is the legacy two-pass unit, not used)
rtl/vecnorm_unit.sv
rtl/cellnorm_unit.sv

# ---- Video front end: top-level orchestrator ----
# streaming version (2-slot frame store, running sums). Runs to completion
# (1,087,245 cycles at NUM_FRAMES=4) with all 1010 outputs bit-exact vs
# verification/full_pipeline_golden.py.
rtl/video_frontend_top.sv
