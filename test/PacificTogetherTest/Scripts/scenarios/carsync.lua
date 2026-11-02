-- M3 car (C1-C4, C7), one proving scenario. Garage fixture; host and guest in the garage yard.
--   guest: one live car (its own copy is gone), enters through the game's door (BP_CarPart_Door_Base:EnterCar -> intent ->
--          host seats it at the passenger seat), rides while the host drives ~24 s, its car follows smoothly and its camera
--          rides along, then the host's fuel / battery / part health show up in its inventory and dashboard values, a
--          removed door and wheel are gone on its car (and come back), and it leaves the car again.
-- Run: tools/run-test.ps1 -Scenario carsync -Fixture garage -Headless
-- Mutation nocarsync: car.lua of the shipping mod does nothing (the guest keeps its duplicate car and never gets seated).
--   guest_view_on_car_frame  the view is rendered from where the camera is after the car moved this frame (the car was placed after
--                            the camera: the interior shook against the view, 2026-10-30). Mutation nocartick fails it.
--   guest_head_sways         the seated guest's head moves with the car's acceleration (passenger inertia). Mutation nosway fails it.
-- Messages "t.*" between the two scenario halves use the native channel (see channel.lua).
return function(T)
    local L = require("scenarios.carlib")(T)
    local S = require("scenarios.sessionlib")(T)
    local log, ROLE = T.log, T.ROLE
    local COMP = "/Game/Gameplay/Inventory/GenericItemProperties/Components/"
    local FUEL_SLOT, BAT_SLOT, HP_SLOT = "Attachments.BackSeatLeft", "Attachments.BackSeatRight", "Body.DoorsFR"
    local FUEL, BAT, HP = 7.5, 12.5, 11.0
    local GONE = { "Body.DoorsRR", "Essentials.WheelFL" }
    local DRIVE_S = 24

    local function cm() return T.first("BP_CarManager_C") end
    local function manif(name)
        local r, r2 = {}, {}
        cm():GetItemManifestationEquippedInSlot({ TagName = FName("Car.Equip." .. name) }, r, r2)
        local m = r.Manifestation
        return (m and m:IsValid()) and m or nil
    end
    local function comp(m, cls)
        for _, x in ipairs(m:K2_GetComponentsByClass(StaticFindObject(COMP .. cls))) do return x:get() end
    end
    local function fuelOf(name)
        local m = manif(name); local c = m and comp(m, "BP_FuelableComponent.BP_FuelableComponent_C")
        if not c then return nil end
        local t = { {}, {}, {}, {}, {}, {}, {} }
        c:GetFuelStatus(t[1], t[2], t[3], t[4], t[5], t[6], t[7])
        return t[1].Fuel
    end
    local function batOf(name)
        local m = manif(name); local c = m and comp(m, "BP_BatteryComponent.BP_BatteryComponent_C")
        if not c then return nil end
        local t = { {}, {}, {}, {}, {} }
        c:GetBatteryStatus(t[1], t[2], t[3], t[4], t[5])
        return t[1].BATTERY
    end
    local function hpOf(name)
        local m = manif(name); local c = m and comp(m, "BP_HealthComponent.BP_HealthComponent_C")
        if not c then return nil end
        local t = { {}, {}, {}, {}, {}, {}, {}, {} }
        c:GetHealth(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8])
        return t[1].Health
    end
    local function near(a, b, tol) return a ~= nil and math.abs(a - b) <= tol end
    local function equippedSlot(name)
        local box = {}
        T.first("BP_InventoryManager_C"):GetCarEquippedContainer(box)
        local found
        box.Inventory_CarEquipped.Slots:ForEach(function(_, e)
            local s = e:get()
            if s.SlotName:ToString() == "Car.Equip." .. name then found = s end
        end)
        return found
    end
    local function itemOf(slot)
        local it
        slot.Items:ForEach(function(_, e) it = e:get() end)
        return (it and it:IsValid()) and it or nil
    end
    local function attached(c, car)
        local p = c:GetAttachParentActor()
        return p:IsValid() and p:GetFullName() == car:GetFullName()
    end

    -- the other half's messages
    local inbox = {}
    local function drain()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then return end
            inbox[kind] = { data = data, at = os.time() }
            log("PT|info msg %s %s", kind, data)
        end
    end
    local function got(kind) drain(); return inbox[kind] end

    if ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local guestPC = function() return S.remotePCs()[1] end
        local function send(kind, data) PTNative_MsgToGuest(guestPC():GetAddress(), kind, data or "") end
        local moved, start, saved = 0, nil, {}
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return S.guestChar() ~= nil end })
        add({ wait = 5 })
        -- the guest walks to the door and uses it; the host seats it
        add({ check = "host_guest_seated", timeout = 240, cond = function()
            local g, car = S.guestChar(), L.car()
            if not g or not car or not attached(g, car) then return false end
            local want = L.v(46.2, 45.8, -12.3) -- X8's measured seat; the native driver transform can be an entry pose above it.
            local d = L.d(L.toLocal(car, g:K2_GetActorLocation()), want)
            log("PT|info guest seat error %.1f", d)
            return d < 5
        end })
        add({ wait = 3 })
        add({ run = function()
            local car = L.car()
            S.char = T.myPawn()
            L.forcePossess(car, S.char)
        end })
        add({ check = "host_in_car", timeout = 20, cond = function() return L.possessing(L.car()) end })
        add({ run = function()
            local car = L.car()
            L.startEngine(car)
            start = car:K2_GetActorLocation()
            send("t.drive")
            L.drive(car, 4)
            local last, startRot, still = nil, car:K2_GetActorRotation(), { t = L.now(), p = start }
            LoopInGameThreadWithDelay(1, function()
                if not L.driving then return end
                pcall(function()
                    local p = car:K2_GetActorLocation()
                    if last then moved = moved + L.d(p, last) end
                    last = p
                    -- against a wall the car sleeps: put it back where it started (as in carride)
                    if L.d(p, still.p) > 100 then still = { t = L.now(), p = p }
                    elseif L.now() - still.t > 3 then
                        car:K2_SetActorLocationAndRotation(start, startRot, false, {}, true)
                        still = { t = L.now(), p = start }
                    end
                end)
            end)
        end })
        add({ wait = DRIVE_S })
        add({ run = function() L.driving = false; send("t.stop") end })
        add({ wait = 5 })
        add({ run = function()
            local p = L.car():K2_GetActorLocation()
            send("t.settled", string.format("%.2f,%.2f,%.2f", p.X, p.Y, p.Z))
            L.car():K2_SetActorLocationAndRotation(L.car():K2_GetActorLocation(), L.car():K2_GetActorRotation(), false, {}, true)
        end })
        add({ check = "host_drove", timeout = 1, cond = function() log("PT|info host drove %.0f uu", moved); return moved > 3000 end })
        add({ wait = 4 })
        -- C3/C4: fuel, battery, part health through the game's own setters
        add({ run = function()
            local f = comp(manif(FUEL_SLOT), "BP_FuelableComponent.BP_FuelableComponent_C")
            f["Set Fuel"](f, FUEL)
            local b = comp(manif(BAT_SLOT), "BP_BatteryComponent.BP_BatteryComponent_C")
            b["Set Battery"](b, BAT)
            comp(manif(HP_SLOT), "BP_HealthComponent.BP_HealthComponent_C"):SetHealth(HP)
        end })
        add({ wait = 1 })
        add({ check = "host_state_set", timeout = 5, cond = function()
            local c = cm()
            if not (near(fuelOf(FUEL_SLOT), FUEL, 0.2) and near(batOf(BAT_SLOT), BAT, 0.2) and near(hpOf(HP_SLOT), HP, 0.2)) then return false end
            send("t.state", string.format("%.2f,%.2f", c.AggregateFuelCurrent, c.AggregateBatteryCurrent))
            return true
        end })
        add({ wait = 8 })
        -- C3: a door and a wheel taken off the car
        add({ run = function()
            for _, n in ipairs(GONE) do
                local slot = equippedSlot(n)
                local it = itemOf(slot)
                saved[n] = it.Archetype
                slot:RemoveAllItems({})
            end
            send("t.remove")
        end })
        add({ check = "host_parts_gone", timeout = 5, cond = function() return manif(GONE[1]) == nil and manif(GONE[2]) == nil end })
        add({ wait = 8 })
        add({ run = function()
            for _, n in ipairs(GONE) do
                equippedSlot(n):SetItem(saved[n]:CreateInstance(T.localPC(), 0), {})
            end
            send("t.restore")
        end })
        add({ check = "host_parts_back", timeout = 5, cond = function() return manif(GONE[1]) ~= nil and manif(GONE[2]) ~= nil end })
        add({ wait = 8 })
        add({ run = function() send("t.exit") end })
        add({ check = "host_guest_left_car", timeout = 30, cond = function()
            local g, car = S.guestChar(), L.car()
            return g ~= nil and car ~= nil and not attached(g, car)
        end })
        add({ wait = 5 })
        return steps
    end

    -- guest ----------------------------------------------------------------------------------------------------------------
    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local met = { frames = 0, stalls = 0, maxJump = 0, dist = 0, camMax = 0, lags = {}, swayMax = 0 }
    local function toHost(kind, data) PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end
    local function measure()
        local car, me = L.car(), T.myPawn()
        if not car then return end
        local t = L.now()
        local p = car:K2_GetActorLocation()
        local rm = car.ReplicatedMovement.LinearVelocity
        local speed = math.sqrt(rm.X ^ 2 + rm.Y ^ 2)
        local cam = T.localPC().PlayerCameraManager:GetCameraLocation()
        local cl = L.toLocal(car, cam)
        if not met.fp then
            for _, c in ipairs(FindAllOf("CameraComponent") or {}) do
                if c:GetFName():ToString() == "FP_Camera" and c:GetOwner():IsValid() and c:GetOwner():GetFullName() == me:GetFullName() then met.fp = c end
            end
        end
        if met.fp and speed > 150 then
            local fl, r = met.fp:K2_GetComponentLocation(), met.fp.RelativeLocation
            met.lags[#met.lags + 1] = L.d(fl, cam)
            met.swayMax = math.max(met.swayMax, math.sqrt(r.X ^ 2 + r.Y ^ 2 + r.Z ^ 2))
        end
        if not met.cam0 then met.cam0 = cl end
        -- the camera manager's location is the last frame's view: compare it with the car where it was then, too
        local xf = car:GetTransform()
        if met.prevXf then met.camPrevMax = math.max(met.camPrevMax or 0, L.d(KML:InverseTransformLocation(met.prevXf, cam), met.cam0)) end
        met.prevXf = xf
        if met.last then
            local dt = t - met.t
            local d = L.d(p, met.last)
            met.frames = met.frames + 1
            met.dist = met.dist + d
            if d > met.maxJump then met.maxJump = d end
            if speed > 150 and d < 0.05 then met.stalls = met.stalls + 1 end
            met.camMax = math.max(met.camMax, L.d(cl, met.cam0))
        end
        met.last, met.t = p, t
    end

    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add({ wait = 8 })
    -- the guest's own copy of the car is gone once the host's replicated one is there
    add({ check = "guest_one_car", timeout = 60, cond = function()
        local cs = L.cars()
        log("PT|info cars=%d copies=%d", #cs, #L.localCopies())
        return #cs == 1 and #L.localCopies() == 0 and cs[1].Role ~= 3
    end })
    add({ check = "guest_car_is_managers", timeout = 10, cond = function()
        local c = L.car()
        return c ~= nil and cm().NewCarActor:IsValid() and cm().NewCarActor:GetFullName() == c:GetFullName()
    end })
    -- through the game's door: stand next to it, run the interaction's own entry (as the highlight does)
    add({ run = function()
        local car, c = L.car(), T.myPawn()
        local l = car:K2_GetActorLocation()
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = l.X + 250, Y = l.Y + 200, Z = l.Z + 20 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        c:K2_HandleSetCharacterLocation(xf, false, false)
    end })
    add({ wait = 2 })
    add({ run = function()
        if os.getenv("PT_VARIANT") == "nodoor" then toHost("g.car.enter") return end
        L.car().SLOT_FrontLeftDoor:GetItemActor({}):StartEntry(false)
    end })
    add({ check = "guest_seated", timeout = 60, cond = function()
        local car, me = L.car(), T.myPawn()
        if not (car and me and attached(me, car)) then return false end
        local e = L.seatErr(me, car)
        log("PT|info guest seat error %.1f", e)
        return e < 3
    end })
    add({ check = "guest_not_driving", timeout = 5, cond = function()
        -- our own enter-car did not run locally: we are still a plain character, not possessing the car
        local me = T.myPawn()
        return me ~= nil and T.cls(me) == T.CHAR
    end })
    -- the host drives
    add({ check = "guest_drive_started", timeout = 120, cond = function() return got("t.drive") ~= nil end })
    add({ run = function() met = { frames = 0, stalls = 0, maxJump = 0, dist = 0, camMax = 0, lags = {}, swayMax = 0 }; L.measuring = true
        LoopInGameThreadWithDelay(1, function() if L.measuring then pcall(measure) end end) end })
    add({ check = "guest_drive_stopped", timeout = DRIVE_S + 60, cond = function() return got("t.stop") ~= nil end })
    add({ run = function() L.measuring = false end })
    add({ check = "guest_car_follows", timeout = 1, cond = function()
        log("PT|info follow frames=%d dist=%.0f maxJump=%.1f stalls=%d", met.frames, met.dist, met.maxJump, met.stalls)
        return met.dist > 3000 and met.maxJump < 200 and met.stalls <= met.frames * 0.03
    end })
    add({ check = "guest_camera_rides", timeout = 1, cond = function()
        log("PT|info camera deviation in the car %.1f uu (against the previous frame's car %.1f uu)", met.camMax, met.camPrevMax or -1)
        return met.frames > 100 and math.min(met.camMax, met.camPrevMax or math.huge) < 40
    end })
    add({ check = "guest_view_on_car_frame", timeout = 1, cond = function()
        table.sort(met.lags)
        local n = #met.lags
        local p95 = n > 0 and met.lags[math.ceil(n * 0.95)] or -1
        log("PT|info view against the camera after the car moved: p95 %.2f uu over %d moving frames", p95, n)
        return n > 100 and p95 < 1
    end })
    add({ check = "guest_head_sways", timeout = 1, cond = function()
        log("PT|info passenger head sway max %.2f uu", met.swayMax)
        return met.swayMax > 1.5
    end })
    add({ check = "guest_car_settled", timeout = 20, cond = function()
        local m = got("t.settled")
        if not m then return false end
        local x, y, z = m.data:match("([^,]+),([^,]+),([^,]+)")
        local d = L.d(L.car():K2_GetActorLocation(), L.v(tonumber(x), tonumber(y), tonumber(z)))
        log("PT|info settled distance %.1f", d)
        return d < 30
    end })
    -- C3/C4: the host's fuel, battery and part health, on the guest's car and dashboard values
    add({ check = "guest_state_matches", timeout = 60, cond = function()
        local m = got("t.state")
        if not m then return false end
        if os.time() - m.at > 4 then log("PT|info state too late"); return false end
        local aggF, aggB = m.data:match("([^,]+),([^,]+)")
        local c = cm()
        log("PT|info state fuel=%s bat=%s hp=%s agg=%.2f/%.2f want %s/%s", tostring(fuelOf(FUEL_SLOT)), tostring(batOf(BAT_SLOT)), tostring(hpOf(HP_SLOT)),
            c.AggregateFuelCurrent, c.AggregateBatteryCurrent, aggF, aggB)
        return near(fuelOf(FUEL_SLOT), FUEL, 0.3) and near(batOf(BAT_SLOT), BAT, 0.3) and near(hpOf(HP_SLOT), HP, 0.3)
            and near(c.AggregateFuelCurrent, tonumber(aggF), 1.0) and near(c.AggregateBatteryCurrent, tonumber(aggB), 1.0)
    end })
    add({ check = "guest_parts_removed", timeout = 60, cond = function()
        if not got("t.remove") then return false end
        return manif(GONE[1]) == nil and manif(GONE[2]) == nil
    end })
    add({ check = "guest_parts_back", timeout = 60, cond = function()
        if not got("t.restore") then return false end
        return manif(GONE[1]) ~= nil and manif(GONE[2]) ~= nil
    end })
    -- leaving: the key (X) and this send the same intent
    add({ check = "guest_exit_asked", timeout = 60, cond = function() return got("t.exit") ~= nil end })
    add({ run = function() toHost("g.car.exit") end })
    add({ check = "guest_left_car", timeout = 30, cond = function()
        local car, me = L.car(), T.myPawn()
        return car ~= nil and me ~= nil and not attached(me, car) and T.cls(me) == T.CHAR
    end })
    add({ wait = 5 })
    return steps
end
