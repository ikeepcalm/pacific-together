-- Playtest-1 bug B: the guest pressed X in the car; on the host they stood outside, on their own screen they stayed in the car.
-- The guest enters and exits through the passenger door's native interaction, then its own pawn must stand outside and walk.
-- Only one guest seat exists (the mirrored driver seat), so there is no separate driver case.
-- Run: tools/run-test.ps1 -Scenario carexit -Fixture garage -Headless      Mutation: noexitfix (guest does not follow the exit)
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
    local function placeGuest(x, y, z)
        L.guestChar():K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
    end
    local function theCar()
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
            local l = c:IsValid() and c:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and (T.ROLE == "host" or c.Role ~= 3) then return c end
        end
    end
    local function attached(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end
    local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
    local function pos(o) local l = o:K2_GetActorLocation(); return string.format("%.0f|%.0f|%.0f", l.X, l.Y, l.Z) end
    local function unpos(s) local x, y, z = s:match("^([^|]*)|([^|]*)|(.*)$"); return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local seat, out1
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 10 })
        add({ run = function()
            local c = theCar()
            local w = KML:TransformLocation(c:GetTransform(), { X = 131, Y = 200, Z = 0 })
            placeGuest(w.X, w.Y, c:K2_GetActorLocation().Z + 10)
            sendGuest("t.p1")
        end })
        add({ check = "guest_seated_by_door_press", timeout = 120, cond = function() local g = L.guestChar(); return g ~= nil and attached(g) end })
        add({ wait = 3 })
        add({ run = function() seat = L.guestChar():K2_GetActorLocation(); sendGuest("t.exit") end })
        add({ check = "host_guest_detached", timeout = 30, cond = function() local g = L.guestChar(); return g ~= nil and not attached(g) end })
        add({ wait = 3 })
        add({ run = function() out1 = L.guestChar():K2_GetActorLocation(); sendGuest("t.report1") end })
        add({ check = "host_guest_exits_passenger_side", timeout = 1, cond = function()
            return KML:InverseTransformLocation(theCar():GetTransform(), out1).Y > 100
        end })
        add({ check = "guest_own_pawn_outside_seat", timeout = 20, cond = function() return has("t.r1") and d3(unpos(got["t.r1"]), seat) > 150 end })
        add({ check = "guest_own_pawn_near_host_view", timeout = 1, cond = function()
            log("PT|info own=%s host=%s seat=%.0f,%.0f,%.0f", got["t.r1"], pos(L.guestChar()), seat.X, seat.Y, seat.Z)
            return d3(unpos(got["t.r1"]), out1) < 100
        end })
        add({ run = function() sendGuest("t.walk") end })
        add({ check = "guest_walked_on_own_side", timeout = 60, cond = function() return has("t.r2") and d3(unpos(got["t.r2"]), unpos(got["t.r1"])) > 150 end })
        add({ check = "host_sees_guest_walked", timeout = 10, cond = function() return d3(L.guestChar():K2_GetActorLocation(), out1) > 150 end })
        add({ wait = 2 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local id
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_one_car", timeout = 90, cond = function() return theCar() ~= nil end })
    add({ check = "guest_told_p1", timeout = 240, cond = function() return has("t.p1") end })
    add({ wait = 2 })
    add({ run = function() id = T.act_begin("door_press", {passenger=true}) end })
    add({ check = "guest_door_press", timeout = 90, cond = function() local d, _, ok = T.act_done(id); return d and ok end })
    add({ check = "guest_seated", timeout = 60, cond = function() return attached(T.myPawn()) end })
    add({ check = "guest_told_exit", timeout = 120, cond = function() return has("t.exit") end })
    add({ run = function() id = T.act_begin("door_press", {passenger=true}) end })
    add({ check = "guest_passenger_door_exit_interact", timeout = 25, cond = function() local d,_,ok = T.act_done(id); return d and ok end })
    add({ check = "guest_told_report1", timeout = 60, cond = function() return has("t.report1") end })
    add({ run = function() sendHost("t.r1", pos(T.myPawn())) end })
    add({ check = "guest_told_walk", timeout = 60, cond = function() return has("t.walk") end })
    add({ run = function()
        local l = T.myPawn():K2_GetActorLocation()
        local cmv = T.myPawn().CharacterMovement
    end })
    for i, dv in ipairs({ { 1, 0 } }) do
        add({ run = function()
            local l = T.myPawn():K2_GetActorLocation()
            id = T.act_begin("move_to", { x = l.X + dv[1] * 500, y = l.Y + dv[2] * 500, z = l.Z, radius = 40, timeout = 4 })
        end })
        add({ check = "guest_walk_dir" .. i, timeout = 20, cond = function()
            local d, t = T.act_done(id)
            if d then log("PT|info walk%d: %s", i, (t or ""):gsub("\n", " / "):sub(1, 400)) end
            return d
        end })
    end
    add({ run = function() sendHost("t.r2", pos(T.myPawn())) end })
    add({ wait = 3 })
    return steps
end
