"""
run_accuracy.py -- one-command accuracy evaluation for the HDC video pipeline paper.

    python run_accuracy.py

With no --data, the KTH dataset (the one the hdcvideoca notebook used) is downloaded from
https://www.csc.kth.se/cvap/actions/ into ./KTH (5 classes, ~980 MB; jogging is not used)
and extracted. If you already have it: --data /path/to/folder-with-boxing/-handclapping/...
Everything else is automatic:

  1. installs numpy and OpenCV 4.x if they are missing (OpenCV 5 has no HOGDescriptor)
  2. extracts features once (~10-30 min, cached in results/hw_feats.npz)
  3. runs every mode twice: quantization ranges from all clips (as the notebook) and from
     training clips only (as a deployed chip would)
  4. writes results/RESULTS.md (the table for the paper), the two JSON files and full logs

Re-running reuses the feature cache, so only the HDC part is repeated.
"""
import argparse, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("--data", default=os.path.join(HERE, "KTH"),
                help="KTH folder with one sub-folder per class (downloaded here if missing)")
ap.add_argument("--out", default=os.path.join(HERE, "results"))
args = ap.parse_args()
data = os.path.abspath(os.path.expanduser(args.data)); out = os.path.abspath(args.out)

# ---------- dataset: download if missing ----------
need = ["boxing", "handclapping", "handwaving", "running", "walking"]

def n_avis(d):
    return len([f for f in os.listdir(d) if f.lower().endswith(".avi")]) if os.path.isdir(d) else 0

def download_kth(root):
    import urllib.request, zipfile, shutil
    os.makedirs(root, exist_ok=True)
    for c in need:
        cdir = os.path.join(root, c)
        if n_avis(cdir) > 0:
            print(f"  {c}: already present ({n_avis(cdir)} videos)"); continue
        zpath = os.path.join(root, c + ".zip")
        if not (os.path.exists(zpath) and zipfile.is_zipfile(zpath)):
            for url in (f"https://www.csc.kth.se/cvap/actions/{c}.zip", f"http://www.csc.kth.se/cvap/actions/{c}.zip"):
                try:
                    print(f"  downloading {url} ...", flush=True)
                    tmp = zpath + ".part"
                    with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
                        total = int(r.headers.get("Content-Length") or 0); got = 0; last = 0
                        while True:
                            b = r.read(1 << 20)
                            if not b: break
                            f.write(b); got += len(b)
                            if total and got - last > 25 << 20:
                                last = got; print(f"    {got >> 20} / {total >> 20} MB", flush=True)
                    os.replace(tmp, zpath)
                    if zipfile.is_zipfile(zpath): break
                except Exception as e:
                    print(f"    failed: {e}")
            else:
                sys.exit(f"could not download {c}.zip; download it by hand from "
                         f"https://www.csc.kth.se/cvap/actions/ into {root} and re-run")
        print(f"  extracting {c}.zip ...", flush=True)
        os.makedirs(cdir, exist_ok=True)
        with zipfile.ZipFile(zpath) as z:
            for m in z.infolist():
                name = os.path.basename(m.filename)
                if name.lower().endswith(".avi"):
                    with z.open(m) as src, open(os.path.join(cdir, name), "wb") as dst:
                        shutil.copyfileobj(src, dst)
        os.remove(zpath)
        print(f"  {c}: {n_avis(cdir)} videos")

if not all(n_avis(os.path.join(data, c)) > 0 for c in need):
    print(f"KTH dataset not found in {data}; downloading it there (~980 MB, once)")
    download_kth(data)

# ---------- dataset check ----------
if not os.path.isdir(data):
    sys.exit(f"--data {data} is not a folder")
present = [d for d in os.listdir(data) if os.path.isdir(os.path.join(data, d))]
missing = [c for c in need if c not in present]
if missing:
    sys.exit(f"{data} has class folders {sorted(present)}; missing {missing}. Point --data at the folder "
             f"that contains boxing/, handclapping/, ... directly.")
n_avi = sum(len([f for f in os.listdir(os.path.join(data, c)) if f.endswith(".avi")]) for c in need)
print(f"dataset: {data}  ({n_avi} .avi files in the 5 used classes)")
if n_avi == 0:
    sys.exit("no .avi files found")

# ---------- dependencies ----------
def have_deps():
    try:
        import numpy, cv2  # noqa
        return int(cv2.__version__.split(".")[0]) < 5 and hasattr(cv2, "HOGDescriptor")
    except Exception:
        return False

