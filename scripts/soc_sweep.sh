#!/usr/bin/env bash
# Run the V.Smile SoC lockstep testbench over captured trace directories,
# in parallel, and summarise: PASS/FAIL plus SoC registers whose RTL value
# disagreed with MAME (audio 0x3000-0x37FF excluded until the SPU exists).
#
#   scripts/soc_sweep.sh <trace dir>...
here=$(cd "$(dirname "$0")/.." && pwd)
make -s -C "$here/sim/soc" >/dev/null || exit 1
tmp=$(mktemp -d)
for d in "$@"; do
    ( "$here/sim/soc/obj_dir/Vvsmile" "$(cat "$d/cart")" "$d" > "$tmp/$(basename "$d").out" 2>&1 ) &
    while [ "$(jobs -r | wc -l)" -ge "$(nproc)" ]; do sleep 1; done
done
wait
pass=0; fail=0
for d in "$@"; do
    o="$tmp/$(basename "$d").out"
    name=$(basename "$(cat "$d/cart")" .bin)
    if grep -q '^LOCKSTEP' "$o" && ! grep -q 'MISMATCH' "$o"; then
        pass=$((pass + 1)); printf 'PASS  %-58s %s\n' "$name" "$(grep '^LOCKSTEP' "$o" | cut -d' ' -f2-)"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n' "$name"; grep -A4 'MISMATCH\|illegal' "$o" | sed 's/^/      /'
    fi
    awk '/^SoC register reads/{f=1;next} f && $1 ~ /^[0-9A-F]{4}$/ && $1 !~ /^3[0-7]/ && $3 != "-" {print "      reg " $0}' "$o"
done
rm -rf "$tmp"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
