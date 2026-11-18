"""
hdc_model.py -- the hardware-exact model of the SWIFT-HDC pipeline, as a library.

Front end: bit-exact Q16.16 models of the RTL units (copied unchanged from
hw_accuracy_eval.py, which was proven equal to the RTL on all 1010 outputs).
HDC: encode / sign / saturating W-bit training / Q1.(W-1) normalize / dot search exactly
as the SWIFT core computes them (proven equal to the RTL on the real KTH prototypes and
test queries), plus the baseline-HDCU emulation and float reference models.
Every random choice takes an explicit seed offset `so` (0 = the notebook's seeds).
"""
import os, re, math
import numpy as np

# ---------------- notebook configuration ----------------
FRAME_SIZE, NUM_FRAMES = 32, 64
FLOW_GRID, N_ANGLE_BINS, BLOCK_SEARCH = 4, 8, 8
HOG_WIN_SIZE, HOG_BLOCK_SIZE, HOG_BLOCK_STRIDE, HOG_CELL_SIZE, HOG_NBINS = (32, 32), (16, 16), (8, 8), (8, 8), 9
AC_LAGS = 16
BASE_NLVL, NEW_NLVL = 21, 11
SKIP_CLASS = "jogging"
W_BASE = 2
D_NB, D_HW = 5000, 5024
KTH_TRAIN_PERSONS = {11,12,13,14,15,16,17,18,19,20,21,23,24,25,1,4}
KTH_TEST_PERSONS  = {22,2,3,5,6,7,8,9,10}
N_CELLS = FLOW_GRID * FLOW_GRID
HOF_DIM = N_CELLS * N_ANGLE_BINS
CH = CW = FRAME_SIZE // FLOW_GRID

HOG_DIM = 324                      # cv2.HOGDescriptor output size for this configuration
_hog_cv = None
def hog_cv():
    global _hog_cv
    if _hog_cv is None:
        import cv2
        _hog_cv = cv2.HOGDescriptor(_winSize=HOG_WIN_SIZE, _blockSize=HOG_BLOCK_SIZE, _blockStride=HOG_BLOCK_STRIDE,
                                    _cellSize=HOG_CELL_SIZE, _nbins=HOG_NBINS)
        assert _hog_cv.compute(np.zeros(HOG_WIN_SIZE, dtype=np.uint8)).flatten().shape[0] == HOG_DIM
    return _hog_cv

# ---------------- loading (identical to notebook) ----------------
def load_video(path):
    import cv2
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
        hog = hog_cv().compute(frames[t]).flatten()
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

# ======================================================================
# Dataset cache
# ======================================================================
GROUP_NAMES = ["base", "dx", "dy", "acd", "acx", "pct"]
ALL_CLASSES = ["boxing", "handclapping", "handwaving", "jogging", "running", "walking"]


def extract_dataset(data_dir, cache, classes, log=print, num_frames=None):
    """Extract float + hardware features for every clip of `classes`; save to `cache` (.npz).
    num_frames: frames sampled per clip (default NUM_FRAMES = 64, the hardware configuration)."""
    import time
    global NUM_FRAMES
    if num_frames is not None: NUM_FRAMES = int(num_frames)
    labels, pids, fl_all, hw_all, names = [], [], [], [], []
    t0 = time.time()
    for ci, cls in enumerate(classes):
        d = os.path.join(data_dir, cls)
        for fname in sorted(f for f in os.listdir(d) if f.lower().endswith(".avi")):
            fr = load_video(os.path.join(d, fname))
            if fr is None: continue
            fl, hw = extract_both(fr)
            fl_all.append(fl); hw_all.append(hw); labels.append(ci); pids.append(get_pid(fname)); names.append(fname)
            if len(labels) % 50 == 0: log(f"  {len(labels)} clips, {time.time() - t0:.0f}s")
    FL = [np.array([x[i] for x in fl_all], np.float32) for i in range(6)]
    HW = [np.array([x[i] for x in hw_all], np.int64) for i in range(6)]
    np.savez(cache, labels=np.array(labels), pids=np.array(pids, dtype=object), names=np.array(names),
             classes=np.array(classes), num_frames=NUM_FRAMES, **{f"fl_{g}": FL[i] for i, g in enumerate(GROUP_NAMES)},
             **{f"hw_{g}": HW[i] for i, g in enumerate(GROUP_NAMES)})
    log(f"extracted {len(labels)} clips in {time.time() - t0:.0f}s -> {cache}")


