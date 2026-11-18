#!/usr/bin/env bash
# =============================================================================
# run_all.sh -- full regression for the HDC video pipeline package.
#
#   ./run_all.sh            all unit / integration testbenches (Icarus, ~10 min)
#   ./run_all.sh --e2e      also the full video_frontend_top run (Verilator,
#                           ~1.09M cycles) compared against the golden model
#   ./run_all.sh --hog      also standalone hog_top vs real cv2.HOGDescriptor
#                           (needs OpenCV 4.x; OpenCV 5 dropped HOGDescriptor)
#
# Requires: iverilog (>=12), python3 + numpy; verilator (>=5) for --e2e/--hog.
# Every testbench prints a scoreboard; this script greps for its pass line and
# exits non-zero if any testbench fails.
# =============================================================================
set -u
PKG="$(cd "$(dirname "$0")" && pwd)"
RUN="${RUN_DIR:-/tmp/hdc_regress}"
# Novelty lane width: NOV_LANE=16 (default, paper configuration) or NOV_LANE=32 (int32 variant)
LANE="${NOV_LANE:-16}"
case "$LANE" in 16) LANEDEF="";; 32) LANEDEF="-DNOV_LANE32";; *) echo "NOV_LANE must be 16 or 32"; exit 2;; esac
echo "novelty lane width: $LANE bits"
E2E=0; HOG=0
for a in "$@"; do case "$a" in --e2e) E2E=1;; --hog) HOG=1;; esac; done

