-- Getting in and out through the passenger door, smoothly (car.lua glides, after PDCoopNet's seatanim). The guest walks to the
-- passenger door and presses it (real input): it must be seated, and on the host its body must move there without a jump (largest
-- step per frame). Then the exit intent: the guest must stand on the passenger side, the host's view of its mesh must move there
-- without a jump, and the guest's own pawn must end next to where the host has it, walking.
-- Run: tools/run-test.ps1 -Scenario carseat -Fixture garage -FixturesDir local/fixtures-fresh -Headless
-- Variant PT_VARIANT=driver: the guest presses the driver's door (EnterCar). guest_walks_in_at_once: the walk-in starts at once
-- (mutation nopredict with the driver variant fails it).
-- Mutations: nopassdoor (the passenger door does not get you in), noglide (jumps as before), driverexit (out on the driver's side).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local got = {}
    local function g(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind]
    end
    local function theCar()
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
            local l = c:IsValid() and c:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and (T.ROLE == "host" or c.Role ~= 3) then return c end
        end
    end
    local function attached(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end
    local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        -- largest per-frame step of the guest's body (the mesh: the actor jumps on purpose on the way out) while watching
        local watch = { on = false, last = nil, max = 0, n = 0 }
        LoopInGameThreadWithDelay(16, function()
            if not watch.on then return end
            pcall(function()
                local c = L.guestChar()
                local p = c.Mesh:K2_GetComponentLocation()
                if watch.last then
                    local s = d3(p, watch.last)
                    if s > watch.max then watch.max = s end
                end
                watch.last, watch.n = p, watch.n + 1
            end)
        end)
        local function startWatch() watch.on, watch.last, watch.max, watch.n = true, nil, 0, 0 end
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 10 })
        add({ run = function()
            local c = theCar()
            local w = KML:TransformLocation(c:GetTransform(), { X = 131, Y = 200, Z = 0 })
            L.guestChar():K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = w.X, Y = w.Y, Z = c:K2_GetActorLocation().Z + 10 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
            PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.enter", "1")
            startWatch() -- from here the body only walks to the door (small steps) and then glides in
        end })
        add({ check = "guest_pressing", timeout = 120, cond = function() return g("t.pressing") ~= nil end })
        add({ check = "guest_seated_through_passenger_door", timeout = 30, cond = function() local x = L.guestChar(); return x ~= nil and attached(x) end })
        add({ run = function() watch.on = false; T.log("PT|info entry: largest step %.0f uu over %d frames", watch.max, watch.n) end })
        add({ check = "host_sees_smooth_entry", timeout = 5, cond = function() return watch.n > 30 and watch.max < 80 end })
        add({ wait = 3 })
        -- the exit intent (key X on the guest, a polled key headless cannot press): the guest sends the same message
        add({ run = function() startWatch(); PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.exit", "1") end })
        add({ check = "guest_out", timeout = 20, cond = function() local x = L.guestChar(); return x ~= nil and not attached(x) end })
        add({ wait = 2 })
        add({ run = function() watch.on = false; T.log("PT|info exit: largest mesh step %.0f uu over %d frames", watch.max, watch.n) end })
        add({ check = "host_sees_smooth_exit", timeout = 5, cond = function() return watch.n > 30 and watch.max < 80 end })
        add({ check = "out_on_passenger_side", timeout = 5, cond = function()
            local l = KML:InverseTransformLocation(theCar():GetTransform(), L.guestChar():K2_GetActorLocation())
            T.log("PT|info guest out at car-local %.0f,%.0f,%.0f", l.X, l.Y, l.Z)
            return l.Y > 60
        end })
        add({ wait = 3 })
        add({ check = "guest_where_host_has_it", timeout = 20, cond = function()
            local x, y, z = (g("t.pos") or ""):match("^(-?[%d.]+),(-?[%d.]+),(-?[%d.]+)$")
            if not x then return false end
            local d = d3(L.guestChar():K2_GetActorLocation(), { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) })
            T.log("PT|info guest's own pawn %.0f uu from the host's copy", d)
            return d < 80
        end })
        add({ check = "guest_walks", timeout = 10, cond = function() return g("t.walk") == "1" end })
        add({ run = function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.done", "1") end })
        add({ wait = 3 })
        return steps
    end

    local id, pressedAt, pressedClock
    local DRIVER = os.getenv("PT_VARIANT") == "driver"
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end },
        { check = "guest_told_enter", timeout = 240, cond = function() return g("t.enter") ~= nil end },
        { wait = 2 },
        -- variant driver: walk to the driver's door and run its own entry (a simulated press of that door does not reach EnterCar headless)
        { run = function()
            if DRIVER then id = T.act_begin("move_to", { actor = theCar().SLOT_FrontLeftDoor:GetItemActor({}):GetFullName(), radius = 120, timeout = 30 })
            else id = T.act_begin("door_press", { passenger = true }) end
        end },
        { check = "guest_door_press", timeout = 90, cond = function()
            local d, _, ok = T.act_done(id)
            if not d then PTNative_MsgToHost(T.localPC():GetAddress(), "t.pressing", "1") end
            if d and ok then
                pressedAt, pressedClock = T.myPawn():K2_GetActorLocation(), os.clock()
                if DRIVER then theCar().SLOT_FrontLeftDoor:GetItemActor({}):StartEntry(false) end
            end
            return d and ok
        end },
        -- the walk to the seat starts on the guest's own screen at once, not after the host's 1.9 s one (friend session 2026-11-01:
        -- every entry took 2.1-2.3 s). Variant driver + mutation nopredict fails it.
        -- the runner's timeout is coarse (whole seconds): the time since the press is measured here. Without prediction the host's
        -- walk-in shows up ~2 s after the press (2026-11-02 run), with it ~1 s.
        { check = "guest_walks_in_at_once", timeout = 3, cond = function()
            -- the passenger door already glided locally before; door_press returns only after the walk-in, so its spot is too late here
            if not DRIVER then return true end
            local l = T.myPawn():K2_GetActorLocation()
            local d = math.sqrt((l.X - pressedAt.X) ^ 2 + (l.Y - pressedAt.Y) ^ 2)
            if d <= 30 then return false end
            local t = os.clock() - pressedClock
            T.log("PT|info guest moved %.0f uu %.2f s after the press", d, t)
            assert(t < 1.5, string.format("the walk-in started only %.2f s after the press", t))
            return true
        end },
        { check = "guest_seated", timeout = 30, cond = function() return attached(T.myPawn()) end },
        { check = "guest_told_exit", timeout = 120, cond = function() return g("t.exit") ~= nil end },
        { run = function() T.intent("g.car.exit", "") end },
        { check = "guest_reports", timeout = 600, cond = function()
            local me = T.myPawn()
            local l = me:K2_GetActorLocation()
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.pos", string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z))
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.walk", (not attached(me) and me.CharacterMovement.MovementMode == 1) and "1" or "0")
            return g("t.done") ~= nil
        end },
    }
end
