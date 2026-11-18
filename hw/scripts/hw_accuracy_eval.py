"""
hw_accuracy_eval.py -- KTH accuracy of the notebook pipeline vs. what the hardware computes.

Run on Kaggle (same dataset as hdcvideoca.ipynb):
    !python hw_accuracy_eval.py --data /kaggle/input/private-dataset
Feature extraction (~10-20 min) is cached to --cache; re-runs only redo the HDC part.

Modes reported (all on the notebook's person-based train/val/test split):
  A. notebook float                     D=5000  (reproduces the notebook)
  B. notebook binary + int32 AM         D=5000  (reproduces the notebook)
  C. notebook fully binary, FIXED       D=5000  (notebook computed Xte@h_bin.T in int8 -> overflow;
                                                  0.20 = chance. Recomputed in int32 here.)
  D. float at D=5024                    isolates the effect of D=5000 -> 5024
  E. HW-EXACT NOVELTY                   D=5024  fixed-point front end (bit-exact models of the RTL),
                                                  quantize_unit rounding, int32 encode + sign, perceptron
                                                  training in int32, Q1.31 NOV_NORMALIZE, integer
                                                  argmax dot search. This is what the chip computes.
  F. HW novelty, binary AM              D=5024  sign(trained prototypes) + Hamming search
  G. BASELINE HDCU (paper) emulation    D=5024  binary bind, bundling limited by M=4-bit counters
                                                  (hierarchical majority, groups of 14, LFSR-style random
                                                  tie-break), binary class prototypes, Hamming search,
                                                  no retraining (the baseline ISA has no signed update)
  H. ideal binary majority              D=5024  G with unbounded counters (upper bound for G)
  I. E with ROTATED position HVs        D=5024  pos_f = rotate(P0_group, f) instead of 1010 stored random
                                                  HVs: position storage 616 KB -> 6 seeds (~4 KB). Shows
                                                  the accuracy cost of the memory-saving option.
  J. E with NARROWER prototype lanes    D=5024  prototypes saturate at int16 / int12 / int8 during training
                                                  and are normalized to Q1.15 / Q1.11 / Q1.7: what the wide
                                                  SPM's lane width (32 bits today, 15.4 mm^2 in sky130) buys.
                                                  The encode accumulator X needs far fewer bits than 32; the
                                                  bound is printed (max |X|).

Hardware-model assumptions (stated so they can go in the paper):
  * HOG: cv2.HOGDescriptor output rounded to Q16.16. The RTL hog_top matches cv2 within 5.3e-4
    (max abs) on the verification set; every other front-end stage is modelled bit-exactly.
  * fmin/fmax for quantization are computed over all samples, as in the notebook (set
    --quant-from-train to use training samples only, as a deployed system would).
  * Level/position hypervectors use the notebook's generators and seeds at D=5024.
"""
import os, re, sys, json, math, argparse, time
import numpy as np
import cv2

ap = argparse.ArgumentParser()
ap.add_argument("--data", default="/kaggle/input/private-dataset")
ap.add_argument("--cache", default="/kaggle/working/hw_feats.npz")
ap.add_argument("--quant-from-train", action="store_true")
ap.add_argument("--seed", type=int, default=0,
                help="random-seed set: 0 = the notebook's seeds; k > 0 shifts every HV / tie-break / "
                     "validation-split seed by 1000*k (test persons stay the KTH protocol split)")
ap.add_argument("--dump-rtl", default="", help="directory: write the mode-E prototypes, test queries and "
                "expected normalize / search results as hex files for the RTL test tb_nov_kth.sv")
ap.add_argument("--dump-bits", type=int, default=16, help="lane width for --dump-rtl (16 or 32)")
ap.add_argument("--skip", default="", help="comma-separated mode letters to skip, e.g. G,H")
args = ap.parse_args()
SO = 1000 * args.seed
SKIP = set(s.strip().upper() for s in args.skip.split(",") if s.strip())

# ---------------- notebook configuration ----------------
FRAME_SIZE, NUM_FRAMES = 32, 64
FLOW_GRID, N_ANGLE_BINS, BLOCK_SEARCH = 4, 8, 8
HOG_WIN_SIZE, HOG_BLOCK_SIZE, HOG_BLOCK_STRIDE, HOG_CELL_SIZE, HOG_NBINS = (32, 32), (16, 16), (8, 8), (8, 8), 9
AC_LAGS = 16
BASE_NLVL, NEW_NLVL = 21, 11
HDC_RETRAIN_EP = 40
SKIP_CLASS = "jogging"
W_BASE = 2
D_NB, D_HW = 5000, 5024
KTH_TRAIN_PERSONS = {11,12,13,14,15,16,17,18,19,20,21,23,24,25,1,4}
KTH_TEST_PERSONS  = {22,2,3,5,6,7,8,9,10}
N_CELLS = FLOW_GRID * FLOW_GRID
HOF_DIM = N_CELLS * N_ANGLE_BINS
CH = CW = FRAME_SIZE // FLOW_GRID

