-- Scripted V.Smile Gym Mat steps for MAME traces (scripts/mame_trace.sh with
-- MAME_CTRL1=mat TRACE_INPUT=this file).  From frame $MAT_START (default
-- 360), every $MAT_EVERY frames (default 30) one square of the list is held
-- for 8 frames, then two squares at once.  Events go to $KBD_LOG in the
-- testbench's KBD_EVENTS format, as the core's pad inputs the square maps to
-- (rtl/vsmile.sv): row 8 d-pad (col 0 up, 1 down, 2 left, 3 right), row 9
-- colours (0 green, 1 blue, 2 yellow, 3 red), row 5 buttons (0 OK, 1 Quit,
-- 2 Help, 3 ABC = Centre); MAME applies a port change at its next frame
-- update, so each event is logged one frame later with that frame's
-- emulated time (the testbench applies timed events at that clock).
local steps = {                 -- {MAME port, bit}
    {"JOY", 0}, {"JOY", 1}, {"JOY", 2}, {"JOY", 3},              -- yellow right red left
    {"COLORS", 0}, {"COLORS", 1}, {"COLORS", 2}, {"COLORS", 3},  -- centre up down green
    {"BUTTONS", 0}, {"BUTTONS", 3}, {"BUTTONS", 2}, {"BUTTONS", 1},  -- ok blue help quit
    {"JOY", 0, "JOY", 3}, {"COLORS", 1, "BUTTONS", 3},           -- two at once
}
-- MAME mat port bit -> core pad input {row, col}
local core = {
    JOY     = { [0] = {9, 2}, [1] = {8, 3}, [2] = {9, 3}, [3] = {8, 2} },
    COLORS  = { [0] = {5, 3}, [1] = {8, 0}, [2] = {8, 1}, [3] = {9, 0} },
    BUTTONS = { [0] = {5, 0}, [1] = {5, 1}, [2] = {5, 2}, [3] = {9, 1} },
}
local klog = io.open(os.getenv("KBD_LOG") or "/dev/null", "w")
local ports = {}
for tag, port in pairs(manager.machine.ioport.ports) do
    for _, n in ipairs({"JOY", "COLORS", "BUTTONS"}) do
        if tag:find(":ctrl1:.*:" .. n .. "$") then ports[n] = port end
    end
end
local function field(p, bit)
    for _, f in pairs(ports[p].fields) do
        if f.mask == (1 << bit) then return f end
    end
end
local START = tonumber(os.getenv("MAT_START") or "360")
local EVERY = tonumber(os.getenv("MAT_EVERY") or "30")
local held, idx, fr = {}, 1, 0
local pending = {}
local function logev(p, bit, down)
    local c = core[p][bit]
    pending[#pending + 1] = string.format("%d %d %d %d", fr, c[1], c[2], down)
end
mat_sub = emu.add_machine_frame_notifier(function()
    fr = fr + 1
    local t = manager.machine.time:as_double()
    for _, p in ipairs(pending) do klog:write(p .. string.format(" %.9f\n", t)) end
    if #pending > 0 then klog:flush() end
    pending = {}
    if #held > 0 and fr == held.at then
        for _, h in ipairs(held) do h.f:set_value(0); logev(h.p, h.bit, 0) end
        held = {}
    end
    if fr >= START and (fr - START) % EVERY == 0 and idx <= #steps then
        local s = steps[idx]; idx = idx + 1
        held = {at = fr + 8}
        for i = 1, #s, 2 do
            local f = field(s[i], s[i + 1])
            f:set_value(1)
            held[#held + 1] = {f = f, p = s[i], bit = s[i + 1]}
            logev(s[i], s[i + 1], 1)
        end
    end
end)
