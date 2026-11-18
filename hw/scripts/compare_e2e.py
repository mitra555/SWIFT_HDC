"""Compare video_frontend_top RTL output against the golden model.
Usage: compare_e2e.py vft_rtl_output.txt golden_derivable.npz [hog_rtl.txt]
With hog_rtl.txt (per-frame hog_top outputs for frames 0..3), the full 904-entry
base_norm is reconstructed in the golden domain and compared too."""
import sys, importlib.util
import numpy as np

rtl_path, npz_path = sys.argv[1], sys.argv[2]
hog_path = sys.argv[3] if len(sys.argv) > 3 else None

lines = [list(map(int, l.split())) for l in open(rtl_path) if l.strip()]
names = ["base_norm", "dx_norm", "dy_norm", "acd_norm", "acx_norm", "pct_norm"]
rtl = {n: np.array(v, dtype=np.int64) for n, v in zip(names, lines)}
g = np.load(npz_path)

ok_all = True
def cmp(name, got, exp):
    global ok_all
    got = np.asarray(got, dtype=np.int64); exp = np.asarray(exp, dtype=np.int64)
    d = np.abs(got - exp)
    exact = np.array_equal(got, exp)
    ok_all &= exact
    print(f"{name:10s} n={len(exp):4d}  exact={'YES' if exact else 'NO '}  "
          f"mismatches={int((d > 0).sum()):4d}  max|diff|={int(d.max())} LSB")
    if not exact:
        idx = np.nonzero(d)[0][:8]
        for i in idx:
            print(f"    [{i}] rtl={got[i]} golden={exp[i]}")

for n in ["dx_norm", "dy_norm", "acd_norm", "acx_norm", "pct_norm"]:
    cmp(n, rtl[n], g[n])

if hog_path:
    spec = importlib.util.spec_from_file_location("fg", "full_pipeline_golden.py")
    fg = importlib.util.module_from_spec(spec); spec.loader.exec_module(fg)
    hog = np.array([list(map(int, l.split())) for l in open(hog_path) if l.strip()], dtype=np.int64)
    # video_frontend_top computes HOG on frame t+1 for pair t
    hog_seq = hog[1:1 + fg.NPAIRS]
    hog_mean = np.zeros(324, dtype=np.int64); hog_std = np.zeros(324, dtype=np.int64)
    for lane in range(324):
        m, s = fg.meanstd(hog_seq[:, lane]); hog_mean[lane] = m; hog_std[lane] = s
    base_raw = np.concatenate([g["hof_global_cn"], hog_mean, g["hof_std"], hog_std])
    cmp("base_norm", rtl["base_norm"], fg.vecnorm(base_raw))

print("ALL EXACT" if ok_all else "MISMATCHES PRESENT")
