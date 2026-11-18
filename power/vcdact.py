"""vcdact.py VCD SCOPE NETLIST OUT_PREFIX [CLK_PS]
Maps RTL-level VCD activity onto a flattened Genus netlist:
  - flip-flop Q pins (by register name), SRAM dout pins, top-level input ports -> OUT.tcl
    (set_power_activity, transitions per clock cycle)
  - SRAM macro port-access counts (cycles with csb low) -> OUT.json
"""
import sys, re, json, collections

vcd, scope, netlist, out = sys.argv[1:5]
CLK = int(sys.argv[5]) if len(sys.argv) > 5 else 10000
import os
UNANN = float(os.environ.get('UNANN', '0.001'))
WT0 = int(os.environ.get('T0', '-1')); WT1 = int(os.environ.get('T1', '-1'))
scope_parts = scope.split('/')
norm = lambda s: re.sub(r'[\\._/\s]', '', s)

# ---------------- netlist
flops = collections.defaultdict(dict)   # basekey -> {idx tuple: inst}
macros = {}                              # key -> (inst, cell)
txt = open(netlist).read()
TOP = sys.argv[6] if len(sys.argv) > 6 else None
mods = {}
for mm in re.finditer(r'^module\s+(\\\S+|[^\s(]+)(.*?)^endmodule', txt, re.M | re.S):
    mods[mm.group(1).lstrip('\\')] = mm.group(2)
if TOP is None: TOP = list(mods)[-1]
def walk(mod, prefix):
    for m in re.finditer(r'^\s*(\\\S+|[A-Za-z_]\w*)\s+(\\\S+|[^\s(]+)\s*\(', mods[mod], re.M):
        cell, inst = m.group(1).lstrip('\\'), m.group(2).lstrip('\\')
        full = prefix + inst
        if cell in mods:
            walk(cell, full + '/'); continue
        if cell.startswith('sky130_sram'):
            macros[norm(full)] = (full, cell); continue
        if not re.match(r'sky130_fd_sc_hd__(df|edf|sdf|dl[xr]|dfb|sedf)', cell): continue
        mx = re.match(r'(.*?)_reg((?:\[\d+\])*)$', inst)
        if not mx: continue
        idx = tuple(int(x) for x in re.findall(r'\[(\d+)\]', mx.group(2)))
        flops[norm(prefix + mx.group(1))][idx] = full
walk(TOP, '')
nflops = sum(len(v) for v in flops.values())

# ---------------- VCD header
ids = collections.defaultdict(list)   # id -> [(relpath tuple, name, msb, lsb, width)]
stack = []; tscale = 1
f = open(vcd, 'r', buffering=1 << 22)
hdr = []
for line in f:
    if '$timescale' in line:
        t = line + ('' if '$end' in line else next(f))
        mm = re.search(r'(\d+)\s*(fs|ps|ns|us)', t)
        tscale = int(mm.group(1)) * {'fs': 1e-3, 'ps': 1, 'ns': 1e3, 'us': 1e6}[mm.group(2)]
    elif line.startswith('$scope') or line.lstrip().startswith('$scope'):
        p = line.split(); stack.append(p[2])
    elif line.lstrip().startswith('$upscope'):
        stack.pop()
    elif line.lstrip().startswith('$var'):
        p = line.split()
        w, code, name = int(p[2]), p[3], p[4]
        rng = p[5] if len(p) > 6 and p[5].startswith('[') else ''
        if stack[:len(scope_parts)] != scope_parts: continue
        rel = tuple(stack[len(scope_parts):])
        if rng:
            a = [int(x) for x in re.findall(r'-?\d+', rng)]
            msb, lsb = (a[0], a[1]) if len(a) == 2 else (a[0], a[0])
        else:
            msb, lsb = (w - 1, 0) if w > 1 else (None, None)
        ids[code].append((rel, name, msb, lsb, w))
    elif line.startswith('$enddefinitions'):
        break

W = {c: v[0][4] for c, v in ids.items()}
tog = {c: [0] * W[c] for c in ids}
val = {c: 0 for c in ids}
lowt = {c: 0 for c in ids if W[c] == 1}
last = {c: 0 for c in lowt}
t0 = None; t = 0
for line in f:
    ch = line[0]
    if ch == '#':
        t = int(line[1:]);
        if t0 is None: t0 = t
        continue
    if ch == 'b' or ch == 'B':
        v, c = line[1:].split()
        if c not in tog: continue
        nv = int(v.replace('x', '0').replace('z', '0').replace('X', '0').replace('Z', '0'), 2)
    elif ch in '01xzXZ':
        c = line[1:].strip()
        if c not in tog: continue
        nv = 1 if ch == '1' else 0
    else:
        continue
    if c in lowt:
        if val[c] == 0: lowt[c] += t - last[c]
        last[c] = t
    d = val[c] ^ nv
    if WT0 >= 0 and not (WT0 <= t < WT1): d = 0
    if d:
        tg = tog[c]
        while d:
            b = d & -d; tg[b.bit_length() - 1] += 1; d ^= b
    val[c] = nv
