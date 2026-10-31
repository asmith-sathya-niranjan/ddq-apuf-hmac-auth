#!/usr/bin/env python3
"""
plot_ddq.py - turn the CSV records printed by the DDQ-APUF testbenches into
figures. Every plotted value comes from a "CSV,..." record; nothing here is
synthetic.

Usage:
    python3 plot_ddq.py logs/run.log logs/run_sar.log logs/run_temp.log

Works with XSim logs too (Vivado: <project>.sim/<simset>/behav/xsim/
simulate.log, or the logs/ copies written by the scripts in vivado/ and
scripts/). Missing logs just leave their panels empty.

Records consumed (extra trailing fields are optional):
    CSV,FLIP,<ones>                                   golden R_O, chip 0
    CSV,REP,<hd_enrol>,<conv_err>[,<hd_gold>,<conv_gold>]
    CSV,INTER,<hd_ro>,<hd_rl>
    CSV,BIT,<k>,<ro_count>,<rl_count>,<n>
    CSV,SARFLIP,<ones_unary>,<code_sar>               golden, same CRP
    CSV,SARREP,<hd_unary>,<err_sar>[,<hd_gold>,<err_gold>]
    CSV,SARINTER,<hd_unary>,<diff_sar>
    CSV,TEMP,<scale>,<sar_drift>,<unary_hd>,<conv>,<tc>[,<noisy>[,<lsb_x10>]]
    CSV,COMB,<mean_err>,<median_err>[,<med_core_enrol>,<med_core_meas>]
"""

import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

LSB_U = 30      # unary step, ps
LSB_S = 4       # SAR step, ps
D_PAPER = 3     # paper's unary tolerance

C_U, C_S, C_G, C_R = "#4C72B0", "#DD8452", "#55A868", "#C44E52"


def load(paths):
    rec = defaultdict(list)
    for path in paths:
        try:
            fh = open(path, errors="replace")
        except OSError:
            print(f"  (skipping {path}: not found)")
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line.startswith("CSV,"):
                    continue
                parts = line.split(",")
                try:
                    rec[parts[1]].append([int(x) for x in parts[2:]])
                except ValueError:
                    pass
    return rec


def rate(values, d):
    return 100.0 * np.mean(np.asarray(values) <= d)


def dmin(values):
    """smallest tolerance that accepted every legitimate re-measurement"""
    return int(np.max(values)) if len(values) else None


def unary_sets(rec):
    """unary reliability/false-accept data; prefer the SAR tb (same pairs)"""
    if rec["SARREP"] and rec["SARINTER"]:
        return [r[0] for r in rec["SARREP"]], [r[0] for r in rec["SARINTER"]]
    return [r[0] for r in rec["REP"]], [r[0] for r in rec["INTER"]]


def empty(ax, msg):
    ax.text(0.5, 0.5, msg, ha="center", va="center", transform=ax.transAxes)
    ax.set_axis_off()


# ----------------------------------------------------------------------------
def fig_flip_hist(rec, ax):
    """Distribution of the quantised delay difference - paper Fig. 6(b)/7(b)."""
    flips = [r[0] for r in rec["FLIP"]]
    if not flips:
        return empty(ax, "run tb_ddq_apuf for this panel")
    ax.hist(flips, bins=np.arange(-0.5, 14.5, 1), color=C_U, edgecolor="white")
    mu, sd = np.mean(flips), np.std(flips)
    x = np.linspace(0, 13, 200)
    pdf = np.exp(-((x - mu) ** 2) / (2 * sd ** 2)) / (sd * np.sqrt(2 * np.pi))
    ax.plot(x, pdf * len(flips), color=C_R, lw=2,
            label=f"normal fit\n$\\mu$={mu:.1f}, $\\sigma$={sd:.1f}")
    sat = 100.0 * sum(f in (0, 13) for f in flips) / len(flips)
    for edge in (0, 13):
        ax.axvspan(edge - 0.5, edge + 0.5, color=C_R, alpha=0.15)
    ax.set_title(f"Quantised $\\Delta D$, unary sweep (golden, n={len(flips)})\n"
                 f"saturated rails carry no information: {sat:.1f}%")
    ax.set_xlabel("number of '1's in $R_O$")
    ax.set_ylabel("CRPs")
    ax.legend(fontsize=8)


