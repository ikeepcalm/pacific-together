-- Hand play 2026-10-24: in a zone, with the host in the driver's seat, the guest leaves the car, walks and jumps: it fell through the
-- ground (both sides traced ground under the exit spot; it once worked when the host had left the car first).
-- The host sits in its car in the coop-zone save, the guest enters through the passenger door; the host travels to the next zone
-- (BFL_ProgressionHelpers:TravelToNextLeg, as through a junction), the guest rejoins and the game puts it in the car; then it leaves,
-- walks 5 m away from the car and jumps (owner: it strikes after a junction's map load, not in a zone both started on foot).
-- Checks: the guest walks 1.5 m on both sides, its jump leaves the ground, and its own pawn and the host's copy of it stay within 3 m
-- below the exit spot for 10 s. Then it gets back in through the DRIVER's door (owner: it sat like a driver, the seat guard fought the
-- game's own entry 229 times in 3 s) and must stay at the passenger seat for 3 s.
-- Run: tools/run-test.ps1 -Scenario zoneexit -Fixture coop-zone -Headless     Mutations: hostout (the host leaves the car first), noexitwalk (walking and collision not restored after the exit's repossess), noseatguard (the guest forwards its seating jolt to the host)
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
    local fixture = (os.getenv("PT_FIXTURE") or ""):match("[^,]+") or "coop-zone"

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local id, exitZ, minZ, exitXY
        for _, s in ipairs(T.loadFixture(fixture)) do add(s) end
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() and T.map() ~= "RB_Garage" end })
        add({ check = "host_guest_in_zone", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 15 })
        add({ run = function() id = T.act_begin("enter_car", {}) end })
        add({ check = "host_in_car", timeout = 60, cond = function()
            local d, t, ok = T.act_done(id)
            if d then log("PT|info host enter_car ok=%s %s", tostring(ok), (t or ""):gsub("\n", " / "):sub(1, 200)) end
            return d and ok
        end })
        add({ run = function()
            local c, g = theCar(), L.guestChar()
            if attached(g) then sendGuest("t.seated"); return end
            local w = KML:TransformLocation(c:GetTransform(), { X = 131, Y = -200, Z = 0 })
            g:K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = w.X, Y = w.Y, Z = c:K2_GetActorLocation().Z + 10 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
            sendGuest("t.p1")
        end })
        add({ check = "guest_seated", timeout = 120, cond = function() local g = L.guestChar(); return g ~= nil and attached(g) end })
        local map0
        add({ wait = 3 })
        -- the guest's seating jolt on its side was forwarded to the host as an anomaly hit (hand play: 60 / 19.8 after each junction)
        local hits = 0
        add({ run = function()
            pcall(RegisterHook, "/Game/Characters/Player/Components/AC_PlayerHealthReceiverHelper.AC_PlayerHealthReceiverHelper_C:MessageBind_MSG_Base_Damage_C", function(self, payload)
                local r, p, me = self:get(), payload:get(), T.myPawn()
                if me and r:GetOwner():GetAddress() == me:GetAddress() and p.Damage > 0 then hits = hits + 1; log("PT|info host hit %.1f", p.Damage) end
            end)
            map0 = T.map()
            StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(T.world())
        end })
        add({ check = "host_on_next_zone", timeout = 300, cond = function() return T.map() ~= map0 and T.netMode() == "listen" and L.gameplay(T.map()) and T.myPawn() ~= nil end })
        add({ check = "host_guest_back_in_car", timeout = 400, cond = function() local g = L.guestChar(); return has("t.exited") or (g ~= nil and attached(g)) end })
        add({ wait = 12 })
        add({ check = "host_not_hurt_by_guest_seating", timeout = 1, cond = function() return hits == 0 end })
        if T.MUTATE == "hostout" then
            add({ wait = 3 })
            add({ run = function() id = T.act_begin("exit_car", {}) end })
            add({ check = "host_left_car", timeout = 40, cond = function() local d = T.act_done(id); return d end })
        end
        add({ wait = 4 })
        add({ run = function() sendGuest("t.exit") end })
        add({ check = "host_guest_detached", timeout = 90, -- the exit intent waits for the zone-join baseline (up to ~40 s)
             cond = function() local g = L.guestChar(); return g ~= nil and not attached(g) end })
        add({ wait = 2 })
        add({ run = function()
            exitXY = L.guestChar():K2_GetActorLocation()
            exitZ = exitXY.Z
            minZ = exitZ
            sendGuest("t.walk")
        end })
        -- sampled for 14 s: the walk, the jump and a few seconds after
        local t0
        add({ check = "host_guest_stays_on_ground", timeout = 16, cond = function()
            t0 = t0 or os.clock()
            local g = L.guestChar()
            if g then minZ = math.min(minZ, g:K2_GetActorLocation().Z) end
            if minZ < exitZ - 300 then log("PT|info host saw the guest fall: exit z=%.0f min z=%.0f", exitZ, minZ); return false end
            if os.clock() - t0 < 14 then return false end
            log("PT|info host guest z exit=%.0f min=%.0f mode=%d", exitZ, minZ, g.CharacterMovement.MovementMode)
            return true
        end })
        add({ check = "host_sees_guest_walked", timeout = 30, cond = function()
            if not has("t.walked") then return false end
            local g, d = L.guestChar(), 0
            if g then local l = g:K2_GetActorLocation(); d = math.sqrt((l.X - exitXY.X) ^ 2 + (l.Y - exitXY.Y) ^ 2) end
            log("PT|info host sees the guest %.0f uu from the exit", d)
            return d > 150
        end })
        add({ check = "guest_stays_on_ground", timeout = 30, cond = function()
            if not has("t.zmin") then return false end
            local e, m = got["t.zmin"]:match("^(%-?[%d.]+)|(%-?[%d.]+)$")
            log("PT|info guest own z exit=%s min=%s", e, m)
            return tonumber(m) > tonumber(e) - 300
        end })
        -- the guest gets back in on its own (driver's door) and checks its seat; the host stays until it is done
        add({ check = "host_guest_done", timeout = 180, cond = function() return has("t.done2") end })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local id, exitZ, minZ, t0, start, maxZ
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() ~= "RB_Garage" and T.map() ~= "RB_MainMenu" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_told_seat", timeout = 400, cond = function() return has("t.p1") or has("t.seated") end })
    add({ run = function() if got["t.p1"] then id = T.act_begin("door_press", {}) end end })
    add({ check = "guest_seated", timeout = 90, cond = function() return attached(T.myPawn()) end })
    local map0
    add({ run = function() map0 = T.map() end })
    add({ check = "guest_on_next_zone", timeout = 600, cond = function() return T.netMode() == "client" and T.map() ~= map0 and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_seated_after_travel", timeout = 120, cond = function() return attached(T.myPawn()) end })
    -- 2026-11-17: leaves at once, as a player does after a junction; the intent used to wait for the whole zone-join baseline (~30 s)
    local arrived, seatedAt
    add({ run = function() id = T.act_begin("door_press", { passenger = true }); seatedAt = os.clock() end })
    add({ check = "guest_exits_before_baseline", timeout = 7, cond = function()
        if attached(T.myPawn()) then return false end
        log("PT|info guest left the car %.1f s after sitting", os.clock() - seatedAt)
        sendHost("t.exited")
        return true
    end })
    add({ check = "guest_told_walk", timeout = 60, cond = function() return has("t.walk") end })
    add({ run = function()
        local l = T.myPawn():K2_GetActorLocation()
        exitZ, minZ, maxZ, start = l.Z, l.Z, l.Z, l
        -- away from the car (straight along X ran into it)
        local c = theCar():K2_GetActorLocation()
        local dx, dy = l.X - c.X, l.Y - c.Y
        local n = math.max(1, math.sqrt(dx * dx + dy * dy))
        id = T.act_begin("move_to", { x = l.X + dx / n * 500, y = l.Y + dy / n * 500, z = l.Z, radius = 40, timeout = 4 })
    end })
    add({ check = "guest_walk_done", timeout = 15, cond = function()
        minZ = math.min(minZ, T.myPawn():K2_GetActorLocation().Z)
        local d, t = T.act_done(id)
        if d then log("PT|info guest walk: %s", (t or ""):gsub("\n", " / "):sub(1, 300)) end
        return d
    end })
    add({ check = "guest_walked_1_5m", timeout = 2, cond = function()
        local l = T.myPawn():K2_GetActorLocation()
        local d = math.sqrt((l.X - start.X) ^ 2 + (l.Y - start.Y) ^ 2)
        log("PT|info guest walked %.0f uu", d)
        return d > 150
    end })
    add({ run = function() sendHost("t.walked", "1"); id = T.act_begin("jump", {}) end })
    add({ check = "guest_watched_10s", timeout = 14, cond = function()
        t0 = t0 or os.clock()
        local p = T.myPawn()
        if p then local z = p:K2_GetActorLocation().Z; minZ = math.min(minZ, z); maxZ = math.max(maxZ, z) end
        return os.clock() - t0 > 10
    end })
    add({ check = "guest_jump_left_ground", timeout = 2, cond = function()
        local d, t = T.act_done(id)
        log("PT|info guest jump: max z %.0f over exit %.0f; %s", maxZ, exitZ, (t or ""):gsub("\n", " / "):sub(1, 300))
        return maxZ > exitZ + 20 or tonumber((t or ""):match("peak ([%d.]+) uu") or "0") > 20
    end })
    add({ run = function()
        log("PT|info guest own z exit=%.0f min=%.0f", exitZ, minZ)
        sendHost("t.zmin", string.format("%.0f|%.0f", exitZ, minZ))
    end })
    -- back in through the driver's door, as a player would from where they stand
    add({ wait = 3 })
    add({ run = function() id = T.act_begin("door_press", { passenger = true, approach = true }) end })
    add({ check = "guest_reentered", timeout = 90, cond = function()
        local d, t = T.act_done(id)
        if d and not attached(T.myPawn()) then log("PT|info guest door press: %s", (t or ""):gsub("\n", " / "):sub(-900)) end
        return attached(T.myPawn())
    end })
    local far, t1 = 0, nil
    add({ check = "guest_stays_on_passenger_seat", timeout = 6, cond = function()
        t1 = t1 or os.clock()
        local me, car = T.myPawn(), theCar()
        if me and car then
            local l = KML:InverseTransformLocation(car:GetTransform(), me:K2_GetActorLocation())
            local d = math.sqrt((l.X - 46.2) ^ 2 + (l.Y - 45.8) ^ 2)
            if d > far then far = d; log("PT|info guest seat offset %.1f,%.1f,%.1f (%.0f uu off the passenger seat)", l.X, l.Y, l.Z, d) end
        end
        if os.clock() - t1 < 3 then return false end
        return far < 20
    end })
    add({ run = function() sendHost("t.done2") end })
    add({ wait = 5 })
    return steps
end
