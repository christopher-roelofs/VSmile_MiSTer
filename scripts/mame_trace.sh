#!/usr/bin/env bash
# Capture a MAME golden trace of the V.Smile CPU for diffing against the RTL.
#
#   scripts/mame_trace.sh <cart.bin> <outdir> [seconds]
#
# Produces in <outdir>:
#   cpu.tr   one line per instruction: "PC: R1 R2 R3 R4 SP BP SR <disasm>"
#            (registers are the state *before* the instruction executes),
#            with "(interrupted at PC, IRQ n)" markers where MAME took an IRQ
#   mem.log  every access to the SoC register ranges (video 0x28xx, audio
#            0x30xx-0x37xx, I/O + DMA 0x3Dxx-0x3Exx), in program order:
#            "R|W addr data"; the testbench replays register reads from this
#            log so the CPU can be verified before any peripheral exists.
#
# MAME=path selects the MAME binary (default: `mame` on PATH).  The trace
# must come from the same MAME revision as ref/mame (see MAME_REVISION):
# 0.264's SPU differs from current git in channel start/stop semantics.
#
# MAME needs a system ROM to start even though the cart boots directly (the
# cart is banked over the BIOS at reset), so a 0xFF-filled placeholder is
# created if the real vsmile_v103.bin is not present.
set -euo pipefail

cart=$(realpath "$1")
out=$(realpath -m "$2")
secs=${3:-1}

here=$(cd "$(dirname "$0")/.." && pwd)
rompath="$here/roms/mame"
mkdir -p "$out" "$rompath/vsmile"
echo "$cart" > "$out/cart"
"${MAME:-mame}" -version > "$out/mame_version" 2>/dev/null || true
if [ ! -f "$rompath/vsmile/vsmile_v103.bin" ]; then
    head -c 2097152 /dev/zero | tr '\0' '\377' > "$rompath/vsmile/vsmile_v103.bin"
fi

cat > "$out/trace.lua" <<EOF
local cpu   = manager.machine.devices[":maincpu"]
local space = cpu.spaces["program"]
local log   = io.open("$out/mem.log", "w")

-- Only SoC *register* ranges are logged: RAM (incl. palette/sprite/scroll
-- RAM) is also read by the video renderer at arbitrary times, so the
-- testbench models RAM itself.  Tap handles must stay referenced.
local ranges = { {0x2800, 0x28ff}, {0x3000, 0x37ff}, {0x3d00, 0x3eff} }
taps = {}
for i, r in ipairs(ranges) do
    taps[#taps + 1] = space:install_read_tap(r[1], r[2], "trace_rd" .. i, function(offset, data, mask)
        log:write(string.format("R %04X %04X\n", offset, data))
    end)
    taps[#taps + 1] = space:install_write_tap(r[1], r[2], "trace_wr" .. i, function(offset, data, mask)
        log:write(string.format("W %04X %04X\n", offset, data))
    end)
end

manager.machine.debugger:command('trace $out/cpu.tr,maincpu,noloop,{tracelog "%04X %04X %04X %04X %04X %04X %04X ",r1,r2,r3,r4,sp,bp,sr}')
manager.machine.debugger.execution_state = "run"
EOF

cd "$out"
timeout -s KILL "${TRACE_TIMEOUT:-300}" env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
"${MAME:-mame}" vsmile -rompath "$rompath" -cart "$cart" ${MAME_BIOS:+-bios "$MAME_BIOS"} \
    -video none -sound none -nothrottle -window -noreadconfig -skip_gameinfo \
    -seconds_to_run "$secs" \
    -debug -debugger none -autoboot_script "$out/trace.lua" \
    > "$out/mame.log" 2>&1 || true

echo "$(grep -c '' "$out/cpu.tr") trace lines, $(grep -c '' "$out/mem.log") memory accesses -> $out"
