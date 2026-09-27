#!/usr/bin/env python3
# Summarise a simulator sweep (scripts/sim_sweep.sh): per cart, frames run
# and scanlines that differed from the reference renderer; per planned
# feature, whether a run reached it (RTL-side census) with no differences.
#
#   sweep_report.py <plan.tsv> <sweep outdir>
import glob, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import census_report as cr

plan, out = sys.argv[1], sys.argv[2]
runs = {}
for cart in glob.glob(os.path.join(out, "*.cart")):
    stem = cart[:-5]
    c = os.path.basename(open(cart).read().strip())
    log = open(stem + ".log", errors="replace").read() if os.path.exists(stem + ".log") else ""
    m = re.search(r"^video: (\d+) frames, (\d+)/(\d+) lines differ", log, re.M)
    bad_frames = re.findall(r"^  frame (\d+): (\d+) lines differ", log, re.M)
    feats = cr.features(stem + ".feat") if os.path.exists(stem + ".feat") else set()
    runs[c] = dict(frames=int(m.group(1)) if m else None, bad=int(m.group(2)) if m else None,
                   lines=int(m.group(3)) if m else None, bad_frames=bad_frames, feats=feats,
                   illegal="illegal" in log)

print("# Simulator sweep against the reference renderer\n")
print("| cart | frames | lines differing | first differing frames |\n|---|---|---|---|")
for c in sorted(runs):
    r = runs[c]
    ff = ", ".join(f"{f} ({n})" for f, n in r["bad_frames"][:4])
    print(f"| {c} | {r['frames']} | {r['bad']}/{r['lines']}{' ILLEGAL' if r['illegal'] else ''} | {ff} |")
print()

print("## Planned features\n")
print("| feature | result | reached by |\n|---|---|---|")
wanted = {}
for line in open(plan):
    c, frames, fs = line.rstrip("\n").split("\t")
    for f in fs.split("; "):
        wanted.setdefault(f, []).append(os.path.basename(c))
for f in sorted(wanted):
    clean = [c for c, r in runs.items() if f in r["feats"] and r["bad"] == 0]
    dirty = [c for c, r in runs.items() if f in r["feats"] and r["bad"]]
    if clean:
        res, who = "verified", clean
    elif dirty:
        res, who = "REACHED, lines differ", dirty
    else:
        res, who = "not reached", wanted[f]
    print(f"| {f} | {res} | {'; '.join(who[:3])} |")