if not have_deps():
    print("installing numpy + opencv-python-headless<5 ...", flush=True)
    req = os.path.join(HERE, "requirements.txt")
    for extra in ([], ["--user"], ["--user", "--break-system-packages"]):
        r = subprocess.run([sys.executable, "-m", "pip", "install", "-q", "-r", req] + extra)
        if r.returncode == 0 and subprocess.run([sys.executable, "-c",
                "import cv2,numpy; assert int(cv2.__version__.split('.')[0])<5 and hasattr(cv2,'HOGDescriptor')"]).returncode == 0:
            break
    else:
        sys.exit("could not install numpy / OpenCV 4.x; run:  python -m pip install -r requirements.txt")

# ---------- runs ----------
os.makedirs(out, exist_ok=True)
cache = os.path.join(out, "hw_feats.npz")
script = os.path.join(HERE, "..", "scripts", "hw_accuracy_eval.py")
runs = [("all", []), ("train_only", ["--quant-from-train"])]
res = {}
for tag, extra in runs:
    log = os.path.join(out, f"log_{tag}.txt")
    print(f"\n=== run '{tag}' (log: {log}) ===", flush=True)
    t0 = time.time()
    with open(log, "w") as lf:
        p = subprocess.Popen([sys.executable, "-u", script, "--data", data, "--cache", cache] + extra,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=out)
        for line in p.stdout:
            sys.stdout.write(line); lf.write(line); lf.flush()
        p.wait()
    if p.returncode != 0:
        sys.exit(f"run '{tag}' failed (exit {p.returncode}); see {log}")
    src = os.path.join(out, "hw_accuracy_results.json"); dst = os.path.join(out, f"results_{tag}.json")
    os.replace(src, dst); res[tag] = json.load(open(dst))
    print(f"=== '{tag}' done in {time.time() - t0:.0f}s -> {dst}", flush=True)

# ---------- summary ----------
a, t = res["all"], res["train_only"]
modes = list(a["results"].keys())
use = {"A": "notebook reproduction (sanity check)", "B": "notebook reproduction (sanity check)",
       "C": "notebook fully-binary, overflow fixed", "D": "D=5024 vs 5000",
       "E": "HEADLINE: what the chip computes", "F": "binary prototypes vs int32",
       "G": "BASELINE HDCU (compare E against this)", "H": "upper bound of G (unbounded counters)",
       "I": "rotated position HVs (memory-saving)", "J": "narrower prototype lanes (wide-SPM size)"}
L = ["# HDC video pipeline — KTH accuracy (5 classes, person-based split)", "",
     f"Dataset: `{data}`  ", f"D (hardware) = {a.get('D_hw')}  ",
     f"Quantized level indices, hardware vs notebook float: {a['quant_index_agreement']*100:.2f}% identical", "",
     "| Mode | Test acc (quant ranges: all clips) | Test acc (train clips only) | Use |",
     "|---|---|---|---|"]
for m in modes:
    L.append(f"| {m} | {a['results'][m]*100:.2f}% | {t['results'].get(m, float('nan'))*100:.2f}% | {use.get(m[0], '')} |")
r = a["results"]
E = next((v for k, v in r.items() if k.startswith("E.")), None)
G = next((v for k, v in r.items() if k.startswith("G.")), None)
H = next((v for k, v in r.items() if k.startswith("H.")), None)
L += ["", "## Key comparisons (quant ranges from all clips)", ""]
if E is not None and G is not None:
    L.append(f"- **Novelty (E) vs baseline HDCU (G): {E*100:.2f}% vs {G*100:.2f}% -> {(E-G)*100:+.2f} points**")
if G is not None and H is not None:
    L.append(f"- Baseline loss from 4-bit counters (H - G): {(H-G)*100:+.2f} points")
for k, v in r.items():
    if k.startswith("J.") and E is not None:
        L.append(f"- {k[3:]}: {v*100:.2f}% ({(v-E)*100:+.2f} vs int32)")
L += ["", f"- Encode accumulator: max |X| = {a.get('max_abs_X')}, bound = {a.get('X_bound')}",
      f"- Trained int32 prototypes: max |value| = {a.get('max_abs_proto_int32')}", "",
      "Single person-based split and fixed seeds (as in the notebook)."]
md = os.path.join(out, "RESULTS.md")
open(md, "w").write("\n".join(L) + "\n")
print("\n" + "\n".join(L))
print(f"\nwrote {md}")