rm -rf "$RUN"; mkdir -p "$RUN"; cd "$RUN" || exit 1
cp "$PKG"/rtl/*.sv "$PKG"/rtl/*.v "$PKG"/tb/*.sv "$PKG"/tb/*.svh "$PKG"/tb/*.txt "$PKG"/tb/*.hex .
cp "$PKG"/sw/program.hex .

python3 "$PKG"/scripts/gen_meanstd_cases.py  >/dev/null
python3 "$PKG"/scripts/gen_vecnorm_cases.py  >/dev/null
python3 "$PKG"/scripts/gen_cellnorm_cases.py >/dev/null
python3 "$PKG"/scripts/gen_hvgen_cases.py   >/dev/null

FAILS=0
# run NAME PASS_REGEX FILES...
run() {
  local name="$1" pat="$2"; shift 2
  if ! iverilog -g2012 $LANEDEF -I. -o "$name.out" "$@" >"$name.build.log" 2>&1; then
    printf "%-26s BUILD FAILED (see %s/%s.build.log)\n" "$name" "$RUN" "$name"; FAILS=$((FAILS+1)); return
  fi
  timeout 1800 vvp -n "$name.out" >"$name.log" 2>&1
  local line; line="$(grep -E 'SCOREBOARD|ALL PASS|PASS:|FAIL|unsupported_op' "$name.log" | tail -1)"
  if grep -qE "$pat" "$name.log" && ! grep -qE "FAIL|TIMEOUT|HANG" "$name.log"; then
    printf "%-26s PASS  %s\n" "$name" "$line"
  else
    printf "%-26s FAIL  %s  (log: %s/%s.log)\n" "$name" "$line" "$RUN" "$name"; FAILS=$((FAILS+1))
  fi
}

PKGF=hdcu_pkg.sv
SOC="$PKGF $(ls *.sv *.v | grep -vE '^(hdcu_pkg|tb_|video_frontend_top)')"
BASE="$PKGF spm.sv binding_unit.sv bundling_unit.sv clipping_unit.sv permutation_unit.sv similarity_unit.sv search_unit.sv hdcu_ctrl.sv hdcu_top.sv"
NOVF="$PKGF spm.sv spm_wide.sv spm_bit_comb.sv hv_gen_unit.sv signed_mac_unit.sv sign_unit.sv dot_accum_unit.sv dot_search_unit.sv norm_sq_accum_unit.sv isqrt_seq_unit.sv fixed_div_seq_unit.sv nov_ctrl.sv nov_top.sv"
STATS="$PKGF seq_divider.sv isqrt_seq_unit.sv autocorr_unit.sv percentile_unit.sv meanstd_unit.sv"
SOC="$(echo $SOC | tr ' ' '\n' | grep -v meanstd_sums_unit | tr '\n' ' ')"

echo "== Baseline HDCU (paper reimplementation)"
run tb_hdcu            "without unsupported_op assertions: 0" $BASE tb_hdcu.sv
run tb_base_values     "SCOREBOARD: ([0-9]+) / \1 "                    $BASE tb_base_values.sv
run tb_base_random     "SCOREBOARD: ([0-9]+) / \1 "            $BASE tb_base_random.sv

echo "== Novelty extension"
run tb_novelty          "dot-product argmax search correctly"  $NOVF tb_novelty.sv
run tb_l2normalize      "CaseB\] PASS"                         $NOVF tb_l2normalize.sv
run tb_scoreboard       "165 / 165"                            $NOVF tb_scoreboard.sv
run tb_scoreboard_multi "3073 / 3073"                          $NOVF tb_scoreboard_multi.sv
run tb_saturation       "3 / 3"                                $NOVF tb_saturation.sv
run tb_hvgen           "HVGEN SCOREBOARD: ([0-9]+) / \1 "     $PKGF hv_gen_unit.sv tb_hvgen.sv

echo "== RISC-V SoC integration"
run tb_quantize         "8 / 8"                                $SOC tb_quantize.sv
run tb_quant_random     "200 / 200"                            $SOC tb_quant_random.sv
python3 "$PKG"/scripts/gen_quant_model_cases.py
run tb_quant_model      "MODEL-vs-RTL: 2000 / 2000"            $PKGF quantize_unit.sv tb_quant_model.sv
run tb_hdc_soc          "5 / 5"                                $SOC tb_hdc_soc.sv
python3 "$PKG"/scripts/gen_isa_test.py "$PKG"/sw >/dev/null      # overwrites program.hex for this test only
run tb_soc_isa          "FULL-ISA SOC TEST: ALL PASS"          $SOC tb_soc_isa.sv
cp "$PKG"/sw/program.hex .
mkdir -p swflow && ( cd swflow && python3 "$PKG"/scripts/gen_sw_flow.py "$PKG"/sw "$LANE" >/dev/null )
( cd swflow && iverilog -g2012 $LANEDEF -I. -I.. -o f.out $(for f in $SOC; do echo ../$f; done) ../tb_sw_flow.sv >build.log 2>&1 && timeout 3000 vvp -n f.out > ../tb_sw_flow.log 2>&1 )
line="$(grep -E "SW FLOW TEST|firmware cycles" tb_sw_flow.log | tr '\n' ' ')"
if grep -q "SW FLOW TEST: ALL PASS" tb_sw_flow.log; then printf "%-26s PASS  %s\n" tb_sw_flow "$line"; else printf "%-26s FAIL  %s\n" tb_sw_flow "$line"; FAILS=$((FAILS+1)); fi

echo "== SoC on the real sky130 OpenRAM macro models (-DSYNTHESIS: the same SRAM wrappers Genus maps)"
SRAMV="$PKG/sky130_sram_1kbyte_1rw1r_32x256_8.v $PKG/sky130_sram_2kbyte_1rw1r_32x512_8.v $PKG/sky130_sram_4kbyte_1rw1r_32x1024_8.v $PKG/sky130_sram_8kbyte_1rw1r_32x2048_8.v"
macro_run() {   # macro_run NAME DIR PASS_REGEX EXTRA_DEFINES TB
  local name="$1" dir="$2" pat="$3" defs="$4" tb="$5"
  ( cd "$dir" && iverilog -g2012 -DSYNTHESIS $LANEDEF $defs -I. -I"$RUN" -o m.out $(for f in $SOC; do echo "$RUN/$f"; done) $SRAMV "$RUN/$tb" >"$RUN/$name.build.log" 2>&1 \
      && timeout 3000 vvp -n m.out >"$RUN/$name.log" 2>&1 )
  local nw; nw=$(grep -c "WARNING: Writing and reading" "$RUN/$name.log" 2>/dev/null)
  local line; line="$(grep -E 'SW FLOW TEST|firmware cycles|ALL PASS|FAIL' "$RUN/$name.log" | tr '\n' ' ')"
  if grep -qE "$pat" "$RUN/$name.log" && ! grep -qE "FAIL" "$RUN/$name.log" && [ "$nw" = "0" ]; then
    printf "%-26s PASS  %s  same-address R/W collisions: %s\n" "$name" "$line" "$nw"
  else
    printf "%-26s FAIL  %s  same-address R/W collisions: %s\n" "$name" "$line" "$nw"; FAILS=$((FAILS+1))
  fi
}
mkdir -p m_soc m_isa
cp program.hex m_soc/
( cd m_isa && python3 "$PKG"/scripts/gen_isa_test.py "$PKG"/sw >/dev/null )   # ISA program + expectations into m_isa/
macro_run m_tb_hdc_soc   m_soc  "ALL PASS"                    ""             tb_hdc_soc.sv
macro_run m_tb_soc_isa   m_isa  "FULL-ISA SOC TEST: ALL PASS" ""             tb_soc_isa.sv
macro_run m_tb_sw_flow   swflow "SW FLOW TEST: ALL PASS"      "-DFOUR_BANKS" tb_sw_flow.sv

echo "== Novelty core on real KTH data vs the accuracy model (hw_accuracy_eval.py --dump-rtl)"
NOVSET="hdcu_pkg.sv spm.sv spm_wide.sv spm_bit_comb.sv hv_gen_unit.sv signed_mac_unit.sv sign_unit.sv dot_accum_unit.sv dot_search_unit.sv norm_sq_accum_unit.sv isqrt_seq_unit.sv fixed_div_seq_unit.sv nov_ctrl.sv nov_top.sv"
for KM in beh mac; do
  d="kth_$KM"; mkdir -p "$d"; cp "$PKG"/tb/kth_case"$LANE"/* "$d"/; cp memio.svh "$d"/
  kdef="$LANEDEF"; kx=""; [ $KM = mac ] && kdef="$kdef -DSYNTHESIS" && kx="$SRAMV"
  ( cd "$d" && iverilog -g2012 $kdef -I. -o k.out $(for f in $NOVSET; do echo "$RUN/$f"; done) $kx "$RUN/tb_nov_kth.sv" >build.log 2>&1 \
      && timeout 3000 vvp -n k.out > run.log 2>&1 )
  nw=$(grep -c "WARNING: Writing and reading" "$d/run.log" 2>/dev/null)
  line="$(grep -E 'normalize:|dot search:' "$d/run.log" | sed 's/  */ /g' | tr '\n' ' ')"
  if grep -q "NOV KTH TEST: ALL PASS" "$d/run.log" && [ "$nw" = "0" ]; then printf "%-26s PASS  %s\n" "tb_nov_kth ($KM)" "$line"
  else printf "%-26s FAIL  %s (log: %s/%s/run.log)\n" "tb_nov_kth ($KM)" "$line" "$RUN" "$d"; FAILS=$((FAILS+1)); fi
