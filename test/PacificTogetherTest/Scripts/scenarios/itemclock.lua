-- Exercise the shipping item render clock with regular and jittered packet arrival.
return function(T)
    local M = assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/itemmotion.lua"))()
    local checks = { T.onMap("RB_MainMenu", 90) }
    local function add(name, fn) checks[#checks + 1] = { check = name, timeout = 1, cond = fn } end
    local function p(x) return { X = x, Y = 0, Z = 0 } end
    local r = { Pitch = 0, Yaw = 0, Roll = 0 }
    local function sample(b, t)
        local a, z, u = M.sample(b, t)
        return a.p.X + (z.p.X - a.p.X) * u
    end
    for _, fps in ipairs({30, 60, 144}) do
        add("jittered_motion_" .. fps, function()
            local b, nextPose, previous, moving, frames = {}, 0, nil, 0, 0
            for frame = 0, fps * 3 do
                local now = frame / fps
                while nextPose <= 60 and nextPose * .05 + (nextPose % 3) * .012 <= now do
                    local t = nextPose * .05 + (nextPose % 3) * .012
                    M.push(b, p(nextPose * 5), r, t, p(previous or 0), r)
                    nextPose = nextPose + 1
                end
                if #b > 0 then
                    local x = sample(b, now)
                    if previous and now > .3 and now < 2.8 then
                        if x < previous - .001 then return false end
                        frames = frames + 1
                        if x - previous > .001 then moving = moving + 1 end
                    end
                    previous = x
                end
            end
            return frames > 0 and moving / frames > .8
        end)
    end
    add("stops_at_last_pose", function()
        local b = {}; M.push(b, p(10), r, 1, p(0), r)
        return math.abs(sample(b, 5) - 10) < .001
    end)
    add("long_gap_starts_from_shown_pose", function()
        local b = {}; M.push(b, p(10), r, 1, p(0), r)
        M.push(b, p(30), r, 2, p(10), r)
        return math.abs(sample(b, 2) - 10) < .001 and math.abs(sample(b, 3) - 30) < .001
    end)
    return checks
end
