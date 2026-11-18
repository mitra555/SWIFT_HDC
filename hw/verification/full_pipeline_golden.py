import numpy as np

SCALE = 65536
FRAME_SIZE = 32
NUM_FRAMES = 4
NPAIRS = NUM_FRAMES - 1     # 3
FLOW_GRID = 4
N_CELLS = FLOW_GRID*FLOW_GRID  # 16
BLOCK_SEARCH = 8
CH = FRAME_SIZE // FLOW_GRID
CW = FRAME_SIZE // FLOW_GRID
N_ANGLE_BINS = 8
AC_LAGS = 16

def trunc_div(a, b):
    a = int(a); b = int(b)
    q = abs(a)//abs(b)
    if (a < 0) ^ (b < 0):
        q = -q
    return q

# ---------------- Stage 1: block match (exact RTL nested-loop order) ----------------
def block_match_frame(prev, curr):
    prev_i = prev.astype(np.int64); curr_i = curr.astype(np.int64)
    dx_arr = np.zeros(N_CELLS, dtype=np.int64)
    dy_arr = np.zeros(N_CELLS, dtype=np.int64)
    cell = 0
    for gy in range(FLOW_GRID):
        for gx in range(FLOW_GRID):
            y0 = gy*CH; x0 = gx*CW
            ref = curr_i[y0:y0+CH, x0:x0+CW]
            best_sad = None; best_dx = 0; best_dy = 0
            for dys in range(-BLOCK_SEARCH, BLOCK_SEARCH+1):
                py0 = y0+dys
                if py0 < 0 or py0+CH > FRAME_SIZE: continue
                for dxs in range(-BLOCK_SEARCH, BLOCK_SEARCH+1):
                    px0 = x0+dxs
                    if px0 < 0 or px0+CW > FRAME_SIZE: continue
                    sad = int(np.abs(ref - prev_i[py0:py0+CH, px0:px0+CW]).sum())
                    if best_sad is None or sad < best_sad:
                        best_sad = sad; best_dx = dxs; best_dy = dys
            dx_arr[cell] = abs(best_dx); dy_arr[cell] = abs(best_dy)
            cell += 1
    return dx_arr, dy_arr

# ---------------- Stage 3: angle_bin8 (exact RTL logic, dx,dy>=0 case) --------------
def angle_bin(dx, dy):
    if dx > 0:
        return 0 if dy < dx else 1
    else:  # dx == 0
        return 2 if dy > 0 else 7  # bin 7 irrelevant, gated by do_accum

def hof_for_pair(dx_cell, dy_cell):
    """Returns (raw_hist[128] int, norm_hist[128] Q16.16) for one frame pair."""
    hist = np.zeros(N_CELLS*N_ANGLE_BINS, dtype=np.int64)
    for c in range(N_CELLS):
        dx = int(dx_cell[c]); dy = int(dy_cell[c])
        magsq = dx*dx + dy*dy
        if magsq >= 1:
            mag = int(np.floor(np.sqrt(magsq * 65536.0)))  # Q8.8-ish, matches isqrt_value=<<16
            b = angle_bin(dx, dy)
            hist[c*N_ANGLE_BINS + b] += mag
    norm = np.zeros(N_CELLS*N_ANGLE_BINS, dtype=np.int64)
    for c in range(N_CELLS):
        s = int(hist[c*N_ANGLE_BINS:(c+1)*N_ANGLE_BINS].sum())
        if s != 0:
            for b in range(N_ANGLE_BINS):
                norm[c*N_ANGLE_BINS+b] = trunc_div(int(hist[c*N_ANGLE_BINS+b]) << 16, s)
    return hist, norm

# ---------------- meanstd (exact RTL formula) ----------------------------------
def meanstd(vals):
    """Streaming mean/std, exactly as meanstd_sums_unit computes it from running sums:
    mean = trunc(S1/T); SSD = S2 - 2*mean*S1 + T*mean^2 (exact sum of squared deviations);
    var = trunc((SSD >> 16) / T); std = floor(sqrt(var << 16))."""
    import math
    T = len(vals)
    q = [int(v) for v in vals]
    s1 = sum(q); s2 = sum(v * v for v in q)
    mean_i = trunc_div(s1, T)
    ssd = s2 - 2 * mean_i * s1 + T * mean_i * mean_i
    var_i = trunc_div(ssd >> 16, T)
    std_i = math.isqrt(var_i << 16) if var_i > 0 else 0
    return mean_i, std_i

# ---------------- vecnorm (exact RTL formula) -----------------------------------
def vecnorm(qi):
    qi = np.array(qi, dtype=np.int64)
    sqterms = (qi*qi) >> 16
    sumsq = int(sqterms.sum())
    norm_i = int(np.floor(np.sqrt(max(sumsq,0)*65536.0)))
    if norm_i == 0:
        return qi.copy()
    return np.array([trunc_div(int(x) << 16, norm_i) for x in qi], dtype=np.int64)

# ---------------- cellnorm (exact RTL formula) ----------------------------------
def cellnorm(qi, nc, nb):
    qi = np.array(qi, dtype=np.int64).reshape(nc, nb)
    out = np.zeros_like(qi)
    for c in range(nc):
        s = int(qi[c].sum())
        if s != 0:
            out[c] = [trunc_div(int(x) << 16, s) for x in qi[c]]
    return out.flatten()