done

echo "== Video front end: leaf units"
run tb_seq_div          "9/9"                                  seq_divider.sv tb_seq_div.sv
run tb_block_match      "32 / 32"                              block_match_unit.sv tb_block_match.sv
run tb_autocorr         "lag4 result"                          seq_divider.sv autocorr_unit.sv tb_autocorr.sv
run tb_percentile       "p4 result"                            seq_divider.sv percentile_unit.sv tb_percentile.sv
run tb_pct_random       "50/50"                                seq_divider.sv percentile_unit.sv tb_pct_random.sv
run tb_anglebin         "200/200"                              angle_bin8_unit.sv tb_anglebin.sv
run tb_hof              "128/128"                              $PKGF seq_divider.sv isqrt_seq_unit.sv angle_bin8_unit.sv hof_unit.sv tb_hof.sv
run tb_fastatan2        "100/100"                              $PKGF seq_divider.sv fastatan2_unit.sv tb_fastatan2.sv
run tb_l2hys            "36/36"                                $PKGF seq_divider.sv isqrt_seq_unit.sv l2hys_unit.sv tb_l2hys.sv
run tb_blockhist        "36/36"                                $PKGF seq_divider.sv isqrt_seq_unit.sv fastatan2_unit.sv hog_rom.sv hog_block_hist_unit.sv tb_blockhist.sv
run tb_meanstd          "44 / 44"                              $SOC tb_meanstd.sv
run tb_vecnorm          "22 / 22"                              $SOC tb_vecnorm.sv
run tb_cellnorm         "12 / 12"                              $SOC tb_cellnorm.sv
python3 "$PKG"/scripts/gen_msu_cases.py 600 >/dev/null
run tb_msu              "MEANSTD_SUMS SCOREBOARD: 600 / 600"   $PKGF seq_divider.sv isqrt_seq_unit.sv meanstd_sums_unit.sv tb_msu.sv

echo "== Video front end: stats units at production parameters"
GOLD="$PKG/verification/full_pipeline_golden.py"
for MT in 3 63; do
  mkdir -p "mt$MT"; ( cd "mt$MT" && python3 "$PKG"/scripts/gen_prod_cases.py "$GOLD" $MT 200 $MT >/dev/null )
  ( cd "mt$MT" && iverilog -g2012 -Ptb_prod_stats.MAX_T=$MT -o s.out $(for f in $STATS; do echo ../$f; done) ../tb_prod_stats.sv >build.log 2>&1 && timeout 1800 vvp -n s.out > s.log 2>&1 )
  line="$(grep MAX_T= "mt$MT/s.log")"
  if echo "$line" | grep -qE "AUTOCORR ([0-9]+)/\1 .*PERCENTILE ([0-9]+)/\2 .*MEANSTD ([0-9]+)/\3 .*HANGS 0"; then
    printf "%-26s PASS  %s\n" "tb_prod_stats MAX_T=$MT" "$line"
  else
    printf "%-26s FAIL  %s\n" "tb_prod_stats MAX_T=$MT" "$line"; FAILS=$((FAILS+1))
  fi
