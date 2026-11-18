import numpy as np
frames = np.load("synth_frames.npy")
FLOW_GRID=4; BLOCK_SEARCH=8; FRAME_SIZE=32
N_CELLS=FLOW_GRID*FLOW_GRID
CH=FRAME_SIZE//FLOW_GRID; CW=FRAME_SIZE//FLOW_GRID

def block_match_frame(prev,curr):
    prev_i=prev.astype(np.int16); curr_i=curr.astype(np.int16)
    dx_arr=np.zeros(N_CELLS,dtype=np.float32)
    dy_arr=np.zeros(N_CELLS,dtype=np.float32)
    cell=0
    for gy in range(FLOW_GRID):
        for gx in range(FLOW_GRID):
            y0=gy*CH; x0=gx*CW
            ref=curr_i[y0:y0+CH,x0:x0+CW]
            best_sad=10**9; best_dx=0; best_dy=0
            for dys in range(-BLOCK_SEARCH,BLOCK_SEARCH+1):
                py0=y0+dys
                if py0<0 or py0+CH>FRAME_SIZE: continue
                for dxs in range(-BLOCK_SEARCH,BLOCK_SEARCH+1):
                    px0=x0+dxs
                    if px0<0 or px0+CW>FRAME_SIZE: continue
                    sad=int(np.abs(ref-prev_i[py0:py0+CH,px0:px0+CW]).sum())
                    if sad<best_sad: best_sad=sad; best_dx=dxs; best_dy=dys
            dx_arr[cell]=abs(float(best_dx)); dy_arr[cell]=abs(float(best_dy)); cell+=1
    return dx_arr,dy_arr

for t in range(1,4):
    dx,dy = block_match_frame(frames[t-1], frames[t])
    print(f"pair {t}: dx={dx} dy={dy}")
