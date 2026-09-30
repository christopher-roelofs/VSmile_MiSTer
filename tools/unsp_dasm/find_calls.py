#!/usr/bin/env python3
"""find_calls.py ROM TARGET...: word addresses of 'call TARGET' (F04x imm) in a
little-endian uNSP ROM image"""
import sys, struct
d = open(sys.argv[1], 'rb').read()
w = struct.unpack(f'<{len(d)//2}H', d[:len(d)//2*2])
for t in sys.argv[2:]:
    t = int(t, 16)
    hi, lo = 0xF040 | (t >> 16), t & 0xFFFF
    hits = [i for i in range(len(w) - 1) if w[i] == hi and w[i + 1] == lo]
    print(f'{t:06X}:', ' '.join(f'{h:06X}' for h in hits))