def fig_uniformity(rec, ax):
    """Per-bit uniformity before and after the LFSR - paper Fig. 12."""
    bits = sorted(rec["BIT"], key=lambda r: r[0])
    if not bits:
        return empty(ax, "run tb_ddq_apuf for this panel")
    k = [r[0] for r in bits]
    n = bits[0][3]
    ro = [100.0 * r[1] / r[3] for r in bits]
    rl = [100.0 * r[2] / r[3] for r in bits]
    band = 100.0 * 1.96 * np.sqrt(0.25 / n)
    ax.axhspan(50 - band, 50 + band, color="grey", alpha=0.12,
               label=f"95% band for a fair bit (n={n})")
    ax.plot(k, ro, "o-", color=C_U, label="$R_O$ (raw)")
    ax.plot(k, rl, "s-", color=C_G, label="$R_L$ (after LFSR)")
    ax.axhline(50, color="grey", ls="--", lw=1)
    ax.set_ylim(0, 100)
    ax.set_title("Per-bit uniformity\nthermometer ramp flattened by the LFSR")
    ax.set_xlabel("bit index $R[i]$")
    ax.set_ylabel("fraction of '1's  (%)")
    ax.legend(fontsize=8, loc="upper left")


def fig_tolerance_ps(rec, ax):
    """Acceptance vs tolerance WINDOW in ps, both quantisers, noisy enrolment."""
    u_rep, u_int = unary_sets(rec)
    if not u_rep:
        return empty(ax, "run tb_ddq_apuf / tb_ddq_sar for this panel")
    du = np.arange(0, 8)
    ax.plot(du * LSB_U, [rate(u_rep, d) for d in du], "o-", color=C_U,
            label="unary: legitimate accepted")
    ax.plot(du * LSB_U, [rate(u_int, d) for d in du], "o--", color=C_U, mfc="white",
            label="unary: foreign accepted")
    if rec["SARREP"]:
        s_rep = [r[1] for r in rec["SARREP"]]
        s_int = [r[1] for r in rec["SARINTER"]]
        ds = np.arange(0, 41)
        ax.plot(ds * LSB_S, [rate(s_rep, d) for d in ds], "-", color=C_S,
                label="SAR: legitimate accepted")
        ax.plot(ds * LSB_S, [rate(s_int, d) for d in ds], "--", color=C_S,
                label="SAR: foreign accepted")
        m = dmin(s_rep)
        ax.plot([m * LSB_S], [rate(s_int, m)], "*", ms=13, color=C_S, zorder=5)
    m = dmin(u_rep)
    ax.plot([m * LSB_U], [rate(u_int, m)], "*", ms=13, color=C_U, zorder=5)
    ax.axvline(D_PAPER * LSB_U, color="grey", ls=":", lw=1)
    ax.annotate("paper's d=3", xy=(D_PAPER * LSB_U, 4), xytext=(D_PAPER * LSB_U + 3, 4),
                fontsize=8, color="grey")
    ax.set_xlim(0, 165)
    ax.set_ylim(-3, 103)
    ax.set_title("What decides false accept is the window in ps\n"
                 "(stars: smallest d with 100% reliability)")
    ax.set_xlabel("tolerance window  (d x LSB, ps)")
    ax.set_ylabel("acceptance rate  (%)")
    ax.legend(fontsize=7, loc="center right")


