-- W6: run-shaping anomalies act on both players, third pass. Fixture `zone`, the guest joins by itself.
--   spark tower (Tesla)        the map's Teslas exist on the guest (firing at the guest is not proven, see the spike doc)
--   pickpocket (Part Stealer)  spawned near the guest: the guest sees it and loses a backpack item to it (the host holds it in the stealer's grab)
--   bunny (Loot Creature)      the guest sees it; its push hurts the guest, not the host
-- Run: tools/run-test.ps1 -Scenario anomalies3 -Fixture zone -Headless
-- Mutation noanom3: the anomalies3 module is off in both processes.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local CLS = {
        tesla = "/Game/Gameplay/Hazards/TeslaAnomaly/BP_Hazard_Tesla.BP_Hazard_Tesla_C",
        stealer = "/Game/Gameplay/Hazards/PartStealer/BP_Hazard_PartStealer.BP_Hazard_PartStealer_C",
        bunny = "/Game/Gameplay/Boons/ChubbyBunny/BP_Boon_LootCreature.BP_Boon_LootCreature_C",
    }
    local WATCH = { tesla = "BP_Hazard_Tesla_C", stealer = "BP_Hazard_PartStealer_C", bunny = "BP_Boon_LootCreature_C" }
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
        local guestHp, guestSpd, maxSpd, hostHp0, guestHp0, guestParts, partsBefore, guestBag, bagBefore = -1, 0, 0, 0, 0, 0, 0, 0, 0
        local gpc, haz = nil, {}
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.parts" then guestParts = tonumber(data) or guestParts end
                if kind == "t.bag" then guestBag = tonumber(data) or guestBag end
                if kind == "t.hp" then guestHp, guestSpd = data:match("^(%-?[%d%.]+)	([%d%.]+)$"); guestHp, guestSpd = tonumber(guestHp) or guestHp, tonumber(guestSpd) or 0; maxSpd = math.max(maxSpd, guestSpd) end -- the peak report can arrive while an earlier check polls
                if kind == "t.haz" then
                    haz = {}
                    for c, role, d in data:gmatch("([^|;]+)|(%d+)|([%d%.]+)") do haz[c] = { role = tonumber(role), dist = tonumber(d) } end
                end
            end
        end
        local function nearGuest(dx, dy) local l = L.guestChar():K2_GetActorLocation(); return l.X + dx, l.Y + dy, l.Z + 120 end
        local function sees(k)
            add({ check = "guest_sees_" .. k, timeout = 30, cond = function()
                poll()
                local h = haz[WATCH[k]]
                T.log("PT|info guest %s: %s", WATCH[k], h and string.format("role=%d dist=%.0f", h.role, h.dist) or "none")
                return h ~= nil and h.role == 1 and h.dist < 1500
            end })
        end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function() gpc = L.remotePCs()[1] end })

        -- spark tower: the map's Teslas exist on the guest (replicated, Role 1). Not proven: that a discharge reaches the guest. A Tesla moved next to the
        -- players fired at the host (hp 100 -> 1 in seconds, then the headless host crashed on its own death), see docs/spikes/PT1-anom3.md
        add({ check = "guest_has_map_teslas", timeout = 30, cond = function()
            poll()
            local h = haz[WATCH.tesla]
            T.log("PT|info guest Tesla: %s", h and string.format("role=%d dist=%.0f", h.role, h.dist) or "none")
            return h ~= nil and h.role == 1
        end })
        -- smhost un-froze the host's hazards: the zone's Tesla leaves and the guest moves far (> 6000 uu) from the host (anomwake2 pattern),
        -- so only the guest can be hit and "host not hurt" means something
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
        -- pickpocket: a Part Stealer within reach of the guest takes a backpack item (the game only reaches for the host's character)
        local stealer
        add({ check = "guest_has_items", timeout = 30, cond = function() poll(); return guestBag >= 1 end })
        add({ run = function()
            poll(); bagBefore, guestHp0 = guestBag, guestHp
            local x, y, z = nearGuest(0, 600)
            stealer = spawn(CLS.stealer, x, y, z + 200)
            T.log("PT|info spawned stealer %s near the guest, guest bag=%d hp=%.0f", T.name(stealer), bagBefore, guestHp0)
        end })
        sees("stealer")
        add({ check = "guest_item_stolen", timeout = 60, cond = function()
            poll()
            T.log("PT|info stealer state=%s guest bag=%d (was %d) hp=%.0f", tostring(stealer:IsValid() and stealer.State), guestBag, bagBefore, guestHp)
            return guestBag < bagBefore
        end })
        add({ check = "pickpocket_hurt_guest", timeout = 10, cond = function() poll(); return guestHp < guestHp0 - 1 end })
        add({ check = "stealer_holds_item", timeout = 15, cond = function()
            local ok, g = pcall(function() return stealer.GrabbedMesh end)
            T.log("PT|info stealer GrabbedMesh=%s", tostring(ok and g and g:IsValid() and g:GetFullName()))
            return ok and g and g:IsValid()
        end })
        add({ run = function() if stealer and stealer:IsValid() then stealer:K2_DestroyActor() end end })
        -- bunny: the guest sees it and its push hurts the guest
        local bunny
        add({ run = function()
            poll(); guestHp0, hostHp0, maxSpd = guestHp, health(), 0 -- the Pufferfish pushes on its own as soon as the guest is in range (smhost): baselines at the spawn
            bunny = spawn(CLS.bunny, nearGuest(400, 0))
            T.log("PT|info spawned bunny %s guestHp=%.0f hostHp=%.0f", T.name(bunny), guestHp0, hostHp0)
        end })
        sees("bunny")
        add({ run = function()
            -- the Pufferfish runs its own AI now (smhost) and wandered off: bring it back to the guest right before the push
            local x, y, z = nearGuest(150, 0)
            bunny:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true)
            local ok, r = pcall(function() return bunny.PlayerPusher.Radius end)
            T.log("PT|info bunny PushRadius=%s dist to guest=%.0f", tostring(ok and r), T.dist(bunny, L.guestChar()))
            poll(); hostHp0 = health() -- the guest baselines stay at the spawn: the bunny's own push or this one both count
            pcall(function() bunny:PushFx() end) -- the game's push step (damage 0.1 intensity, radial force) as a touch starts it
            T.log("PT|info bunny push sent")
        end })
        add({ check = "guest_hurt_by_bunny", timeout = 20, cond = function()
            poll()
            T.log("PT|info bunny: guest hp=%.0f (was %.0f) host hp=%.0f", guestHp, guestHp0, health())
            return guestHp < guestHp0 - 0.5
        end })
        add({ check = "guest_pushed_by_bunny", timeout = 10, cond = function() poll(); T.log("PT|info guest peak speed %.0f", maxSpd); return maxSpd > 100 end })
        add({ check = "host_not_hurt_by_bunny_on_guest", timeout = 5, cond = L.holds(3, function() return health() >= hostHp0 - 0.5 end) })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    local finished, peak = false, 0
    LoopInGameThreadWithDelay(50, function()
        pcall(function()
            local me = T.netMode() == "client" and T.myPawn()
            if me and me:IsValid() then local v = me:GetVelocity(); local sp = math.sqrt(v.X ^ 2 + v.Y ^ 2); peak = math.max(peak, sp) end
        end)
    end)
    local home
    local WATCHL = { "BP_Hazard_Tesla_C", "BP_Hazard_PartStealer_C", "BP_Boon_LootCreature_C" }
    LoopInGameThreadWithDelay(1000, function()
        pcall(function()
            if T.netMode() ~= "client" then return end
            local me, out = T.myPawn(), {}
            if me and me:IsValid() then
                for _, c in ipairs(WATCHL) do
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
            local bag = 0
            if im then pcall(function() bag = im.Inventory_Player:GetNumItems() end) end
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.bag", tostring(bag))
            local v = me and me:IsValid() and me:GetVelocity() or { X = 0, Y = 0, Z = 0 }
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.hp", string.format("%.0f	%.0f", health(), peak)); peak = 0
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then break end
                if kind == "t.end" then finished = true end
                if kind == "t.tp" and me and me:IsValid() then
                    home = home or me:K2_GetActorLocation()
                    local x, y, z = data:match("^(%-?[%d%.]+)	(%-?[%d%.]+)	(%-?[%d%.]+)$")
                    me:K2_SetActorLocation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, false, {}, true)
                end
                if kind == "t.home" and home and me and me:IsValid() then me:K2_SetActorLocation(home, false, {}, true) end
            end
        end)
    end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { wait = 12 }, -- the backpack handshake: the host answers "new guest" and the guest keeps its own backpack
        { run = function()
            local A = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
            local a = StaticFindObject(A)
            if not a:IsValid() then LoadAsset(A); a = StaticFindObject(A) end
            local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
            for _ = 1, 3 do T.first("BP_InventoryManager_C").Inventory_Player:AddItem(lib:CreateItemInstance(T.world(), a, 0), true) end
            T.log("PT|info guest given 3 scrap steel, bag now %d", T.first("BP_InventoryManager_C").Inventory_Player:GetNumItems())
        end },
        { check = "client_stays_until_host_done", timeout = 600, cond = function() return finished end },
    }
end
