import numpy as np

np.random.seed(7)
SCALE = 65536
MAX_T = 64

cases = []
# fixed edge cases
cases.append(np.array([3.5], dtype=np.float64))
cases.append(np.array([1.0, -1.0], dtype=np.float64))
cases.append(np.array([0.0]*5, dtype=np.float64))
cases.append(np.full(63, 2.25))

# randomized cases
for _ in range(40):
    T = np.random.randint(1, MAX_T+1)
    vals = np.random.uniform(-50, 50, size=T)
    cases.append(vals)

with open("meanstd_cases.txt", "w") as f:
    f.write(f"{len(cases)}\n")
    for vals in cases:
        T = len(vals)
        q = np.round(vals*SCALE).astype(np.int64)
        # clip to int32 signed range just in case
        q = np.clip(q, -(2**31), 2**31-1)
        mean = q.astype(np.float64).sum() / T
        var  = ((q.astype(np.float64) - mean)**2).sum() / T
        # emulate RTL's fixed point mean/var truncation
        mean_i = int(np.trunc(mean))
        # variance computed same two-pass way but in "Q16.16 units squared then /T truncated"
        diffs = q.astype(np.int64) - mean_i
        diffsq_q16 = np.array([ (int(d)*int(d)) >> 16 for d in diffs ], dtype=np.int64)
        var_i = int(np.trunc(diffsq_q16.sum() / T))
        std_i = int(np.floor(np.sqrt(max(var_i,0) * (1<<16)))) if var_i >= 0 else 0
        f.write(f"{T} " + " ".join(str(int(x)) for x in q) + f" {mean_i} {std_i}\n")

print("wrote", len(cases), "cases")
