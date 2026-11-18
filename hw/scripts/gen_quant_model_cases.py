"""Random quantize_unit cases from the same formula hw_accuracy_eval.py uses (quant_hw):
idx = clamp(round_half_away((feat - fmin) * (nlvl-1) / span), 0, nlvl-1), Q16.16 integers.
Writes qcases.txt: feat fmin span nlvl expected_idx."""
import numpy as np
rng = np.random.default_rng(5)
with open("qcases.txt", "w") as f:
    for i in range(2000):
        nlvl = int(rng.choice([11, 21, 2, 255]))
        fmin = int(rng.integers(-65536, 65536)); span = int(rng.integers(1, 3 * 65536))
        feat = int(fmin + rng.integers(-span // 4, span + span // 4)) if i % 7 else fmin + (span * int(rng.integers(0, nlvl))) // (nlvl - 1)
        num = (feat - fmin) * (nlvl - 1); half = span >> 1
        adj = num + half if num >= 0 else num - half
        q = (1 if adj > 0 else -1 if adj < 0 else 0) * (abs(adj) // abs(span))
        f.write(f"{feat} {fmin} {span} {nlvl} {min(max(q, 0), nlvl - 1)}\n")
