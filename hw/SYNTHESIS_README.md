# Synthesis (paper runs)

Run all 8 runs below (section 1). They cover the baseline HDCU, the SWIFT core (`nov_top`)
with 16- and 32-bit lanes, the SoC and the video front end.

What the design contains:
- **Table-free encoding (`BINDGEN`, custom-0 funct3 = 001, funct7 18 first / 19 add).** The
  unit `rtl/hv_gen_unit.sv` inside `nov_top` generates each 32-lane chunk of the level and
  position hypervectors from two 32-bit seeds (CSR 7 `GEN_SEEDL`, CSR 8 `GEN_SEEDP`, CSR 9
  `GEN_STEP`) with a multiply-xorshift hash, during the address cycle of the chunk loop. Encoding
  a feature is one instruction (`rs1` = level index from `QUANTIZE`, `rs2` = feature index) with
  no tables in memory and no copies: 400 cycles per feature end to end in the SoC, against 770
  with the copy engine and 13.6 k with CPU copies. Bit-exact with `scripts/hvgen.py`.
- **Table-copy engine (`MEMCPY`, funct3 = 100)** in `hdc_soc_top`, used by the table-based
  `BINDMAC` path.
- Regression `./run_all.sh` covers every unit and the firmware flow on the sky130 OpenRAM
  models. The switching-activity files in `synth/vcd/` come from the firmware flow.

```
PDK_ROOT=/path/to/sky130A nohup ./synth/run_genus_all.sh > synth/genus_all.log 2>&1 &
```

Everything below runs on the lab machine with Cadence Genus and the sky130A PDK
(sky130_fd_sc_hd standard cells + the sky130 OpenRAM SRAM macros). No simulator is needed:
the switching-activity files for power are already in `synth/vcd/`.

## 1. One command (recommended)

Copy this whole folder to the lab machine, then from inside it:

```
PDK_ROOT=/path/to/sky130A nohup ./synth/run_genus_all.sh > synth/genus_all.log 2>&1 &
```

- Change `PDK_ROOT` if your sky130A is elsewhere (it must contain
  `libs.ref/sky130_fd_sc_hd/lib` and `libs.ref/sky130_sram_macros/lib`).
- If `genus` is not on your PATH: add `GENUS=/full/path/to/genus` before the command.
- Progress: `tail -f synth/genus_all.log`. Expect a few hours in total.
- If it stops (logout, crash), run the same command again: finished runs are skipped.
- To redo a single run, delete its folder in `synth/out/` and run the command again, or run
  only some: `ONLY="nov16_10p0 soc16_10p0" PDK_ROOT=... ./synth/run_genus_all.sh`

## 2. The 8 runs it does

| # | Run folder | Top module | Novelty lanes | Clock | Power from | Why it is in the paper |
|---|---|---|---|---|---|---|
| 1 | `hdcu_10p0` | `hdcu_top` | – | 10.0 ns (100 MHz) | `vcd/base16.vcd` | baseline HDCU (the paper you extend) |
| 2 | `nov16_10p0` | `nov_top` | **16-bit** | 10.0 ns | `vcd/nov16.vcd` | **this work (incl. HV generator), paper configuration** |
| 3 | `nov16_10p5` | `nov_top` | 16-bit | 10.5 ns (95 MHz) | `vcd/nov16.vcd` | timing-closure point if 10.0 ns fails |
| 4 | `nov32_10p0` | `nov_top` | 32-bit | 10.0 ns | `vcd/nov32.vcd` | int32 vs int16 comparison |
| 5 | `nov32_10p5` | `nov_top` | 32-bit | 10.5 ns | `vcd/nov32.vcd` | int32 at the closing clock (missed 10.0 ns by 8 ps before) |
| 6 | `soc16_10p0` | `hdc_soc_top` | **16-bit** | 10.0 ns | `vcd/busy16.vcd` | **full SoC incl. HV generator and copy engine, paper configuration** |
| 7 | `soc32_10p0` | `hdc_soc_top` | 32-bit | 10.0 ns | `vcd/busy32.vcd` | full SoC incl. HV generator and copy engine, int32 variant |
| 8 | `vfe_10p0` | `video_frontend_top` | – | 10.0 ns | vectorless (no VCD) | streaming feature extractor |

Memories map to these sky130 macros (all from your PDK):

