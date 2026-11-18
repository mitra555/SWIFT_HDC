"""Summarize Yosys generic-gate 'stat' output as NAND2-equivalent gate counts (GE).

Weights are typical standard-cell area ratios relative to NAND2 (≈ a 65 nm library):
inverter 0.67, NAND2/NOR2 1.0, AND2/OR2 1.33, XOR2/XNOR2 2.33, MUX2 2.33, D flip-flop
(with enable / async reset variants) 5.0-6.0. This is an early, library-independent
estimate; use Genus with the real library for paper numbers.
usage: yosys_ge.py <yosys.log> [...]
"""
import re, sys

W = {"$_NOT_": 0.67, "$_NAND_": 1.0, "$_NOR_": 1.0, "$_AND_": 1.33, "$_OR_": 1.33,
     "$_ANDNOT_": 1.33, "$_ORNOT_": 1.33, "$_XOR_": 2.33, "$_XNOR_": 2.33, "$_MUX_": 2.33}
def ff_weight(name):
    w = 4.67                                   # plain DFF
    if "E" in name.split("_")[1][3:]: w += 0.67  # enable
    if re.search(r"_(PN|PP)[01]", name) or "SDFF" in name: w += 0.67   # set/reset
    return w

for path in sys.argv[1:]:
    txt = open(path).read()
    blk = txt[txt.rfind("Number of cells"):]
    # Accept both yosys stat orderings: "name count" (<=0.33) and "count name" (>=0.6x).
    cells = {}
    for line in blk.splitlines():
        m = re.match(r"\s+(\S+)\s+(\d+)\s*$", line)      # name then count
        if m:
            cells[m.group(1)] = int(m.group(2)); continue
        m = re.match(r"\s+(\d+)\s+(\S+)\s*$", line)      # count then name
        if m:
            cells[m.group(2)] = int(m.group(1))
    logic = sum(n * W[c] for c, n in cells.items() if c in W)
    ffs = {c: n for c, n in cells.items() if "DFF" in c}
    ff_ge = sum(n * ff_weight(c) for c, n in ffs.items())
    other = {c: n for c, n in cells.items() if c not in W and c not in ffs}
    print(f"{path}: comb {logic:,.0f} GE + {sum(ffs.values())} flops {ff_ge:,.0f} GE = {logic + ff_ge:,.0f} GE"
          + (f"   (black boxes / memories: {other})" if other else ""))
