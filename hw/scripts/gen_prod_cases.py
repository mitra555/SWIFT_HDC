"""Random cases for autocorr/percentile/meanstd at a given MAX_T, golden values
from the package's own full_pipeline_golden.py fixed-point functions."""
import sys, random, importlib.util
golden_path, max_t, ncases, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
spec = importlib.util.spec_from_file_location("g", golden_path)
g = importlib.util.module_from_spec(spec)
sys.argv = [golden_path]  # golden module may parse argv at import; keep it inert
spec.loader.exec_module(g)
random.seed(seed)

def meanstd_twopass(vals):
    """Legacy meanstd_unit (two-pass, per-term >>16). No longer used by video_frontend_top
    (replaced by meanstd_sums_unit, tested by tb_msu), but kept and tested as a standalone unit."""
    T = len(vals); q = [int(v) for v in vals]
    m = g.trunc_div(sum(q), T)
    var = g.trunc_div(sum(((v - m) * (v - m)) >> 16 for v in q), T)
    import math
    return m, (math.isqrt(var << 16) if var > 0 else 0)

def q16(x): return int(round(x * 65536))

with open("ac_cases.txt", "w") as fa, open("pc_cases.txt", "w") as fp, open("ms_cases.txt", "w") as fm:
    for c in range(ncases):
        T = max_t if c % 2 == 0 else random.randint(2, max_t)
        mode = c % 4
        if mode == 0:   xs = [q16(random.uniform(-8, 8)) for _ in range(T)]
        elif mode == 1: xs = [q16(random.randint(0, 16)) for _ in range(T)]   # integer-valued like motion vectors
        elif mode == 2: xs = [q16(random.uniform(0, 1)) for _ in range(T)]
        else:           xs = [q16(3.25)] * T                                  # constant -> v==0 path
        ac = g.autocorr(xs)
        pc = g.percentile5(xs)
        mean, std = meanstd_twopass(xs)
        line = f"{T} " + " ".join(map(str, xs + [0] * (max_t - T)))
        fa.write(line + " " + " ".join(str(int(v)) for v in ac) + "\n")
        fp.write(line + " " + " ".join(str(int(v)) for v in pc) + "\n")
        fm.write(line + f" {int(mean)} {int(std)}\n")
print("wrote", ncases, "cases at MAX_T =", max_t)
