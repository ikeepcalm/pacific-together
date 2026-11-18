-- anomthrow (W6): the guest THROWS an item at a Tourist (BP_Hazard_Landmine) in the zone; the HOST's Tourist must explode.
--   The guest stands 450 uu from a map Tourist (the host is far away), waits for the zone baseline, then spawns a steel scrap item
--   beside it and sets its physics velocity at the Tourist's antenna (what the game's throw does: ThrowItem spawns the world item
--   with a velocity). loot.lua reports the drop with its velocity and the host spawns its copy flying; the host's physics hit the host's
--   Tourist (steel scrap knocks it over, as on the host; it does not always explode). A throw is repeated every 8 s, 4 times at most, until the Tourist is gone. Info lines tell how many throws it took.
-- Run: tools/run-test.ps1 -Scenario anomthrow -Fixture zone -Headless ; mutation nodropvel (guest drops are reported without velocity: the host's copy just falls).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local MINE = "/Game/Gameplay/Hazards/Landmine/BP_Hazard_Landmine.BP_Hazard_Landmine_C"
    local STEEL = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
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
        local copies, thrown = -1, 0
        hookExplode(boom)
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.copies" then copies = tonumber(data) or copies end
                if kind == "t.throwed" then thrown = tonumber(data) or thrown end
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
            local gl = { X = spot.X + 450, Y = spot.Y, Z = spot.Z + 150 }
            PTNative_MsgToGuest(gpc:GetAddress(), "t.tp", string.format("%.0f\t%.0f\t%.0f", gl.X, gl.Y, gl.Z))
            pcall(function() L.guestChar():K2_TeleportTo(gl, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
            T.log("PT|info Tourist %s at %.0f %.0f %.0f, guest beside it, host %.0f uu away", T.name(mine), spot.X, spot.Y, spot.Z, T.dist(mine, T.myPawn()))
        end })
        -- the zone baseline arrives about 40 s after the join; the throw waits for it on the guest (and is held by net.lua if early)
        add({ wait = 45 })
        add({ check = "tourist_stands_before_throw", timeout = 5, cond = function() return left(spot) == 1 and boom.n == 0 end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.throw", string.format("%.0f\t%.0f", spot.X, spot.Y)) end })
        -- The throw reaches the host as a flying item (loot.lua reports the drop with its velocity); whether the host's physics then knock the
        -- Tourist over is information only (steel scrap did not move it in these runs, nor a host-spawned one: docs/spikes/anomcarry.md).
        local fast, rot0 = 0, nil
        local function angle(a) return math.abs((a + 180) % 360 - 180) end
        add({ check = "host_gets_thrown_item_flying", timeout = 60, cond = function()
            poll()
            for _, w in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
                if w:IsValid() and not w:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then
                    local l = w:K2_GetActorLocation()
                    if math.sqrt((l.X - spot.X) ^ 2 + (l.Y - spot.Y) ^ 2 + (l.Z - spot.Z) ^ 2) < 1500 then
                        local v = w:GetVelocity()
                        fast = math.max(fast, math.sqrt(v.X ^ 2 + v.Y ^ 2 + v.Z ^ 2))
                    end
                end
            end
            local moved = -1
            for _, o in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
                if o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and near(o, spot) then
                    local r = o.Body:K2_GetComponentRotation()
                    rot0 = rot0 or { r.Pitch, r.Roll, r.Yaw }
                    moved = math.max(angle(r.Pitch - rot0[1]), angle(r.Roll - rot0[2]), angle(r.Yaw - rot0[3]))
                end
            end
            T.log("PT|info throws tried=%d fastest item near the Tourist %.0f uu/s, explodes=%d left=%d turned=%.0f deg", thrown, fast, boom.n, left(spot), moved)
            return fast > 1000
        end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    local finished, kicking, spot, kicks = false, false, nil, 0
    local function mineCopy()
        for _, o in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
            if o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and near(o, spot) then return o end
        end
    end
    local function throw()
        local m = mineCopy()
        local pc = T.localPC()
        if not (m and pc and pc.Pawn:IsValid()) then return end
        local tip = m.TipScene:K2_GetComponentLocation()
        local p = pc.Pawn:K2_GetActorLocation()
        local from = { X = p.X - 60, Y = p.Y, Z = p.Z + 40 }
        local arch = StaticFindObject(STEEL)
        local a = T.first("InventorySystem"):SpawnItemActor(T.world(), { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = from, Scale3D = { X = 1, Y = 1, Z = 1 } }, arch, 0, 0)
        local dx, dy, dz = tip.X - from.X, tip.Y - from.Y, tip.Z - from.Z
        local len = math.sqrt(dx * dx + dy * dy + dz * dz)
        local v = { X = dx / len * 2200, Y = dy / len * 2200, Z = dz / len * 2200 + 150 }
        for _, wrapped in ipairs(a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))) do
            local c = wrapped:get()
            if c:IsSimulatingPhysics(FName("None")) then c:SetPhysicsLinearVelocity(v, false, FName("None")) end
        end
        kicks = kicks + 1
        T.log("PT|info guest threw item %d at the Tourist, speed 2200", kicks)
    end
    local every, tpAt = 0, nil
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
            if kind == "t.throw" then
                local x, y = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                spot, kicking = { X = tonumber(x), Y = tonumber(y) }, true
            end
        end
        if tpAt and me and me:IsValid() then -- the guest's pawn is replaced a while after the join: stand at the spot again if it was
            local l = me:K2_GetActorLocation()
            if math.abs(l.X - tpAt.X) > 300 or math.abs(l.Y - tpAt.Y) > 300 then me:K2_SetActorLocation(tpAt, false, {}, true) end
        end
        if spot then
            local n = 0
            for _, o in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
                if o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and near(o, spot) then n = n + 1 end
            end
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.copies", tostring(n))
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.throwed", tostring(kicks))
            every = every + 1
            if kicking and n > 0 and every % 8 == 0 and kicks < 4 then throw() end -- a throw every 8 s until the host's Tourist has exploded
        end
    end) end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { check = "client_stays_until_host_done", timeout = 600, cond = function() return finished end },
    }
end
