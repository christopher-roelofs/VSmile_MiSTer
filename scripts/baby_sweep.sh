#!/usr/bin/env bash
# V.Smile Baby sweep: for each cart, capture a MAME vsmileb trace (no input:
# boot + attract), gzip it, and run the SoC lockstep testbench on it (BABY=1)
# while the next capture runs.  Captures run one at a time (parallel MAME
# traces are slow enough to hit the timeout).  Then a summary like
# scripts/soc_sweep.sh.  MAME 0.264 is fine without input: CPU, video and
# interrupts; button input needs scripts/mame_spg28x_io.patch.
#
#   scripts/baby_sweep.sh <outdir> <seconds> <cart>...
here=$(cd "$(dirname "$0")/.." && pwd)
out=$(realpath -m "$1"); secs=$2; shift 2
make -s -C "$here/sim/soc" >/dev/null || exit 1
mkdir -p "$out"
for c in "$@"; do
    name=$(basename "$c" | sed 's/\.[^.]*$//' | tr -cd 'A-Za-z0-9()_ -' | tr ' ' '_')
    d="$out/$name"
    if [ ! -f "$d/cpu.tr.gz" ]; then
        MAME_SYSTEM=vsmileb TRACE_TIMEOUT=${TRACE_TIMEOUT:-1200} "$here/scripts/mame_trace.sh" "$c" "$d" "$secs" >/dev/null 2>&1
        gzip -1 "$d/cpu.tr"
    fi
    ( BABY=1 "$here/sim/soc/obj_dir/Vvsmile" "$c" "$d" > "$d.out" 2>&1; echo "done $name" ) &
done
wait
pass=0; fail=0
for c in "$@"; do
    name=$(basename "$c" | sed 's/\.[^.]*$//' | tr -cd 'A-Za-z0-9()_ -' | tr ' ' '_')
    o="$out/$name.out"
    if grep -q '^LOCKSTEP' "$o" && ! grep -q 'MISMATCH' "$o"; then
        pass=$((pass + 1)); printf 'PASS  %-58s %s\n' "$name" "$(grep '^LOCKSTEP' "$o" | cut -d' ' -f2-)"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n' "$name"; grep -A4 'MISMATCH\|illegal' "$o" | sed 's/^/      /'
    fi
    grep '^video:' "$o" | sed 's/^/      /'
    awk '/^interrupts taken/{f=1;next} f && /^  IRQ/ && $(NF-1) != $NF {print "      " $0} /^SoC/{f=0}' "$o"
done
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
