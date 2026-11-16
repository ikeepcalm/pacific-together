-- Guest garage rear door (owner 2026-11-16): the host presses the rear door button; the guest's door must travel over several
-- frames (not snap) and play the garage door's start/stop sounds (pro_garageDoor_*), closing and opening.
-- Run: tools/run-test.ps1 -Scenario guestgarage -Fixture garage -Headless
-- Mutation nogaragedoorvisual: the guest's door is driven as before (position only, no door sounds).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function real(o) return alive(o) and not o:GetFullName():find("/Engine/Transient", 1, true) end
    local function door()
        for _, d in ipairs(FindAllOf("BP_GarageDoor_C") or {}) do
            if real(d) and not d.IsFrontGarageDoor then return d end
        end
    end
    local function pos() local d = door(); return d and d.CurrentDoorPosition or -1 end
    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind]
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ check = "host_rear_door_open_at_start", timeout = 40, cond = function() return pos() > 0.99 end })
        add({ wait = 10 })
        for _, key in ipairs({ "close", "open" }) do
            add({ run = function() toGuest("t.rec", key) end })
            add({ wait = 1.5 })
            add({ run = function()
                local b = T.first("BP_BackDoorButton_01_C")
                b.Highlight:InteractPressed(nil)
                b.Highlight:InteractReleased(nil)
            end })
            add({ check = "guest_reported_" .. key, timeout = 60, cond = function() return has("t.res_" .. key) ~= nil end })
            add({ run = function()
                local frames, step, last, snd = got["t.res_" .. key]:match("^(%d+)|([%d.]+)|([%d.]+)|(%d+)$")
                log("PT|info %s: guest door position changed on %s frames, biggest frame step %s, ends at %s, sounds %s", key, frames, step, last, snd)
            end })
            add({ check = "guest_door_" .. key .. "_over_frames", timeout = 2, cond = function()
                local frames, step, last = got["t.res_" .. key]:match("^(%d+)|([%d.]+)|([%d.]+)|(%d+)$")
                frames, step, last = tonumber(frames), tonumber(step), tonumber(last)
                return frames >= 8 and step < 0.3 and (key == "close" and last < 0.01 or key == "open" and last > 0.99)
            end })
            add({ check = "guest_door_" .. key .. "_plays_sound", timeout = 2, cond = function()
                local _, _, _, snd = got["t.res_" .. key]:match("^(%d+)|([%d.]+)|([%d.]+)|(%d+)$")
                return tonumber(snd) >= 1
            end })
        end
        add({ wait = 3 })
        return steps
    end

    -- guest ---------------------------------------------------------------------------------------------------------------
    local snd = 0
    local function hookSound()
        for _, path in ipairs({ "/Script/AkAudio.AkGameplayStatics:PostEvent", "/Script/AkAudio.AkComponent:PostAkEvent" }) do
            pcall(function()
                RegisterHook(path, function(self, ev)
                    pcall(function()
                        local n = ev:get():GetFName():ToString():lower()
                        log("PT|info ak event %s", n)
                        if n:find("garagedoor") then snd = snd + 1 end
                    end)
                end)
            end)
        end
    end
    local steps = {}
    local function add(s) steps[#steps + 1] = s end
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() ~= "RB_MainMenu" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_rear_door_open_at_start", timeout = 60, cond = function() return pos() > 0.99 end })
    add({ run = hookSound })
    for _, key in ipairs({ "close", "open" }) do
        add({ check = "guest_told_" .. key, timeout = 300, cond = function()
            if has("t.rec") == key then got["t.rec"] = nil; return true end
        end })
        add({ run = function()
            local frames, step, last, t0, loop = 0, 0, pos(), os.clock(), nil
            snd = 0
            loop = LoopInGameThreadWithDelay(1, function()
                pcall(function()
                    local p = pos()
                    if math.abs(p - last) > 0.0005 then frames = frames + 1 end
                    step = math.max(step, math.abs(p - last))
                    last = p
                end)
                if os.clock() - t0 > 25 then
                    CancelDelayedAction(loop)
                    PTNative_MsgToHost(T.localPC():GetAddress(), "t.res_" .. key, string.format("%d|%.3f|%.3f|%d", frames, step, last, snd))
                end
            end)
        end })
        add({ wait = 27 })
    end
    return steps
end
