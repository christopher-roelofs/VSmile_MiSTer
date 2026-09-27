#!/usr/bin/env python3
# Summarise a BIOS survey (scripts/bios_survey.sh): which carts execute
# system-ROM code, which pointer-table slots (top of the ROM) they read,
# and which data ranges behind them, with how many carts use each.
#
#   bios_report.py <survey dir> [system rom]
import glob, os, struct, sys
from collections import defaultdict

d = sys.argv[1]
rom = open(sys.argv[2], 'rb').read() if len(sys.argv) > 2 else None
carts = {}
for t in sorted(glob.glob(os.path.join(d, '*.txt'))):
    stem = t[:-4]
    name = open(stem + '.cart').read().strip() if os.path.exists(stem + '.cart') else os.path.basename(stem)
    code, data = [], []
    for line in open(t):
        p = line.split()
        if p[0] in ('code', 'data'):
            (code if p[0] == 'code' else data).append((int(p[1], 16), int(p[2], 16)))
    carts[name] = (code, data)

print(f"# BIOS usage survey: {len(carts)} carts\n")
users = [c for c, (cd, dt) in carts.items() if cd or dt]
coders = [c for c, (cd, dt) in carts.items() if cd]
print(f"- carts that read the system ROM at all: {len(users)}")
print(f"- carts that execute system ROM code: {len(coders)}")
for c in coders[:20]:
    print(f"    {c}: " + ", ".join(f"{a:05X}-{b:05X}" for a, b in carts[c][0][:6]))
print()

# pointer table: words 0xFFFC0-0xFFFFF, two words (lo, hi) per slot
slot_users = defaultdict(set)
for c, (cd, dt) in carts.items():
    for a, b in dt:
        for w in range(max(a, 0xFFFC0), min(b, 0xFFFFF) + 1):
            slot_users[(w - 0xFFFC0) // 2].add(c)
print("## Pointer table slots read (top of the system ROM)\n")
print("| slot | word | points to | carts |\n|---|---|---|---|")
for s in sorted(slot_users):
    w = 0xFFFC0 + 2 * s
    tgt = ''
    if rom:
        lo, hi = struct.unpack_from('<HH', rom, 2 * w)
        tgt = f"{(hi << 16) | lo:06X}"
    print(f"| {s} | {w:05X} | {tgt} | {len(slot_users[s])} |")
print()

# data ranges, bucketed to 4K words, below the table
bucket = defaultdict(set)
for c, (cd, dt) in carts.items():
    for a, b in dt:
        for k in range(a >> 12, (min(b, 0xFFFBF) >> 12) + 1):
            if a <= 0xFFFBF:
                bucket[k].add(c)
print("## System ROM data read, by 4K-word block\n")
print("| block (word offset) | carts |\n|---|---|")
for k in sorted(bucket):
    print(f"| {k << 12:05X}-{(k << 12) | 0xFFF:05X} | {len(bucket[k])} |")