hog_cv = cv2.HOGDescriptor(_winSize=HOG_WIN_SIZE, _blockSize=HOG_BLOCK_SIZE, _blockStride=HOG_BLOCK_STRIDE,
                           _cellSize=HOG_CELL_SIZE, _nbins=HOG_NBINS)
HOG_DIM = hog_cv.compute(np.zeros(HOG_WIN_SIZE, dtype=np.uint8)).flatten().shape[0]

# ---------------- loading (identical to notebook) ----------------
def load_video(path):
    cap = cv2.VideoCapture(path); frames = []
    while True:
        ret, frame = cap.read()
        if not ret: break
        frames.append(cv2.resize(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY), (FRAME_SIZE, FRAME_SIZE)))
    cap.release()
    if not frames: return None
    idx = np.linspace(0, len(frames) - 1, NUM_FRAMES).astype(int)
    return np.array([frames[i] for i in idx])

def get_pid(fname):
    m = re.search(r'person(\d{2,3})', fname, re.IGNORECASE)
    return int(m.group(1)) if m else None

all_classes = sorted(d for d in os.listdir(args.data) if os.path.isdir(os.path.join(args.data, d)))
classes = [c for c in all_classes if c != SKIP_CLASS]; NUM_CLASSES = len(classes)
label_map = {c: i for i, c in enumerate(classes)}

# ======================================================================
# Bit-exact models of the RTL front end (Q16.16), from full_pipeline_golden.py
# ======================================================================
def trunc_div(a, b):
    q = abs(int(a)) // abs(int(b))
    return -q if (a < 0) ^ (b < 0) else q

def block_match_frame(prev, curr):
    """Integer SAD block matching; same candidate order as notebook and RTL. Returns |dx|,|dy| ints."""
    prev_i = prev.astype(np.int32); curr_i = curr.astype(np.int32)
    dx_arr = np.zeros(N_CELLS, dtype=np.int64); dy_arr = np.zeros(N_CELLS, dtype=np.int64)
    cell = 0
    for gy in range(FLOW_GRID):
        for gx in range(FLOW_GRID):
            y0 = gy * CH; x0 = gx * CW
            ref = curr_i[y0:y0 + CH, x0:x0 + CW]
            best_sad = None; best_dx = 0; best_dy = 0
            for dys in range(-BLOCK_SEARCH, BLOCK_SEARCH + 1):
                py0 = y0 + dys
                if py0 < 0 or py0 + CH > FRAME_SIZE: continue
                for dxs in range(-BLOCK_SEARCH, BLOCK_SEARCH + 1):
                    px0 = x0 + dxs
                    if px0 < 0 or px0 + CW > FRAME_SIZE: continue
                    sad = int(np.abs(ref - prev_i[py0:py0 + CH, px0:px0 + CW]).sum())
                    if best_sad is None or sad < best_sad:
                        best_sad = sad; best_dx = dxs; best_dy = dys
            dx_arr[cell] = abs(best_dx); dy_arr[cell] = abs(best_dy); cell += 1
    return dx_arr, dy_arr

def angle_bin(dx, dy):
    if dx > 0: return 0 if dy < dx else 1
    return 2 if dy > 0 else 7

def hof_for_pair_hw(dx_cell, dy_cell):
    hist = np.zeros(HOF_DIM, dtype=np.int64)
    for c in range(N_CELLS):
        dx = int(dx_cell[c]); dy = int(dy_cell[c]); magsq = dx * dx + dy * dy
        if magsq >= 1:
            hist[c * N_ANGLE_BINS + angle_bin(dx, dy)] += math.isqrt(magsq * 65536)
    norm = np.zeros(HOF_DIM, dtype=np.int64)
    for c in range(N_CELLS):
        s = int(hist[c * N_ANGLE_BINS:(c + 1) * N_ANGLE_BINS].sum())
        if s:
            for b in range(N_ANGLE_BINS):
                norm[c * N_ANGLE_BINS + b] = trunc_div(int(hist[c * N_ANGLE_BINS + b]) << 16, s)
    return hist, norm

