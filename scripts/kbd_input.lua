-- Scripted typing on a V.Smile Smart Keyboard for MAME traces
-- (scripts/mame_trace.sh with MAME_CTRL1=smartkb_us TRACE_INPUT=this file).
-- From frame $KBD_START (default 360), every 30 frames one key of the list is held for 8 frames;
-- every event is logged to $KBD_LOG as "<frame> <row> <col> <1|0>" (matrix
-- position as in MAME's keyboard ROW0-4 ports, bit = column) so a testbench
-- can replay the same keys at the same frames.  Row 5 is the BUTTONS port
-- (col 0 OK, 1 Quit, 2 Help).
local keys = {
    {1, 1}, {1, 2}, {1, 3}, {1, 4}, {1, 5},      -- q w e r t
    {2, 1}, {2, 2}, {2, 3},                      -- a s d
    {0, 0}, {0, 1}, {0, 2},                      -- 1 2 3
    {3, 0}, {3, 1}, {3, 0},                      -- shift, z, shift
    {4, 2},                                      -- space
    {0, 11},                                     -- backspace
    {5, 0},                                      -- OK
    {4, 4}, {4, 6}, {3, 10}, {4, 5},             -- left right up down
    {1, 6}, {1, 7}, {5, 0},
}
local klog = io.open(os.getenv("KBD_LOG") or "/dev/null", "w")
local ports = {}
for tag, port in pairs(manager.machine.ioport.ports) do
    for r = 0, 4 do
        if tag:find(":ctrl1:.*:ROW" .. r .. "$") then ports[r] = port end
    end
    if tag:find(":ctrl1:.*:BUTTONS$") then ports[5] = port end
end
local function field(row, col)
    local p = ports[row]
    if not p then return nil end
    for _, f in pairs(p.fields) do
        if f.mask == (1 << col) then return f end
    end
end
local KBD_START = tonumber(os.getenv("KBD_START") or "360")
local held, idx = nil, 1
local fr = 0
kbd_sub = emu.add_machine_frame_notifier(function()
    fr = fr + 1
    if held and fr % 30 == 8 then
        held.f:set_value(0)
        klog:write(string.format("%d %d %d 0\n", fr, held.r, held.c)); klog:flush()
        held = nil
    end
    if fr >= KBD_START and fr % 30 == 0 and idx <= #keys then
        local k = keys[idx]; idx = idx + 1
        local f = field(k[1], k[2])
        if f then
            f:set_value(1)
            held = {f = f, r = k[1], c = k[2]}
            klog:write(string.format("%d %d %d 1\n", fr, k[1], k[2])); klog:flush()
        end
    end
end)
