-- Scripted V.Smile Baby buttons for MAME traces (scripts/mame_trace.sh with
-- MAME_SYSTEM=vsmileb TRACE_INPUT=this file).  From frame $BABY_START
-- (default 20), every $BABY_EVERY frames (default 12) one step of the list
-- runs: a button held for 6 frames, or a function switch move (MAME acts on
-- the key's release).  Events go to $KBD_LOG in the testbench's KBD_EVENTS
-- format: "<frame> 6 <button bit> <1|0> <time>" and "<frame> 7 <switch
-- position> 1 <time>"; MAME applies a port change at its next frame update,
-- so each event is logged one frame later with that frame's emulated time
-- (the testbench applies timed events at that clock).  For the SPG28x UART
-- rate MAME needs scripts/mame_spg28x_io.patch.
local steps = {
    {"b", 0}, {"b", 1}, {"b", 2}, {"b", 3}, {"b", 4}, {"b", 5}, {"b", 6}, {"b", 7},
    {"m", 1}, {"b", 3}, {"m", 2}, {"b", 0}, {"m", 0}, {"b", 4},
}
local klog = io.open(os.getenv("KBD_LOG") or "/dev/null", "w")
local ports = {}
for tag, port in pairs(manager.machine.ioport.ports) do
    if tag:find(":BUTTONS$") then ports.b = port end
    if tag:find(":MODE$") then ports.m = port end
end
local function field(p, bit)
    for _, f in pairs(ports[p].fields) do
        if f.mask == (1 << bit) then return f end
    end
end
local START = tonumber(os.getenv("BABY_START") or "20")
local EVERY = tonumber(os.getenv("BABY_EVERY") or "12")
local held, idx, fr = nil, 1, 0
local pending = {}
local function logev(fmt, ...) pending[#pending + 1] = string.format(fmt, ...) end
baby_sub = emu.add_machine_frame_notifier(function()
    fr = fr + 1
    local t = manager.machine.time:as_double()
    for _, p in ipairs(pending) do klog:write(p .. string.format(" %.9f\n", t)) end
    if #pending > 0 then klog:flush() end
    pending = {}
    if held and fr == held.at then
        held.f:set_value(0)
        if held.p == "b" then
            logev("%d 6 %d 0", fr, held.bit)
        else
            logev("%d 7 %d 1", fr, held.bit)
        end
        held = nil
    end
    if fr >= START and (fr - START) % EVERY == 0 and idx <= #steps then
        local s = steps[idx]; idx = idx + 1
        local f = field(s[1], s[2])
        f:set_value(1)
        held = {f = f, p = s[1], bit = s[2], at = fr + (s[1] == "b" and 6 or 2)}
        if s[1] == "b" then
            logev("%d 6 %d 1", fr, s[2])
        end
    end
end)
