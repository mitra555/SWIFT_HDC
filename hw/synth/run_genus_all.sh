#!/usr/bin/env bash
# =============================================================================
# run_genus_all.sh -- every Genus run the paper needs, then one metrics table.
#
#   cd <package root>
#   PDK_ROOT=/path/to/sky130A nohup ./synth/run_genus_all.sh > synth/genus_all.log 2>&1 &
#
# Runs (sky130_fd_sc_hd tt_025C_1v80 + sky130 OpenRAM macros):
#   hdcu_top             10.0 ns          power from VCD (baseline core busy)
#   nov_top   16-bit     10.0 / 10.5 ns   power from VCD (novelty core busy)   <- paper configuration
#   nov_top   32-bit     10.0 / 10.5 ns   power from VCD (novelty core busy)   <- int32 comparison
#   hdc_soc_top 16-bit   10.0 ns          power from VCD (either HDC core busy)
#   hdc_soc_top 32-bit   10.0 ns          power from VCD (either HDC core busy)
#   video_frontend_top   10.0 ns          vectorless power (no VCD for the front end)
# Results: synth/out/<run>/{area,gates,timing,power,qor,unresolved}.rpt, netlist, sdc, genus.log
#          synth/out/metrics.csv and synth/out/metrics.md (collect_metrics.py)
# Re-running skips runs whose qor.rpt already exists (delete the folder to redo one).
# ONLY="nov16_10p0 soc16" limits the runs; CLK_LIST etc. are fixed below.
# =============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
PKG="$(pwd)"
PDK_ROOT="${PDK_ROOT:-/path/to/sky130A}"
GENUS="${GENUS:-genus}"
OUTROOT="$PKG/synth/out"
VCDDIR="$PKG/synth/vcd"
mkdir -p "$OUTROOT"

command -v "$GENUS" >/dev/null || { echo "genus not found in PATH (set GENUS=/path/to/genus)"; exit 1; }
[ -d "$PDK_ROOT/libs.ref/sky130_fd_sc_hd/lib" ] || { echo "PDK_ROOT=$PDK_ROOT has no libs.ref/sky130_fd_sc_hd/lib"; exit 1; }
ls "$PDK_ROOT"/libs.ref/sky130_sram_macros/lib/sky130_sram_8kbyte_1rw1r_32x2048_8_TT_1p8V_25C.lib >/dev/null 2>&1 \
  || echo "WARNING: sky130_sram_8kbyte_1rw1r_32x2048_8 .lib not found; hdc_soc_top main memory will not map"

# unpack the switching-activity dumps shipped with the package (synth/vcd/*.vcd.gz)
for z in "$VCDDIR"/*.vcd.gz; do
  [ -e "$z" ] || continue
  [ -f "${z%.gz}" ] || { echo "unpacking $(basename "$z")"; gunzip -k "$z"; }
done

# name | top | lane | clock ns | vcd file | vcd scope
RUNS="
hdcu_10p0|hdcu_top|16|10.0|base16.vcd|tb_sw_flow/dut/u_base
nov16_10p0|nov_top|16|10.0|nov16.vcd|tb_sw_flow/dut/u_nov
nov16_10p5|nov_top|16|10.5|nov16.vcd|tb_sw_flow/dut/u_nov
nov32_10p0|nov_top|32|10.0|nov32.vcd|tb_sw_flow/dut/u_nov
nov32_10p5|nov_top|32|10.5|nov32.vcd|tb_sw_flow/dut/u_nov
soc16_10p0|hdc_soc_top|16|10.0|busy16.vcd|tb_sw_flow/dut
soc32_10p0|hdc_soc_top|32|10.0|busy32.vcd|tb_sw_flow/dut
vfe_10p0|video_frontend_top|16|10.0|-|-
"
ONLY="${ONLY:-}"
for line in $RUNS; do
  IFS='|' read -r name top lane clk vcd scope <<<"$line"
  if [ -n "$ONLY" ] && ! echo " $ONLY " | grep -q " $name "; then continue; fi
  out="$OUTROOT/$name"
  if [ -f "$out/qor.rpt" ]; then echo "[$(date +%H:%M)] $name: already done, skipping"; continue; fi
  mkdir -p "$out"
  tcl="$out/run.tcl"
  vcdused="none"; [ "$vcd" != "-" ] && [ -f "$VCDDIR/$vcd" ] && vcdused="$VCDDIR/$vcd"
  printf "TOP=%s\nLANE=%s\nCLK_NS=%s\nVCD=%s\n" "$top" "$lane" "$clk" "$vcdused" > "$out/run_info.txt"
  {
    echo "set PDK_ROOT {$PDK_ROOT}"
    echo "set TOP $top"; echo "set LANE $lane"; echo "set CLK_NS $clk"; echo "set OUT {$out}"
    if [ "$vcd" != "-" ] && [ -f "$VCDDIR/$vcd" ]; then
      echo "set VCD {$VCDDIR/$vcd}"; echo "set VCD_SCOPE {$scope}"
    elif [ "$vcd" != "-" ]; then
      echo "puts \"WARNING: $VCDDIR/$vcd missing, power will be vectorless\""
    fi
    echo "source {$PKG/synth/genus_synth.tcl}"
    echo "exit"
  } > "$tcl"
  echo "[$(date +%H:%M)] $name: genus ($top, ${lane}-bit lanes, ${clk} ns) ..."
  t0=$(date +%s)
  "$GENUS" -batch -no_gui -files "$tcl" -log "$out/genus" > "$out/console.log" 2>&1
  [ -f "$out/genus.log" ] || cp "$out/console.log" "$out/genus.log"
  if [ -f "$out/qor.rpt" ]; then echo "[$(date +%H:%M)] $name: done in $(( ($(date +%s) - t0) / 60 )) min"
  else echo "[$(date +%H:%M)] $name: FAILED (see $out/console.log)"; fi
done

python3 "$PKG/synth/collect_metrics.py" "$OUTROOT" 2>/dev/null || python "$PKG/synth/collect_metrics.py" "$OUTROOT"
echo "all runs finished; table: $OUTROOT/metrics.md"
