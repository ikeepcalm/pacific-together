-- Hand play 2026-11-15: a junction never fired while the GUEST drove (BP_LevelTransition_EnterExit counts CarChassis only when
-- BP_CarManager.PlayerCarState == 1, and nothing sets it while a guest drives). The guest sits at the wheel of the car, which is put
-- on the approach of the zone's exit junction (the host stays on foot), turns the key, engages drive and holds W: the junction's exit
-- volume must fire and the host must leave the zone map (the guest drives off the junction into the garage).
-- Run: tools/run-test.ps1 -Scenario guestjunction -Fixture coop-zone -Headless     Mutation: nojunctionfix (no PlayerCarState lift)
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind] ~= nil
    end
    local function take(kind) if has(kind) then got[kind] = nil; return true end return false end
    local function sendGuest(kind) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), kind, "") end
    local function theCar()
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
            local l = c:IsValid() and c:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and (T.ROLE == "host" or c.Role ~= 3) then return c end
        end
    end
    local function attached(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end
    local function cm() return FindFirstOf("BP_CarManager_C") end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        for _, s in ipairs(T.loadFixture("coop-zone")) do add(s) end
        add({ check = "host_listen_zone", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_zone", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 5 })
        local map0
        add({ run = function()
            map0 = T.map()
            local c = theCar()
            c:ManualSetIgnition_NoAnim(0)
            c:ManualActivate_Gearbox(1, true)
            local w = KML:TransformLocation(c:GetTransform(), { X = 60, Y = -230, Z = 0 })
            L.guestChar():K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = w.X, Y = w.Y, Z = c:K2_GetActorLocation().Z + 10 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
            sendGuest("t.sit")
        end })
        add({ check = "guest_seated_at_wheel", timeout = 150, cond = function()
            local g = L.guestChar()
            return g ~= nil and attached(g) and KML:InverseTransformLocation(theCar():GetTransform(), g:K2_GetActorLocation()).Y < 0
        end })
        add({ wait = 4 })
        -- the car is put on the approach of the zone's exit junction, facing its exit volume (the host stays on foot: PlayerCarState 0)
        add({ run = function()
            local c = theCar()
            c:K2_SetActorLocationAndRotation({ X = 44100, Y = -55270, Z = 7330 }, { Pitch = 0, Yaw = -15.8, Roll = 0 }, false, {}, true)
            log("PT|info host car put at the junction approach, PlayerCarState %d", cm().PlayerCarState)
            sendGuest("t.ign")
        end })
        add({ check = "host_ignition_on_by_guest", timeout = 20, cond = function() return cm().CarIgnitionState == 2 end })
        add({ run = function() sendGuest("t.gear") end })
        add({ check = "host_drive_by_guest", timeout = 20, cond = function() return cm().MyCarGearBox == 0 end })
        add({ run = function() sendGuest("t.w") end })
        local t0
        add({ check = "host_travels_through_junction_guest_driving", timeout = 60, cond = function()
            local c = theCar()
            local l = c and c:K2_GetActorLocation()
            if l and (not t0 or os.clock() - t0 > 2) then t0 = os.clock(); local v = c:GetVelocity(); log("PT|info car at %.0f,%.0f,%.0f speed %.0f thr %.2f gear %d ign %d state %d", l.X, l.Y, l.Z, math.sqrt(v.X * v.X + v.Y * v.Y), c.ThrottleCurrent, cm().MyCarGearBox, cm().CarIgnitionState, cm().PlayerCarState) end
            return T.map() ~= map0 -- DoLevelTransition is jumped to inside the ubergraph: no hook sees it, the map load shows it
        end })
        add({ check = "host_guest_follows_to_next_map", timeout = 300, cond = function() return T.netMode() == "listen" and T.myPawn() ~= nil and L.guestChar() ~= nil end })
        add({ wait = 3 })
        return steps
    end

    -- guest
    local steps = {}
    local function add(s) steps[#steps + 1] = s end
    local keys, loop = "0 0 0 0", nil
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() ~= "RB_MainMenu" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_one_car", timeout = 90, cond = function() return theCar() ~= nil end })
    add({ check = "guest_told_sit", timeout = 300, cond = function() return take("t.sit") end })
    local sentAt = -99
    add({ check = "guest_seated_by_driver_door", timeout = 120, cond = function()
        if attached(T.myPawn()) then return true end
        if os.clock() - sentAt > 5 then sentAt = os.clock(); T.intent("g.car.enter", "D") end
        return false
    end })
    add({ run = function()
        loop = LoopInGameThreadWithDelay(150, function() if attached(T.myPawn()) then T.intent("g.car.drive", keys) end end)
    end })
    local function on(kind, fn) add({ check = "guest_told_" .. kind:sub(3), timeout = 120, cond = function() if take(kind) then fn(); return true end return false end }) end
    on("t.ign", function() T.intent("g.car.ctl", "ign") end)
    on("t.gear", function() T.intent("g.car.ctl", "gear") end)
    on("t.w", function() keys = "1 0 0 0" end)
    add({ check = "guest_on_next_map", timeout = 300, cond = function() return T.netMode() == "client" and T.map() ~= "Wilderness_Forest_06" and T.map() ~= "RB_MainMenu" and T.cls(T.myPawn()) == T.CHAR end })
    add({ run = function() if loop then CancelDelayedAction(loop) end end })
    return steps
end
