"""Random cases for tb_hvgen: c C q f seedL seedP step expL expP (hex), from scripts/hvgen.py."""
import os, sys, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hvgen as G
random.seed(7)
out = []
for t in range(600):
    C = random.choice([157, 157, 157, 64, 37, 16])
    D = 32 * C
    c = random.randrange(C); q = random.randrange(0, 64); f = random.randrange(0, min(D, 904 if C == 157 else D))
    sl = random.getrandbits(32); sp = random.getrandbits(32)
    st = random.choice([G.step_for(n) for n in (5, 11, 21, 64)] + [random.getrandbits(16)])
    L = G.word(G.level_bits(sl, st, q, D), c); P = G.word(G.pos_bits(sp, f, D), c)
    out.append(f"{c:x} {C:x} {q:x} {f:x} {sl:x} {sp:x} {st:x} {L:x} {P:x}")
open("hvgen_cases.txt", "w").write("\n".join(out) + "\n")
print(len(out), "cases")