def load_cache(cache):
    z = np.load(cache, allow_pickle=True)
    classes = list(z["classes"]) if "classes" in z.files else [c for c in ALL_CLASSES if c != "jogging"]
    return dict(labels=np.asarray(z["labels"]), pids=np.array([int(p) for p in z["pids"]]),
                FL=[z[f"fl_{g}"] for g in GROUP_NAMES], HW=[z[f"hw_{g}"] for g in GROUP_NAMES],
                classes=[str(c) for c in classes])


def subset(data, keep_mask, classes_keep):
    """Restrict a loaded cache to clips in keep_mask and relabel to classes_keep order."""
    old = data["classes"]; remap = {old.index(c): i for i, c in enumerate(classes_keep)}
    idx = np.where(keep_mask)[0]
    return dict(labels=np.array([remap[int(l)] for l in data["labels"][idx]]), pids=data["pids"][idx],
                FL=[g[idx] for g in data["FL"]], HW=[g[idx] for g in data["HW"]], classes=list(classes_keep))

# ======================================================================
# Splits
# ======================================================================
KTH_OFFICIAL_TRAIN = {11, 12, 13, 14, 15, 16, 17, 18}
KTH_OFFICIAL_VAL = {19, 20, 21, 23, 24, 25, 1, 4}
KTH_OFFICIAL_TEST = {22, 2, 3, 5, 6, 7, 8, 9, 10}


def split_notebook(pids, so, num_classes):
    """The hdcvideoca notebook split: test = KTH test persons; train+val persons pooled and
    15 % of them drawn at random (seed 42+so) as validation."""
    train_mask = np.array([p in (KTH_OFFICIAL_TRAIN | KTH_OFFICIAL_VAL) for p in pids])
    test_mask = np.array([p in KTH_OFFICIAL_TEST for p in pids])
    train_mask |= ~(train_mask | test_mask)
    tr_all = np.where(train_mask)[0]; te = np.where(test_mask)[0]
    perm = np.random.RandomState(42 + so).permutation(len(tr_all))
    n_val = max(num_classes, int(len(tr_all) * 0.15))
    return dict(tr=tr_all[perm[n_val:]], va=tr_all[perm[:n_val]], te=te, tr_all=tr_all)


def split_official(pids):
    """Schuldt et al. 2004: train persons 11-18, validation 1,4,19-21,23-25, test 2,3,5-10,22."""
    tr = np.where([p in KTH_OFFICIAL_TRAIN for p in pids])[0]
    va = np.where([p in KTH_OFFICIAL_VAL for p in pids])[0]
    te = np.where([p in KTH_OFFICIAL_TEST for p in pids])[0]
    return dict(tr=tr, va=va, te=te, tr_all=np.concatenate([tr, va]))


def split_lopo(pids, person, so, num_classes):
    """Leave-one-person-out: test = one person; validation = 15 % of the rest (seeded)."""
    te = np.where(pids == person)[0]; rest = np.where(pids != person)[0]
    perm = np.random.RandomState(42 + so).permutation(len(rest))
    n_val = max(num_classes, int(len(rest) * 0.15))
    return dict(tr=rest[perm[n_val:]], va=rest[perm[:n_val]], te=te, tr_all=rest)

