import numpy as np
np.random.seed(11)
SCALE = 65536
N = 32

def q(v):
    return int(np.clip(np.round(v*SCALE), -(2**31), 2**31-1))

def _trunc_div(a,b):
    qq = abs(a)//abs(b)
    if (a<0) ^ (b<0): qq = -qq
    return qq

cases = []
cases.append(np.zeros(N))                      # all-zero edge case
cases.append(np.random.uniform(-1,1,size=N))
for _ in range(20):
    cases.append(np.random.uniform(-5,5,size=N))

with open("vecnorm_cases.txt","w") as f:
    f.write(f"{len(cases)} {N}\n")
    for vals in cases:
        qi = np.array([q(v) for v in vals], dtype=np.int64)
        # emulate RTL fixed point: sumsq_q16 = sum((qi*qi)>>16)
        sqterms = (qi*qi) >> 16
        sumsq = int(sqterms.sum())
        norm_i = int(np.floor(np.sqrt(max(sumsq,0) * (1<<16))))
        if norm_i == 0:
            out = qi.copy()
        else:
            out = np.array([ _trunc_div(int(x)<<16, norm_i) for x in qi ])
        f.write(" ".join(str(int(x)) for x in qi) + " " + " ".join(str(int(x)) for x in out) + "\n")

print("wrote", len(cases), "cases")
