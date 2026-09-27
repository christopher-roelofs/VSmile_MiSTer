#!/usr/bin/env bash
# Feature census: run every cart in MAME (headless, faster than real time)
# with a scripted button sequence and record which video, audio and I/O
# modes each game actually uses (scripts/census.lua).  Then summarise what
# the core does not implement and what the MAME lockstep traces have not
# exercised (scripts/census_report.py).
#
#   MAME=<0.289 binary> scripts/feature_census.sh <outdir> [seconds] [cart.bin...]
#
# Default: all of ROMS/*.bin (not ROMS/Baby), 120 s of game time each, one
# MAME per CPU.  Carts run with the v102 system ROM (some call into it).
here=$(cd "$(dirname "$0")/.." && pwd)
out=$1; secs=${2:-120}; shift 2 2>/dev/null
[ -n "$out" ] || { echo "usage: $0 <outdir> [seconds] [cart...]"; exit 1; }
mkdir -p "$out"
if [ $# -eq 0 ]; then set -- "$here"/ROMS/*.bin; fi
rompath="${ROMPATH:-$here/roms/mame}"     # ROMPATH=/ CENSUS_BIOS= for another system ROM
[ -f "$rompath/vsmile/vsmile_v102.bin" ] || cp "$here/roms/bios/vsmile_v102.bin" "$rompath/vsmile/"
[ -f "$rompath/vsmile/vsmile_v103.bin" ] || head -c 2097152 /dev/zero | tr '\0' '\377' > "$rompath/vsmile/vsmile_v103.bin"

run() {
    local c=$1 name
    name=$(basename "$c" .bin | tr -cd 'A-Za-z0-9()_ -' | tr ' ' '_')
    [ -s "$out/$name.txt" ] && return
    CENSUS_OUT="$out/$name.txt" timeout -s KILL $((secs * 2 + 120)) \
        env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        "${MAME:-mame}" vsmile -bios "${CENSUS_BIOS:-1}" -rompath "$rompath" -cart "$c" \
        -video none -sound none -nothrottle -window -noreadconfig -skip_gameinfo \
        -seconds_to_run "$secs" -autoboot_script "$here/scripts/census.lua" \
        > "$out/$name.log" 2>&1
    echo "$(basename "$c")" > "$out/$name.cart"
    echo "done $name ($(grep -c '' "$out/$name.txt" 2>/dev/null) features)"
}
export -f run; export out secs rompath here MAME CENSUS_BIOS
printf '%s\0' "$@" | xargs -0 -P "$(nproc)" -I{} bash -c 'run "$@"' _ {}