# ---------------- autocorr (exact RTL formula, lags 1..16) ---------------------
def autocorr(x, n_lags=AC_LAGS):
    T = len(x)
    x = np.array(x, dtype=np.int64)
    mean_i = trunc_div(int(x.sum()), T)
    xc = x - mean_i
    v = int((xc.astype(object)*xc.astype(object)).sum())
    result = np.zeros(n_lags, dtype=np.int64)
    if v == 0:
        return result
    for k in range(1, n_lags+1):
        if T - k <= 0:
            result[k-1] = 0
            continue
        dot = int((xc[:T-k].astype(object) * xc[k:].astype(object)).sum())
        result[k-1] = trunc_div(dot << 16, v)
    return result

# ---------------- percentile (exact RTL / numpy linear interp) -----------------
def percentile5(x):
    T = len(x)
    xs = np.sort(np.array(x, dtype=np.int64))
    ps = [10,25,50,75,90]
    out = np.zeros(5, dtype=np.int64)
    for i,p in enumerate(ps):
        rank_num = p*(T-1)
        lo = rank_num // 100
        rem = rank_num % 100
        frac_q16 = trunc_div(rem << 16, 100)
        lo_val = xs[lo]; hi_val = xs[min(lo+1, T-1)]
        diff = int(hi_val) - int(lo_val)
        interp = (diff * frac_q16) >> 16
        out[i] = int(lo_val) + interp
    return out


def main():
    frames = np.load("synth_frames.npy")
    assert frames.shape[0] == NUM_FRAMES

    dx_c_buf = np.zeros((NPAIRS, N_CELLS), dtype=np.int64)  # Q16.16 (abs dx << 16)
    dy_c_buf = np.zeros((NPAIRS, N_CELLS), dtype=np.int64)
    gdx_buf = np.zeros(NPAIRS, dtype=np.int64)
    gdy_buf = np.zeros(NPAIRS, dtype=np.int64)
    hof_accum = np.zeros(N_CELLS*N_ANGLE_BINS, dtype=np.int64)
    hof_seq_buf = np.zeros((NPAIRS, N_CELLS*N_ANGLE_BINS), dtype=np.int64)

    for t in range(NPAIRS):
        dx_cell, dy_cell = block_match_frame(frames[t], frames[t+1])
        dx_c_buf[t] = dx_cell << 16
        dy_c_buf[t] = dy_cell << 16
        cell_dx_sum = int(dx_cell.sum())
        cell_dy_sum = int(dy_cell.sum())
        # gdx_buf[t] = (cell_dx_sum <<< 16) >>> 4  (arithmetic right shift by 4 = /16)
        gdx_buf[t] = (cell_dx_sum << 16) >> 4
        gdy_buf[t] = (cell_dy_sum << 16) >> 4
        raw, norm = hof_for_pair(dx_cell, dy_cell)
        hof_accum += raw
        hof_seq_buf[t] = norm

    # dx_norm / dy_norm: per-cell mean,std of dx_c_buf/dy_c_buf across T pairs -> vecnorm(32)
    dx_raw = np.zeros(32, dtype=np.int64)
    dy_raw = np.zeros(32, dtype=np.int64)
    for lane in range(N_CELLS):
        m, s = meanstd(dx_c_buf[:, lane])
        dx_raw[lane] = m; dx_raw[16+lane] = s
        m, s = meanstd(dy_c_buf[:, lane])
        dy_raw[lane] = m; dy_raw[16+lane] = s
    dx_norm = vecnorm(dx_raw)
    dy_norm = vecnorm(dy_raw)

    # acd_norm = vecnorm(autocorr(gdy_buf)), acx_norm = vecnorm(autocorr(gdx_buf))
    acd_raw = autocorr(gdy_buf)
    acx_raw = autocorr(gdx_buf)
    acd_norm = vecnorm(acd_raw)
    acx_norm = vecnorm(acx_raw)

    # pct_norm = vecnorm(concat(percentile(gdx_buf), percentile(gdy_buf)))
    pct_raw = np.concatenate([percentile5(gdx_buf), percentile5(gdy_buf)])
    pct_norm = vecnorm(pct_raw)

    # base_raw[0:127] = cellnorm(hof_accum, 16, 8)   (hof_global portion of base_norm)
    hof_global_cn = cellnorm(hof_accum, N_CELLS, N_ANGLE_BINS)

    # base_raw[452:579] = hof_std per lane (std of hof_seq_buf across T pairs)
    hof_std = np.zeros(N_CELLS*N_ANGLE_BINS, dtype=np.int64)
    for lane in range(N_CELLS*N_ANGLE_BINS):
        _, s = meanstd(hof_seq_buf[:, lane])
        hof_std[lane] = s

    np.savez("golden_derivable.npz",
             dx_norm=dx_norm, dy_norm=dy_norm,
             acd_norm=acd_norm, acx_norm=acx_norm, pct_norm=pct_norm,
             hof_global_cn=hof_global_cn, hof_std=hof_std,
             gdx_buf=gdx_buf, gdy_buf=gdy_buf,
             dx_raw=dx_raw, dy_raw=dy_raw, acd_raw=acd_raw, acx_raw=acx_raw, pct_raw=pct_raw)

    print("dx_norm", dx_norm)
    print("dy_norm", dy_norm)
    print("acd_norm", acd_norm)
    print("acx_norm", acx_norm)
    print("pct_norm", pct_norm)
    print("hof_global_cn (base_raw[0:127])", hof_global_cn)
    print("hof_std (base_raw[452:579])", hof_std)
    print("wrote golden_derivable.npz")

if __name__ == "__main__":
    main()
