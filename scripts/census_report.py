#!/usr/bin/env python3
# Summarise a feature census (scripts/feature_census.sh):
#   1. carts using something the core does not implement
#   2. features the core implements but no MAME-verified cart has exercised
#      (so they are only as good as reading the code)
#   3. how many carts use each feature
#
#   census_report.py <census dir> <verified census dir>
#
# The verified census is the same scan run over the carts that have passed
# lockstep against MAME, for the length of their traces.
import glob, os, re, sys
from collections import defaultdict

UNSUPPORTED_PAGE = {"LINEMAP": "bitmap/line-map page", "VCMP": "vertical compression",
                    "HICOLOR": "hi-colour page"}
# I/O blocks MAME gives behaviour that the core only stores (sleep/wake-up,
# UART reset and the regulator/clock registers are storage in MAME too)
UNSUPPORTED_IO = [(0x3D40, 0x3D45, "SPI"), (0x3D50, 0x3D55, "serial ROM (SIO)"),
                  (0x3D58, 0x3D5F, "I2C")]


def features(path):
    """Normalised feature set of one census file."""
    out = set()
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line or line.startswith("frames"):
            continue
        m = re.match(r"sprite bpp=(\d+) size=(\d+x\d+) ?(.*)", line)
        if m:
            out.add(f"sprite {m.group(1)}bpp")
            out.add(f"sprite size {m.group(2)}")
            for f in filter(None, m.group(3).split(",")):
                out.add(f"sprite {f}")
            continue
        m = re.match(r"page bpp=(\d+) tile=(\d+x\d+) (.*)", line)
        if m:
            out.add(f"page {m.group(1)}bpp")
            out.add(f"page tile {m.group(2)}")
            for f in filter(None, m.group(3).split(",")):
                out.add(f"page {f}")
            continue
        m = re.match(r"io (read|write) ([0-9A-F]{4})", line)
        if m:
            a = int(m.group(2), 16)
            for lo, hi, name in UNSUPPORTED_IO:
                if lo <= a <= hi:
                    out.add(f"IO {name}")
            continue
        if line.startswith("audio reg"):
            continue
        out.add(line)
    return out


def load(d):
    carts = {}
    for t in glob.glob(os.path.join(d, "*.txt")):
        stem = t[:-4]
        name = open(stem + ".cart").read().strip() if os.path.exists(stem + ".cart") else os.path.basename(stem)
        carts[name] = features(t)
    return carts


def unsupported(f):
    if f.startswith("IO "):
        return True
    if f.startswith("SATURATION"):
        return True
    return f.startswith("page ") and f.split()[1] in UNSUPPORTED_PAGE


allc = load(sys.argv[1])
verified = set().union(*load(sys.argv[2]).values()) if len(sys.argv) > 2 else set()
use = defaultdict(list)
for c, fs in allc.items():
    for f in fs:
        use[f].append(c)

print(f"# V.Smile feature census: {len(allc)} carts\n")
print("## 1. Carts using features the core does not implement\n")
bad = {c: sorted(f for f in fs if unsupported(f)) for c, fs in allc.items()}
bad = {c: v for c, v in bad.items() if v}
if not bad:
    print("None.\n")
for c in sorted(bad):
    print(f"- {c}: {', '.join(bad[c])}")
print()

print("## 2. Implemented but never exercised by a MAME-verified cart\n")
print("| feature | carts | examples |\n|---|---|---|")
for f in sorted(use, key=lambda f: -len(use[f])):
    if unsupported(f) or f in verified:
        continue
    ex = "; ".join(sorted(use[f])[:3])
    print(f"| {f} | {len(use[f])} | {ex} |")
print()

print("## 3. All features by number of carts\n")
print("| feature | carts | verified |\n|---|---|---|")
for f in sorted(use, key=lambda f: (-len(use[f]), f)):
    v = "unsupported" if unsupported(f) else ("yes" if f in verified else "no")
    print(f"| {f} | {len(use[f])} | {v} |")
