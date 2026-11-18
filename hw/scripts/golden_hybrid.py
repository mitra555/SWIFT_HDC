import numpy as np

N_CELLS=16; N_ANGLE_BINS=8; HOF_DIM=128; HOG_DIM=324
T_PAIRS=3
BASE_LEN = HOF_DIM+HOG_DIM+HOF_DIM+HOG_DIM

def trunc_div(a,b):
    q = abs(int(a))//abs(int(b))
    if (a<0)^(b<0): q=-q
    return q

def meanstd(samples):
    T=len(samples)
    s=int(np.array(samples,dtype=np.int64).sum())
    mean_i=trunc_div(s,T)
    diffs=[int(x)-mean_i for x in samples]
    diffsq_q16=[(d*d)>>16 for d in diffs]
    sumsq=sum(diffsq_q16)
    var_i=trunc_div(sumsq,T)
    std_i=int(np.floor(np.sqrt(max(var_i,0)*(1<<16)))) if var_i>=0 else 0
    return mean_i, std_i

def vecnorm(vec):
    vec=np.asarray(vec,dtype=np.int64)
    sq=[(int(v)*int(v))>>16 for v in vec]
    sumsq=sum(sq)
    norm_i=int(np.floor(np.sqrt(max(sumsq,0)*(1<<16))))
    if norm_i==0: return vec.copy()
    return np.array([trunc_div(int(v)<<16, norm_i) for v in vec], dtype=np.int64)

def cellnorm(hof_accum):
    out=np.zeros(HOF_DIM,dtype=np.int64)
    for c in range(N_CELLS):
        seg=hof_accum[c*N_ANGLE_BINS:(c+1)*N_ANGLE_BINS]
        s=int(seg.sum())
        if s==0: continue
        for b in range(N_ANGLE_BINS):
            out[c*N_ANGLE_BINS+b]=trunc_div(int(seg[b])<<16, s)
    return out

dx_c_buf = np.load("golden4_dx_c_buf.npy")
dy_c_buf = np.load("golden4_dy_c_buf.npy")
hof_accum = np.load("golden4_hof_accum.npy")
hof_seq_buf = np.load("golden4_hof_seq_buf.npy")

# fake_hog's deterministic output: hog_out_packed[gi] = (gi+1)<<10, same every frame-pair
hog_lane = np.array([((gi+1) << 10) & 0xFFFFFFFF for gi in range(HOG_DIM)], dtype=np.int64)
# sign-extend as RTL would interpret it ($signed on a 32-bit reg)
hog_lane_signed = np.where(hog_lane >= 2**31, hog_lane - 2**32, hog_lane)
hog_seq = np.tile(hog_lane_signed, (T_PAIRS, 1))

hof_global = cellnorm(hof_accum)

hog_mean = np.zeros(HOG_DIM, dtype=np.int64); hog_std = np.zeros(HOG_DIM, dtype=np.int64)
for lane in range(HOG_DIM):
    m, s = meanstd(hog_seq[:, lane]); hog_mean[lane] = m; hog_std[lane] = s

hof_std = np.zeros(HOF_DIM, dtype=np.int64)
for lane in range(HOF_DIM):
    _, s = meanstd(hof_seq_buf[:, lane]); hof_std[lane] = s

dx_mean = np.zeros(N_CELLS, dtype=np.int64); dx_std = np.zeros(N_CELLS, dtype=np.int64)
dy_mean = np.zeros(N_CELLS, dtype=np.int64); dy_std = np.zeros(N_CELLS, dtype=np.int64)
for cell in range(N_CELLS):
    m, s = meanstd(dx_c_buf[:, cell]); dx_mean[cell] = m; dx_std[cell] = s
    m, s = meanstd(dy_c_buf[:, cell]); dy_mean[cell] = m; dy_std[cell] = s

base_vec = np.concatenate([hof_global, hog_mean, hof_std, hog_std])
dx_vec = np.concatenate([dx_mean, dx_std])
dy_vec = np.concatenate([dy_mean, dy_std])

base_norm = vecnorm(base_vec)
dx_norm = vecnorm(dx_vec)
dy_norm = vecnorm(dy_vec)

with open("golden_hybrid_output.txt", "w") as f:
    f.write(" ".join(str(int(x)) for x in base_norm) + "\n")
    f.write(" ".join(str(int(x)) for x in dx_norm) + "\n")
    f.write(" ".join(str(int(x)) for x in dy_norm) + "\n")

print("dx_norm:", dx_norm.tolist())
print("dy_norm:", dy_norm.tolist())
print("base_norm[:8]:", base_norm[:8].tolist())
print("done")
