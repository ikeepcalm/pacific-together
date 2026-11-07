-- PT1 garage, in a session (playtest 1: no garage door ever moved, the car could not leave, the guest lacked the host's garage parts):
--   rear door      the host presses its button the way a player does (the highlight's own interact): both sides see it close and open
--   front door     the host's route-ready switch opens it (its director is stopped, as a chosen route would): both sides, and the exit gate switch
--   guest press    the guest presses the rear button: the host's door closes too
--   car out        the host drives the car from the yard through the rear door and the garage out through the front door; it ends outside on both sides
--   garage parts   the host installs the fax machine, part shredder and destabilizer stations: the guest gets all three
-- Run: tools/run-test.ps1 -Scenario garagesync -Fixture garage -Headless      Mutation nogarage: garage.lua inert (doors stuck, nothing synced).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local C = require("scenarios.carlib")(T)
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function real(o) return alive(o) and not o:GetFullName():find("/Engine/Transient", 1, true) end
    -- WB.GarageUpgrades.* (install counts): the guest's were double the host's after the stations came over (hand play 2026-10-24)
    local function wbup()
        local L = {}
        T.first("BP_ProgressionManager_C").GlobalWhiteboard.Entries:ForEach(function(k, v)
            local t = k:get().TagName:ToString()
            if t:find("^WB%.GarageUpgrades%.") then L[#L + 1] = string.format("%s=%.0f", t, v:get()) end
        end)
        table.sort(L)
        return table.concat(L, ",")
    end
    local function door(front)
        for _, d in ipairs(FindAllOf("BP_GarageDoor_C") or {}) do
            if real(d) and (d.IsFrontGarageDoor and true or false) == front then return d end
        end
    end
    local function pos(front) local d = door(front); return d and d.CurrentDoorPosition or -1 end
    local GSS = "/Game/Systems/GlobalStateSwitches/"
    local function sw(name) return StaticFindObject(GSS .. name .. "." .. name) end
    local function switchOn(name) return FindFirstOf("DrivingGameInstance"):GetGlobalSwitch(sw(name)) and true or false end
    local UP = {
        fax = { "BP_GarageStation_Fax", "/Game/Gameplay/CarGarage/Stations/FaxMachine/UP_Garage_FaxMachine_Install.UP_Garage_FaxMachine_Install_C" },
        shredder = { "BP_GarageStation_PartShredder", "/Game/Gameplay/CarGarage/Stations/PartShredder/UP_Garage_PartShredder_Install.UP_Garage_PartShredder_Install_C" },
        destabilizer = { "BP_GarageStation_Destabilizer", "/Game/Gameplay/CarGarage/Stations/Destabilizer/UP_Garage_Destabilizer_Install.UP_Garage_Destabilizer_Install_C" },
    }
    local function spawner(name)
        for _, s in ipairs(FindAllOf("BP_GarageInstallation_Spawner_C") or {}) do
            if real(s) and s:GetFName():ToString() == name then return s end
        end
    end
    -- does the station's upgrade slot hold its upgrade on this side?
    local function hasUp(key)
        local s, im, sm = spawner(UP[key][1]), T.first("BP_InventoryManager_C"), T.first("BP_StatusEffectManager_C")
        if not (s and im and sm) then return false end
        local a = {}
        s:GetUpgradeArchetype(a)
        local item = im:FindOrCreateGarageUpgradeSlot(a.Archetype, s.StationInstallTag):GetItem(0)
        if not (item and item:IsValid()) then return false end
        local want = UP[key][2]:match("[^.]+$")
        local list = sm:GetStatusEffects(item)
        for i = 1, #list do if list[i]:get():GetClass():GetFName():ToString() == want then return true end end
        return false
    end
    local function ups() return string.format("%d%d%d", hasUp("fax") and 1 or 0, hasUp("shredder") and 1 or 0, hasUp("destabilizer") and 1 or 0) end
    local function theCar() -- the replicated car on the guest, the only one on the host
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
            local l = alive(c) and c:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and (T.ROLE == "host" or c.Role ~= 3) then return c end
        end
    end

    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind] ~= nil
    end
    local function g(kind) has(kind); return got[kind] end
    local function press(who)
        local b = T.first("BP_BackDoorButton_01_C")
        b.Highlight:InteractPressed(who)
        b.Highlight:InteractReleased(who)
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        local function gpos(kind) return tonumber(g(kind) or "-1") end
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        -- rear door by the host's button
        add({ check = "host_rear_door_open_at_start", timeout = 40, cond = function() return pos(false) > 0.99 end })
        add({ check = "guest_rear_door_open_at_start", timeout = 40, cond = function() return gpos("t.rear") > 0.99 end })
        add({ run = function() press(nil) end })
        add({ check = "host_rear_door_closes", timeout = 30, cond = function() return pos(false) < 0.01 end })
        add({ check = "guest_rear_door_closes", timeout = 30, cond = function() return gpos("t.rear") >= 0 and gpos("t.rear") < 0.01 end })
        add({ run = function() press(nil) end })
        add({ check = "host_rear_door_reopens", timeout = 30, cond = function() return pos(false) > 0.99 end })
        add({ check = "guest_rear_door_reopens", timeout = 30, cond = function() return gpos("t.rear") > 0.99 end })
        -- the guest presses the same button: the host's door closes, the host opens it again
        add({ run = function() toGuest("t.press", "1") end })
        add({ check = "guest_press_closes_host_door", timeout = 40, cond = function() return pos(false) < 0.01 end })
        add({ check = "guest_press_closes_guest_door", timeout = 30, cond = function() return gpos("t.rear") >= 0 and gpos("t.rear") < 0.01 end })
        add({ run = function() press(nil) end })
        add({ check = "rear_door_open_again", timeout = 30, cond = function() return pos(false) > 0.99 and gpos("t.rear") > 0.99 end })
        -- front door and exit gate: what a chosen route does (its director would write the switch each frame, so it is stopped)
        add({ run = function()
            for _, d in ipairs(FindAllOf("BP_Director_GSS_GarageFrontDoor_C") or {}) do d:SetTickEnabled(false) end
            FindFirstOf("DrivingGameInstance"):SetGlobalSwitch(sw("GSS_Garage_FrontDoorOpened"), FName("LegSelectedAndEmbark"), 1)
        end })
        add({ check = "host_front_door_opens", timeout = 30, cond = function() return pos(true) > 0.99 end })
        add({ check = "guest_front_door_opens", timeout = 30, cond = function() return gpos("t.front") > 0.99 end })
        add({ check = "host_exit_gate_open", timeout = 10, cond = function() return switchOn("GSS_Garage_ExitGateOpened") end })
        add({ check = "guest_exit_gate_open", timeout = 30, cond = function() return g("t.exit") == "1" end })
        -- garage parts
        add({ check = "guest_has_no_parts_yet", timeout = 10, cond = function() return g("t.up") == "000" end })
        add({ run = function()
            for _, k in ipairs({ "fax", "shredder", "destabilizer" }) do spawner(UP[k][1]):InstallSpecificUpgrade(StaticFindObject(UP[k][2]), true) end
        end })
        add({ check = "host_has_parts", timeout = 10, cond = function() return ups() == "111" end })
        add({ check = "guest_gets_fax_shredder_destabilizer", timeout = 40, cond = function() return g("t.up") == "111" end })
        add({ check = "guest_garage_upgrade_counts_equal", timeout = 30, cond = function()
            local h, gu = wbup(), g("t.wbup")
            if h ~= gu then T.log("PT|info wbup host=%s guest=%s", h, tostring(gu)) end
            return h == gu
        end })
        -- the car leaves: yard -> rear door -> garage -> front door -> road
        local WP, idx, last, started = { { -1800, -1000 }, { -700, -496 }, { 400, -496 }, { 2500, -496 } }, 1, nil, nil
        add({ run = function()
            local car = C.car()
            C.forcePossess(car, T.myPawn())
            C.startEngine(car)
            local loop
            loop = LoopInGameThreadWithDelay(5, function()
                if not alive(car) then CancelDelayedAction(loop) return end
                local p, w = car:K2_GetActorLocation(), WP[idx]
                if not w then pcall(function() car:AccelerateBrake(0) end) CancelDelayedAction(loop) return end
                local dx, dy = w[1] - p.X, w[2] - p.Y
                if math.sqrt(dx * dx + dy * dy) < 350 then idx = idx + 1 return end
                local d = (math.deg(math.atan(dy, dx)) - car:K2_GetActorRotation().Yaw + 180) % 360 - 180
                local steer = math.max(-1, math.min(1, d / 35))
                pcall(function() car:AccelerateBrake(1.0) car:DriveControl(1.0) end)
                pcall(function() car.VehicleController.ThrottleInput = 1.0 car.VehicleController.SteerInput = steer end)
            end)
        end })
        add({ check = "host_car_outside_front_door", timeout = 120, cond = function() local c = theCar(); return c ~= nil and c:K2_GetActorLocation().X > 1200 end })
        add({ check = "guest_sees_car_outside_front_door", timeout = 40, cond = function() return (gpos("t.car")) > 1200 end })
        add({ run = function() toGuest("t.done") end })
        add({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local pressed
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_reports", timeout = 900, cond = function()
        local me = T.localPC():GetAddress()
        local function say(k, v) PTNative_MsgToHost(me, k, v) end
        say("t.rear", string.format("%.3f", pos(false)))
        say("t.front", string.format("%.3f", pos(true)))
        say("t.exit", switchOn("GSS_Garage_ExitGateOpened") and "1" or "0")
        say("t.up", ups())
        say("t.wbup", wbup())
        local c = theCar()
        say("t.car", string.format("%.0f", c and c:K2_GetActorLocation().X or -99999))
        local p = g("t.press")
        if p and p ~= pressed then pressed = p; press(T.myPawn()) end
        return got["t.done"] ~= nil or has("t.done")
    end })
    return steps
end
