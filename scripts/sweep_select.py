#!/usr/bin/env python3
# Pick carts for the simulator sweep: a small set that together uses every
# video feature (from the census) not yet exercised by a MAME-verified cart,
# two carts per feature where the census has them.  Prints one line per cart:
#   <cart file>\t<frames to run>\t<features it covers>
# Frames to run: the latest first appearance (census "@frame") among the
# features it was picked for, plus 5 s.
#
#   sweep_select.py <census dir> <verified census dir> <roms dir>
import glob, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import census_report as cr

VIDEO = ("page ", "sprite ", "blendlevel", "fade")


def first_frames(path):
    """Normalised feature -> first frame it appeared (census '@' stamps)."""
    out = {}
    for line in open(path, errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 2 or not parts[1].startswith("@"):
            continue
        fr = int(parts[1][1:])
        for f in cr.features_of([parts[0]]):
            out[f] = min(out.get(f, fr), fr)
    return out


census, verified_dir, roms = sys.argv[1], sys.argv[2], sys.argv[3]
allc = cr.load(census)
verified = set().union(*cr.load(verified_dir).values())
want = {}
def bad_dump(c):
    return "[b]" in c or "TWO CHIP" in c


for c, fs in allc.items():
    if bad_dump(c):
        continue
    for f in fs:
        if f.startswith(VIDEO) and not cr.unsupported(f) and f not in verified:
            want.setdefault(f, set()).add(c)
# per feature, the two carts where it first appears earliest (a cart's
# census has "@frame" stamps); each cart then runs until the latest of the
# features it was picked for
stems = {}
for t in glob.glob(os.path.join(census, "*.cart")):
    stems[open(t).read().strip()] = t[:-5]
firsts = {c: first_frames(stems[c] + ".txt") for c in allc if c in stems}
picked = {}
for f, cs in want.items():
    ranked = sorted(cs, key=lambda c: firsts.get(c, {}).get(f, 10 ** 9))
    for c in ranked[:2]:
        picked.setdefault(c, []).append(f)
for c, fs in picked.items():
    ff = firsts.get(c, {})
    frames = max(ff.get(f, 7200) for f in fs) + 300
    print(f"{os.path.join(roms, c)}\t{frames}\t{'; '.join(sorted(fs))}")
