-- Hand play 2026-11-15 (friend session): the guest left a MOVING car with E and (1) the glide to the exit spot ran on car-local waypoints
-- for 1.1 s, then the placement snapped it to the world spot of the exit moment (speed x 1.1 s back; one death followed), and (2) the
-- one E press sent `car exit intent` and `car enter intent D` together. The guest drives at speed on the open zone map, then presses E
-- at the driver's door like a player (door_press while seated).
-- Checks: the guest is placed within 500 uu of the car (not speed x 1.1 s behind it), the host's copy follows it, and it stays out for 6 s.
-- Run: tools/run-test.ps1 -Scenario guestexitmove -Fixture coop-zone -Headless     Mutations: noexitrel (world spot placement), noexitpress (enter intent sent too)
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
        add({ run = function() sendGuest("t.w") end })
        add({ check = "host_car_at_speed", timeout = 40, cond = function()
            local v = theCar():GetVelocity()
            local s = math.sqrt(v.X * v.X + v.Y * v.Y)
            log("PT|info car speed %.0f", s)
            return s > 80 -- the host refuses exits above 500 uu/s and the car gains ~130 uu/s while the press (~1.5 s) walks to the door
        end })
        add({ run = function() sendGuest("t.exit") end })
        add({ check = "host_guest_left_the_car", timeout = 30, cond = function() local g = L.guestChar(); return g ~= nil and not attached(g) end })
        local t0
        add({ check = "host_guest_stays_out_6s", timeout = 12, cond = function()
            t0 = t0 or os.clock()
            local g = L.guestChar()
            if g and attached(g) then log("PT|info host guest is back in the car"); return false end
            return os.clock() - t0 > 6
        end })
        add({ check = "guest_placed_beside_the_moving_car", timeout = 60, cond = function()
            if not has("t.maxstep") then return false end
            local m = tonumber(got["t.maxstep"])
            log("PT|info guest placed %.0f uu from the car (it drove ~700+ uu/s at the exit)", m or -1)
            return m ~= nil and m > 0 and m < 250
        end })
        -- the host's copy of the guest must be where the guest stands (a copy left at the exit-time spot gets the guest put back by desync.lua)
        add({ check = "host_copy_where_guest_stands", timeout = 30, cond = function()
            if not has("t.pos") then return false end
            local x, y = got["t.pos"]:match("^(%-?[%d.]+)|(%-?[%d.]+)$")
            local l = L.guestChar():K2_GetActorLocation()
            local d = math.sqrt((l.X - tonumber(x)) ^ 2 + (l.Y - tonumber(y)) ^ 2)
            log("PT|info host copy %.0f uu from where the guest stands", d)
            return d < 200
        end })
        add({ wait = 2 })
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
    local id, last, maxstep, t1, tlast, placeDist, tdet, tpress
    on("t.exit", function()
        keys = "0 0 0 0"
        tpress = os.clock()
        id = T.act_begin("door_press", {})
        t1 = os.clock()
        maxstep = 0
        LoopInGameThreadWithDelay(5, function()
            local p = T.myPawn()
            if not (p and t1 and os.clock() - t1 < 8) then return end
            -- the host refuses an exit above 500 uu/s (the car may still be gaining speed): press again once the press is done
            if attached(p) and os.clock() - tpress > 2.5 and (T.act_done(id)) then tpress = os.clock(); id = T.act_begin("door_press", {}) end
            local l = p:K2_GetActorLocation()
            if last then
                local st = math.sqrt((l.X - last.X) ^ 2 + (l.Y - last.Y) ^ 2)
                -- the glide ends with the guest standing still: its distance to the car there is where it was placed
                if attached(p) then tdet = nil elseif not tdet then tdet = os.clock() end
                -- the glide takes 1.1 s from the detach; the car has rolled on ~0.2 s since the placement
                if st < 1 and tdet and os.clock() - tdet > 1.3 and not placeDist and theCar() then
                    local c = theCar():K2_GetActorLocation()
                    placeDist = math.sqrt((l.X - c.X) ^ 2 + (l.Y - c.Y) ^ 2)
                    log("PT|info guest stands still %.0f uu from the car at %.2f s", placeDist, os.clock() - t1)
                end
            end
            last, tlast = l, os.clock()
        end)
    end)
    add({ check = "guest_watched_exit", timeout = 20, cond = function()
        if os.clock() - t1 < 8 then return false end
        local d, t = T.act_done(id)
        log("PT|info guest door press: %s", tostring(t):gsub("\n", " / "):sub(1, 200))
        T.intent("t.maxstep", string.format("%.0f", placeDist or -1))
        return true
    end })
    add({ wait = 4 })
    add({ run = function() local l = T.myPawn():K2_GetActorLocation(); T.intent("t.pos", string.format("%.0f|%.0f", l.X, l.Y)) end })
    add({ wait = 10 })
    add({ run = function() if loop then CancelDelayedAction(loop) end end })
    return steps
end
