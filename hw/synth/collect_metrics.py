"""collect_metrics.py -- turn Genus report folders into one CSV + Markdown table.

    python synth/collect_metrics.py synth/out            # scans synth/out/<run>/
    python synth/collect_metrics.py synth/out -o metrics  # writes metrics.csv / metrics.md

Each run folder needs qor.rpt, gates.rpt and power.rpt (genus_synth.tcl writes them) and
optionally run_info.txt (TOP / LANE / CLK_NS / VCD, written by run_genus_all.sh) and the
Genus log (genus.log) for the switching-activity annotation.
"""
import csv, os, re, sys, argparse

ap = argparse.ArgumentParser()
ap.add_argument("root")
ap.add_argument("-o", "--out", default=None, help="output basename (default <root>/metrics)")
args = ap.parse_args()
root = os.path.abspath(args.root)
out = args.out or os.path.join(root, "metrics")


def num(s):
    return float(s.replace(",", ""))


def parse_run(d):
    r = {"run": os.path.basename(d)}
    info = os.path.join(d, "run_info.txt")
    if os.path.exists(info):
        for line in open(info):
            if "=" in line:
                k, v = line.strip().split("=", 1); r[k.lower()] = v
    q = open(os.path.join(d, "qor.rpt")).read() if os.path.exists(os.path.join(d, "qor.rpt")) else ""
    m = re.search(r"^\s*Module:\s+(\S+)", q, re.M)
    if m and "top" not in r: r["top"] = m.group(1)
    m = re.search(r"^clk\s+(\S+)", q, re.M)                       # clock period (ps) from the Timing table
    if m and "clk_ns" not in r: r["clk_ns"] = f"{num(m.group(1)) / 1000:g}"
    m = re.search(r"^clk\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)", q, re.M)
    if m:
        r["slack_ps"] = num(m.group(1)); r["tns_ps"] = num(m.group(2)); r["violating_paths"] = int(m.group(3))
        r["timing"] = "MET" if r["slack_ps"] >= 0 else "VIOLATED"
    for key, pat in [("cells", r"Leaf Instance Count\s+(\d+)"), ("flops", r"Sequential Instance Count\s+(\d+)"),
                     ("total_area_um2", r"Total Area \(Cell\+Physical\+Net\)\s+([\d.]+)")]:
        m = re.search(pat, q)
        if m: r[key] = num(m.group(1))
    g = os.path.join(d, "gates.rpt")
    sram_n, sram_a, macros = 0, 0.0, []
    if os.path.exists(g):
        seen = set()
        for line in open(g):
            m = re.match(r"^(sky130_sram_\S+?)\s+(\d+)\s+([\d.]+)\s+\S+_lib\s*$", line)
            if m and m.group(1) not in seen:
                seen.add(m.group(1)); n, a = int(m.group(2)), num(m.group(3))
                sram_n += n; sram_a += a; macros.append(f"{n}x{m.group(1).replace('sky130_sram_', '')}")
    r["sram_macros"] = sram_n; r["sram_area_um2"] = round(sram_a, 1); r["sram_list"] = " + ".join(macros)
    if "total_area_um2" in r:
        r["logic_area_um2"] = round(r["total_area_um2"] - sram_a, 1)
        r["total_area_mm2"] = round(r["total_area_um2"] / 1e6, 4)
    p = os.path.join(d, "power.rpt")
    if os.path.exists(p):
        txt = open(p).read()
        m = re.search(r"Subtotal\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)", txt)
        if m:
            r["leak_mW"], r["internal_mW"], r["switching_mW"], r["total_power_mW"] = [round(num(x) * 1e3, 4) for x in m.groups()]
        m = re.search(r"^\s*memory\s+\S+\s+\S+\s+\S+\s+(\S+)", txt, re.M)
        if m: r["memory_power_mW"] = round(num(m.group(1)) * 1e3, 4)
    unres = os.path.join(d, "unresolved.rpt")
    if os.path.exists(unres):
        m = re.search(r"Total number of unresolved references.*?:\s*(\d+)", open(unres).read())
        r["unresolved"] = int(m.group(1)) if m else 0
    vcd = r.get("vcd", "none")
    if vcd in ("", "none"):
        r["power_mode"] = "vectorless"
    elif os.path.exists(os.path.join(d, "VCD_READ_FAILED")):
        r["power_mode"] = "VCD FAILED -> vectorless"
    else:
        r["power_mode"] = "VCD"
        act = os.path.join(d, "activity.rpt")
        if os.path.exists(act):
            m = re.search(r"(\d+(?:\.\d+)?)\s*%", open(act, errors="replace").read())
            if m: r["vcd_annotation_pct"] = m.group(1)
    return r