| Memory | Macro | Count |
|---|---|---|
| Baseline SPM (4 banks) | `sky130_sram_1kbyte_1rw1r_32x256_8` | 4 |
| Novelty bit SPM (2 copies) | `sky130_sram_2kbyte_1rw1r_32x512_8` | 2 |
| Novelty wide SPM | `sky130_sram_4kbyte_1rw1r_32x1024_8` | **16** (16-bit lanes) / 32 (32-bit lanes) |
| SoC main memory (16 KB) | `sky130_sram_8kbyte_1rw1r_32x2048_8` | 2 (SoC runs only) |

## 3. What you get

- `synth/out/<run>/` for each run: `area.rpt`, `gates.rpt`, `timing.rpt`, `power.rpt`,
  `qor.rpt`, `unresolved.rpt`, `activity.rpt`, netlist, SDC, `genus.log`, `console.log`
- `synth/out/metrics.md` and `synth/out/metrics.csv`: one table with timing/slack, cells,
  flops, logic area, SRAM area, total area, power, energy over the VCD window, power source.

## 4. Check before using any number

In `synth/out/metrics.md`:

1. **Unresolved = 0 for every run.** Anything else means a memory did not map to a macro
   (check `MEM_LIBS`/`PDK_ROOT`, and that the 8 KB macro `.lib` exists for the SoC runs).
2. **Power source = VCD** for runs 1–7 (run 8 is vectorless by design). "VCD FAILED" means
   `read_vcd` errored; the message is in that run's `VCD_READ_FAILED` file.
3. **SRAM column**: `nov16_*` must show 16 × 4kbyte, `nov32_*` 32 × 4kbyte, the SoC runs
   also 2 × 8kbyte.
4. **Timing**: note which `nov_top` clock meets (10.0 or 10.5 ns); the paper uses that one.

## 5. Send back

The whole `synth/out` folder zipped (or at least `metrics.md`, `metrics.csv` and every
run's `qor.rpt`, `power.rpt`, `unresolved.rpt`, `activity.rpt`, `console.log`).

## 6. If the batch script does not work on your machine

Run one configuration by hand from this folder (example: run 2):

```
cat > my_run.tcl <<'EOF'
set PDK_ROOT /path/to/sky130A
set TOP nov_top
set LANE 16
set CLK_NS 10.0
set OUT synth/out/nov16_10p0
set VCD synth/vcd/nov16.vcd
set VCD_SCOPE tb_sw_flow/dut/u_nov
source synth/genus_synth.tcl
exit
EOF
gunzip -k synth/vcd/nov16.vcd.gz
genus -batch -files my_run.tcl -log synth/out/nov16_10p0/genus
```

Change TOP / LANE / CLK_NS / OUT / VCD / VCD_SCOPE per the table in section 2
(`VCD_SCOPE`: `tb_sw_flow/dut/u_base` for `hdcu_top`, `tb_sw_flow/dut/u_nov` for `nov_top`,
`tb_sw_flow/dut` for `hdc_soc_top`; no VCD lines for `video_frontend_top`). Then:
`python3 synth/collect_metrics.py synth/out`.

More detail: `synth/README_synth.md` (flow and VCD method).

## 7. Optional: post-layout (Innovus) for the paper configuration

After run 2 (`nov16_10p0`) finishes, `synth/innovus_pnr.tcl` places and routes it (macros +
logic, power grid, CTS, routing, post-route optimization) and writes post-layout area, die
size, setup/hold timing and VCD-based power to `synth/pnr/nov16_10p0/`:

```
gunzip -k synth/vcd/nov16.vcd.gz
cat > pnr.tcl <<'EOF'
set PDK_ROOT /path/to/sky130A
set TOP nov_top ; set RUN nov16_10p0 ; set CLK_NS 10.0
set VCD synth/vcd/nov16.vcd ; set VCD_SCOPE tb_sw_flow/dut/u_nov
source synth/innovus_pnr.tcl
exit
EOF
mkdir -p synth/pnr/nov16_10p0
innovus -no_gui -files pnr.tcl -log synth/pnr/nov16_10p0/innovus
```

It needs the macro LEFs under `$PDK_ROOT/libs.ref/sky130_sram_macros/lef/`. It was written
without Innovus access here, so treat it as a starting point: if a step fails, send the log.
Send back `synth/pnr/nov16_10p0/` (summary.rpt, die.rpt, timing_*, power.rpt, drc.rpt).
