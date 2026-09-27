-- Feature census for one V.Smile cart in MAME (see scripts/feature_census.sh).
-- Records which video/audio/I/O modes the game actually uses while it runs,
-- with a fixed button script to get past title screens.  Writes one line per
-- distinct feature to $CENSUS_OUT.
local cpu   = manager.machine.devices[":maincpu"]
local space = cpu.spaces["program"]
local out   = io.open(os.getenv("CENSUS_OUT"), "w")

local seen = {}
local frame = 0
-- one line per feature: "<feature>\t@<first frame>"
local function note(k)
    if not seen[k] then
        seen[k] = true
        out:write(k, "\t@", frame, "\n")
        out:flush()
    end
end

-- video register shadow (writes only; the renderer reads the same values)
local vr = {}
for i = 0, 255 do vr[i] = 0 end
vr[0x3c] = 0x20
vr[0x42] = 0x01
taps = {}
taps[#taps + 1] = space:install_write_tap(0x2800, 0x28ff, "cen_v", function(offset, data, mask)
    vr[offset - 0x2800] = data
end)

-- audio: channel MODE (ch*16+1) and ADPCM_SEL (ch*16+0xd) writes
taps[#taps + 1] = space:install_write_tap(0x3000, 0x31ff, "cen_a", function(offset, data, mask)
    local r = (offset - 0x3000) & 0xf
    if r == 1 then
        note(string.format("audio mode adpcm=%d pcm16=%d tone=%d",
            (data >> 15) & 1, (data >> 14) & 1, (data >> 12) & 3))
    elseif r == 0xd then
        note(string.format("audio adpcm36=%d", (data >> 15) & 1))
    end
end)
taps[#taps + 1] = space:install_write_tap(0x3200, 0x37ff, "cen_a2", function(offset, data, mask)
    note(string.format("audio reg %04X", offset & 0xfff0))
end)

-- I/O and DMA registers touched
taps[#taps + 1] = space:install_write_tap(0x3d00, 0x3eff, "cen_iow", function(offset, data, mask)
    note(string.format("io write %04X", offset))
end)
taps[#taps + 1] = space:install_read_tap(0x3d00, 0x3eff, "cen_ior", function(offset, data, mask)
    note(string.format("io read %04X", offset))
end)


local function bpp(attr) return ((attr & 3) + 1) * 2 end

local function page(p)
    local attr, ctrl = vr[0x12 + 6 * p], vr[0x13 + 6 * p]
    if (ctrl & 0x0008) == 0 then return end
    local flags = {}
    if ctrl & 0x0001 ~= 0 then flags[#flags + 1] = "LINEMAP" end
    if ctrl & 0x0002 ~= 0 then flags[#flags + 1] = "regattr" else flags[#flags + 1] = "exattr" end
    if ctrl & 0x0004 ~= 0 then flags[#flags + 1] = "wallpaper" end
    if ctrl & 0x0010 ~= 0 then flags[#flags + 1] = "rowscroll" end
    if ctrl & 0x0040 ~= 0 then flags[#flags + 1] = "VCMP" end
    if ctrl & 0x0080 ~= 0 then flags[#flags + 1] = "HICOLOR" end
    if ctrl & 0x0100 ~= 0 then flags[#flags + 1] = "blend" end
    note(string.format("page bpp=%d tile=%dx%d %s", bpp(attr), 8 << ((attr >> 4) & 3),
        8 << ((attr >> 6) & 3), table.concat(flags, ",")))
    if ctrl & 0x0001 == 0 then
        local tm = vr[0x14 + 6 * p]
        note("page tilemap in " .. ((tm < 0x2800) and "RAM" or "other"))
    end
end

local function sprites()
    if (vr[0x42] & 1) == 0 then return end
    note(string.format("sprite ctrl42=%04X", vr[0x42]))
    for i = 0, 255 do
        local b = 0x2c00 + i * 4
        local tile = space:read_u16(b)
        if tile ~= 0 then
            local attr = space:read_u16(b + 3)
            local f = {}
            if attr & 0x4000 ~= 0 then f[#f + 1] = "blend" end
            if attr & 0x0004 ~= 0 then f[#f + 1] = "flipx" end
            if attr & 0x0008 ~= 0 then f[#f + 1] = "flipy" end
            note(string.format("sprite bpp=%d size=%dx%d %s", bpp(attr), 8 << ((attr >> 4) & 3),
                8 << ((attr >> 6) & 3), table.concat(f, ",")))
        end
    end
end

-- button script: an OK every 3 s, directions in between, cycling
local ports = {}
for tag, port in pairs(manager.machine.ioport.ports) do
    if tag:find("JOY$") then ports.joy = port end
    if tag:find("BUTTONS$") then ports.buttons = port end
    if tag:find("COLORS$") then ports.colors = port end
end
local script = {
    {"buttons", "OK"}, {"joy", "Joypad Right"}, {"buttons", "OK"}, {"joy", "Joypad Down"},
    {"buttons", "OK"}, {"colors", "Green"}, {"joy", "Joypad Left"}, {"buttons", "OK"},
    {"colors", "Red"}, {"joy", "Joypad Up"}, {"buttons", "OK"}, {"colors", "Blue"},
    {"buttons", "OK"}, {"colors", "Yellow"}, {"buttons", "ABC"}, {"buttons", "OK"},
}
local held = nil
emu.register_frame_done(function()
    frame = frame + 1
    page(0)
    page(1)
    if frame % 6 == 0 then sprites() end
    note(string.format("blendlevel=%d", vr[0x2a] & 3))
    if vr[0x30] ~= 0 then note("fade used") end
    if (vr[0x3c] & 0xff) ~= 0x20 then note(string.format("SATURATION %02X", vr[0x3c] & 0xff)) end
    -- input
    if held and frame % 90 == 8 then held:set_value(0); held = nil end
    if frame > 300 and frame % 90 == 0 then
        local s = script[((frame // 90) % #script) + 1]
        local p = ports[s[1]]
        if p and p.fields[s[2]] then held = p.fields[s[2]]; held:set_value(1) end
    end
end)

stop_sub = emu.add_machine_stop_notifier(function()
    out:write(string.format("frames %d\n", frame))
    out:close()
end)
