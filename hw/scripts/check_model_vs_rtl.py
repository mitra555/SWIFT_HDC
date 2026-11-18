"""Cross-check: the hardware model inside hw_accuracy_eval.py vs. the RTL video front end.

Feeds the same frames through hw_accuracy_eval.extract_both() and compares its hardware
features with video_frontend_top's outputs. HOG is substituted with hog_top's RTL output so the
comparison isolates everything else; every one of the 1010 values must match exactly.

usage: check_model_vs_rtl.py hw_accuracy_eval.py synth_frames.txt hog_rtl.txt vft_rtl_output.txt
"""
import sys, os, tempfile
import numpy as np

src_path, frames_txt, hog_txt, rtl_txt = sys.argv[1:5]
src = open(src_path).read()
defs = src[:src.index("GROUP_NAMES = ")]                    # config + model definitions only
empty = tempfile.mkdtemp()
sys.argv = ["hw_accuracy_eval.py", "--data", empty, "--cache", os.path.join(empty, "x.npz")]
g = {"__name__": "hw_model"}
exec(compile(defs, src_path, "exec"), g)

frames = np.array(open(frames_txt).read().split(), dtype=np.int64).reshape(-1, 32, 32).astype(np.uint8)
hog_rtl = np.array([list(map(int, l.split())) for l in open(hog_txt) if l.strip()], dtype=np.int64)

class RtlHog:                                               # returns hog_top's output for that frame
    def compute(self, frame):
        for i in range(len(frames)):
            if np.array_equal(frame, frames[i]):
                return (hog_rtl[i] / 65536.0).astype(np.float64)
        raise KeyError("frame not found")
g["hog_cv"] = RtlHog()

_, hw = g["extract_both"](frames)
rtl = [np.array(l.split(), dtype=np.int64) for l in open(rtl_txt) if l.strip()]
names = ["base_norm", "dx_norm", "dy_norm", "acd_norm", "acx_norm", "pct_norm"]
ok = True
for n, m, r in zip(names, hw, rtl):
    d = np.abs(np.asarray(m, dtype=np.int64) - r)
    ok &= not d.any()
    print(f"{n:10s} n={len(r):4d}  model==RTL: {'YES' if not d.any() else 'NO '}  mismatches={int((d>0).sum())}  max|diff|={int(d.max())}")
print("MODEL MATCHES RTL" if ok else "MODEL DIFFERS FROM RTL")
