# SWIFT-HDC: Table-Free Integer Hyperdimensional Learning on a RISC-V SoC

SWIFT-HDC is a PicoRV32-based SoC that learns on chip with integer hyperdimensional computing (HDC).
Its SWIFT core generates level and position hypervectors inside the datapath (`BINDGEN`), so the
682 KB of hypervector tables that HDC encoding normally needs never exist. One set of 32 signed
weighted MAC lanes serves both encoding and perceptron updates, next to a multiplier-free dot search
and in-place Q1.15 normalization. A streaming fixed-point front end turns raw video into features
without storing the clip.

All memories are sky130 OpenRAM macros; the design is synthesized with Cadence Genus in SkyWater sky130.

## Results at a glance

| | |
|---|---|
| KTH, leave-one-person-out (5 / 6 classes) | 82.8 % / 70.1 % (bit-exact model of the chip) |
| Gain over a binary RISC-V HDC unit | +17 to +24 points in every KTH protocol |
| UCI HAR / ISOLET | 91.6 % / 91.9 % |
| UCF101, 101 classes, frozen ResNet-18 embeddings | 63.9 % (binary unit: 15.3 %) |
| Cycles per clip vs. Ara RVV processor at equal throughput | 4.8x fewer |
| SWIFT core, sky130 at 100 MHz | 8.18 mm² (logic 0.185 mm², the rest SRAM) |
| Table-free vs. table-based encoding | no measurable accuracy change; 18 % less energy per feature |

The paper (`paper/main.pdf`) has the full evaluation.

## Repository layout

| Folder | Contents |
|---|---|
| `hw/` | RTL (`rtl/`), testbenches (`tb/`, `verification/`), firmware generator (`sw/`), golden-model and test-case scripts (`scripts/`), Genus/Innovus scripts and switching-activity files (`synth/`), OpenRAM SRAM simulation models |
| `eval/` | Bit-exact Python model of the pipeline (`hdc_model.py`), hypervector generator model (`hvgen.py`), generator ablation (`run_bindgen_ablation.py`), plotting (`make_plots.py`) |
| `results/` | Raw accuracy results (JSON + summaries): `kth_uci/` (KTH, UCI HAR, ISOLET and all sweeps), `extra/` (table-free vs. tables, LOPO repeats), `ucf101/`, `ablation/` (generator ablation) |
| `synthesis/genus/` | Genus area, timing, gate and QoR reports for all runs; mapped netlists gzipped |
| `power/` | OpenSTA-based power estimate from the Genus netlists and simulation activity |
| `paper/` | LaTeX source, bibliography, figures and draw.io sources |

## Hardware

Key RTL modules:

- `hw/rtl/nov_top.sv`, `nov_ctrl.sv`: SWIFT core and its two-phase chunk controller
- `hw/rtl/hv_gen_unit.sv`: table-free level/position hypervector generator (`BINDGEN`)
- `hw/rtl/signed_mac_unit.sv`, `dot_search_unit.sv`, `sign_unit.sv`, `norm_sq_accum_unit.sv`, `isqrt_seq_unit.sv`, `fixed_div_seq_unit.sv`: datapath
- `hw/rtl/hdcu_top.sv`: baseline binary HDC unit
- `hw/rtl/pcpi_hdc_bridge.sv`, `hdc_soc_top.sv`: PCPI bridge and SoC
- `hw/rtl/video_frontend_top.sv` and the units it instantiates: streaming video front end

Simulation regression (Icarus Verilog / Verilator):

```
cd hw
./run_all.sh
```

Synthesis (Cadence Genus, sky130A PDK with the OpenRAM macros):

```
cd hw
PDK_ROOT=/path/to/sky130A ./synth/run_genus_all.sh
```

See `hw/SYNTHESIS_README.md` for the run list and `hw/synth/README_synth.md` for details.

## Custom instructions (`custom-0`)

| funct3 | Operations |
|---|---|
| 000 | baseline HDCU: bind, bundle, clip, permute, similarity, search, CSRs |
| 001 | SWIFT: `BINDGEN`, `BINDMAC`, `PROTO_UPDATE`, `SIGN`, `DOTSEARCH`, `NORMALIZE` |
| 010 | CSR writes (HVSIZE, K, WEIGHT, quantizer range, DST_ADDR, generator seeds and step) |
| 011 | `QUANTIZE` |
| 100 | `MEMCPY` (table copy engine) |

## Third-party components

- `hw/rtl/picorv32.v`: PicoRV32 by Claire Xenia Wolf, ISC license (header in the file).
- `hw/sky130_sram_*.v`: OpenRAM-generated sky130 SRAM simulation models.
- Datasets (KTH, UCI HAR, ISOLET, UCF101) are not included; download them from their original sources.

## License

MIT for the original code in this repository (see `LICENSE`); third-party files keep their own licenses.
