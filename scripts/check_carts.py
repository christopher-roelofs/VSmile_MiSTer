#!/usr/bin/env python3
"""Check V.Smile / Motion / Baby cart dumps against MAME's software lists and
put two-chip (16 MB) carts into MAME's chip order, which is what the core
expects (and the order it is verified against).

MAME lists a two-chip cart as two 8 MB files with their load offsets (LOW at
0x000000, HIGH at 0x800000); TOSEC keeps one 16 MB file, and has been seen
with the chips the other way round (HIGH first).  Single-chip dumps are the
same bytes in both (16-bit words, low byte first), which is also how the
core loads them.

  check_carts.py [--fix] [--backup DIR] FILE_OR_DIR...
      report every .bin: MAME set it matches, or why not; with --fix, a
      16 MB file whose halves match a MAME set in reverse order is rewritten
      in MAME's order (the original moved to --backup, default
      <file's dir>/_originals)
  check_carts.py --swap [--backup DIR] FILE...
      swap the 8 MB halves of 16 MB files that MAME does not list (so the
      order cannot be checked by checksum; e.g. a crash in MAME that goes
      away once swapped)
  check_carts.py --join OUT.bin SET.zip|CHIP.bin...
      build the single file the core loads from a MAME multi-chip set, given
      as its zip or as the loose chip files (chips placed at their
      software-list offsets in the set's ROM area, the rest 0x00 as in MAME)
"""
import argparse, glob, hashlib, os, re, shutil, sys, zipfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LISTS = ['vsmile_cart.xml', 'vsmilem_cart.xml', 'vsmileb_cart.xml']
HALF = 8 * 1024 * 1024

# MAME entries that list a two-chip cart as one 16 MB file with the chips
# HIGH first (the order TOSEC also has them in).  Found by running them:
# toystor3mfr crashes in MAME (unknown opcode at 0x10008B) and runs swapped;
# cars2mfr as listed never plays a sample or reads the controller in 3 min
# of scripted play, swapped it does both.  Checked 2026-09-29.
# MAME sets whose LOW/HIGH offsets are the wrong way round: joined as listed
# they stall (cars2mge: no sound or controller reads in 2 min of scripted
# play) or crash (toystor3mge and toystor3msp at frame 34); swapped they play
# like the other 16 MB carts.  Joined and checked with the offsets exchanged.
MAME_OFFSETS_SWAPPED = {'toystor3mge', 'toystor3msp', 'cars2mge'}

KNOWN_HIGH_FIRST = {
    '1ba5162181b29757335ab92451c3e164919e9c74': 'toystor3mfr',
    '0ff3fe336369f95dec640a5ca691daabacbc5332': 'cars2mfr',
}


def load_lists():
    whole, chips, sets = {}, {}, {}
    for x in LISTS:
        path = os.path.join(HERE, 'ref', 'mame', x)
        s = open(path, encoding='utf-8').read()
        for name, body in re.findall(r'<software name="([^"]+)"[^>]*>(.*?)</software>', s, re.S):
            desc = re.search(r'<description>([^<]+)', body).group(1).replace('&amp;', '&')
            area = re.search(r'<dataarea name="rom" size="([^"]+)"', body)
            area = int(area.group(1), 0) if area else 0
            roms = []
            for r in re.findall(r'<rom ([^>]*)/>', body):
                a = dict(re.findall(r'(\w+)="([^"]*)"', r))
                if 'sha1' in a:
                    roms.append((int(a.get('offset', '0'), 0), int(a['size'], 0), a['sha1'], a['name']))
            if name in MAME_OFFSETS_SWAPPED and len(roms) == 2 and roms[0][1] == roms[1][1]:
                (o0, s0, h0, n0), (o1, s1, h1, n1) = roms
                roms = [(o1, s0, h0, n0), (o0, s1, h1, n1)]
            roms.sort()
            sets[(x, name)] = (desc, roms, area)   # names repeat across lists (carebear)
            if len(roms) == 1:
                whole[roms[0][2]] = name
            for off, size, sha, rn in roms:
                chips[sha] = (name, off)
    return whole, chips, sets


def sha1(b):
    return hashlib.sha1(b).hexdigest()


def backup_and_write(path, data, backup):
    bdir = backup or os.path.join(os.path.dirname(path), '_originals')
    os.makedirs(bdir, exist_ok=True)
    dst = os.path.join(bdir, os.path.basename(path))
    if os.path.exists(dst):
        sys.exit(f'backup exists, not overwriting: {dst}')
    shutil.move(path, dst)
    open(path, 'wb').write(data)
    return dst


