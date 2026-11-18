import sys,collections
vcd=sys.argv[1]; sig={'D1':'w0',  'C1':'w1',':1':'wweb',';+':'a0','9+':'a1',']+':'b1','I':'busy','9,':'op'}
val={k:1 for k in sig}; val['9,']=0; val['I']=0
acc=collections.defaultdict(collections.Counter); tp=None
f=open(vcd)
for l in f:
    if l.startswith('$enddefinitions'): break
for l in f:
    ch=l[0]
    if ch=='#':
        t=int(l[1:])
        if tp is not None and t>tp:
            n=(t-tp)/10000; op=val['9,'] if val['I'] else 'idle'; c=acc[op]; c['cyc']+=n
            for k,nm in sig.items():
                if nm in ('busy','op'): continue
                if val[k]==0: c[nm+'_low']+=n
        tp=t; continue
    if ch=='b':
        v,c=l[1:].split()
        if c in sig: val[c]=int(v.replace('x','0').replace('z','0'),2)
    elif ch in '01xz':
        c=l[1:].strip()
        if c in sig: val[c]=1 if ch=='1' else 0
for op,c in sorted(acc.items(),key=lambda x:str(x[0])): print(op,{k:round(v) for k,v in c.items()})
