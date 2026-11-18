-- W6, W7: anomalies act on both players, second pass. Fixture `zone`, the guest joins by itself.
--   leech/bombrock  world-item hazards spawned next to the guest on the host exist on the guest too (Role 1, same spot)
-- Run: tools/run-test.ps1 -Scenario anomalies2 -Fixture zone -Headless
-- Mutation noanom2: the anomalies2 module is off in both processes (the guest never gets the hazards).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local P = "/Game/Gameplay/Hazards/"
    local CLS = {
        leech = P .. "Leech/BP_Hazard_Leech.BP_Hazard_Leech_C",
        bombrock = P .. "BombRock/BP_Hazard_BombRock.BP_Hazard_BombRock_C",
        grabber = P .. "PhysicsGrabber/BP_Hazard_PhysicsGrabber.BP_Hazard_PhysicsGrabber_C",
    }
    local WATCH = { "BP_Hazard_Leech_C", "BP_Hazard_BombRock_C" }
    local function health()
        local rm = T.first("BP_ResourceManager_C")
        local h = rm and rm.PlayerHealth
        if not (h and h:IsValid()) then return -1 end
        return h.Current
    end
    local mapName = "Rural_Forest_Radio_Scylla_02"

    local function xf(x, y, z) return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } } end
    local function spawn(path, x, y, z)
        local cls = StaticFindObject(path)
        if not cls:IsValid() then LoadAsset(path); cls = StaticFindObject(path) end
        local gs = UEHelpers.GetGameplayStatics()
        return gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(T.world(), cls, xf(x, y, z), 2, nil), xf(x, y, z))
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local guestHp, guestSpd, maxSpd, hostHp0, guestHp0, guestParts, partsBefore = -1, 0, 0, 0, 0, 0, 0
        local gpc, haz = nil, {} -- haz: what the guest reports, class -> { role, dist } of the nearest
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.parts" then guestParts = tonumber(data) or guestParts end
                if kind == "t.hp" then guestHp, guestSpd = data:match("^(%-?[%d%.]+)	([%d%.]+)$"); guestHp, guestSpd = tonumber(guestHp) or guestHp, tonumber(guestSpd) or 0 end
                if kind == "t.haz" then
                    haz = {}
                    for c, role, d in data:gmatch("([^|;]+)|(%d+)|([%d%.]+)") do haz[c] = { role = tonumber(role), dist = tonumber(d) } end
                end
            end
        end
        local function nearGuest(dx, dy) local l = L.guestChar():K2_GetActorLocation(); return l.X + dx, l.Y + dy, l.Z + 120 end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function() gpc = L.remotePCs()[1] end })
        -- smhost un-froze the host's hazards: they act on a HOST standing nearby too. The zone's Tesla leaves and the guest moves far (> 6000 uu) from
        -- the host (anomwake2 pattern), so only the guest can be hit and "host not hurt" means something
        add({ run = function()
            local tesla
            for _, o in ipairs(FindAllOf("BP_Hazard_Tesla_C") or {}) do
                if T.inWorld(o) and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then tesla = tesla or o end
            end
            assert(tesla, "no map Tesla")
            local l = tesla:K2_GetActorLocation()
            local gl = { X = l.X + 400, Y = l.Y, Z = l.Z + 150 }
            PTNative_MsgToGuest(gpc:GetAddress(), "t.tp", string.format("%.0f\t%.0f\t%.0f", gl.X, gl.Y, gl.Z))
            pcall(function() L.guestChar():K2_TeleportTo(gl, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
            tesla:K2_DestroyActor()
        end })
        add({ check = "host_far_from_guest", timeout = 30, cond = function()
            local d = T.dist(L.guestChar(), T.myPawn())
            T.log("PT|info host-guest distance %.0f", d)
            return d > 6000
        end })
        add({ wait = 4 })
        local leech
        for _, k in ipairs({ "leech", "bombrock" }) do
            local cname = k == "leech" and WATCH[1] or WATCH[2]
            add({ run = function()
                local a = spawn(CLS[k], nearGuest(500, 0))
                if k == "leech" then leech = a end
                T.log("PT|info spawned %s %s", k, T.name(a))
            end })
            add({ check = "guest_sees_" .. k, timeout = 30, cond = function()
                poll()
                local h = haz[cname]
                T.log("PT|info guest %s: %s", cname, h and string.format("role=%d dist=%.0f", h.role, h.dist) or "none")
                return h ~= nil and h.role == 1 and h.dist < 1500
            end })
        end
        -- the Leech leaps (LeechState 3) and its hit event reports the guest's pawn: the game only knows the host's character
        add({ run = function()
            poll(); guestHp0, hostHp0 = guestHp, health()
            leech.LeechState = 3
            leech:CheckForHitPlayer(L.guestChar())
            T.log("PT|info leech leap hit sent: guestHp=%.0f hostHp=%.0f", guestHp0, hostHp0)
        end })
        add({ check = "guest_hurt_by_leech", timeout = 20, cond = function()
            poll()
            T.log("PT|info leech: guest hp=%.0f (was %.0f) host hp=%.0f", guestHp, guestHp0, health())
            return guestHp < guestHp0 - 8
        end })
        add({ check = "host_not_hurt_by_leech_on_guest", timeout = 8, cond = L.holds(3, function() return health() >= hostHp0 - 0.5 end) })
        -- a Part Stealer (and the crash damage, a Can Opener's rip) takes a part off the host's car with CarManager:PopOffPartFromCar:
        -- the car lane's mirror must take it off the guest's car too
        local popped
        add({ check = "guest_car_has_parts", timeout = 60, cond = function() poll(); return guestParts >= 3 end })
        add({ run = function()
            local im, cm, box = T.first("BP_InventoryManager_C"), T.first("BP_CarManager_C"), {}
            im:GetCarEquippedContainer(box)
            local pick
            box.Inventory_CarEquipped.Slots:ForEach(function(_, e)
                local slot, it = e:get(), nil
                slot.Items:ForEach(function(_, x) it = x:get() end)
                local n = slot.SlotName:ToString()
                if it and it:IsValid() and (not pick or n:find("Door", 1, true) or n:find("Fender", 1, true)) then pick = { slot = slot, name = n } end
            end)
            partsBefore = guestParts
            popped = pick.name
            local ok, actor = {}, {}
            cm:PopOffPartFromCar({ TagName = pick.slot.SlotName }, 1.0, ok, actor)
            T.log("PT|info popped %s success=%s guest parts before=%d", pick.name, tostring(ok.Success), partsBefore)
        end })
        add({ check = "guest_car_lost_part", timeout = 40, cond = function()
            poll()
            T.log("PT|info guest car parts %d (was %d, popped %s)", guestParts, partsBefore, tostring(popped))
            return guestParts < partsBefore
        end })
        -- a bomb rock blows up next to the guest: it feels the blast, the host (a car's length away) does not
        local rock
        add({ run = function()
            poll(); guestHp0, hostHp0 = guestHp, health()
            rock = spawn(CLS.bombrock, nearGuest(150, 0))
            T.log("PT|info rock %s guestHp=%.0f hostHp=%.0f", T.name(rock), guestHp0, hostHp0)
        end })
        add({ wait = 4 })
        add({ run = function() rock:OnExlodeStart() end })
        add({ check = "guest_hurt_by_bombrock", timeout = 20, cond = function()
            poll()
            T.log("PT|info bombrock: guest hp=%.0f (was %.0f) host hp=%.0f", guestHp, guestHp0, health())
            return guestHp < guestHp0 - 5
        end })
        -- once, not twice (the guest's own copy of the rock must not blow up on its own): 25 per blast (the host stands in it too, so no host check)
        add({ check = "bombrock_hit_once", timeout = 10, cond = L.holds(4, function() poll(); return guestHp0 - guestHp < 30 end) })
        -- a physics grabber next to the guest: the guest takes the hit (health) and is pulled (speed), the host does neither
        add({ run = function()
            poll(); guestHp0, hostHp0, maxSpd = guestHp, health(), 0
            local a = spawn(CLS.grabber, nearGuest(400, 0))
            T.log("PT|info spawned grabber %s guestHp=%.0f hostHp=%.0f", T.name(a), guestHp0, hostHp0)
        end })
        add({ check = "guest_hurt_by_grabber", timeout = 40, cond = function()
            poll(); maxSpd = math.max(maxSpd, guestSpd)
            T.log("PT|info grabber: guest hp=%.0f speed=%.0f host hp=%.0f", guestHp, guestSpd, health())
            return guestHp < guestHp0 - 5
        end })
        add({ check = "guest_pulled_by_grabber", timeout = 10, cond = function() poll(); maxSpd = math.max(maxSpd, guestSpd); return maxSpd > 30 end })
        add({ check = "host_not_hurt_by_grabber_on_guest", timeout = 5, cond = function() return health() >= hostHp0 - 0.5 end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    local finished = false
    LoopInGameThreadWithDelay(1000, function()
        pcall(function()
            if T.netMode() ~= "client" then return end
            local me, out = T.myPawn(), {}
            if me and me:IsValid() then
                for _, c in ipairs(WATCH) do
                    local best
                    for _, o in ipairs(FindAllOf(c) or {}) do
                        if T.inWorld(o) and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then
                            local d = T.dist(me, o)
                            if not best or d < best.d then best = { d = d, r = o.Role } end
                        end
                    end
                    if best then out[#out + 1] = string.format("%s|%d|%.0f", c, best.r, best.d) end
                end
            end
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.haz", table.concat(out, ";"))
            local n, im, box = 0, T.first("BP_InventoryManager_C"), {}
            if im then
                im:GetCarEquippedContainer(box)
                local c = box.Inventory_CarEquipped
                if c and c:IsValid() then c.Slots:ForEach(function(_, e) e:get().Items:ForEach(function() n = n + 1 end) end) end
            end
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.parts", tostring(n))
            local v = me and me:IsValid() and me:GetVelocity() or { X = 0, Y = 0, Z = 0 }
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.hp", string.format("%.0f	%.0f", health(), math.sqrt(v.X ^ 2 + v.Y ^ 2)))
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then break end
                if kind == "t.end" then finished = true end
                if kind == "t.tp" and me and me:IsValid() then
                    local x, y, z = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                    me:K2_SetActorLocation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, false, {}, true)
                end
            end
        end)
    end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { check = "client_stays_until_host_done", timeout = 600, cond = function() return finished end },
    }
end