def meanstd_sums_lanes(seq):
    """seq: (T, L) int64 Q16.16 -> (mean[L], std[L]) exactly as meanstd_sums_unit."""
    T = seq.shape[0]
    s1 = seq.sum(0); s2 = (seq * seq).sum(0)
    mean = np.array([trunc_div(int(v), T) for v in s1], dtype=np.int64)
    ssd = s2 - 2 * mean * s1 + T * mean * mean
    var = ssd >> 16
    var = np.array([trunc_div(int(v), T) for v in var], dtype=np.int64)
    std = np.array([math.isqrt(int(v) << 16) if v > 0 else 0 for v in var], dtype=np.int64)
    return mean, std

def vecnorm_hw(qi):
    qi = np.asarray(qi, dtype=np.int64)
    sumsq = int(((qi * qi) >> 16).sum())
    n = math.isqrt(max(sumsq, 0) << 16)
    if n == 0: return qi.copy()
    return np.array([trunc_div(int(x) << 16, n) for x in qi], dtype=np.int64)

def cellnorm_hw(qi, nc, nb):
    qi = np.asarray(qi, dtype=np.int64).reshape(nc, nb); out = np.zeros_like(qi)
    for c in range(nc):
        s = int(qi[c].sum())
        if s: out[c] = [trunc_div(int(x) << 16, s) for x in qi[c]]
    return out.flatten()

def autocorr_hw(x, n_lags=AC_LAGS):
    T = len(x); x = [int(v) for v in x]
    m = trunc_div(sum(x), T); xc = [v - m for v in x]
    v = sum(a * a for a in xc)
    out = np.zeros(n_lags, dtype=np.int64)
    if v == 0: return out
    for k in range(1, n_lags + 1):
        if T - k <= 0: continue
        out[k - 1] = trunc_div(sum(xc[i] * xc[i + k] for i in range(T - k)) << 16, v)
    return out

def percentile5_hw(x):
    T = len(x); xs = np.sort(np.asarray(x, dtype=np.int64)); out = np.zeros(5, dtype=np.int64)
    for i, p in enumerate([10, 25, 50, 75, 90]):
        rank_num = p * (T - 1); lo = rank_num // 100; rem = rank_num % 100
        frac = trunc_div(rem << 16, 100)
        lo_v = int(xs[lo]); hi_v = int(xs[min(lo + 1, T - 1)])
        out[i] = lo_v + (((hi_v - lo_v) * frac) >> 16)
    return out

# ---------------- notebook float feature helpers ----------------
def autocorr_f(x, n):
    x = x - x.mean(); v = np.dot(x, x)
    if v < 1e-8: return np.zeros(n, dtype=np.float32)
    # lags >= len(x) have no pairs (only possible for very short test clips; never at T=63)
    return np.array([np.dot(x[:len(x) - k], x[k:]) / v if k < len(x) else 0.0 for k in range(1, n + 1)], dtype=np.float32)

def norm_hof_cells(h):
    out = h.copy()
    for c in range(N_CELLS):
        s = out[c * N_ANGLE_BINS:(c + 1) * N_ANGLE_BINS].sum()
        if s > 1e-6: out[c * N_ANGLE_BINS:(c + 1) * N_ANGLE_BINS] /= s
    return out

