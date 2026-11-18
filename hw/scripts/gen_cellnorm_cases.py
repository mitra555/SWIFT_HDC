import numpy as np
np.random.seed(13)
SCALE = 65536
NC, NB = 16, 8
N = NC*NB

def q(v):
    return int(np.clip(np.round(v*SCALE), -(2**31), 2**31-1))

def trunc_div(a,b):
    qq = abs(a)//abs(b)
    if (a<0) ^ (b<0): qq = -qq
    return qq

cases = []
# all zero
cases.append(np.zeros(N))
# one case where some cells are all-zero, others not
v = np.random.uniform(0,5,size=N)
v = v.reshape(NC,NB)
v[3,:] = 0.0
v[7,:] = 0.0
cases.append(v.flatten())
for _ in range(10):
    cases.append(np.random.uniform(0,5,size=N))

with open("cellnorm_cases.txt","w") as f:
    f.write(f"{len(cases)}\n")
    for vals in cases:
        qi = np.array([q(v) for v in vals], dtype=np.int64).reshape(NC,NB)
        out = np.zeros_like(qi)
        for c in range(NC):
            s = int(qi[c].sum())
            if s == 0:
                out[c] = 0
            else:
                out[c] = [trunc_div(int(x)<<16, s) for x in qi[c]]
        f.write(" ".join(str(int(x)) for x in qi.flatten()) + " " + " ".join(str(int(x)) for x in out.flatten()) + "\n")

print("wrote", len(cases), "cases")
