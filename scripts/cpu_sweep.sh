#!/usr/bin/env bash
# Run the CPU lockstep testbench over every captured trace directory.
#
#   scripts/cpu_sweep.sh <trace dir>...
#
# Each trace dir must contain cpu.tr, mem.log and `cart` (the cart path,
# written by mame_trace.sh).
here=$(cd "$(dirname "$0")/.." && pwd)
make -s -C "$here/sim/cpu" >/dev/null || exit 1
pass=0; fail=0
for d in "$@"; do
    cart=$(cat "$d/cart")
    out=$("$here/sim/cpu/obj_dir/Vunsp_core" "$cart" "$d" 2>&1)
    if grep -q '^PASS' <<<"$out"; then
        pass=$((pass + 1)); printf 'PASS  %-60s %s\n' "$(basename "$cart" .bin)" "$(grep '^PASS' <<<"$out" | cut -d' ' -f2-3)"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n' "$(basename "$cart" .bin)"; grep -A4 'MISMATCH\|exhausted' <<<"$out" | sed 's/^/      /'
    fi
done
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
