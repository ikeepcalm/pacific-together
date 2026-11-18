-- anomhit (W6): the guest kicks a Tourist (BP_Hazard_Landmine) in the zone; the HOST's Tourist must explode.
--   The guest bot walks next to a map Tourist (the host is far away), waits for the zone baseline (guest intents are held until it
--   arrives, ~40 s), then does what the kick key does: aims at the Tourist's antenna tip and calls BP_MainCharacterManager:PlayerKick
--   (the game function the controller calls; a rendered key press is not driven). It retries until the Tourist is gone.
--   Checks: the guest's own copy gets the kick (ObjectKicked), the host's Tourist explodes (StartExplode on the host, gone), the
--   guest's copy is gone too, nothing is left near the spot on either side.
-- Run: tools/run-test.ps1 -Scenario anomhit -Fixture zone -Headless ; mutation noanomhit switches anomhit.lua off.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local MINE = "/Game/Gameplay/Hazards/Landmine/BP_Hazard_Landmine.BP_Hazard_Landmine_C"
    local SPOT = { X = 40005, Y = -23942 } -- a map Tourist of the zone fixture (not a creeper)
    local function near(o, p) local l = o:K2_GetActorLocation(); return math.abs(l.X - p.X) < 250 and math.abs(l.Y - p.Y) < 250 end
    -- Tourists left at the spot (a destroyed actor lingers in FindAllOf with no Body and position 0,0,0)
    local function left(p)
        local n = 0
        for _, o in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
            if o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and near(o, p) then n = n + 1 end
        end
        return n
    end
    local function hookExplode(counter)
        local done = false
        LoopInGameThreadWithDelay(1000, function()
            if done then return end
            done = pcall(RegisterHook, MINE .. ":StartExplode", function() counter.n = counter.n + 1 end)
        end)
    end

    if T.ROLE == "host" then
        local steps, spot = {}, nil
        local function add(s) steps[#steps + 1] = s end
        local gpc, mine, boom = nil, nil, { n = 0 }
        local copies, kicked = -1, 0
        hookExplode(boom)
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.copies" then copies = tonumber(data) or copies end
                if kind == "t.kicked" then kicked = tonumber(data) or kicked end
            end
        end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function()
            gpc = L.remotePCs()[1]
            for _, o in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
                if o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and near(o, SPOT) then mine = o end
            end
            assert(mine, "no map Tourist at the spot")
            spot = mine:K2_GetActorLocation()
            local gl = { X = spot.X + 90, Y = spot.Y, Z = spot.Z + 150 }
            PTNative_MsgToGuest(gpc:GetAddress(), "t.tp", string.format("%.0f\t%.0f\t%.0f", gl.X, gl.Y, gl.Z))
            pcall(function() L.guestChar():K2_TeleportTo(gl, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
            T.log("PT|info Tourist %s at %.0f %.0f %.0f, guest beside it, host %.0f uu away", T.name(mine), spot.X, spot.Y, spot.Z, T.dist(mine, T.myPawn()))
        end })
        add({ check = "host_far_from_guest", timeout = 30, cond = function() return T.dist(L.guestChar(), T.myPawn()) > 6000 end })
        -- the zone baseline arrives about 40 s after the join; the kick waits for it on the guest (and is held by net.lua if early)
        add({ wait = 45 })
        add({ check = "tourist_stands_before_kick", timeout = 5, cond = function() return left(spot) == 1 and boom.n == 0 end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.kick", string.format("%.0f\t%.0f", spot.X, spot.Y)) end })
        add({ check = "host_tourist_exploded", timeout = 120, cond = function()
            poll()
            T.log("PT|info kicks tried=%d explodes=%d left=%d", kicked, boom.n, left(spot))
            return boom.n > 0 and left(spot) == 0
        end })
        add({ check = "guest_copy_gone", timeout = 60, cond = function() poll(); T.log("PT|info guest copies left=%d", copies); return copies == 0 end })
        add({ wait = 5 })
        add({ check = "no_duplicate_after", timeout = 5, cond = function() poll(); return left(spot) == 0 and copies == 0 end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    local finished, kicking, spot, kicks, tpAt = false, false, nil, 0, nil
    local hookedKick = false
    local ownKick = 0
    LoopInGameThreadWithDelay(1000, function()
        if hookedKick then return end
        hookedKick = pcall(RegisterHook, MINE .. ":ObjectKicked", function() ownKick = ownKick + 1 end)
    end)
    local function mineCopy()
        for _, o in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
            if o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and near(o, spot) then return o end
        end
    end
    local function aimAndKick()
        local pc = T.localPC()
        if not (mineCopy() and pc and pc.Pawn:IsValid()) then return end
        -- the kick traces only ~200 uu from the camera: stand at the spot again before every kick (the pawn drifts or is replaced), then aim
        if tpAt then pc.Pawn:K2_SetActorLocation(tpAt, false, {}, true) end
        ExecuteWithDelay(250, function() ExecuteInGameThread(function() pcall(function()
            local m = mineCopy()
            if not (m and pc.Pawn:IsValid()) then return end
            local t0, a = m.TipScene:K2_GetComponentLocation(), m:K2_GetActorLocation()
            local f = ({ 1, 0.6, 0.3 })[kicks % 3 + 1] -- antenna tip, middle, base: the tip sits at a different height from run to run and the trace is 20 uu wide
            local tip = { X = a.X + (t0.X - a.X) * f, Y = a.Y + (t0.Y - a.Y) * f, Z = a.Z + (t0.Z - a.Z) * f }
            local c = pc.PlayerCameraManager:GetCameraLocation()
            local dx, dy, dz = tip.X - c.X, tip.Y - c.Y, tip.Z - c.Z
            pc:SetControlRotation({ Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 })
            ExecuteWithDelay(300, function() ExecuteInGameThread(function() -- a moment later the camera has the new rotation
                local ok, err = pcall(function() T.first("BP_MainCharacterManager_C"):PlayerKick({}, {}, {}) end)
                local p = pc.Pawn:K2_GetActorLocation()
                T.log("PT|info kick pcall=%s %s pawn=%.0f,%.0f,%.0f tip=%.0f,%.0f,%.0f cam=%.0f,%.0f,%.0f reach=%.0f ownKick=%d", tostring(ok), ok and "" or tostring(err), p.X, p.Y, p.Z, tip.X, tip.Y, tip.Z, c.X, c.Y, c.Z, math.sqrt(dx * dx + dy * dy + dz * dz), ownKick)
                kicks = kicks + 1
            end) end)
        end) end) end)
    end
    local every = 0
    LoopInGameThreadWithDelay(1000, function() pcall(function()
        if T.netMode() ~= "client" then return end
        local me = T.myPawn()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then break end
            if kind == "t.end" then finished = true end
            if kind == "t.tp" and me and me:IsValid() then
                local x, y, z = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                tpAt = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
            end
            if kind == "t.kick" then
                local x, y = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                spot, kicking = { X = tonumber(x), Y = tonumber(y) }, true
            end
        end
        if tpAt and me and me:IsValid() then -- the guest's pawn is replaced a while after the join (anomcarry probe): stand at the spot again if it was
            local l = me:K2_GetActorLocation()
            if math.abs(l.X - tpAt.X) > 300 or math.abs(l.Y - tpAt.Y) > 300 then me:K2_SetActorLocation(tpAt, false, {}, true) end
        end
        if spot then
            local n = 0
            for _, o in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
                if o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and near(o, spot) then n = n + 1 end
            end
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.copies", tostring(n))
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.kicked", tostring(kicks))
            every = every + 1
            if kicking and n > 0 and every % 4 == 0 then aimAndKick() end -- a kick every 4 s until the host's Tourist has exploded
        end
    end) end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { check = "client_stays_until_host_done", timeout = 600, cond = function() return finished end },
    }
end
