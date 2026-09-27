-- BIOS usage survey for one V.Smile cart in MAME (see scripts/bios_survey.sh).
-- Runs census.lua (button script; its feature log goes to $CENSUS_OUT) and
-- records every access into the system ROM window: 0x300000-0x3FFFFF while
-- the chip select mode maps it there (REG_EXT_MEMORY_CTRL 0x3D23 bits 7:6 =
-- 2 or 3).  An access at the current PC is a code fetch, anything else is
-- data (CPU data reads, SPU sample reads, DMA).  At the end $BIOS_OUT gets:
--   code <start> <end>   word ranges of BIOS code executed (offsets, merged)
--   data <start> <end>   word ranges of BIOS data read
--   entry <offset>       first fetch of each new stretch of BIOS code (a
--                        jump or call target from outside what ran before)
dofile(os.getenv("CENSUS_LUA"))

-- BIOS_NO_INTRO=1: switch the region DIP's "VTech Intro" off (the carts play
-- the intro themselves, from system ROM assets)
if os.getenv("BIOS_NO_INTRO") then
    local f = manager.machine.ioport.ports[":REGION"].fields["VTech Intro"]
    f.user_value = 0
end

local cpu   = manager.machine.devices[":maincpu"]
local space = cpu.spaces["program"]
local bout  = io.open(os.getenv("BIOS_OUT"), "w")

local code, data, entries = {}, {}, {}
local last_code = nil

local function pc()
    local p = cpu.state["PC"].value
    if p < 0x10000 then p = p | ((cpu.state["SR"].value & 0x3f) << 16) end
    return p
end

local function on_read(offset, value, mask)
    local o = offset - 0x300000
    if offset == pc() then
        if not code[o] and (last_code == nil or o < last_code - 64 or o > last_code + 64) then
            entries[o] = true
        end
        last_code = o
        code[o] = true
    else
        data[o] = true
    end
end

local bios_tap = nil
local function map(cs)
    local want = (cs == 2 or cs == 3)
    if want and not bios_tap then
        bios_tap = space:install_read_tap(0x300000, 0x3fffff, "bios_rd", on_read)
    elseif not want and bios_tap then
        bios_tap:remove(); bios_tap = nil
    end
end
cs_tap = space:install_write_tap(0x3d23, 0x3d23, "bios_cs", function(offset, v, mask)
    map((v >> 6) & 3)
end)

local function ranges(set)
    local keys = {}
    for k in pairs(set) do keys[#keys + 1] = k end
    table.sort(keys)
    local r, s, e = {}, nil, nil
    for _, k in ipairs(keys) do
        if s and k <= e + 8 then e = k
        else
            if s then r[#r + 1] = {s, e} end
            s, e = k, k
        end
    end
    if s then r[#r + 1] = {s, e} end
    return r
end

bios_stop = emu.add_machine_stop_notifier(function()
    for _, r in ipairs(ranges(code)) do bout:write(string.format("code %05X %05X\n", r[1], r[2])) end
    for _, r in ipairs(ranges(data)) do bout:write(string.format("data %05X %05X\n", r[1], r[2])) end
    local es = {}
    for k in pairs(entries) do es[#es + 1] = k end
    table.sort(es)
    for _, k in ipairs(es) do bout:write(string.format("entry %05X\n", k)) end
    bout:close()
end)