def extract_both(frames):
    """One block-matching pass feeding both the notebook (float) and hardware (Q16.16) features."""
    T = len(frames)
    dx_c = np.zeros((T - 1, N_CELLS), np.float32); dy_c = np.zeros((T - 1, N_CELLS), np.float32)
    hof_accum = np.zeros(HOF_DIM, np.float32); hof_seq = np.zeros((T - 1, HOF_DIM), np.float32)
    hog_seq = np.zeros((T - 1, HOG_DIM), np.float32)
    gdx = np.zeros(T - 1, np.float32); gdy = np.zeros(T - 1, np.float32)
    # hardware
    h_hof_acc = np.zeros(HOF_DIM, np.int64)
    h_seq = np.zeros((T - 1, HOG_DIM + HOF_DIM + 2 * N_CELLS), np.int64)
    h_gdx = np.zeros(T - 1, np.int64); h_gdy = np.zeros(T - 1, np.int64)
    for t in range(1, T):
        dxi, dyi = block_match_frame(frames[t - 1], frames[t])
        dx = dxi.astype(np.float32); dy = dyi.astype(np.float32)
        dx_c[t - 1] = dx; dy_c[t - 1] = dy; gdx[t - 1] = dx.mean(); gdy[t - 1] = dy.mean()
        hof_frame = np.zeros(HOF_DIM, np.float32)
        for cell in range(N_CELLS):
            mag = np.sqrt(dx[cell] ** 2 + dy[cell] ** 2)
            if mag > 0.5:
                ang = np.arctan2(float(dy[cell]), float(dx[cell])) % (2 * np.pi)
                b = int(ang / (2 * np.pi) * N_ANGLE_BINS) % N_ANGLE_BINS
                hof_frame[cell * N_ANGLE_BINS + b] += mag; hof_accum[cell * N_ANGLE_BINS + b] += mag
        hof_seq[t - 1] = norm_hof_cells(hof_frame)
        hog = hog_cv.compute(frames[t]).flatten()
        hog_seq[t - 1] = hog
        # hardware path
        raw, hn = hof_for_pair_hw(dxi, dyi)
        h_hof_acc += raw
        h_seq[t - 1, :HOG_DIM] = np.round(hog.astype(np.float64) * 65536).astype(np.int64)
        h_seq[t - 1, HOG_DIM:HOG_DIM + HOF_DIM] = hn
        h_seq[t - 1, HOG_DIM + HOF_DIM:HOG_DIM + HOF_DIM + N_CELLS] = dxi << 16
        h_seq[t - 1, HOG_DIM + HOF_DIM + N_CELLS:] = dyi << 16
        h_gdx[t - 1] = (int(dxi.sum()) << 16) >> 4; h_gdy[t - 1] = (int(dyi.sum()) << 16) >> 4
    # float (notebook)
    hof_global = norm_hof_cells(hof_accum)
    fl = [np.concatenate([hof_global, hog_seq.mean(0), hof_seq.std(0), hog_seq.std(0)]).astype(np.float32),
          np.concatenate([dx_c.mean(0), dx_c.std(0)]), np.concatenate([dy_c.mean(0), dy_c.std(0)]),
          autocorr_f(gdy, AC_LAGS), autocorr_f(gdx, AC_LAGS),
          np.array([np.percentile(gdx, p) for p in [10, 25, 50, 75, 90]] +
                   [np.percentile(gdy, p) for p in [10, 25, 50, 75, 90]], np.float32)]
    # hardware
    mean, std = meanstd_sums_lanes(h_seq)
    a, b, c = HOG_DIM, HOG_DIM + HOF_DIM, HOG_DIM + HOF_DIM + N_CELLS
    base_raw = np.concatenate([cellnorm_hw(h_hof_acc, N_CELLS, N_ANGLE_BINS), mean[:a], std[a:b], std[:a]])
    hw = [vecnorm_hw(base_raw),
          vecnorm_hw(np.concatenate([mean[b:c], std[b:c]])),
          vecnorm_hw(np.concatenate([mean[c:], std[c:]])),
          vecnorm_hw(autocorr_hw(h_gdy)), vecnorm_hw(autocorr_hw(h_gdx)),
          vecnorm_hw(np.concatenate([percentile5_hw(h_gdx), percentile5_hw(h_gdy)]))]
    return fl, hw

GROUP_NAMES = ["base", "dx", "dy", "acd", "acx", "pct"]
if os.path.exists(args.cache):
    z = np.load(args.cache, allow_pickle=True)
    labels = z["labels"]; pids = z["pids"]
    FL = [z[f"fl_{g}"] for g in GROUP_NAMES]; HW = [z[f"hw_{g}"] for g in GROUP_NAMES]
    print(f"loaded cached features: {len(labels)} clips")
else:
    labels, pids, fl_all, hw_all = [], [], [], []
    t0 = time.time()
    for cls in all_classes:
        if cls == SKIP_CLASS: continue
        d = os.path.join(args.data, cls)
        for fname in sorted(f for f in os.listdir(d) if f.endswith(".avi")):
            fr = load_video(os.path.join(d, fname))
            if fr is None: continue
            fl, hw = extract_both(fr)
            fl_all.append(fl); hw_all.append(hw); labels.append(label_map[cls]); pids.append(get_pid(fname))
            if len(labels) % 50 == 0: print(f"  {len(labels)} clips, {time.time() - t0:.0f}s", flush=True)
    labels = np.array(labels); pids = np.array(pids, dtype=object)
    FL = [np.array([x[i] for x in fl_all], np.float32) for i in range(6)]
    HW = [np.array([x[i] for x in hw_all], np.int64) for i in range(6)]
    np.savez(args.cache, labels=labels, pids=pids,
             **{f"fl_{g}": FL[i] for i, g in enumerate(GROUP_NAMES)},
             **{f"hw_{g}": HW[i] for i, g in enumerate(GROUP_NAMES)})
    print(f"extracted {len(labels)} clips in {time.time() - t0:.0f}s -> {args.cache}")

