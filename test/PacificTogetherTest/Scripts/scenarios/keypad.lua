-- Door keypads (BP_ExternalDoorLock_Keypad, the red light by a locked door) work for the guest (friend session 2026-11-01: "red doors
-- do not open for the guest"; the guest had no copy of the keypad, so nothing to press).
--   guest_sees_keypad          the host's keypad (spawned at run time, as a zone building's are) exists on the guest as a copy
--   host_keypad_pressed        the guest presses its copy (the interact action, as a player): the host's own keypad gets the press
-- Run: tools/run-test.ps1 -Scenario keypad -Fixture zone -Headless   Mutation nokeypad: no copy hooks, the press is not sent (FAILS).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local KEYPAD = "/Game/Gameplay/Props/Doors/BP_ExternalDoorLock_Keypad.BP_ExternalDoorLock_Keypad_C"
    local function alive(o) return o ~= nil and o:IsValid() end
    local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end
    local function pt(s) local x, y, z = s:match("^([^,]+),([^,]+),([^,]+)$"); return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end
    local function str(p) return string.format("%.1f,%.1f,%.1f", p.X, p.Y, p.Z) end
    local function near(p, r)
        for _, o in ipairs(FindAllOf("BP_ExternalDoorLock_Keypad_C") or {}) do
            if alive(o) and not o:GetFullName():find("/Engine/Transient", 1, true) and d3(o:K2_GetActorLocation(), p) < r then return o end
        end
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        local K, presses = nil, 0
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_zone", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ check = "guest_ready", timeout = 400, cond = function() poll(); return got["t.ready"] ~= nil end })
        add({ run = function()
            if not StaticFindObject(KEYPAD):IsValid() then pcall(LoadAsset, KEYPAD) end
            local g = L.guestChar():K2_GetActorLocation()
            local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = g.X + 150, Y = g.Y, Z = g.Z + 40 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
            K = gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(T.myPawn(), StaticFindObject(KEYPAD), xf, 1, nil), xf)
            RegisterHook("/Script/PenDriverPro.HighlightComponent:InteractPressed", function(self)
                pcall(function() if self:get():GetOwner():GetAddress() == K:GetAddress() then presses = presses + 1 end end)
            end)
            T.log("PT|info host spawned keypad %s", K:GetFName():ToString())
            toGuest("t.spawned", str(K:K2_GetActorLocation()))
        end })
        add({ check = "guest_sees_keypad", timeout = 120, cond = function() poll(); return got["t.seen"] ~= nil end })
        add({ check = "host_keypad_pressed", timeout = 30, cond = function()
            poll()
            if got["t.pressed"] then T.log("PT|info host keypad presses %d", presses) end
            return presses > 0
        end })
        add({ wait = 2 })
        return steps
    end

    local kp
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.cls(T.myPawn()) == T.CHAR end },
        { wait = 20 },
        { run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.ready", "1") end },
        { check = "got_spawned", timeout = 60, cond = function() poll(); if got["t.spawned"] then kp = pt(got["t.spawned"]); return true end end },
        { check = "guest_sees_keypad", timeout = 120, cond = function()
            if near(kp, 60) then PTNative_MsgToHost(T.localPC():GetAddress(), "t.seen", "1"); return true end
        end },
        { run = function()
            local k = near(kp, 60)
            local id = T.act_begin("interact", { actor = k:GetFullName(), approach = true, hold = 0.3 })
            T.log("PT|info guest pressing its keypad copy (act %s)", tostring(id))
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.pressed", "1")
        end },
        { wait = 15 },
    }
end
