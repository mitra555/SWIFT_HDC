"""
run_bindgen_ablation.py -- why the hypervector generator is built the way it is.

Same chip pipeline (16-bit lanes, retraining, dot search), only the generated hypervectors change:
  chip         : BINDGEN as built (nested threshold levels, independent hashed positions)
  naive_level  : every level an independent hash (no nested flips; nearby levels uncorrelated)
  rot_pos      : positions as rotations of one hash sequence (cheaper addressing)
  naive_both   : both shortcuts
  tables       : random level/position tables (conventional encoding, reference)
KTH 5c notebook / 5c official / 6c official: 20 seed sets; UCI HAR and ISOLET: 5 seed sets.

Run from the swift_hdc_accuracy_eval folder (uses work\\):
    python run_bindgen_ablation.py
Writes results_ablation\\ and results_ablation.zip (about 30-60 min). Re-running resumes.
"""
import os, sys, json, time, argparse, zipfile
import numpy as np
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hdc_model as M

VARIANTS = ["chip", "naive_level", "rot_pos", "naive_both", "tables"]
D_HW = 5024
_DATA = {}


def load_kth(cache, ncls):
    key = (cache, ncls)
    if key not in _DATA:
        d = M.load_cache(cache)
        classes = list(M.ALL_CLASSES) if ncls == 6 else [c for c in M.ALL_CLASSES if c != "jogging"]
        if list(classes) != d["classes"]:
            keep = np.isin(np.array(d["classes"])[d["labels"]], classes)
            d = M.subset(d, keep, classes)
        _DATA[key] = d
    return _DATA[key]


def enc(idx, D, so, v, **kw):
    if v == "tables":
        return M.encode_sum(idx, D, so, gen=False, **kw)
    return M.encode_sum(idx, D, so, gen=True, gen_variant=v, **kw)


def kth_job(args):
    cache, ncls, protocol, seed = args
    d = load_kth(cache, ncls); y = d["labels"]; K = len(d["classes"]); so = 1000 * seed
    sp = M.split_notebook(d["pids"], so, K) if protocol == "notebook" else M.split_official(d["pids"])
    ihw = M.quantize_groups(d, sp["tr_all"], hardware=True)
    r = dict(bench=f"KTH {ncls}c {protocol}", seed=seed)
    for v in VARIANTS:
        r[v] = 100 * M.train_hw(M.sign_pm1(enc(ihw, D_HW, so, v)), y, sp, K, bits=16)["acc"]
    return r


def uci_job(args):
    data_dir, name, seed = args
    z = np.load(os.path.join(data_dir, name + ".npz"))
    X = np.concatenate([z["Xtr"], z["Xte"]]); y = np.concatenate([z["ytr"], z["yte"]]).astype(int)
    ntr = len(z["Xtr"]); K = int(y.max()) + 1; so = 1000 * seed
    perm = np.random.RandomState(42 + so).permutation(ntr); nv = int(0.1 * ntr)
    sp = dict(tr=np.sort(perm[nv:]), va=np.sort(perm[:nv]), te=np.arange(ntr, len(y)), tr_all=np.arange(ntr))
    idx = [M.quant_hw(np.round(X.astype(np.float64) * 65536).astype(np.int64), 64, sp["tr_all"])]
    r = dict(bench=name, seed=seed)
    for v in VARIANTS:
        r[v] = 100 * M.train_hw(M.sign_pm1(enc(idx, D_HW, so, v, nlvls=[64], weights=[1])), y, sp, K, bits=16, epochs=20)["acc"]
    return r


def summarize(res):
    from scipy import stats
    L = ["# Hypervector generator ablation (16-bit lanes, retraining, dot search)\n",
         "Accuracy (%) mean +- std over seed sets; difference to the chip's generator, paired over seed sets.\n",
         "| Benchmark | " + " | ".join(VARIANTS) + " |", "|---|" + "---|" * len(VARIANTS)]
    D = ["", "| Benchmark | " + " | ".join(f"{v} - chip (p)" for v in VARIANTS[1:]) + " |", "|---|" + "---|" * (len(VARIANTS) - 1)]
    for b in sorted(set(r["bench"] for r in res)):
        rs = [r for r in res if r["bench"] == b]
        A = {v: np.array([r[v] for r in rs]) for v in VARIANTS}
        L.append(f"| {b} | " + " | ".join(f"{A[v].mean():.1f} +- {A[v].std(ddof=1) if len(rs) > 1 else 0:.1f}" for v in VARIANTS) + " |")
        cells = []
        for v in VARIANTS[1:]:
            d = A[v] - A["chip"]
            p = stats.wilcoxon(A[v], A["chip"]).pvalue if len(rs) > 5 and np.any(d) else (stats.ttest_rel(A[v], A["chip"]).pvalue if len(rs) > 1 and np.any(d) else float("nan"))
            cells.append(f"{d.mean():+.1f} ({p:.2g})")
        D.append(f"| {b} | " + " | ".join(cells) + " |")
    return "\n".join(L + D) + "\n"


def pool(fn, jobs, n, label):
    import multiprocessing as mp
    out = []; t0 = time.time()
    with ProcessPoolExecutor(max_workers=n, mp_context=mp.get_context("spawn")) as ex:
        for i, r in enumerate(ex.map(fn, jobs)):
            out.append(r); print(f"  {label}: {i + 1}/{len(jobs)} ({time.time() - t0:.0f}s)", flush=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", default=os.path.join(HERE, "work"))
    ap.add_argument("--out", default=os.path.join(HERE, "results_ablation"))
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    ap.add_argument("--quick", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    cache = os.path.join(a.work, "kth_f64_6c.npz"); uci = os.path.join(a.work, "uci")
    ns, nu = (2, 2) if a.quick else (20, 5)
    p1 = os.path.join(a.out, "ablation_kth.json")
    if os.path.exists(p1): kth = json.load(open(p1)); print("KTH: already done")
    else:
        jobs = [(cache, c, pr, s) for (c, pr) in ((5, "notebook"), (5, "official"), (6, "official")) for s in range(ns)]
        print(f"== KTH: {len(jobs)} runs", flush=True)
        kth = pool(kth_job, jobs, a.jobs, "KTH"); json.dump(kth, open(p1, "w"))
    p2 = os.path.join(a.out, "ablation_uci.json")
    if os.path.exists(p2): uu = json.load(open(p2)); print("UCI: already done")
    else:
        jobs = [(uci, n, s) for n in ("ucihar", "isolet") if os.path.exists(os.path.join(uci, n + ".npz")) for s in range(nu)]
        print(f"== UCI: {len(jobs)} runs", flush=True)
        uu = pool(uci_job, jobs, min(a.jobs, 5), "UCI") if jobs else []; json.dump(uu, open(p2, "w"))
    md = summarize(kth + uu)
    open(os.path.join(a.out, "ABLATION.md"), "w", encoding="utf-8").write(md); print(md)
    zp = os.path.join(HERE, "results_ablation.zip")
    with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
        for f in os.listdir(a.out): z.write(os.path.join(a.out, f), os.path.join("results_ablation", f))
    print("send back:", zp)


if __name__ == "__main__":
    main()
