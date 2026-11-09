-- Guest driving (owner 2026-11-09: "can't drive backwards, the wheel isn't turning, driving feels stiff"). On an open zone map the
-- guest gets in by the driver's door (which shuts behind it), turns the key and drives through its real g.car.drive intents:
-- W moves the car forward with the game's own throttle (no per-frame reset by the host's controller), D steers and turns the
-- guest's steering wheel model, S brakes and then reverses, and the seated guest's lights key toggles the host's headlights.
-- Run: tools/run-test.ps1 -Scenario guestdrive -Fixture coop-zone -Headless
-- Mutations: nothrottlehook (W barely moves the car, S never reverses), nowheelmirror (guest wheel stands still).
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
    local function fwd()
        local c = theCar()
        return KML:InverseTransformDirection(c:GetTransform(), c.Chassis:GetPhysicsLinearVelocity(FName("None"))).X
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        for _, s in ipairs(T.loadFixture("coop-zone")) do add(s) end
        add({ check = "host_listen_zone", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_zone", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 5 })
        add({ run = function()
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
        add({ check = "host_driver_door_shut_after_entry", timeout = 6, cond = function()
            local m, open = cm(), 0
            for d = 0, 5 do local o = {}; m:GetDoorState(d, o); if o.Open then open = open + 1 end end
            log("PT|info doors open %d", open)
            return open == 0
        end })
        add({ run = function() sendGuest("t.ign") end })
        add({ check = "host_ignition_on_by_guest", timeout = 20, cond = function() return cm().CarIgnitionState == 2 end })
        add({ run = function() sendGuest("t.gear") end })
        add({ check = "host_drive_by_guest", timeout = 20, cond = function() return cm().MyCarGearBox == 0 end })
        add({ run = function() sendGuest("t.w") end })
        local top = 0
        add({ check = "host_car_drives_forward", timeout = 8, cond = function()
            local c = theCar()
            local v = fwd()
            top = math.max(top, c.ThrottleCurrent)
            log("PT|info forward %.0f throttle %.2f", v, c.ThrottleCurrent)
            return v > 200 and top > 0.5
        end })
        add({ run = function() sendGuest("t.d") end })
        local yaw0
        add({ run = function() yaw0 = theCar():K2_GetActorRotation().Yaw end })
        add({ check = "host_car_turns_by_guest", timeout = 6, cond = function()
            local d = (theCar():K2_GetActorRotation().Yaw - yaw0 + 180) % 360 - 180
            return math.abs(d) > 15
        end })
        add({ check = "guest_wheel_turned", timeout = 10, cond = function() return take("t.wheelok") end })
        add({ run = function() sendGuest("t.s") end })
        add({ check = "host_car_reverses_by_guest", timeout = 14, cond = function()
            local c = theCar()
            log("PT|info forward %.0f reverse %s", fwd(), tostring(c.PlayerInReverseMode))
            return c.PlayerInReverseMode and fwd() < -150
        end })
        add({ run = function() sendGuest("t.stop") end })
        local lights0
        add({ run = function() lights0 = cm().CarLightsOn; sendGuest("t.lights") end })
        add({ check = "host_lights_toggled_by_guest", timeout = 15, cond = function() return cm().CarLightsOn ~= lights0 end })
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
    -- intents wait for the zone baseline (~40 s after joining): ask again until seated
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
    on("t.d", function() keys = "1 0 1 0" end)
    add({ check = "guest_steering_wheel_follows", timeout = 8, cond = function()
        local v = theCar().SteeringWheelRotationTarget
        log("PT|info guest wheel target %.2f", v)
        if v > 0.3 then T.intent("t.wheelok"); return true end
        return false
    end })
    on("t.s", function() keys = "0 1 0 0" end)
    on("t.stop", function() keys = "0 0 0 0" end)
    on("t.lights", function() T.intent("g.car.ctl", "lights") end)
    add({ wait = 8 })
    add({ run = function() if loop then CancelDelayedAction(loop) end end })
    return steps
end
