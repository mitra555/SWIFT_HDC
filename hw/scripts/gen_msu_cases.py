"""Random cases for meanstd_sums_unit: each line = T s1 s2 exp_mean exp_std."""
import random, math, sys

def trunc_div(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) ^ (b < 0) else q

def meanstd_sums(vals):
    """Golden for streaming mean/std (matches meanstd_sums_unit exactly)."""
    T = len(vals); s1 = sum(vals); s2 = sum(v * v for v in vals)
    m = trunc_div(s1, T)
    ssd = s2 - 2 * m * s1 + T * m * m          # exact sum (x - m)^2, >= 0
    var = trunc_div(ssd >> 16, T)
    std = math.isqrt(var << 16) if var > 0 else 0
    return m, std, s1, s2

if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 500
    random.seed(7)
    with open("msu_cases.txt", "w") as f:
        for c in range(n):
            T = random.choice([2, 3, 63]) if c % 3 else random.randint(2, 63)
            kind = c % 5
            if kind == 0:   xs = [random.randint(0, 65536) for _ in range(T)]            # HOG/HOF range [0,1]
            elif kind == 1: xs = [random.randint(0, 8) << 16 for _ in range(T)]          # |dx|,|dy| motion
            elif kind == 2: xs = [random.randint(-(1 << 20), 1 << 20) for _ in range(T)] # signed
            elif kind == 3: xs = [random.randint(0, 1 << 24) for _ in range(T)]          # large (256.0; var must fit 32 bits)
            else:           xs = [random.randint(0, 65536)] * T                           # constant -> std 0
            m, s, s1, s2 = meanstd_sums(xs)
            f.write(f"{T} {s1} {s2} {m} {s}\n")
    print("wrote", n, "cases")
