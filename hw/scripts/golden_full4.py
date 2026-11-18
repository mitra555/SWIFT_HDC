import numpy as np, math

NUM_FRAMES=4; FRAME_SIZE=32; FLOW_GRID=4; N_ANGLE_BINS=8; BLOCK_SEARCH=8
N_CELLS=FLOW_GRID*FLOW_GRID; HOF_DIM=N_CELLS*N_ANGLE_BINS; HOG_DIM=324
T_PAIRS=NUM_FRAMES-1
SCALE=65536
BASE_LEN = HOF_DIM+HOG_DIM+HOF_DIM+HOG_DIM

frames = np.load("synth_frames.npy").astype(np.int32)

def trunc_div(a,b):
    q = abs(int(a))//abs(int(b))
    if (a<0)^(b<0): q=-q
    return q

def block_match_frame(prev,curr):
    CH=FRAME_SIZE//FLOW_GRID; CW=FRAME_SIZE//FLOW_GRID
    dx_arr=np.zeros(N_CELLS,dtype=np.int64); dy_arr=np.zeros(N_CELLS,dtype=np.int64)
    cell=0
    for gy in range(FLOW_GRID):
        for gx in range(FLOW_GRID):
            y0=gy*CH; x0=gx*CW
            ref=curr[y0:y0+CH,x0:x0+CW]
            best_sad=10**9; best_dx=0; best_dy=0
            for dys in range(-BLOCK_SEARCH,BLOCK_SEARCH+1):
                py0=y0+dys
                if py0<0 or py0+CH>FRAME_SIZE: continue
                for dxs in range(-BLOCK_SEARCH,BLOCK_SEARCH+1):
                    px0=x0+dxs
                    if px0<0 or px0+CW>FRAME_SIZE: continue
                    sad=int(np.abs(ref-prev[py0:py0+CH,px0:px0+CW]).sum())
                    if sad<best_sad: best_sad=sad; best_dx=dxs; best_dy=dys
            dx_arr[cell]=abs(best_dx); dy_arr[cell]=abs(best_dy); cell+=1
    return dx_arr, dy_arr

def angle_bin8(dx,dy):
    if dx>0 and dy>=0: return 0 if dy<dx else 1
    elif dx<=0 and dy>0: return 2 if (-dx)<dy else 3
    elif dx<0 and dy<=0: return 4 if (-dy)<(-dx) else 5
    else: return 6 if dx<(-dy) else 7

def isqrt(n): return math.isqrt(int(n))

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

dx_c_buf=np.zeros((T_PAIRS,N_CELLS),dtype=np.int64)
dy_c_buf=np.zeros((T_PAIRS,N_CELLS),dtype=np.int64)
gdx_buf=np.zeros(T_PAIRS,dtype=np.int64)
gdy_buf=np.zeros(T_PAIRS,dtype=np.int64)
hof_seq_buf=np.zeros((T_PAIRS,HOF_DIM),dtype=np.int64)
hof_accum=np.zeros(HOF_DIM,dtype=np.int64)

for t in range(1,NUM_FRAMES):
    dx,dy = block_match_frame(frames[t-1], frames[t])
    dx_c_buf[t-1]=dx*SCALE
    dy_c_buf[t-1]=dy*SCALE
    gdx_buf[t-1]=int(dx.sum())*4096
    gdy_buf[t-1]=int(dy.sum())*4096

    raw_hist=np.zeros(HOF_DIM,dtype=np.int64)
    for cell in range(N_CELLS):
        dxv=int(dx[cell]); dyv=int(dy[cell])
        magsq=dxv*dxv+dyv*dyv
        if magsq>=1:
            mag_fixed=isqrt(magsq*65536)
            b=angle_bin8(dxv,dyv)
            raw_hist[cell*N_ANGLE_BINS+b]+=mag_fixed
            hof_accum[cell*N_ANGLE_BINS+b]+=mag_fixed
    for cell in range(N_CELLS):
        seg=raw_hist[cell*N_ANGLE_BINS:(cell+1)*N_ANGLE_BINS]
        s=int(seg.sum())
        if s>0:
            for b in range(N_ANGLE_BINS):
                hof_seq_buf[t-1,cell*N_ANGLE_BINS+b]=trunc_div(int(seg[b])<<16, s)

np.save("golden4_dx_c_buf.npy", dx_c_buf)
np.save("golden4_dy_c_buf.npy", dy_c_buf)
np.save("golden4_hof_accum.npy", hof_accum)
np.save("golden4_hof_seq_buf.npy", hof_seq_buf)
np.save("golden4_gdx_buf.npy", gdx_buf)
np.save("golden4_gdy_buf.npy", gdy_buf)
print("saved intermediate golden4 arrays; run this AFTER rtl_dump.txt exists to also finalize with real hog_seq")
