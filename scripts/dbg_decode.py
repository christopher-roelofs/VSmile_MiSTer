#!/usr/bin/env python3
# Decode a screenshot of the core's OSD "Debug" screens (rtl/emu.sv): 16 rows
# of 64 bits, bit 63 at the left, 5 px per bit, 14 px per row from line 8.
#
#   dbg_decode.py sdram   shot.png cart.bin [bios.bin]
#   dbg_decode.py console shot.png
import struct, sys
from PIL import Image

mode, shot = sys.argv[1], sys.argv[2]
im = Image.open(shot).convert('RGB')
sx, sy = im.size[0] / 320, im.size[1] / 240

def row(r):
    v = 0
    for i in range(64):
        p = im.getpixel((int((5 * i + 1.5) * sx), int((8 + 14 * r + 5) * sy)))
        v = (v << 1) | (1 if sum(p) > 384 else 0)
    return v

def words(v):
    return ['%04x' % ((v >> (16 * k)) & 0xFFFF) for k in range(4)]

if mode == 'sdram':
    cart = open(sys.argv[3], 'rb').read()
    bios = open(sys.argv[4], 'rb').read() if len(sys.argv) > 4 else b''

    def word(a):
        if a & 0x800000:            # system ROM, low byte first like the cart
            o = (a & 0xFFFFF) * 2
            return '%04x' % struct.unpack_from('<H', bios, o)[0] if o + 1 < len(bios) else '----'
        o = a * 2
        return '%04x' % struct.unpack_from('<H', cart, o)[0] if o + 1 < len(cart) else '----'

    for n in range(4):
        a = row(4 * n)
        print('read %d: word addr %06x' % (n, a))
        print('   expected  ' + ' '.join(word((a & ~3) + k) for k in range(4)))
        for k, name in enumerate(('s0', 's1', 's2')):
            print('   %s        %s' % (name, ' '.join(words(row(4 * n + 1 + k)))))
else:
    r = [row(i) for i in range(16)]
    print('PC          %06x' % (r[0] >> 32))
    print('insns       %d' % (r[0] & 0xFFFFFFFF))
    print('irq acks    %d' % (r[1] >> 48))
    print('illegal     %d' % ((r[1] >> 32) & 0xFFFF))
    print('sdram reads %d' % (r[1] & 0xFFFFFFFF))
    print('frames      %d' % (r[2] >> 48))
    print('ppu overrun %d' % ((r[2] >> 32) & 0xFFFF))
    print('io writes   %d' % (r[2] & 0xFFFFFFFF))
    print('PC@frames   ' + ' '.join(reversed(words(r[3]))) + '  (newest last)')
    for i in range(8):
        ws = words(r[4 + i])
        print('  %04x: %s' % (0x2810 + 4 * i, ' '.join(ws)))
    p = r[12]
    fl = (p >> 10) & 0x3F
    print('pad: idle_t=%d rts_t=%d tx_t=%d (x512 clks) active=%d sel=%d empty=%d tx_active=%d rts=%d head=%d tail=%d'
          % (p >> 48, (p >> 32) & 0xFFFF, (p >> 16) & 0xFFFF, fl >> 5 & 1, fl >> 4 & 1, fl >> 3 & 1, fl >> 2 & 1, fl >> 1 & 1,
             (p >> 5) & 0x1F, p & 0x1F))
    q = r[13]
    print('pad: bytes pad->console=%d console->pad=%d select changes=%d select=%d stale=%02x'
          % (q >> 48, (q >> 32) & 0xFFFF, (q >> 16) & 0xFFFF, (q >> 7) & 1, q & 0x7F))
    print('pad->console last: ' + ' '.join('%02x' % ((r[14] >> (8 * k)) & 0xFF) for k in range(7, -1, -1)))
    print('console->pad last: ' + ' '.join('%02x' % ((r[15] >> (8 * k)) & 0xFF) for k in range(7, -1, -1)))