# ---------------- split (identical to notebook) ----------------
train_mask = np.array([int(p) in KTH_TRAIN_PERSONS for p in pids])
test_mask  = np.array([int(p) in KTH_TEST_PERSONS for p in pids])
train_mask |= ~(train_mask | test_mask)
tr_all = np.where(train_mask)[0]; te_idx = np.where(test_mask)[0]
rng = np.random.RandomState(42 + SO); perm = rng.permutation(len(tr_all))
n_val = max(NUM_CLASSES, int(len(tr_all) * 0.15))
val_idx = tr_all[perm[:n_val]]; tr_idx = tr_all[perm[n_val:]]
print(f"split: train={len(tr_idx)} val={len(val_idx)} test={len(te_idx)}")

# ======================================================================
# HDC
# ======================================================================
def make_level_vectors(n_levels, dim, seed=42):
    rng = np.random.RandomState(seed); base = rng.choice([-1., 1.], size=dim).astype(np.float32)
    lvls = np.zeros((n_levels, dim), np.float32); lvls[0] = base
    flip = max(1, dim // (2 * max(1, n_levels - 1))); order = rng.permutation(dim); cur, done = base.copy(), 0
    for lvl in range(1, n_levels):
        fi = order[done:done + flip]; cur = cur.copy(); cur[fi] *= -1.; lvls[lvl] = cur; done += flip
    return lvls

def fnorm(f):
    n = np.linalg.norm(f, axis=1, keepdims=True); return f / np.where(n > 0, n, 1.0)

def quant_float(feat, nlvl, ref):
    fmin = feat[ref].min(0, keepdims=True); fmax = feat[ref].max(0, keepdims=True)
    span = np.where(fmax > fmin, fmax - fmin, 1.0)
    return np.clip(((feat - fmin) / span * (nlvl - 1)).round().astype(int), 0, nlvl - 1)

def quant_hw(feat_q, nlvl, ref):
    """quantize_unit: idx = clamp(round_half_away((x - fmin)*(nlvl-1) / span)), all Q16.16 integers.
    fmin/span come from software (CSRs); span defaults to 1.0 when fmax == fmin (as the notebook)."""
    fmin = feat_q[ref].min(0, keepdims=True); fmax = feat_q[ref].max(0, keepdims=True)
    span = np.where(fmax > fmin, fmax - fmin, 65536)
    num = (feat_q - fmin) * (nlvl - 1)
    half = span >> 1
    adj = np.where(num >= 0, num + half, num - half)
    q = np.sign(adj) * (np.abs(adj) // np.abs(span))
    return np.clip(q, 0, nlvl - 1).astype(int)

def encode_sum(idx_groups, nlvls, weights, D, rotate_pos=False):
    """Shared accumulator X = sum_g w_g sum_f lvl_g[idx] * pos_gf (bipolar). Exact integers (int32 in HW).
    rotate_pos: pos_gf = roll(P0_g, f) from one random seed HV per group (memory-saving option)."""
    N = idx_groups[0].shape[0]; X = np.zeros((N, D), np.int32)
    for i, (idx, nlvl, w) in enumerate(zip(idx_groups, nlvls, weights)):
        lhvs = make_level_vectors(nlvl, D, seed=42 + SO + i * 7).astype(np.int8)
        if rotate_pos:
            p0 = np.random.RandomState(43 + SO + i * 7).choice([-1, 1], size=D).astype(np.int8)
            phvs = np.stack([np.roll(p0, f) for f in range(idx.shape[1])])
        else:
            phvs = np.random.RandomState(43 + SO + i * 7).choice([-1, 1], size=(idx.shape[1], D)).astype(np.int8)
        grp = np.zeros((N, D), np.int32)
        for f in range(idx.shape[1]): grp += lhvs[idx[:, f]] * phvs[f]
        X += w * grp
    return X

def sign_pm1(X):
    s = np.sign(X).astype(np.int8); s[s == 0] = 1; return s       # ties -> +1 (sign_unit)

def acc(y, p): return float(np.mean(y == p))

def train_float(X, y, binary_am=False):
    """Notebook train_eval, with the fully-binary mode computed in int32 (the notebook's int8 bug fixed)."""
    Xtr, ytr, Xv, yv, Xte, yte = X[tr_idx], y[tr_idx], X[val_idx], y[val_idx], X[te_idx], y[te_idx]
    D = X.shape[1]
    if binary_am:
        hvs = np.zeros((NUM_CLASSES, D), np.int64)
        for hv, l in zip(Xtr, ytr): hvs[l] += hv
        best_v, best_h = -1., hvs.copy()
        for _ in range(HDC_RETRAIN_EP):
            for hv, l in zip(Xtr, ytr):
                p = int(np.argmax(hvs @ hv.astype(np.int64)))
                if p != l: hvs[l] += hv; hvs[p] -= hv
            va = acc(yv, np.argmax(Xv.astype(np.int64) @ hvs.T, 1))
            if va > best_v: best_v, best_h = va, hvs.copy()
        hb = sign_pm1(best_h).astype(np.int32)
        return acc(yte, np.argmax(Xte.astype(np.int32) @ hb.T, 1))
    hvs = np.zeros((NUM_CLASSES, D), np.float64)
    for hv, l in zip(Xtr, ytr): hvs[l] += hv
    best_v, best_h = -1., hvs.copy()
    for _ in range(HDC_RETRAIN_EP):
        for hv, l in zip(Xtr, ytr):
            p = int(np.argmax(hvs @ hv))
            if p != l: hvs[l] += hv; hvs[p] -= hv
        n = np.linalg.norm(hvs, axis=1, keepdims=True) + 1e-8
        va = acc(yv, np.argmax(Xv @ (hvs / n).T, 1))
        if va > best_v: best_v, best_h = va, hvs.copy()
    for c in range(NUM_CLASSES):
        n = np.linalg.norm(best_h[c])
        if n > 0: best_h[c] /= n
    return acc(yte, np.argmax(Xte @ best_h.T, 1))

INT32_MAX, INT32_MIN = 2**31 - 1, -2**31
def normalize_q31(h, bits=32):
    """NOV_NORMALIZE: q = sign(h) * min(trunc(|h| * 2^(bits-1) / isqrt(sum h^2)), 2^(bits-1)-1);
    norm==0 -> copy. bits=32 is the hardware (Q1.31); smaller values model a narrower lane (mode J)."""
    out = h.copy(); fb = bits - 1; top = 2**fb - 1
    for c in range(h.shape[0]):
        n = math.isqrt(int((h[c].astype(object) ** 2).sum()))
        if n:
            mag = np.minimum((np.abs(h[c]) << fb) // n, top)
            out[c] = np.sign(h[c]) * mag
    return out

def train_hw(Xb, y, binary_am=False, bits=32):
    """Hardware novelty flow: int32 prototypes (saturating), NOV_PROTO_UPDATE perceptron, validation and
    test via NOV_NORMALIZE (Q1.31) + NOV_DOTSEARCH (first max wins). Xb is +-1 (sign_unit output).
    bits < 32 models a narrower prototype lane (saturation and normalize scale), mode J."""
    Xtr, ytr, Xv, yv, Xte, yte = Xb[tr_idx], y[tr_idx], Xb[val_idx], y[val_idx], Xb[te_idx], y[te_idx]
    lo, hi = -2**(bits - 1), 2**(bits - 1) - 1
    sat = lambda a: np.clip(a, lo, hi)
    hvs = np.zeros((NUM_CLASSES, Xb.shape[1]), np.int64)
    for hv, l in zip(Xtr, ytr): hvs[l] = sat(hvs[l] + hv)
    best_v, best_h = -1., hvs.copy()
    for _ in range(HDC_RETRAIN_EP):
        for hv, l in zip(Xtr, ytr):
            p = int(np.argmax(hvs @ hv.astype(np.int64)))
            if p != l: hvs[l] = sat(hvs[l] + hv); hvs[p] = sat(hvs[p] - hv)
        va = acc(yv, np.argmax(Xv.astype(np.int64) @ normalize_q31(hvs, bits).T, 1))
        if va > best_v: best_v, best_h = va, hvs.copy()
    if binary_am:
        hb = sign_pm1(best_h).astype(np.int64)
        return acc(yte, np.argmax(Xte.astype(np.int64) @ hb.T, 1)), best_h
    return acc(yte, np.argmax(Xte.astype(np.int64) @ normalize_q31(best_h, bits).T, 1)), best_h

# ---- baseline HDCU emulation: binary bundling limited by M-bit counters ----
M_BITS = 4
GROUP = 2 ** M_BITS - 2          # 14: even group size <= 15 (counter max), threshold n/2, random ties
tie_rng = np.random.RandomState(2024 + SO)

def clip_bits(cnt, n):
    """hvclip with threshold n/2 (n even); exact ties broken randomly (the HDCU uses an LFSR)."""
    thr = n // 2
    out = (cnt > thr).astype(np.uint8)
    ties = cnt == thr
    out[ties] = tie_rng.randint(0, 2, size=int(ties.sum())).astype(np.uint8)
    return out

def bundle_hier(vec_iter, shape, ideal=False):
    """Majority of a stream of binary (0/1) HVs. ideal=False: hierarchical, at most GROUP per counter
    pass, then majority of the partial results (what an M-bit-counter bundler can do).
    ideal=True: one unbounded counter."""
    if ideal:
        cnt = np.zeros(shape, np.int32); n = 0
        for v in vec_iter: cnt += v; n += 1
        if n % 2 == 0: return clip_bits(cnt, n)             # random tie-break at exactly n/2
        return (cnt > n // 2).astype(np.uint8)              # odd n: strict majority, no ties
    level = []
    cnt = np.zeros(shape, np.int32); n = 0
    def flush():
        nonlocal cnt, n
        if n == 0: return
        if n % 2:                                   # pad to even with a random HV (standard trick)
            cnt += tie_rng.randint(0, 2, size=shape); n += 1
        level.append(clip_bits(cnt, n)); cnt = np.zeros(shape, np.int32); n = 0
    for v in vec_iter:
        cnt += v; n += 1
        if n == GROUP: flush()
    flush()
    while len(level) > 1:
        nxt = []
        for i in range(0, len(level), GROUP):
            grp = level[i:i + GROUP]; c = np.sum(grp, axis=0, dtype=np.int32); m = len(grp)
            if m % 2: c += tie_rng.randint(0, 2, size=shape); m += 1
            nxt.append(clip_bits(c, m))
        level = nxt
    return level[0]

def baseline_mode(idx_groups, nlvls, weights, y, D, ideal):
    """Binary encode (bind = XOR, bit 1 <-> -1) + bundling; weights by repetition; class prototypes by
    bundling the class's training HVs; Hamming-distance search (argmin, first wins)."""
    N = idx_groups[0].shape[0]
    lbits = [((1 - make_level_vectors(nl, D, seed=42 + SO + i * 7)) // 2).astype(np.uint8) for i, nl in enumerate(nlvls)]
    pbits = [((1 - np.random.RandomState(43 + SO + i * 7).choice([-1, 1], size=(g.shape[1], D))) // 2).astype(np.uint8)
             for i, g in enumerate(idx_groups)]
    def stream():
        for i, (idx, w) in enumerate(zip(idx_groups, weights)):
            for f in range(idx.shape[1]):
                b = lbits[i][idx[:, f]] ^ pbits[i][f]
                for _ in range(w): yield b
    H = bundle_hier(stream(), (N, D), ideal=ideal)
    protos = np.stack([bundle_hier((H[i] for i in tr_idx[y[tr_idx] == c]), (D,), ideal=ideal)
                       for c in range(NUM_CLASSES)])
    ham = np.array([[np.count_nonzero(H[i] ^ protos[c]) for c in range(NUM_CLASSES)] for i in te_idx])
    return acc(y[te_idx], np.argmin(ham, 1))

# ======================================================================
# run
# ======================================================================
y = labels
weights = [W_BASE, 1, 1, 1, 1, 1]
nlvls = [BASE_NLVL] + [NEW_NLVL] * 5
ref = tr_all if args.quant_from_train else np.arange(len(y))
results = {}

fl_groups = [fnorm(g.astype(np.float32)) for g in FL]
idx_fl = [quant_float(g, nl, ref) for g, nl in zip(fl_groups, nlvls)]
idx_hw = [quant_hw(g, nl, ref) for g, nl in zip(HW, nlvls)]
agree = np.mean(np.concatenate([(a == b).ravel() for a, b in zip(idx_fl, idx_hw)]))
print(f"quantized level indices: hardware == notebook for {agree*100:.2f}% of (sample, feature) pairs")

def run(tag, fn):
    if tag[0] in SKIP: return
    t0 = time.time(); a = fn(); results[tag] = a
    print(f"  {tag:<44s} {a:.4f}   ({time.time() - t0:.0f}s)", flush=True)

print("\nmode                                          test acc")
X5000 = encode_sum(idx_fl, nlvls, weights, D_NB)
run("A. notebook float (D=5000)", lambda: train_float((X5000 / np.maximum(np.linalg.norm(X5000, axis=1, keepdims=True), 1e-12)).astype(np.float32), y))
run("B. notebook binary + int32 AM (D=5000)", lambda: train_float(sign_pm1(X5000).astype(np.float32), y))
run("C. notebook fully binary, int8 bug fixed (D=5000)", lambda: train_float(sign_pm1(X5000), y, binary_am=True))
del X5000
X_f = encode_sum(idx_fl, nlvls, weights, D_HW)
run("D. float (D=5024)", lambda: train_float((X_f / np.maximum(np.linalg.norm(X_f, axis=1, keepdims=True), 1e-12)).astype(np.float32), y))
del X_f
X_hw = encode_sum(idx_hw, nlvls, weights, D_HW)
assert np.abs(X_hw).max() < 2**31, "accumulator would saturate"
Xb_hw = sign_pm1(X_hw)
run("E. HW-EXACT NOVELTY (D=5024)", lambda: train_hw(Xb_hw, y)[0])
run("F. HW novelty, binary AM + Hamming (D=5024)", lambda: train_hw(Xb_hw, y, binary_am=True)[0])
run("G. BASELINE HDCU emulation, 4-bit counters", lambda: baseline_mode(idx_hw, nlvls, weights, y, D_HW, ideal=False))
run("H. ideal binary majority (G upper bound)", lambda: baseline_mode(idx_hw, nlvls, weights, y, D_HW, ideal=True))
if "I" not in SKIP:
    Xb_rot = sign_pm1(encode_sum(idx_hw, nlvls, weights, D_HW, rotate_pos=True))
    run("I. HW novelty, rotated position HVs", lambda: train_hw(Xb_rot, y)[0])

if "J" not in SKIP:
    for b in (16, 12, 8):
        run(f"J. E with int{b} prototype lanes", lambda b=b: train_hw(Xb_hw, y, bits=b)[0])
_, h32 = train_hw(Xb_hw, y)
proto_peak = int(np.abs(h32).max())
xmax = int(np.abs(X_hw).max())
xbound = sum(w * g.shape[1] for w, g in zip(weights, idx_hw))
if args.dump_rtl:
    W = args.dump_bits; os.makedirs(args.dump_rtl, exist_ok=True)
    acc_w, best_h = train_hw(Xb_hw, y, bits=W)
    hn = normalize_q31(best_h, W)
    Xte_b = Xb_hw[te_idx]
    pred = np.argmax(Xte_b.astype(np.int64) @ hn.T, 1)
    K, Dh = best_h.shape; CHN = Dh // 32; m = (1 << W) - 1
    def rows(h):                                   # wide-SPM rows: lane l of chunk c at bits [l*W +: W]
        out = []
        for k in range(K):
            for c in range(CHN):
                v = 0
                for l in range(32): v |= (int(h[k, c*32 + l]) & m) << (l * W)
                out.append(f"{v:0{32*W//4}x}")
        return out
    open(os.path.join(args.dump_rtl, "protos_raw.hex"), "w").write("\n".join(rows(best_h)) + "\n")
    open(os.path.join(args.dump_rtl, "protos_norm.hex"), "w").write("\n".join(rows(hn)) + "\n")
    q = []
    for i in range(Xte_b.shape[0]):
        for c in range(CHN):
            w = 0
            for l in range(32): w |= (1 if Xte_b[i, c*32 + l] < 0 else 0) << l    # bit 1 <-> -1
            q.append(f"{w:08x}")
    open(os.path.join(args.dump_rtl, "queries.hex"), "w").write("\n".join(q) + "\n")
    open(os.path.join(args.dump_rtl, "pred.hex"), "w").write("\n".join(f"{int(v):08x}" for v in pred) + "\n")
    open(os.path.join(args.dump_rtl, "kth_case.svh"), "w").write(
        f"localparam int KC = {K}, CHN = {CHN}, NQ = {Xte_b.shape[0]}, LANE = {W};\n"
        f"localparam int MODEL_CORRECT = {int((pred == y[te_idx]).sum())};\n")
    print(f"dumped RTL case to {args.dump_rtl}: K={K}, chunks={CHN}, {Xte_b.shape[0]} test queries, "
          f"lane {W} bits, model test acc {acc_w:.4f}")

print(f"\nmax |X| in HW encode: {xmax} (bound sum(w*features) = {xbound}: needs "
      f"{xbound.bit_length() + 1} signed bits; int32 lanes never saturate)")
print(f"max |prototype| after int32 training: {proto_peak} (needs {proto_peak.bit_length() + 1} signed bits)")
with open(os.path.join(os.path.dirname(os.path.abspath(args.cache)), "hw_accuracy_results.json"), "w") as f:
    json.dump({"results": results, "quant_index_agreement": agree,
               "max_abs_X": xmax, "X_bound": xbound, "max_abs_proto_int32": proto_peak,
               "quant_from_train": bool(args.quant_from_train), "seed": args.seed, "D_hw": D_HW}, f, indent=2)
print("wrote hw_accuracy_results.json")
