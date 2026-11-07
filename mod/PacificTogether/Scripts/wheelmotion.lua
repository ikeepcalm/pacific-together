-- Fixed-delay snapshot clock adapted from MultiVoid active_drive.h, revision 4fbf1acf.
-- Copyright (c) 2026 pelmentor and Multivoid contributors; MIT, see ../MULTIVOID-LICENSE.txt.
-- Rolling is an unwrapped scalar phase, separate from steering: quaternion shortest paths alias full wheel turns.
local M = {}
local TAU = 2 * math.pi
function M.push(buffer, snapshot)
    local last = buffer[#buffer]
    if last and snapshot.t <= last.t then return false end
    if last then
        local dt = snapshot.t - last.t
        for i, wheel in pairs(snapshot.wheels) do
            local previous = last.wheels[i]
            if previous then
                local expected = previous.phase + (previous.omega + wheel.omega) * dt / 2
                wheel.phase = wheel.phase + TAU * math.floor((expected - wheel.phase) / TAU + 0.5)
            end
        end
    end
    local offset = snapshot.at - snapshot.t
    buffer.offset = buffer.offset and math.min(buffer.offset, offset) or offset
    buffer[#buffer + 1] = snapshot
    while #buffer > 8 do table.remove(buffer, 1) end
    return true
end
function M.sample(buffer, now)
    local last = buffer[#buffer]
    if not last then return end
    if os.getenv("PT_MUTATE")=="oldwheelclock" then return last,last,0,0 end
    -- Packet jitter must not reset or reverse the render clock. The car body also renders about 100 ms behind.
    local render = now - buffer.offset - 0.1
    for i = 2, #buffer do
        local a, b = buffer[i - 1], buffer[i]
        if render <= b.t then return a, b, math.max(0, math.min(1, (render - a.t) / (b.t - a.t))), 0 end
    end
    return last, last, 1, math.min(0.1, math.max(0, render - last.t))
end
function M.phase(a, b, u, extrapolate)
    return a.phase + (b.phase - a.phase) * u + b.omega * extrapolate
end
return M
