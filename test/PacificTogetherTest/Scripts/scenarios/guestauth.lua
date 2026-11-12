-- Guest authority over the car it drives (owner 2026-11-12). On an open zone map the guest gets in by the driver's door, turns
-- the key and drives forward and back through its own keys (the bot's g.car.drive intents, which guestauth.lua also applies on
-- the guest). Checks:
--   guest_input_local        the guest's own car takes the throttle within a few frames of the key (no host round trip) and
--                            simulates its own physics
--   host_follows_guest       the host's car is a kinematic follower while the guest drives
--   host_car_tracks_guest    the host's car stays near the guest's while it moves (p95 < 300 uu) and matches it once stopped (< 30 uu)
--   host_handback_*          after the guest gets out the host simulates again where the car was: no jump (< 50 uu), not falling
-- Run: tools/run-test.ps1 -Scenario guestauth -Fixture coop-zone -Headless
-- Mutation noguestauth: the host simulates the guest's driving as before: guest_input_local fails.
--   guest_door_parts_stay / host_door_parts_stay  the guest at the wheel opens and shuts a rear door: no part leaves the car
--   host_passenger_* / guest_passenger_car_steady  the host sits as passenger while the guest simulates: the car stays down, parts stay
-- Mutations: guestauthdoors (doors posed kinematic, no hinge handling), guestauthbodies (the host body collides with the guest car).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local NONE = FName("None")
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            if k == "t.gpos" then got.gpos = got.gpos or {}; table.insert(got.gpos, d) else got[k] = d end
        end
    end
    local function take(kind) poll(); if got[kind] ~= nil then got[kind] = nil; return true end return false end
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
        return KML:InverseTransformDirection(c:GetTransform(), c:GetVelocity()).X
    end
    -- forward speed from the car's movement since the last call (a kinematic follower has no physics velocity)
    local lastP, lastT
    local function moved()
        local c, t = theCar(), os.clock()
        local p = c:K2_GetActorLocation()
        local v = 0
        if lastP and t > lastT then
            v = KML:InverseTransformDirection(c:GetTransform(), { X = p.X - lastP.X, Y = p.Y - lastP.Y, Z = p.Z - lastP.Z }).X / (t - lastT)
        end
        lastP, lastT = p, t
        return v
    end
    local function physics() return theCar().Chassis:IsSimulatingPhysics(NONE) end
    local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
    -- the car's parts on it and the loose items around it: a part that falls off leaves the first and joins the second
    local function partsOn()
        local c, n = theCar(), 0
        for _, cls in ipairs({ "BP_CarPart_Door_Base_C", "BP_Panel_Base_C", "BP_CarPart_Wheel_Base_C" }) do
            for _, a in ipairs(FindAllOf(cls) or {}) do
                local par = a:IsValid() and a:GetAttachParentActor()
                if par and par:IsValid() and par:GetFullName() == c:GetFullName() then n = n + 1 end
            end
        end
        return n
    end
    local function itemsNear()
        local c, n = theCar():K2_GetActorLocation(), 0
        for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
            if a:IsValid() and not a:GetAttachParentActor():IsValid() and d3(a:K2_GetActorLocation(), c) < 1500 then n = n + 1 end
        end
        return n
    end
    -- worst vertical speed and tilt of the car over the next seconds (every frame)
    local function watchCar(seconds)
        local w = { vz = 0, tilt = 0 }
        local c = theCar()
        local last, lt, t0 = c:K2_GetActorLocation(), os.clock(), os.clock()
        local h
        h = LoopInGameThreadWithDelay(1, function()
            pcall(function()
                local p, t, r = c:K2_GetActorLocation(), os.clock(), c:K2_GetActorRotation()
                if t > lt then w.vz = math.max(w.vz, math.abs(p.Z - last.Z) / (t - lt)) end
                w.tilt = math.max(w.tilt, math.abs(r.Pitch), math.abs(r.Roll))
                last, lt = p, t
            end)
            if os.clock() - t0 > seconds then CancelDelayedAction(h); w.done = true end
        end)
        return w
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
        add({ run = function() sendGuest("t.ign") end })
        add({ check = "host_ignition_on_by_guest", timeout = 20, cond = function() return cm().CarIgnitionState == 2 end })
        add({ run = function() sendGuest("t.gear") end })
        add({ check = "host_drive_by_guest", timeout = 20, cond = function() return cm().MyCarGearBox == 0 end })
        -- the guest's car position against ours as it arrives (t.gpos "x,y,z,speed", 5 Hz)
        local moving, still, kinematic, tracking = {}, nil, 0, true
        local track = LoopInGameThreadWithDelay(50, function()
            if not tracking then return end
            pcall(function()
                poll()
                local list = got.gpos or {}
                got.gpos = nil
                local c = theCar()
                if not physics() then kinematic = kinematic + 1 end
                for _, d in ipairs(list) do
                    local x, y, z, sp = d:match("^([^,]+),([^,]+),([^,]+),([^,]+)$")
                    local dist = d3(c:K2_GetActorLocation(), { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) })
                    if tonumber(sp) > 100 then moving[#moving + 1] = dist end
                    still = dist
                end
            end)
        end)
        add({ run = function() moved(); sendGuest("t.w") end })
        add({ check = "host_car_moves_forward", timeout = 10, cond = function()
            local v = moved(); log("PT|info host car forward %.0f", v); return v > 200
        end })
        add({ check = "guest_input_local", timeout = 15, cond = function() return take("t.localok") end })
        add({ wait = 2 })
        add({ run = function() moved(); sendGuest("t.s") end })
        add({ check = "host_car_reverses", timeout = 15, cond = function()
            local v = moved(); log("PT|info host car forward %.0f", v); return v < -150
        end })
        add({ wait = 2 })
        add({ run = function() sendGuest("t.stop") end })
        add({ wait = 6 })
        add({ check = "host_follows_guest", timeout = 2, cond = function()
            log("PT|info host car kinematic in %d samples", kinematic); return kinematic > 40
        end })
        add({ check = "host_car_tracks_guest", timeout = 2, cond = function()
            table.sort(moving)
            local p95 = #moving > 0 and moving[math.ceil(#moving * 0.95)] or -1
            log("PT|info host-guest car distance moving n=%d p50=%.0f p95=%.0f stopped=%.1f", #moving,
                #moving > 0 and moving[math.ceil(#moving * 0.5)] or -1, p95, still or -1)
            return #moving >= 10 and p95 < 300 and still and still < 30
        end })
        add({ run = function() tracking = false; CancelDelayedAction(track) end })
        -- the guest at the wheel opens and shuts a rear door (owner 2026-11-12: doors fell off and came back as parts)
        local parts0, items0
        add({ run = function() parts0, items0 = partsOn(), itemsNear(); sendGuest("t.door") end })
        add({ check = "guest_door_done", timeout = 30, cond = function() return take("t.doorok") or take("t.doorbad") end })
        add({ wait = 3 })
        add({ check = "host_door_parts_stay", timeout = 2, cond = function()
            local p, i = partsOn(), itemsNear()
            log("PT|info door test host parts %d -> %d, items near %d -> %d", parts0, p, items0, i)
            return p == parts0 and i <= items0
        end })
        -- the host sits down as passenger while the guest drives (owner 2026-11-12: the car was thrown into the sky), as
        -- car.lua's hostSit does it: collision and walking off, attached at the mirrored seat
        local seatWatch, guestSeat
        add({ run = function()
            parts0, items0 = partsOn(), itemsNear()
            local me, c = T.myPawn(), theCar()
            me:SetActorEnableCollision(false)
            pcall(function() me.CharacterMovement:DisableMovement() end)
            local r = c:K2_GetActorRotation()
            me:K2_SetActorLocationAndRotation(KML:TransformLocation(c:GetTransform(), { X = 46.2, Y = 45.8, Z = -12.3 }), { Pitch = 0, Yaw = r.Yaw, Roll = 0 }, false, {}, true)
            me:K2_AttachToActor(c, NONE, 1, 1, 1, false)
            seatWatch = watchCar(8)
            sendGuest("t.seatwatch")
        end })
        add({ wait = 9 })
        add({ check = "host_passenger_car_steady", timeout = 2, cond = function()
            log("PT|info host passenger: host car max vz %.0f uu/s tilt %.1f deg", seatWatch.vz, seatWatch.tilt)
            return seatWatch.done and seatWatch.vz < 300 and seatWatch.tilt < 25
        end })
        add({ check = "host_passenger_parts_stay", timeout = 2, cond = function()
            local p, i = partsOn(), itemsNear()
            log("PT|info passenger test host parts %d -> %d, items near %d -> %d, seated %s", parts0, p, items0, i, tostring(attached(T.myPawn())))
            return p == parts0 and i <= items0 and attached(T.myPawn())
        end })
        add({ check = "guest_passenger_reported", timeout = 20, cond = function()
            if take("t.seatok") then guestSeat = true; return true end
            if take("t.seatbad") then guestSeat = false; return true end
            return false
        end })
        add({ check = "guest_saw_steady_car", timeout = 2, cond = function() return guestSeat == true end })
        add({ run = function()
            local me = T.myPawn()
            pcall(function() me:K2_DetachFromActor(1, 1, 1) end)
            local c = theCar()
            me:K2_SetActorLocation(KML:TransformLocation(c:GetTransform(), { X = 60, Y = 260, Z = 60 }), false, {}, true)
            me:SetActorEnableCollision(true)
            pcall(function() me.CharacterMovement:SetMovementMode(1, 0) end)
        end })
        add({ wait = 3 })
        -- hand back: the guest gets out; every frame of the next 4 s the car must not move more than a little
        local before, maxStep, last, frames, minVz, sim = nil, 0, nil, 0, 0, false
        add({ run = function()
            before = theCar():K2_GetActorLocation()
            last = before
            local t0 = os.clock()
            local watch
            watch = LoopInGameThreadWithDelay(1, function()
                pcall(function()
                    local c = theCar()
                    local p = c:K2_GetActorLocation()
                    maxStep = math.max(maxStep, d3(p, last))
                    last, frames = p, frames + 1
                    minVz = math.min(minVz, c:GetVelocity().Z)
                    if physics() and not attached(L.guestChar()) then sim = true end
                end)
                if os.clock() - t0 > 6 then CancelDelayedAction(watch) end
            end)
            sendGuest("t.exit")
        end })
        add({ check = "host_guest_out", timeout = 20, cond = function() return not attached(L.guestChar()) end })
        add({ wait = 4 })
        add({ check = "host_handback_physics", timeout = 3, cond = function() return sim end })
        add({ check = "host_handback_no_jump", timeout = 2, cond = function()
            local moved = d3(theCar():K2_GetActorLocation(), before)
            log("PT|info handback frames=%d max step %.1f uu, moved %.1f uu, min vz %.0f", frames, maxStep, moved, minVz)
            return frames > 20 and maxStep < 50 and moved < 50 and minVz > -200
        end })
        add({ wait = 3 })
        return steps
    end

    -- guest
    local steps = {}
    local function add(s) steps[#steps + 1] = s end
    local keys, loop, report, probeAt = "0 0 0 0", nil, nil, nil
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
        report = LoopInGameThreadWithDelay(200, function()
            pcall(function()
                local c = theCar()
                local p, v = c:K2_GetActorLocation(), c:GetVelocity()
                if os.clock() - (probeAt or 0) > 1 then
                    probeAt = os.clock()
                    local okp, errp = pcall(function()
                        local vc = c.VehicleController
                        local okb, pb = pcall(function() return vc:GetParkingBrakeActive() end)
                        log("PT|info guest car p=%.0f,%.0f,%.0f v=%.0f,%.0f,%.0f fwd=%.0f thr=%.2f in=%.2f/%.2f phys=%s vctick=%s pb=%s gear=%s ign=%s keys=%s",
                            p.X, p.Y, p.Z, v.X, v.Y, v.Z, fwd(), c.ThrottleCurrent, vc.ThrottleInput, vc.BrakeInput, tostring(physics()),
                            tostring(vc:IsComponentTickEnabled()), tostring(okb and pb), tostring(cm().MyCarGearBox), tostring(cm().CarIgnitionState), keys)
                    end)
                    if not okp then log("PT|info guest car probe error %s", tostring(errp)) end
                    pcall(function()
                        local ch = c.Chassis
                        local cp, cv = ch:K2_GetComponentLocation(), ch:GetPhysicsLinearVelocity(NONE)
                        local root = c.RootComponent
                        log("PT|info guest chassis p=%.0f,%.0f,%.0f v=%.0f,%.0f,%.0f root=%s attached=%s mutes=%s role=%s repmove=%s",
                            cp.X, cp.Y, cp.Z, cv.X, cv.Y, cv.Z, root:GetFName():ToString(), tostring(ch.AttachParent and ch.AttachParent:IsValid() and ch.AttachParent:GetFName():ToString()),
                            tostring(PTNative_MuteCount and PTNative_MuteCount()), tostring(c.Role), tostring(c.bReplicateMovement))
                    end)
                end
                T.intent("t.gpos", string.format("%.1f,%.1f,%.1f,%.1f", p.X, p.Y, p.Z, math.sqrt(v.X ^ 2 + v.Y ^ 2 + v.Z ^ 2)))
            end)
        end)
    end })
    local function on(kind, fn) add({ check = "guest_told_" .. kind:sub(3), timeout = 120, cond = function() if take(kind) then fn(); return true end return false end }) end
    on("t.ign", function() T.intent("g.car.ctl", "ign") end)
    on("t.gear", function() T.intent("g.car.ctl", "gear") end)
    -- frames from our key to our own car's throttle and to our own car moving: local physics answer at once; the host's answer
    -- comes a round trip plus the follow delay later
    local probe
    on("t.w", function()
        keys = "1 0 0 0"
        T.intent("g.car.drive", keys)
        probe = { t0 = os.clock(), frames = 0 }
        local lp
        lp = LoopInGameThreadWithDelay(1, function()
            pcall(function()
                local c = theCar()
                probe.frames = probe.frames + 1
                if not probe.thr and c.ThrottleCurrent > 0.05 then probe.thr, probe.thrMs = probe.frames, (os.clock() - probe.t0) * 1000 end
                if not probe.move and fwd() > 30 then probe.move, probe.moveMs = probe.frames, (os.clock() - probe.t0) * 1000 end
                if probe.phys == nil then probe.phys = physics() end
            end)
            if (probe.thr and probe.move) or os.clock() - probe.t0 > 6 then CancelDelayedAction(lp); probe.done = true end
        end)
    end)
    add({ check = "guest_input_local", timeout = 10, cond = function()
        if not (probe and probe.done) then return false end
        log("PT|info guest key->own throttle %s frames (%.0f ms), ->own car moving %s frames (%.0f ms), physics %s",
            tostring(probe.thr), probe.thrMs or -1, tostring(probe.move), probe.moveMs or -1, tostring(probe.phys))
        -- the bot's key reaches guestauth.lua through the test intent (one or two frames); the car's tick takes the next one
        local ok = probe.thr ~= nil and probe.thr <= 6 and probe.move ~= nil and probe.phys == true
        if ok then T.intent("t.localok") end
        return ok
    end })
    on("t.s", function() keys = "0 1 0 0" end)
    on("t.stop", function() keys = "0 0 0 1"; T.intent("g.car.ctl", "gear") end) -- handbrake, then park
    -- the rear right door, opened and shut by the door's own code as the E key does (car.lua turns it into the host intent)
    local function rearDoor()
        local c = theCar()
        for _, a in ipairs(FindAllOf("BP_CarPart_Door_Base_C") or {}) do
            local par = a:IsValid() and a:GetAttachParentActor()
            if par and par:IsValid() and par:GetFullName() == c:GetFullName() and a.RootComponent.AttachParent:GetFName():ToString() == "SLOT_RearRightDoor" then return a end
        end
    end
    local gParts, gItems, gWatch
    on("t.door", function()
        gParts, gItems = partsOn(), itemsNear()
        gWatch = watchCar(9)
        local d = rearDoor()
        log("PT|info guest opens the rear right door %s", tostring(d ~= nil))
        if d then d:AttemptOpen() end
        ExecuteInGameThreadWithDelay(3500, function() pcall(function() local x = rearDoor(); if x then x:AttemptShut() end end) end)
    end)
    add({ wait = 9 })
    add({ check = "guest_door_parts_stay", timeout = 2, cond = function()
        local p, i = partsOn(), itemsNear()
        log("PT|info door test guest parts %d -> %d, items near %d -> %d, car max vz %.0f tilt %.1f", gParts, p, gItems, i, gWatch.vz, gWatch.tilt)
        local ok = p == gParts and i <= gItems
        T.intent(ok and "t.doorok" or "t.doorbad")
        return ok
    end })
    on("t.seatwatch", function() gParts, gItems = partsOn(), itemsNear(); gWatch = watchCar(8) end)
    add({ wait = 9 })
    add({ check = "guest_passenger_car_steady", timeout = 2, cond = function()
        local p, i = partsOn(), itemsNear()
        log("PT|info host passenger on the guest: car max vz %.0f uu/s tilt %.1f deg, parts %d -> %d, items %d -> %d", gWatch.vz, gWatch.tilt, gParts, p, gItems, i)
        local ok = gWatch.done and gWatch.vz < 300 and gWatch.tilt < 25 and p == gParts and i <= gItems
        T.intent(ok and "t.seatok" or "t.seatbad")
        return ok
    end })
    on("t.exit", function()
        keys = "0 0 0 0"
        CancelDelayedAction(report)
        T.intent("g.car.exit")
    end)
    add({ check = "guest_out_of_car", timeout = 20, cond = function() return not attached(T.myPawn()) end })
    add({ wait = 6 })
    add({ check = "guest_follows_host_again", timeout = 5, cond = function() return not physics() end })
    add({ run = function() if loop then CancelDelayedAction(loop) end end })
    return steps
end