done

# Verilator models of hog_rom (a large combinational case ROM) need a big stack
ulimit -s unlimited 2>/dev/null || ulimit -s 1048576 2>/dev/null

if [ $HOG -eq 1 ] || [ $E2E -eq 1 ]; then
  ( cd "$PKG"/scripts && python3 gen_synth_video.py >/dev/null ) && cp "$PKG"/scripts/synth_frames.txt "$PKG"/scripts/synth_frames.npy .
fi

if [ $HOG -eq 1 ]; then
  echo "== hog_top vs real cv2.HOGDescriptor"
  verilator -Wno-fatal --bbox-unsup -Mdir hogobj --top-module hog_top --cc --exe --build -O3 \
    hdcu_pkg.sv seq_divider.sv isqrt_seq_unit.sv fastatan2_unit.sv hog_rom.sv hog_block_hist_unit.sv \
    l2hys_unit.sv hog_gradient_unit.sv hog_top.sv "$PKG"/verification/vtb_hog.cpp >hog.build.log 2>&1
  ( cd hogobj && cp ../synth_frames.txt . && ./Vhog_top 2>/dev/null )
  python3 "$PKG"/scripts/compare_hog.py synth_frames.txt hogobj/hog_rtl.txt | tail -1
fi

if [ $E2E -eq 1 ]; then
  echo "== video_frontend_top end to end (Verilator)"
  # Verilator-only build copies: Verilator rejects a delayed array write inside a
  # for loop in always_ff (standard SV, fine for Icarus and synthesis tools).
  python3 - <<'PYEOF'
c=open('hof_unit.sv').read()
o="for (int i = 0; i < N_CELLS*N_ANGLE_BINS; i++) hist_mem[i] <= '0;"
assert c.count(o)==1; open('hof_build.sv','w').write(c.replace(o,"hist_mem <= '{default: '0};"))
c=open('video_frontend_top.sv').read()
old="""        S_FIN_CELLNORM_CAPTURE: begin
          for (int gh2 = 0; gh2 < HOF_DIM; gh2++) base_raw[gh2] <= cn_result_packed[gh2*32 +: 32];
        end"""
assert c.count(old)==1; c=c.replace(old,"        S_FIN_CELLNORM_CAPTURE: ;")
m="  genvar gh;\n  generate\n"; assert c.count(m)==1
L="\n".join(f"      base_raw[{i}] <= cn_result_packed[{i}*32 +: 32];" for i in range(128))
c=c.replace(m,"  always_ff @(posedge clk) begin\n    if (state_r == S_FIN_CELLNORM_CAPTURE) begin\n"+L+"\n    end\n  end\n\n"+m)
open('vft_build.sv','w').write(c)
PYEOF
  verilator -Wno-fatal --bbox-unsup -Mdir vftobj --top-module video_frontend_top -GNUM_FRAMES=4 -GFRAME_SIZE=32 \
    --cc --exe --build -O3 hdcu_pkg.sv autocorr_unit.sv block_match_unit.sv cellnorm_unit.sv hof_build.sv \
    hog_top.sv hog_gradient_unit.sv hog_block_hist_unit.sv hog_rom.sv l2hys_unit.sv fastatan2_unit.sv \
    angle_bin8_unit.sv meanstd_sums_unit.sv percentile_unit.sv vecnorm_unit.sv seq_divider.sv isqrt_seq_unit.sv \
    vft_build.sv "$PKG"/verification/vtb_stream.cpp >vft.build.log 2>&1
  ( cd vftobj && cp ../synth_frames.txt . && ./Vvideo_frontend_top > trace.log 2>/dev/null; tail -2 trace.log )
  cp "$PKG"/verification/full_pipeline_golden.py .
  python3 full_pipeline_golden.py >/dev/null
  if [ -f hogobj/hog_rtl.txt ]; then
    python3 "$PKG"/scripts/compare_e2e.py vftobj/vft_rtl_output.txt golden_derivable.npz hogobj/hog_rtl.txt || FAILS=$((FAILS+1))
  else
    python3 "$PKG"/scripts/compare_e2e.py vftobj/vft_rtl_output.txt golden_derivable.npz || FAILS=$((FAILS+1))
  fi
  grep -q "ALL EXACT" <(python3 "$PKG"/scripts/compare_e2e.py vftobj/vft_rtl_output.txt golden_derivable.npz) || FAILS=$((FAILS+1))
fi

echo
if [ $FAILS -eq 0 ]; then echo "REGRESSION: ALL PASS"; exit 0; else echo "REGRESSION: $FAILS FAILED"; exit 1; fi