def files_of(args):
    for a in args:
        if os.path.isdir(a):
            for f in sorted(glob.glob(os.path.join(a, '**', '*.bin'), recursive=True)):
                if '_originals' not in f.split(os.sep):
                    yield f
        else:
            yield a


def check(paths, fix, backup):
    whole, chips, sets = load_lists()
    counts = {}
    for f in files_of(paths):
        d = open(f, 'rb').read()
        h = sha1(d)
        swapped = d[HALF:] + d[:HALF] if len(d) == 2 * HALF else None
        if h in KNOWN_HIGH_FIRST:
            st, note = 'REVERSED', f"{KNOWN_HIGH_FIRST[h]}: MAME's own file has the chips HIGH first"
            if fix:
                b = backup_and_write(f, swapped, backup)
                st, note = 'FIXED', f'{KNOWN_HIGH_FIRST[h]}: rewritten LOW first (original: {b})'
        elif swapped and sha1(swapped) in KNOWN_HIGH_FIRST:
            st, note = 'OK', f'{KNOWN_HIGH_FIRST[sha1(swapped)]} (chips swapped into order)'
        elif h in whole:
            st, note = 'OK', whole[h]
            if swapped:
                st, note = 'CHECK', f'{whole[h]}: MAME lists it as one 16 MB file, chip order not verified'
        elif len(d) == 2 * HALF:
            lo, hi = chips.get(sha1(d[:HALF])), chips.get(sha1(d[HALF:]))
            if lo and hi and lo[0] == hi[0]:
                if lo[1] == 0 and hi[1] == HALF:
                    st, note = 'OK', f'{lo[0]} (two chips, MAME order)'
                elif lo[1] == HALF and hi[1] == 0:
                    st, note = 'REVERSED', f'{lo[0]}: chips in reverse order'
                    if fix:
                        b = backup_and_write(f, d[HALF:] + d[:HALF], backup)
                        st, note = 'FIXED', f'{lo[0]}: rewritten in MAME order (original: {b})'
                else:
                    st, note = 'CHECK', f'{lo[0]}: unexpected chip offsets'
            else:
                st, note = 'CHECK', '16 MB, not in MAME\'s lists: chip order cannot be verified'
        else:
            st, note = 'UNLISTED', 'not in MAME\'s lists'
            # a multi-chip set joined into one file (check_carts.py --join)
            for (lst, name), (desc, roms, area) in sets.items():
                if len(roms) > 1 and area == len(d) and all(
                        sha1(d[off:off + sz]) == sh for off, sz, sh, _ in roms):
                    st, note = 'OK', f'{name} ({len(roms)} chips, MAME layout)'
                    break
        counts[st] = counts.get(st, 0) + 1
        if st != 'OK':
            print(f'{st:9s} {os.path.relpath(f)}  - {note}')
    print('summary:', ', '.join(f'{k} {v}' for k, v in sorted(counts.items())))


def swap(paths, backup):
    for f in paths:
        d = open(f, 'rb').read()
        if len(d) != 2 * HALF:
            print(f'skipped (not 16 MB): {f}')
            continue
        b = backup_and_write(f, d[HALF:] + d[:HALF], backup)
        print(f'swapped halves: {f} (original: {b})')


def join(out, inputs):
    whole, chips, sets = load_lists()
    data = {}
    for i in inputs:
        if i.lower().endswith('.zip'):
            z = zipfile.ZipFile(i)
            for n in z.namelist():
                b = z.read(n)
                data[sha1(b)] = b
        else:
            b = open(i, 'rb').read()
            data[sha1(b)] = b
    for (lst, name), (desc, roms, area) in sets.items():
        if len(roms) > 1 and all(r[2] in data for r in roms):
            size = max([area] + [off + sz for off, sz, _, _ in roms])
            img = bytearray(size)
            for off, sz, sh, _ in roms:
                img[off:off + sz] = data[sh]
            open(out, 'wb').write(img)
            print(f'{name} ({desc}): {len(roms)} chips -> {out}')
            return
    sys.exit('no two-chip MAME set in this zip matches the software lists')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--fix', action='store_true')
    p.add_argument('--swap', action='store_true')
    p.add_argument('--join', metavar='OUT.bin')
    p.add_argument('--backup')
    p.add_argument('paths', nargs='*')
    a = p.parse_args()
    if a.join:
        join(a.join, a.paths)
    elif a.swap:
        swap(a.paths, a.backup)
    else:
        check(a.paths or [os.path.join(HERE, 'ROMS')], a.fix, a.backup)


if __name__ == '__main__':
    main()