# ======================================================================
# HDC (identical arithmetic to hw_accuracy_eval.py; seeds explicit)
# ======================================================================
BASE_NLVL, NEW_NLVL, W_BASE = 21, 11, 2
NLVLS = [BASE_NLVL] + [NEW_NLVL] * 5
WEIGHTS = [W_BASE, 1, 1, 1, 1, 1]


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
    fmin = feat_q[ref].min(0, keepdims=True); fmax = feat_q[ref].max(0, keepdims=True)
    span = np.where(fmax > fmin, fmax - fmin, 65536)
    num = (feat_q - fmin) * (nlvl - 1)
    half = span >> 1
    adj = np.where(num >= 0, num + half, num - half)
    q = np.sign(adj) * (np.abs(adj) // np.abs(span))
    return np.clip(q, 0, nlvl - 1).astype(int)


def quantize_groups(data, ref, hardware=True, nlvls=NLVLS):
    if hardware:
        return [quant_hw(g, nl, ref) for g, nl in zip(data["HW"], nlvls)]
    return [quant_float(fnorm(g.astype(np.float32)), nl, ref) for g, nl in zip(data["FL"], nlvls)]


# SWIFT_GEN=1 makes table-free encoding (BINDGEN, rtl/hv_gen_unit.sv) the default for every SWIFT
# and float-HDC encoding; the baseline-HDCU emulation keeps its random tables.
GEN_DEFAULT = os.environ.get("SWIFT_GEN", "0") == "1"


def encode_sum(idx_groups, D, so=0, rotate_pos=False, nlvls=NLVLS, weights=WEIGHTS, groups=None, gen=None, gen_variant="chip"):
    """X = sum_g w_g sum_f L_g[q] * P_gf (bipolar), exact integers. `groups` optionally limits
    the encoded groups (ablation); the seeds of every group stay those of the full model."""
    if gen is None: gen = GEN_DEFAULT and not rotate_pos   # rotated-position ablation stays table-based
    N = idx_groups[0].shape[0]; X = np.zeros((N, D), np.int32)
    for i, (idx, nlvl, w) in enumerate(zip(idx_groups, nlvls, weights)):
        if groups is not None and i not in groups: continue
        if gen:                       # table-free encoding: bit-exact with rtl/hv_gen_unit.sv
            import hvgen
            sl, sp = hvgen.seeds(so, i)
            Dg = -(-D // 32) * 32     # generator works on whole 32-lane chunks; trim for D % 32 != 0
            lt = hvgen.level_table_naive if gen_variant in ("naive_level", "naive_both") else hvgen.level_table
            pt = hvgen.pos_table_rot if gen_variant in ("rot_pos", "naive_both") else hvgen.pos_table
            lhvs = hvgen.bip(lt(sl, nlvl, Dg))[:, :D]
            phvs = hvgen.bip(pt(sp, idx.shape[1], Dg))[:, :D]
            grp = np.zeros((N, D), np.int32)
            for f in range(idx.shape[1]): grp += lhvs[idx[:, f]] * phvs[f]
            X += w * grp
            continue
        lhvs = make_level_vectors(nlvl, D, seed=42 + so + i * 7).astype(np.int8)
        if rotate_pos:
            p0 = np.random.RandomState(43 + so + i * 7).choice([-1, 1], size=D).astype(np.int8)
            phvs = np.stack([np.roll(p0, f) for f in range(idx.shape[1])])
        else:
            phvs = np.random.RandomState(43 + so + i * 7).choice([-1, 1], size=(idx.shape[1], D)).astype(np.int8)
        grp = np.zeros((N, D), np.int32)
        for f in range(idx.shape[1]): grp += lhvs[idx[:, f]] * phvs[f]
        X += w * grp
    return X


def sign_pm1(X):
    s = np.sign(X).astype(np.int8); s[s == 0] = 1; return s


def accuracy(y, p): return float(np.mean(np.asarray(y) == np.asarray(p)))


def normalize_q(h, bits=16):
    """NOV_NORMALIZE: q = sign(h) * min(trunc(|h| * 2^(bits-1) / isqrt(sum h^2)), 2^(bits-1)-1)."""
    out = h.copy(); fb = bits - 1; top = 2 ** fb - 1
    for c in range(h.shape[0]):
        n = math.isqrt(int((h[c].astype(object) ** 2).sum()))
        if n:
            mag = np.minimum((np.abs(h[c]) << fb) // n, top)
            out[c] = np.sign(h[c]) * mag
    return out


def train_hw(Xb, y, sp, K, bits=16, epochs=40, binary_am=False, train_subset=None, curve=False):
    """SWIFT core flow: saturating W-bit prototypes, perceptron updates (NOV_PROTO_UPDATE), best
    validation epoch kept, NOV_NORMALIZE, NOV_DOTSEARCH. Returns dict with acc, pred, protos,
    and (curve=True) per-epoch validation/test accuracy and update counts."""
    tr = sp["tr"] if train_subset is None else train_subset
    Xtr, ytr, Xv, yv, Xte, yte = Xb[tr], y[tr], Xb[sp["va"]], y[sp["va"]], Xb[sp["te"]], y[sp["te"]]
    lo, hi = -2 ** (bits - 1), 2 ** (bits - 1) - 1
    sat = lambda a: np.clip(a, lo, hi)
    hvs = np.zeros((K, Xb.shape[1]), np.int64)
    for hv, l in zip(Xtr, ytr): hvs[l] = sat(hvs[l] + hv)
    best_v, best_h, best_ep = -1., hvs.copy(), 0
    hist = []
    if curve:
        hist.append(dict(epoch=0, updates=0,
                         val=accuracy(yv, np.argmax(Xv.astype(np.int64) @ normalize_q(hvs, bits).T, 1)),
                         test=accuracy(yte, np.argmax(Xte.astype(np.int64) @ normalize_q(hvs, bits).T, 1))))
    for ep in range(epochs):
        upd = 0
        for hv, l in zip(Xtr, ytr):
            p = int(np.argmax(hvs @ hv.astype(np.int64)))
            if p != l: hvs[l] = sat(hvs[l] + hv); hvs[p] = sat(hvs[p] - hv); upd += 1
        hn = normalize_q(hvs, bits)
        va = accuracy(yv, np.argmax(Xv.astype(np.int64) @ hn.T, 1))
        if curve:
            hist.append(dict(epoch=ep + 1, updates=upd, val=va,
                             test=accuracy(yte, np.argmax(Xte.astype(np.int64) @ hn.T, 1))))
        if va > best_v: best_v, best_h, best_ep = va, hvs.copy(), ep + 1
    if binary_am:
        hb = sign_pm1(best_h).astype(np.int64)
        pred = np.argmax(Xte.astype(np.int64) @ hb.T, 1)
        return dict(acc=accuracy(yte, pred), pred=pred, protos=hb, best_epoch=best_ep, curve=hist)
    hn = normalize_q(best_h, bits)
    pred = np.argmax(Xte.astype(np.int64) @ hn.T, 1)
    return dict(acc=accuracy(yte, pred), pred=pred, protos=hn, raw=best_h, best_epoch=best_ep, curve=hist)


def train_float(X, y, sp, K, epochs=40, binary_am=False):
    """Reference (notebook) training in float, fully-binary mode computed in integers."""
    Xtr, ytr, Xv, yv, Xte, yte = X[sp["tr"]], y[sp["tr"]], X[sp["va"]], y[sp["va"]], X[sp["te"]], y[sp["te"]]
    D = X.shape[1]
    if binary_am:
        hvs = np.zeros((K, D), np.int64)
        for hv, l in zip(Xtr, ytr): hvs[l] += hv
        best_v, best_h = -1., hvs.copy()
        for _ in range(epochs):
            for hv, l in zip(Xtr, ytr):
                p = int(np.argmax(hvs @ hv.astype(np.int64)))
                if p != l: hvs[l] += hv; hvs[p] -= hv
            va = accuracy(yv, np.argmax(Xv.astype(np.int64) @ hvs.T, 1))
            if va > best_v: best_v, best_h = va, hvs.copy()
        hb = sign_pm1(best_h).astype(np.int32)
        pred = np.argmax(Xte.astype(np.int32) @ hb.T, 1)
        return dict(acc=accuracy(yte, pred), pred=pred)
    hvs = np.zeros((K, D), np.float64)
    for hv, l in zip(Xtr, ytr): hvs[l] += hv
    best_v, best_h = -1., hvs.copy()
    for _ in range(epochs):
        for hv, l in zip(Xtr, ytr):
            p = int(np.argmax(hvs @ hv))
            if p != l: hvs[l] += hv; hvs[p] -= hv
        n = np.linalg.norm(hvs, axis=1, keepdims=True) + 1e-8
        va = accuracy(yv, np.argmax(Xv @ (hvs / n).T, 1))
        if va > best_v: best_v, best_h = va, hvs.copy()
    for c in range(K):
        n = np.linalg.norm(best_h[c])
        if n > 0: best_h[c] /= n
    pred = np.argmax(Xte @ best_h.T, 1)
    return dict(acc=accuracy(yte, pred), pred=pred)

# ---- baseline HDCU emulation: binary bundling limited by M-bit counters ----
M_BITS = 4
GROUP = 2 ** M_BITS - 2


def clip_bits(cnt, n, rng):
    thr = n // 2
    out = (cnt > thr).astype(np.uint8)
    ties = cnt == thr
    out[ties] = rng.randint(0, 2, size=int(ties.sum())).astype(np.uint8)
    return out


def bundle_hier(vec_iter, shape, rng, ideal=False):
    if ideal:
        cnt = np.zeros(shape, np.int32); n = 0
        for v in vec_iter: cnt += v; n += 1
        if n % 2 == 0: return clip_bits(cnt, n, rng)
        return (cnt > n // 2).astype(np.uint8)
    level = []
    cnt = np.zeros(shape, np.int32); n = 0
    def flush():
        nonlocal cnt, n
        if n == 0: return
        if n % 2:
            cnt += rng.randint(0, 2, size=shape); n += 1
        level.append(clip_bits(cnt, n, rng)); cnt = np.zeros(shape, np.int32); n = 0
    for v in vec_iter:
        cnt += v; n += 1
        if n == GROUP: flush()
    flush()
    while len(level) > 1:
        nxt = []
        for i in range(0, len(level), GROUP):
            grp = level[i:i + GROUP]; c = np.sum(grp, axis=0, dtype=np.int32); m = len(grp)
            if m % 2: c += rng.randint(0, 2, size=shape); m += 1
            nxt.append(clip_bits(c, m, rng))
        level = nxt
    return level[0]


def baseline_mode(idx_groups, y, sp, K, D, so, rng, ideal=False, nlvls=NLVLS, weights=WEIGHTS):
    """Baseline HDCU: XOR bind, M-bit-counter bundling (weights by repetition), class prototypes
    by bundling training HVs, Hamming search (argmin, first wins). No retraining."""
    N = idx_groups[0].shape[0]
    lbits = [((1 - make_level_vectors(nl, D, seed=42 + so + i * 7)) // 2).astype(np.uint8) for i, nl in enumerate(nlvls)]
    pbits = [((1 - np.random.RandomState(43 + so + i * 7).choice([-1, 1], size=(g.shape[1], D))) // 2).astype(np.uint8)
             for i, g in enumerate(idx_groups)]
    def stream():
        for i, (idx, w) in enumerate(zip(idx_groups, weights)):
            for f in range(idx.shape[1]):
                b = lbits[i][idx[:, f]] ^ pbits[i][f]
                for _ in range(w): yield b
    H = bundle_hier(stream(), (N, D), rng, ideal=ideal)
    tr = sp["tr"]
    protos = np.stack([bundle_hier((H[i] for i in tr[y[tr] == c]), (D,), rng, ideal=ideal) for c in range(K)])
    ham = np.array([[np.count_nonzero(H[i] ^ protos[c]) for c in range(K)] for i in sp["te"]])
    pred = np.argmin(ham, 1)
    return dict(acc=accuracy(y[sp["te"]], pred), pred=pred)


def train_onlinehd(X, y, sp, K, epochs=40, lr=0.035):
    """OnlineHD-style training (Hernandez-Cano et al., DATE 2021) on the non-binary float encoding:
    a single weighted pass h_y += lr (1 - cos(x, h_y)) x, then iterative passes updating only on
    mispredictions, h_y += lr (1 - cos_y) x, h_p -= lr (1 - cos_p) x; best validation epoch kept.
    A software HDC-algorithm reference (float, not a hardware mode)."""
    Xn = X / np.maximum(np.linalg.norm(X, axis=1, keepdims=True), 1e-12)
    Xtr, ytr, Xv, yv, Xte, yte = Xn[sp["tr"]], y[sp["tr"]], Xn[sp["va"]], y[sp["va"]], Xn[sp["te"]], y[sp["te"]]
    h = np.zeros((K, X.shape[1]))
    def cos(hm, x): return (hm @ x) / np.maximum(np.linalg.norm(hm, axis=1), 1e-12)
    for x, l in zip(Xtr, ytr):
        c = cos(h, x); h[l] += lr * (1 - c[l]) * x
    def vacc(hm): return accuracy(yv, np.argmax(Xv @ (hm / np.maximum(np.linalg.norm(hm, axis=1, keepdims=True), 1e-12)).T, 1))
    best_v, best_h = vacc(h), h.copy()
    for _ in range(epochs):
        for x, l in zip(Xtr, ytr):
            c = cos(h, x); p = int(np.argmax(c))
            if p != l: h[l] += lr * (1 - c[l]) * x; h[p] -= lr * (1 - c[p]) * x
        v = vacc(h)
        if v > best_v: best_v, best_h = v, h.copy()
    hn = best_h / np.maximum(np.linalg.norm(best_h, axis=1, keepdims=True), 1e-12)
    pred = np.argmax(Xte @ hn.T, 1)
    return dict(acc=accuracy(yte, pred), pred=pred, scores=Xte @ hn.T)


def extract_one(job):
    """Worker: (path, num_frames) -> (float groups, hardware groups) or None."""
    path, num_frames = job
    global NUM_FRAMES
    NUM_FRAMES = int(num_frames)
    fr = load_video(path)
    if fr is None: return None
    return extract_both(fr)