# window length of each shipped VCD (ns), for energy = power x busy time
windows = {}
wf = os.path.join(os.path.dirname(root), "vcd", "windows.txt")
if os.path.exists(wf):
    for line in open(wf):
        pv = line.split()
        if len(pv) >= 2 and not line.startswith("#"): windows[pv[0]] = float(pv[1])

runs = []
for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    if os.path.isdir(d) and os.path.exists(os.path.join(d, "qor.rpt")):
        r = parse_run(d)
        vname = os.path.basename(r.get("vcd", "none")).replace(".gz", "")
        # the VCDs were recorded with a 10 ns clock: energy only for the 10 ns runs
        if (r.get("power_mode") == "VCD" and vname in windows and "total_power_mW" in r
                and abs(float(r.get("clk_ns", 0) or 0) - 10.0) < 1e-6):
            r["window_us"] = round(windows[vname] / 1000, 2)
            r["energy_uJ"] = round(r["total_power_mW"] * windows[vname] / 1e6, 3)   # mW x ns = pJ; /1e6 -> uJ
        runs.append(r)
if not runs:
    sys.exit(f"no run folders with qor.rpt under {root}")

cols = ["run", "top", "lane", "clk_ns", "timing", "slack_ps", "tns_ps", "violating_paths", "cells", "flops",
        "logic_area_um2", "sram_macros", "sram_list", "sram_area_um2", "total_area_um2", "total_area_mm2",
        "total_power_mW", "window_us", "energy_uJ", "memory_power_mW", "internal_mW", "switching_mW", "leak_mW", "power_mode",
        "vcd_annotation_pct", "unresolved"]
with open(out + ".csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore"); w.writeheader()
    for r in runs: w.writerow(r)
md = ["| Run | Top | Lane | Clock (ns) | Timing (slack ps) | Cells | Flops | Logic area (mm²) | SRAM | SRAM area (mm²) "
      "| Total area (mm²) | Power (mW) | Energy over VCD window (uJ) | Power source | Unresolved |", "|" + "---|" * 15]
for r in runs:
    md.append("| {run} | {top} | {lane} | {clk} | {t} ({s}) | {cells} | {flops} | {la} | {sl} | {sa} | {ta} | {p} | {e} | {pm} | {u} |".format(
        run=r["run"], top=r.get("top", ""), lane=r.get("lane", ""), clk=r.get("clk_ns", ""),
        t=r.get("timing", "?"), s=r.get("slack_ps", "?"), cells=int(r.get("cells", 0)), flops=int(r.get("flops", 0)),
        la=f"{r.get('logic_area_um2', 0) / 1e6:.4f}", sl=r.get("sram_list", "") or "none",
        sa=f"{r.get('sram_area_um2', 0) / 1e6:.4f}", ta=r.get("total_area_mm2", ""),
        p=r.get("total_power_mW", ""), e=(f"{r['energy_uJ']} ({r['window_us']} us)" if "energy_uJ" in r else ""), pm=r.get("power_mode", "") + (f" ({r['vcd_annotation_pct']}%)" if r.get("vcd_annotation_pct") else ""),
        u=r.get("unresolved", "")))
open(out + ".md", "w").write("\n".join(md) + "\n")
print("\n".join(md))
print(f"\nwrote {out}.csv and {out}.md")
