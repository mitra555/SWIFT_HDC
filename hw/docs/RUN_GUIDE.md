# Run Guide

Tools: Icarus Verilog >= 12, Verilator >= 5, Python 3 + NumPy. OpenCV **4.x** for the HOG
comparison and the accuracy script (OpenCV 5 removed `cv2.HOGDescriptor`).
```
sudo apt-get install -y iverilog verilator
pip install numpy "opencv-python-headless<5"
```

## 1. Regression (all unit and integration tests, ~10-15 min)
```
./run_all.sh                 # exits non-zero if anything fails
./run_all.sh --hog           # + hog_top vs real cv2.HOGDescriptor
./run_all.sh --e2e           # + streaming video_frontend_top run vs golden (~1.09M cycles)
```
Set `RUN_DIR=/some/dir` to choose where builds and logs go (default `/tmp/hdc_regress`).
`NOV_LANE=32 ./run_all.sh` verifies the int32-lane variant (default 16, the paper configuration).

What runs, by group: baseline HDCU value tests; novelty scoreboards; SoC integration
(including `tb_soc_isa`, every custom instruction through the real PicoRV32, and
`tb_sw_flow`, a firmware-only flow at D = 5024 with nothing preloaded); video front-end
leaf units; the statistics units at their production parameters.
The SoC tests then run a second time with `-DSYNTHESIS` against the real sky130 OpenRAM
models (`sky130_sram_*.v` in the package root), the same memory wrappers Genus maps
(`m_tb_hdc_soc`, `m_tb_soc_isa`, `m_tb_sw_flow`); these fail on any same-address
read/write collision on a macro.

## 2. Video front end end-to-end (manual)
The front end streams frames: load frames 0 and 1, pulse `start`, then load each next
frame whenever `ld_ready` is high. `verification/vtb_stream.cpp` does this and logs
every top-level state change; if any state holds for 20M cycles it dumps the sub-unit
states and exits (a hang detector). `run_all.sh --e2e` builds it with the two
Verilator-only source patches (Verilator rejects a non-blocking array write inside a
`for` loop in `always_ff`; the RTL is standard SystemVerilog and is not modified).

Compare with `scripts/compare_e2e.py <vft_rtl_output.txt> golden_derivable.npz [hog_rtl.txt]`
after running `verification/full_pipeline_golden.py` (expects `synth_frames.npy` from
`scripts/gen_synth_video.py`). With `hog_rtl.txt` (from `vtb_hog.cpp`) all 1010 outputs
are compared, including the HOG-derived part of `base_norm`.

## 3. Accuracy (Kaggle)
```
!pip install "opencv-python-headless<5"      # only if the kernel has OpenCV 5
!python hw_accuracy_eval.py --data /kaggle/input/private-dataset
```
Features are cached to `/kaggle/working/hw_feats.npz`; results go to
`hw_accuracy_results.json`. `scripts/check_model_vs_rtl.py` re-proves that the script's
hardware model equals the RTL.

## 4. Synthesis
See `synth/README_synth.md` (Genus script, memory-macro list, power methodology).
