-- Delayed snapshot interpolation, following MultiVoid active_drive (MIT; see ../MULTIVOID-LICENSE.txt).
local M = {}
local DELAY = 0.12

function M.push(b, p, r, now, currentP, currentR)
    local last = b[#b]
    if not last or now - last.t > 0.25 then
        for i = #b, 1, -1 do b[i] = nil end
        b[1] = { p = currentP, r = currentR, t = now - DELAY }
    end
    if b[#b].t >= now then b[#b] = nil end
    b[#b + 1] = { p = p, r = r, t = now }
    while #b > 8 do table.remove(b, 1) end
end

function M.pushTimed(b,p,r,source,received,currentP,currentR)
    b.clock=math.min(b.clock or math.huge,received-source)
    M.push(b,p,r,source,currentP,currentR)
end
function M.sample(b, now)
    if b.clock then now=now-b.clock end
    if #b == 0 then return end
    if os.getenv("PT_MUTATE") == "olditemclock" then return b[#b], b[#b], 1 end
    local t = now - DELAY
    while #b > 2 and b[2].t <= t do table.remove(b, 1) end
    if #b == 1 then return b[1], b[1], 1 end
    local a, z = b[1], b[2]
    return a, z, math.max(0, math.min(1, (t - a.t) / (z.t - a.t)))
end

return M
