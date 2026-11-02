-- The seated guest turns the ignition key and moves the shifter (P <-> D, P holds the parking brake) through the host (car.lua
-- g.car.ctl). Headless checks aim at native components and send E's intent; OS keyboard capture is separate.
-- Host: ignition 0 -> 2 -> 0 and gear 1 -> 0 (brake off) -> 1 (brake on); guest: its car shows the host's ignition and gear.
-- Run: tools/run-test.ps1 -Scenario guestctl -Fixture garage -Headless      Mutation: noguestctl (host ignores the intent)
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
    local function sendGuest(kind, data) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), kind, data or "") end
    local function sendHost(kind, data) PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end
    local function theCar()
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
            local l = c:IsValid() and c:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and (T.ROLE == "host" or c.Role ~= 3) then return c end
        end
    end
    local function attached(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end
    local function cm() return FindFirstOf("BP_CarManager_C") end
    local function st()
        local c, m = theCar(), cm()
        local pb = false
        pcall(function() pb = c.VehicleController:GetParkingBrakeActive() end)
        return string.format("ign=%d gear=%d pb=%s", m.CarIgnitionState, m.MyCarGearBox, tostring(pb))
    end
    local function is(ign, gear)
        local m = cm()
        log("PT|info car %s", st())
        return m.CarIgnitionState == ign and m.MyCarGearBox == gear
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 10 })
        add({ run = function()
            local c = theCar()
            -- a known start: engine off, in park
            c:ManualSetIgnition_NoAnim(0)
            c:ManualActivate_Gearbox(1, true)
            local w = KML:TransformLocation(c:GetTransform(), { X = 131, Y = -200, Z = 0 })
            L.guestChar():K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = w.X, Y = w.Y, Z = c:K2_GetActorLocation().Z + 10 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
            sendGuest("t.p1")
        end })
        add({ check = "guest_seated", timeout = 120, cond = function() local g = L.guestChar(); return g ~= nil and attached(g) end })
        add({ check = "host_start_off_park", timeout = 5, cond = function() return is(0, 1) end })
        add({ check = "guest_dashboard_ready", timeout = 45, cond = function() return has("t.ui") end })
        add({ run = function() sendGuest("t.ign") end })
        add({ check = "host_ignition_on_by_guest", timeout = 20, cond = function() return is(2, 1) end })
        add({ run = function() sendGuest("t.gear") end })
        add({ check = "host_drive_by_guest", timeout = 20, cond = function() return is(2, 0) end })
        add({ check = "host_brake_off_in_drive", timeout = 10, cond = function() return not theCar().VehicleController:GetParkingBrakeActive() end })
        add({ run = function() sendGuest("t.check1") end })
        add({ check = "guest_saw_on_drive", timeout = 60, cond = function() return has("t.ok1") end })
        add({ run = function() sendGuest("t.gear") end })
        add({ check = "host_park_by_guest", timeout = 20, cond = function() return is(2, 1) end })
        add({ check = "host_brake_on_in_park", timeout = 10, cond = function() return theCar().VehicleController:GetParkingBrakeActive() end })
        add({ run = function() sendGuest("t.ign") end })
        add({ check = "host_ignition_off_by_guest", timeout = 20, cond = function() return is(0, 1) end })
        add({ wait = 2 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local id
    local function control(what)
        local c = theCar()
        if what == "ign" then return c.Highlight_Key end
        for _, a in ipairs(FindAllOf("BP_Carpart_Shifter_Base_C") or {}) do
            if a:IsValid() and a:GetAttachParentActor():IsValid() and a:GetAttachParentActor():GetAddress() == c:GetAddress() then return a.Highlight end
        end
    end
    local function aim(what)
        local h, pc = control(what), T.localPC()
        if not (h and h:IsValid() and h.HighlightCollision[1]:IsValid()) then return end
        pc:SetControlRotation(KML:FindLookAtRotation(pc.PlayerCameraManager:GetCameraLocation(), h.HighlightCollision[1]:K2_GetComponentLocation()))
        return h
    end
    local function selected(what)
        local c = theCar()
        local mesh = what == "ign" and c.SM_Wagon_01_KeyPhysics
        if what == "gear" then
            for _, a in ipairs(FindAllOf("BP_Carpart_Shifter_Base_C") or {}) do
                if a:IsValid() and a:GetAttachParentActor():IsValid() and a:GetAttachParentActor():GetAddress() == c:GetAddress() then mesh = a.MainMesh; break end
            end
        end
        return mesh and mesh:IsValid() and mesh.bRenderCustomDepth
    end
    local function intentOn(kind, what)
        return { check = "guest_" .. kind, timeout = 120, cond = function()
            if not has(kind) then return false end
            aim(what)
            if not selected(what) then return false end
            got[kind] = nil
            sendHost("g.car.ctl", what)
            return true
        end }
    end
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_one_car", timeout = 90, cond = function() return theCar() ~= nil end })
    add({ check = "guest_told_p1", timeout = 240, cond = function() return has("t.p1") end })
    add({ wait = 2 })
    add({ run = function() id = T.act_begin("door_press", {}) end })
    add({ check = "guest_door_press", timeout = 90, cond = function() local d, _, ok = T.act_done(id); return d and ok end })
    add({ check = "guest_seated", timeout = 60, cond = function() return attached(T.myPawn()) end })
    for _, what in ipairs({"ign", "gear"}) do
        add({ check = "guest_native_highlight_" .. what, timeout = 15, tick = function() aim(what) end, cond = function() return selected(what) end })
    end
    add({ check = "guest_shifter_beats_arc_selection", timeout = 5, cond = function()
        for _, a in ipairs(FindAllOf("BP_Carpart_Internal_GobblerScreen_C") or {}) do
            if a:IsValid() and a:GetAttachParentActor():IsValid() and a:GetAttachParentActor():GetAddress() == theCar():GetAddress() then
                return selected("gear") and a.ScreenCollision:GetCollisionEnabled() == 0
            end
        end
        return false
    end })
    add({ run = function() sendHost("t.ui") end })
    add(intentOn("t.ign", "ign"))
    add(intentOn("t.gear", "gear"))
    add({ check = "guest_told_check1", timeout = 60, cond = function() return has("t.check1") end })
    add({ check = "guest_car_on_drive", timeout = 20, cond = function() return is(2, 0) end })
    add({ run = function() sendHost("t.ok1") end })
    add(intentOn("t.gear", "gear"))
    add(intentOn("t.ign", "ign"))
    add({ wait = 6 })
    return steps
end