def fig_matched(rec, ax):
    """Unary vs SAR at matched reliability, plus the paper's operating point."""
    if not rec["SARREP"]:
        return empty(ax, "run tb_ddq_sar for this panel")
    u_rep, u_int = unary_sets(rec)
    s_rep = [r[1] for r in rec["SARREP"]]
    s_int = [r[1] for r in rec["SARINTER"]]
    du, ds = dmin(u_rep), dmin(s_rep)
    cfg = [(f"unary d={D_PAPER}\n(paper)", rate(u_rep, D_PAPER), rate(u_int, D_PAPER), C_U, 0.45),
           (f"unary d={du}\n(min @100%)", rate(u_rep, du), rate(u_int, du), C_U, 1.0),
           (f"SAR d={ds}\n(min @100%)", rate(s_rep, ds), rate(s_int, ds), C_S, 1.0)]
    x = np.arange(2)
    w = 0.26
    for j, (lab, rel, fa, col, alpha) in enumerate(cfg):
        xs = x + (j - 1) * w
        ax.bar(xs, [rel, fa], w, color=col, alpha=alpha, label=lab.replace("\n", " "))
        for xi, v in zip(xs, [rel, fa]):
            ax.text(xi, v + 1.5, f"{v:.1f}", ha="center", fontsize=7)
    n_i = len(s_int)
    ax.set_xticks(x)
    ax.set_xticklabels(["reliability\n(want high)", f"false accept\n(want low, n={n_i} pairs)"])
    ax.set_ylim(0, 115)
    ax.set_title("Same silicon, two quantisers, noisy enrolment\n"
                 "compare at matched reliability, not at d=3")
    ax.set_ylabel("rate  (%)")
    ax.legend(fontsize=7, loc="upper right")


def fig_code_spread_ps(rec, ax):
    """Both codes on ONE physical axis (ps). Same dD, two rulers."""
    pairs = rec["SARFLIP"]
    if not pairs:
        return empty(ax, "run tb_ddq_sar for this panel")
    k = np.array([p[0] for p in pairs])
    c = np.array([p[1] for p in pairs])
    # unary: k ones <=> dD in (30(k-7), 30(k-6)]; rails drawn just outside +/-180
    u_ps = np.where(k == 0, -195, np.where(k == 13, 195, LSB_U * (k - 6.5)))
    s_ps = np.where(c > 0, LSB_S * c + 2, np.where(c < 0, LSB_S * c - 2, 0))
    edges = np.arange(-210, 211, 30)
    ax.hist(u_ps, bins=edges, color=C_U, alpha=0.55, label="unary (30 ps bins)")
    ax.hist(s_ps, bins=np.arange(-264, 265, 12), histtype="step", lw=2, color=C_S,
            label="SAR (4 ps LSB, 12 ps bins)")
    for v, col in ((180, C_U), (252, C_S)):
        ax.axvline(-v, color=col, ls=":", lw=1.2)
        ax.axvline(v, color=col, ls=":", lw=1.2)
    ax.set_title("Same $\\Delta D$, two rulers  (range in ps: "
                 "unary $\\pm$180, SAR $\\pm$252)\n"
                 "the gain is 127 vs 14 levels, not a 10x wider range")
    ax.set_xlabel("quantised $\\Delta D$  (ps)")
    ax.set_ylabel("CRPs")
    ax.legend(fontsize=8, loc="upper left")


