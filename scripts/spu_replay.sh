#!/usr/bin/env bash
# Audio check against MAME: run a cart in a MAME built with the SPU_DUMP hook
# (src/devices/machine/spg2xx_audio.cpp) with the v102 system ROM and the
# census button script, then replay MAME's SPU register writes into
# rtl/spg2xx/spg2xx_spu.sv alone (sim/spu) and compare every output sample.
#
#   MAME=<patched binary> scripts/spu_replay.sh <outdir> <seconds> <cart.bin>...
#
# Per cart: <outdir>/<name>.txt with the replay summary.  Differences of 1
# are MAME's floating-point interpolation factor; "off by more than 1" is
# the number that matters.
here=$(cd "$(dirname "$0")/.." && pwd)
secs=$2
[ $# -gt 2 ] || { echo "usage: $0 <outdir> <seconds> <cart.bin>..."; exit 1; }
mkdir -p "$1"; out=$(cd "$1" && pwd); shift 2
make -s -C "$here/sim/spu" >/dev/null || exit 1
rompath="$here/roms/mame"
run() {
    local c name
    c=$(realpath "$1")
    name=$(basename "$c" .bin | tr -cd 'A-Za-z0-9()_ -' | tr ' ' '_')
    [ -s "$out/$name.txt" ] && return
    ( cd "$out" && SPU_DUMP="$out/$name" CENSUS_OUT=/dev/null timeout -s KILL $((secs * 3 + 120)) \
        env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        "${MAME:-mame}" vsmile -bios 1 -rompath "$rompath" -cart "$c" \
        -video none -sound none -nothrottle -window -noreadconfig -skip_gameinfo \
        -seconds_to_run "$secs" -autoboot_script "$here/scripts/census.lua" > "$out/$name.mame.log" 2>&1 )
    BIOS="$here/roms/bios/vsmile_v102.bin" "$here/sim/spu/obj_dir/Vspg2xx_spu" "$c" "$out/$name" \
        > "$out/$name.txt" 2>/dev/null
    echo "$(basename "$c"): $(cat "$out/$name.txt")"
    rm -f "$out/$name.s" "$out/$name.w" "$out/$name.c"
}
export -f run; export out secs rompath here MAME
printf '%s\0' "$@" | xargs -0 -P "$(nproc)" -I{} bash -c 'run "$@"' _ {}