tend = t
for c in lowt:
    if val[c] == 0: lowt[c] += tend - last[c]
span_ps = ((WT1 - WT0) if WT0 >= 0 else (tend - (t0 or 0))) * tscale
cycles = span_ps / CLK

# ---------------- map
act = collections.defaultdict(list)   # activity -> pins
nflop_hit = 0; seen = set()
sram_sig = collections.defaultdict(dict)
inports = []
for c, lst in ids.items():
    for rel, name, msb, lsb, w in lst:
        pre = tuple(int(x) for x in re.findall(r'\[(\d+)\]', name)); name = re.sub(r'\[\d+\]', '', name)
        key = norm('/'.join(rel + (name,)))
        bits = list(range(min(msb, lsb), max(msb, lsb) + 1)) if msb is not None else [None]
        if len(rel) and norm('/'.join(rel)) in macros and name in ('csb0', 'web0', 'csb1', 'dout0', 'dout1'):
            inst = macros[norm('/'.join(rel))][0]
            sram_sig[inst][name] = c
            if name.startswith('dout'):
                for k, b in enumerate(bits):
                    a = tog[c][k] / cycles
                    act[round(a, 4)].append(f'{inst}/{name}[{b}]')
            continue
        if not rel:
            for k, b in enumerate(bits):
                inports.append((name if b is None else f'{name}[{b}]', tog[c][k] / cycles))
        if key in flops:
            fl = flops[key]
            dims = max((len(i) for i in fl), default=0)
            for k, b in enumerate(bits):
                if pre:
                    idx = pre + ((b,) if (b is not None and dims > len(pre)) else ())
                elif dims == 0: idx = ()
                elif dims == 1: idx = (b if b is not None else 0,)
                else:
                    inner = max(i[-1] for i in fl if len(i) == 2) + 1
                    idx = (b // inner, b % inner)
                inst = fl.get(idx)
                if inst and inst not in seen:
                    seen.add(inst); nflop_hit += 1
                    act[round(tog[c][k] / cycles, 4)].append(f'{inst}/Q')

def esc(p):
    inst, pin = p.rsplit('/', 1)
    inst = inst.replace('[', '\\[').replace(']', '\\]')
    if pin.endswith('/Q') or pin == 'Q': return inst + '/' + pin
    return inst + '/' + pin
with open(out + '.tcl', 'w') as o:
    for a, pins in act.items():
        for i in range(0, len(pins), 2000):
            o.write('set_power_activity -activity %g -duty 0.5 -pins [get_pins -quiet {%s}]\n' % (a, ' '.join(esc(p) for p in pins[i:i + 2000])))
    rest = [inst + '/Q' for fl in flops.values() for inst in fl.values() if inst not in seen]
    for i in range(0, len(rest), 2000):
        o.write('set_power_activity -activity %g -duty 0.5 -pins [get_pins -quiet {%s}]\n' % (UNANN, ' '.join(esc(p) for p in rest[i:i + 2000])))
    for p, a in inports:
        o.write('catch {set_power_activity -activity %g -duty 0.5 -input_ports [get_ports -quiet {%s}]}\n' % (a, p))

sram = {}
for key, (inst, cell) in macros.items():
    s = sram_sig.get(inst, {})
    p0 = (lowt[s['csb0']] * tscale / CLK) if 'csb0' in s else None
    p1 = (lowt[s['csb1']] * tscale / CLK) if 'csb1' in s else None
    sram[inst] = dict(cell=cell, port0_cycles=p0, port1_cycles=p1)
miss = collections.Counter()
for k, fl in flops.items():
    for idx, inst in fl.items():
        if inst not in seen: miss[re.sub(r'\[\d+\]', '[]', inst)] += 1
open(out + '.miss', 'w').write('\n'.join(f'{n} {k}' for k, n in miss.most_common()))
json.dump(dict(cycles=cycles, span_ps=span_ps, flops=nflops, flops_annotated=nflop_hit,
               macros=len(macros), macros_found=sum(1 for v in sram.values() if v['port0_cycles'] is not None),
               sram=sram), open(out + '.json', 'w'), indent=1)
print(f'cycles={cycles:.0f} flops={nflops} annotated={nflop_hit} ({100*nflop_hit/max(1,nflops):.1f}%) macros={len(macros)} found={sum(1 for v in sram.values() if v["port0_cycles"] is not None)}')
