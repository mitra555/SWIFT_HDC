import json, sys, numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

R = sys.argv[1]; OUT = sys.argv[2]
plt.rcParams.update({"font.size": 7, "font.family": "DejaVu Sans", "axes.linewidth": 0.6,
                     "xtick.major.width": 0.6, "ytick.major.width": 0.6, "legend.frameon": False})

# ---------------------------------------------------------------- accuracy vs D and vs lane width
dim = json.load(open(f"{R}/dim_sweep.json"))
Ds = sorted({r["D"] for r in dim})
series = [("E_hw_16bit", "SWIFT, 16-bit", "#1f6fb4", "o"),
          ("F_binary_protos_hamming", "binary prototypes", "#e08a1e", "s"),
          ("H_baseline_unbounded", "baseline, ideal counters", "#7a7a7a", "^"),
          ("G_baseline_hdcu", "baseline HDCU", "#c0392b", "v")]
fig, (a1, a2) = plt.subplots(1, 2, figsize=(3.5, 1.75), gridspec_kw=dict(width_ratios=[1.15, 1]))
for key, lab, col, mk in series:
    m = [100 * np.mean([r["acc"][key] for r in dim if r["D"] == D]) for D in Ds]
    s = [100 * np.std([r["acc"][key] for r in dim if r["D"] == D]) for D in Ds]
    a1.errorbar(Ds, m, yerr=s, label=lab, color=col, marker=mk, ms=2.5, lw=0.9, capsize=1.2, elinewidth=0.6)
a1.set_xscale("log", base=2); a1.set_xticks([512, 1024, 2048, 4096, 8192])
a1.set_xticklabels(["512", "1k", "2k", "4k", "8k"]); a1.minorticks_off()
a1.set_xlabel("dimension D"); a1.set_ylabel("KTH accuracy (%)"); a1.set_ylim(30, 82)
a1.grid(alpha=0.25, lw=0.4); a1.set_title("(a)", fontsize=7, pad=2)
h, l = a1.get_legend_handles_labels()

bits = json.load(open(f"{R}/bits_sweep.json"))
W = sorted({int(k) for k in bits[0]["acc"]})
m = [100 * np.mean([r["acc"][str(w)] for r in bits]) for w in W]
s = [100 * np.std([r["acc"][str(w)] for r in bits]) for w in W]
a2.errorbar(W, m, yerr=s, color="#1f6fb4", marker="o", ms=2.5, lw=0.9, capsize=1.2, elinewidth=0.6)
a2.axvline(16, color="#2e8b57", lw=0.7, ls="--"); a2.text(16.6, 30, "chosen", color="#2e8b57", fontsize=6)
a2.set_xticks([4, 8, 12, 16, 20, 24, 32]); a2.set_xlabel("prototype lane width (bits)")
a2.set_ylim(15, 82); a2.grid(alpha=0.25, lw=0.4); a2.set_title("(b)", fontsize=7, pad=2)
fig.tight_layout(pad=0.3, w_pad=0.6, rect=(0, 0, 1, 0.84))
fig.legend(h, l, loc="upper center", ncol=2, fontsize=6, handlelength=1.6, columnspacing=1.0, labelspacing=0.2,
           bbox_to_anchor=(0.5, 1.0))
fig.savefig(f"{OUT}/fig_res_sweeps.pdf"); fig.savefig(f"{OUT}/fig_res_sweeps.png", dpi=250)
plt.close(fig)

# ---------------------------------------------------------------- 6-class confusion matrices
m6 = json.load(open(f"{R}/main_6c.json"))
names = ["box", "clap", "wave", "jog", "run", "walk"]
fig, axs = plt.subplots(1, 2, figsize=(3.5, 2.05))
for ax, (key, title) in zip(axs, [("E_hw_16bit", "SWIFT, 16-bit"), ("G_baseline_hdcu", "baseline HDCU")]):
    C = np.sum([np.array(r["results"][key]["confusion"]) for r in m6], axis=0).astype(float)
    C = 100 * C / C.sum(1, keepdims=True)
    ax.imshow(C, cmap="Blues", vmin=0, vmax=100)
    for i in range(6):
        for j in range(6):
            ax.text(j, i, f"{C[i, j]:.0f}", ha="center", va="center", fontsize=5.2,
                    color="white" if C[i, j] > 55 else "black")
    acc = 100 * np.mean([r["results"][key]["acc"] for r in m6])
    ax.set_title(f"{title} ({acc:.1f}%)", fontsize=6.5, pad=2)
    ax.set_xticks(range(6)); ax.set_yticks(range(6))
    ax.set_xticklabels(names, rotation=90, fontsize=5.5); ax.set_yticklabels(names, fontsize=5.5)
    ax.tick_params(length=0, pad=1)
axs[0].set_ylabel("true", fontsize=6); axs[0].set_xlabel("predicted", fontsize=6); axs[1].set_xlabel("predicted", fontsize=6)
fig.tight_layout(pad=0.3, w_pad=0.8)
fig.savefig(f"{OUT}/fig_res_confusion.pdf", bbox_inches="tight", pad_inches=0.02); fig.savefig(f"{OUT}/fig_res_confusion.png", dpi=250, bbox_inches="tight", pad_inches=0.02)
print("ok")
