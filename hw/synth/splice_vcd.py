"""splice_vcd.py -- remove $dumpoff gaps from a VCD so that only the dumped windows
remain, back to back.

tb_sw_flow -DDUMP_VCD +vcd_core=nov dumps only while the novelty core is busy, using
$dumpoff/$dumpon. Tools that compute average toggle rates over the file's time span
(Genus read_vcd -static) would otherwise divide by the idle gaps too and under-report the
core's power while it works. This keeps every value change, shifts time to close each
gap, and drops the X values a simulator writes at $dumpoff.

It also removes X/Z transients: the OpenRAM Verilog models drive dout to X for part of
every cycle (and the X propagates combinationally), whereas a real macro holds its last
output. Every X/Z bit is replaced by that signal's previous known bit (0 if none), and a
change that leaves the value unchanged is dropped, so X never counts as switching.

    python splice_vcd.py in.vcd out.vcd
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
offset = 0           # total time removed so far
off_at = None        # time of the pending $dumpoff (None = dumping)
last_out = None      # last timestamp written
skip_block = False   # inside a $dumpoff ... $end block
dumpon_block = False # inside a $dumpon ... $end block
in_header = True
pending_t = None     # timestamp read but not yet written (written only before a value change)
kept_time = 0
first_t = None
last_val = {}        # identifier -> last written value (full-width bit string)
width = {}           # identifier -> declared width

with open(src) as fi, open(dst, "w") as fo:
    for line in fi:
        if in_header:
            fo.write(line)
            pv = line.split()
            if len(pv) >= 5 and pv[0] == "$var":
                width.setdefault(pv[3], int(pv[2]))
            if line.startswith("$enddefinitions"):
                in_header = False
            continue
        s = line.strip()
        if not s:
            continue
        if skip_block:
            if s == "$end": skip_block = False
            continue
        if s.startswith("#"):
            t = int(s[1:])
            if first_t is None:                # start the spliced file at time 0
                first_t = t; offset = t
            elif off_at is not None:
                # first timestamp after a $dumpoff: close the gap
                offset += t - off_at; off_at = None
            pending_t = t - offset
            continue
        if s == "$dumpoff":
            off_at = pending_t + offset if pending_t is not None else 0
            skip_block = True
            continue
        if s in ("$dumpon", "$dumpvars", "$dumpall"):
            dumpon_block = True
            continue
        if s == "$end":
            dumpon_block = False
            continue
        # a value change: scalar "<v><id>" or vector "b<bits> <id>" / "r<real> <id>"
        if s[0] in "bB":
            bits, ident = s[1:].split()
            w = width.get(ident, len(bits))
            if len(bits) < w:                  # VCD left-extension: 0/x/z extend themselves, 1 extends with 0
                bits = (bits[0] if bits[0] in "0xXzZ" else "0") * (w - len(bits)) + bits
            if "x" in bits or "X" in bits or "z" in bits or "Z" in bits:
                prev = last_val.get(ident, "")
                prev = prev.rjust(len(bits), "0")
                bits = "".join(p if c in "xXzZ" else c for c, p in zip(bits, prev))
            if last_val.get(ident) == bits:
                continue
            last_val[ident] = bits
            line = f"b{bits} {ident}\n"
        elif s[0] in "01xXzZ":
            v, ident = s[0], s[1:]
            if v in "xXzZ":
                continue                       # hold the previous value
            if last_val.get(ident) == v:
                continue
            last_val[ident] = v
        if pending_t is not None and pending_t != last_out:
            fo.write(f"#{pending_t}\n"); last_out = pending_t
        pending_t = None if pending_t == last_out else pending_t
        fo.write(line if line.endswith("\n") else line + "\n")
    if last_out is not None:
        kept_time = last_out
print(f"{src} -> {dst}: {kept_time} time units kept (gaps and leading idle time removed)")
