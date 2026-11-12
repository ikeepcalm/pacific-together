-- Owner request 2026-11-12: the "[H] Patch up <name>" hint (heal.lua, overlay.lua PTHint) shows only while the local player aims at the
-- partner within reach AND the heal is off cooldown. The guest is the healer: the host (hurt, so the heal is not refunded) stands 2 m in
-- front of it. guest_hint_hidden_not_aiming (looking away), guest_hint_shown_when_aiming, guest_hint_hidden_on_cooldown (the host sends
-- the guest's H press as g.heal.testpress; the guest keeps aiming).
-- Run: tools/run-test.ps1 -Scenario healhint -Fixture zone -Headless    Mutation healhintalways: always shown, the first check fails.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local fly = { run = function() local m = T.ROLE == "host" and L.own() or T.myPawn(); m.CharacterMovement:SetMovementMode(5, 0) end }
    local function hint() -- text of the visible hint, nil when hidden
        for _, b in ipairs(FindAllOf("TextBlock") or {}) do
            if b:IsValid() and b:GetFName():ToString() == "PTHint" and b:GetVisibility() == 3 then return b:GetText():ToString() end
        end
    end
    local function send(kind, data)
        local a
        if T.ROLE == "host" then local pc = L.remotePCs()[1]; a = pc and pc:GetAddress() else a = T.localPC():GetAddress() end
        if not a then return end
        if T.ROLE == "host" then PTNative_MsgToGuest(a, kind, data) else PTNative_MsgToHost(a, kind, data) end
    end
    local function polled(want)
        while true do
            local k = PTNative_MsgPoll("t.")
            if not k then return false end
            if k == want then return true end
        end
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        -- 2 m in front of the guest (+X), every tick so it stays there
        local function stand() pcall(function()
            local g = L.guestChar():K2_GetActorLocation()
            L.own():K2_TeleportTo({ X = g.X + 200, Y = g.Y, Z = g.Z }, { Pitch = 0, Yaw = 180, Roll = 0 })
        end) end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add(fly)
        add({ run = function() -- hurt, so the guest's heal is taken
            local m = FindFirstOf("BP_ResourceManager_C")
            m.PlayerHealth:Adjust(m, -50)
        end })
        add({ check = "host_guest_aimed", timeout = 120, cond = function() stand(); return polled("t.aimed") end })
        add({ run = function() send("g.heal.testpress", "") end })
        add({ check = "host_guest_done", timeout = 60, cond = function() stand(); return polled("t.done") end })
        add({ wait = 3 })
        return steps
    end

    local function aim(off)
        return { run = function()
            local a, b = T.myPawn():K2_GetActorLocation(), T.otherChar():K2_GetActorLocation()
            T.localPC():SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(b.Y - a.Y, b.X - a.X)) + off, Roll = 0 })
        end }
    end
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { wait = 12 },
        fly,
        { check = "client_host_near", timeout = 120, cond = function() local o = T.otherChar(); return o and T.dist(T.myPawn(), o) < 400 end },
        aim(180), { wait = 3 },
        { check = "guest_hint_hidden_not_aiming", timeout = 2, cond = function() local h = hint(); T.log("PT|info hint (away)=%s", tostring(h)); return h == nil end },
        aim(0),
        { check = "guest_hint_shown_when_aiming", timeout = 10, cond = function() local h = hint(); T.log("PT|info hint (aim)=%s", tostring(h)); return h ~= nil and h:find("[H]", 1, true) ~= nil end },
        { run = function() send("t.aimed", "1") end },
        { check = "guest_hint_hidden_on_cooldown", timeout = 40, cond = function() local h = hint(); T.log("PT|info hint (cooldown)=%s", tostring(h)); return h == nil end },
        { wait = 2 },
        { check = "guest_hint_stays_hidden", timeout = 2, cond = function() return hint() == nil end },
        { run = function() send("t.done", "1") end },
        { wait = 3 },
    }
end