def fig_temperature(rec, ax):
    """Drift vs delay scale, in PICOSECONDS.

    Quoting this drift in LSB is misleading: the LSB is itself silicon and
    shrinks with the die, so a fixed amount of arbiter jitter spans more
    codes at the cold/fast end. Converting with the LSB reported in the
    record makes the TC=0 curve flat, which is the ratiometric cancellation,
    and leaves the TC term as the gap between the two noisy curves.
    """
    recs = rec["TEMP"]
    if not recs:
        return empty(ax, "run tb_ddq_temp for this panel")
    groups = defaultdict(lambda: defaultdict(list))
    lsb_of = {}
    for r in recs:
        scale, sar, _uni, _conv, tc = r[:5]
        noisy = r[5] if len(r) > 5 else 1
        lsb_of[scale] = (r[6] / 10.0) if len(r) > 6 else LSB_S * scale / 100.0
        groups[(tc, noisy)][scale].append(sar)

    style = {1: "o-", 0: "s:"}
    colour = {0: C_G, 10: C_R}
    for (tc, noisy) in sorted(groups, key=lambda g: (-g[1], g[0])):
        scales = sorted(groups[(tc, noisy)])
        drift = [np.mean(groups[(tc, noisy)][s]) * lsb_of[s] for s in scales]
        lab = f"TC mismatch {tc} ps" + ("" if noisy else ", noise-free (truncation)")
        ax.plot(scales, drift, style.get(noisy, "o-"),
                color=colour.get(tc, C_U), label=lab)

    # the TC term on its own: same scale, same noise, only TC_VAR differs
    noisy_tcs = sorted({tc for (tc, n) in groups if n == 1})
    if len(noisy_tcs) >= 2:
        lo, hi = noisy_tcs[0], noisy_tcs[-1]
        scales = sorted(groups[(lo, 1)])
        diff = [(np.mean(groups[(hi, 1)][s]) - np.mean(groups[(lo, 1)][s])) * lsb_of[s]
                for s in scales]
        ax.bar(scales, diff, width=6, color=C_R, alpha=0.25,
               label=f"TC term alone ({hi}-{lo} ps)")
    ax.axhline(0, color="grey", lw=0.8)
    ax.set_title("Delay-scale sweep, drift in PICOSECONDS\n"
                 "flat at TC=0 = ratiometric; TC term grows with |scale-100|")
    ax.set_xlabel("delay scale (% of nominal)  -  hotter is slower")
    ax.set_ylabel("mean |SAR code drift|  (ps)")
    ax.set_ylim(bottom=0)
    ax.legend(fontsize=7)


def fig_combiner(rec, ax, d_tol):
    """Median vs mean - a negative result, plotted as measured."""
    recs = rec["COMB"]
    if not recs:
        return empty(ax, "run tb_ddq_temp for this panel")
    mean_e = np.array([r[0] for r in recs])
    med_e = np.array([r[1] for r in recs])
    bins = np.arange(-0.5, max(mean_e.max(), med_e.max()) + 1.5, 1)
    ax.hist(mean_e, bins=bins, alpha=0.75, color=C_U,
            label=f"mean: pass {rate(mean_e, d_tol):.1f}%, worst {mean_e.max()}")
    ax.hist(med_e, bins=bins, alpha=0.75, color=C_R,
            label=f"median: pass {rate(med_e, d_tol):.1f}%, worst {med_e.max()}")
    ax.axvline(d_tol + 0.5, color="grey", ls="--", lw=1)
    ax.text(d_tol + 0.8, ax.get_ylim()[1] * 0.5, f"tolerance d={d_tol}", fontsize=8, color="grey")
    ax.set_yscale("log")
    ax.set_title(f"Median combiner: NEGATIVE result (n={len(recs)})\n"
                 "the noisy core passes at full weight when it is the middle value")
    ax.set_xlabel("|error vs enrolment|  (LSB)")
    ax.set_ylabel("CRPs (log)")
    ax.legend(fontsize=8)


def main():
    logs = sys.argv[1:] or ["logs/run.log", "logs/run_sar.log", "logs/run_temp.log"]
    rec = load(logs)
    if not rec:
        sys.exit("no CSV records found - did you run the testbenches and keep the logs?")

    fig, axes = plt.subplots(2, 3, figsize=(17, 9.5))
    fig_flip_hist(rec, axes[0][0])
    fig_uniformity(rec, axes[0][1])
    fig_tolerance_ps(rec, axes[0][2])
    fig_matched(rec, axes[1][0])
    fig_code_spread_ps(rec, axes[1][1])
    fig_temperature(rec, axes[1][2])
    fig.suptitle("DDQ-APUF simulation results", fontsize=14)
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    fig.savefig("ddq_results.png", dpi=140)
    print("wrote ddq_results.png")

    d_tol = dmin([r[1] for r in rec["SARREP"]]) if rec["SARREP"] else 7
    fig2, ax2 = plt.subplots(1, 1, figsize=(6.8, 4.6))
    fig_combiner(rec, ax2, d_tol)
    fig2.tight_layout()
    fig2.savefig("ddq_combiner.png", dpi=140)
    print("wrote ddq_combiner.png")


if __name__ == "__main__":
    main()
