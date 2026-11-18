# Evaluation models

- `hdc_model.py`: bit-exact model of the SWIFT-HDC pipeline (Q16.16 front end, quantizer, encoding,
  saturating training, Q1.(W-1) normalization, dot search), the baseline-HDCU emulation and the
  floating-point references. `SWIFT_GEN=1` selects table-free (generated) hypervectors.
- `hvgen.py`: Python model of `hv_gen_unit.sv`, bit-exact with the RTL.
- `run_bindgen_ablation.py`: generator ablation (Table III of the paper); needs the KTH feature cache
  and UCI HAR / ISOLET arrays in `work/`.
- `make_plots.py`: paper plots from a results folder, e.g. `python make_plots.py ../results/kth_uci out`.

Requirements: Python 3.9+, numpy, scipy, matplotlib.
