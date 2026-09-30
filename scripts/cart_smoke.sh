#!/usr/bin/env bash
# Free-run each cart for N instructions (default 20M, ~3 s of game time) in
# the system testbench and report: illegal opcodes, renderer overruns, and
# whether the last dumped frame has any picture.  Frames go to <out>/<cart>/.
#
#   scripts/cart_smoke.sh <outdir> <any trace dir> <cart.bin>...
here=$(cd "$(dirname "$0")/.." && pwd)
out=$1; tr=$2; shift 2
N=${N:-20000000}
make -s -C "$here/sim/soc" >/dev/null || exit 1
mkdir -p "$out"
run() {
    local c=$1 name d
    name=$(basename "$c" .bin | tr -cd 'A-Za-z0-9()_ -' | tr ' ' '_')
    d="$out/$name"; mkdir -p "$d"
    ON_BUTTON=1 FREERUN=1 DUMP="$d" FRAMES=60 timeout 1800 "$here/sim/soc/obj_dir/Vvsmile" "$c" "$tr" "$N" > "$d/log.txt" 2>&1
    python3 - "$d" "$c" <<'P'
import sys, glob, os
d, c = sys.argv[1], sys.argv[2]
log = open(os.path.join(d, 'log.txt')).read()
fr = sorted(glob.glob(os.path.join(d, 'rtl_*.ppm')))
def lit(p):
    b = open(p, 'rb').read().split(b'\n', 3)[3]
    return sum(1 for i in range(0, len(b), 3) if b[i] | b[i+1] | b[i+2]) * 100 // (len(b) // 3)
last = lit(fr[-1]) if fr else -1
ill = 'illegal' in log
ov = [l for l in log.splitlines() if l.startswith('video:')]
ov = ov[0].split(',')[-1].strip() if ov else '?'
st = 'OK  ' if (not ill and last > 5) else 'FAIL'
print(f"{st} {os.path.basename(c)[:62]:62s} frames={len(fr):3d} lit%={last:3d} {'ILLEGAL ' if ill else ''}{ov}")
P
}
export -f run; export here out tr N
printf '%s\0' "$@" | xargs -0 -P "$(nproc)" -I{} bash -c 'run "$@"' _ {}
