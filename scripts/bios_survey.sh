#!/usr/bin/env bash
# BIOS usage survey: run every cart in MAME with the real v102 system ROM and
# the census button script, recording which parts of the system ROM each
# game executes or reads (scripts/bios_survey.lua); then summarise with
# scripts/bios_report.py.
#
#   MAME=<0.289 binary> scripts/bios_survey.sh <outdir> [seconds] [cart.bin...]
# BIOS_NO_INTRO=1 runs with the region DIP's VTech intro switched off.
# MAME_SYSTEM=vsmilem surveys the V.Smile Motion's system ROM instead
# (BIOS_INDEX: 0 vsmilemotion.bin, 1 vmotionbios.bin; default 0).
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$1"; out=$(cd "$1" && pwd); secs=${2:-60}; shift 2 2>/dev/null
if [ $# -eq 0 ]; then set -- "$here"/ROMS/*.bin; fi
rompath="$here/roms/mame"
run() {
    local c name
    c=$(realpath "$1")
    name=$(basename "$c" .bin | tr -cd 'A-Za-z0-9()_ -' | tr ' ' '_')
    [ -s "$out/$name.txt" ] && return
    ( cd "$out" && BIOS_OUT="$out/$name.txt" CENSUS_LUA="$here/scripts/census.lua" CENSUS_OUT=/dev/null \
        timeout -s KILL $((secs * 3 + 120)) env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        "${MAME:-mame}" "${MAME_SYSTEM:-vsmile}" -bios "${BIOS_INDEX:-$([ "${MAME_SYSTEM:-vsmile}" = vsmile ] && echo 1 || echo 0)}" -rompath "$rompath" -cart "$c" \
        -video none -sound none -nothrottle -window -noreadconfig -skip_gameinfo \
        -seconds_to_run "$secs" -autoboot_script "$here/scripts/bios_survey.lua" > "$out/$name.log" 2>&1 )
    basename "$c" > "$out/$name.cart"
    echo "done $name"
}
export -f run; export out secs rompath here MAME BIOS_NO_INTRO MAME_SYSTEM BIOS_INDEX
printf '%s\0' "$@" | xargs -0 -P "$(nproc)" -I{} bash -c 'run "$@"' _ {}
