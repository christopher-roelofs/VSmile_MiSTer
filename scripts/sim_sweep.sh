#!/usr/bin/env bash
# Simulator sweep: run the carts of a sweep plan (scripts/sweep_select.py)
# free-running with the v102 system ROM and census.lua's button script, every
# scanline compared with the reference renderer.  Per cart, in <outdir>:
#   <name>.log   testbench output ("video:" summary, differing frames)
#   <name>.feat  video features the RTL actually used (first frame each)
#   <name>/      rtl/ref images of the first frames with differing lines
# Then scripts/sweep_report.py summarises.
#
#   scripts/sim_sweep.sh <plan.tsv> <outdir> <any trace dir>
here=$(cd "$(dirname "$0")/.." && pwd)
plan=$1; out=$2; tr=$3
[ -n "$tr" ] || { echo "usage: $0 <plan.tsv> <outdir> <trace dir>"; exit 1; }
make -s -C "$here/sim/soc" >/dev/null || exit 1
mkdir -p "$out"
run() {
    local c=$1 frames=$2 name
    name=$(basename "$c" .bin | tr -cd 'A-Za-z0-9()_ -' | tr ' ' '_')
    mkdir -p "$out/$name"
    FREERUN=1 BIOS="$here/roms/bios/vsmile_v102.bin" SWEEP_INPUT=1 SWEEP_FRAMES="$frames" \
        CENSUS_OUT="$out/$name.feat" DUMP_BAD="$out/$name" \
        "$here/sim/soc/obj_dir/Vvsmile" "$c" "$tr" 4000000000 > "$out/$name.log" 2>&1
    echo "$c" > "$out/$name.cart"
    echo "done $name: $(grep '^video:' "$out/$name.log" | cut -d, -f1-2)"
}
export -f run; export out tr here
cut -f1,2 "$plan" | tr '\t' '\n' | tr '\n' '\0' | xargs -0 -n 2 -P "$(nproc)" bash -c 'run "$@"' _
