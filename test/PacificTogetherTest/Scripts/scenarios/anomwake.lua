-- anomwake: hazards wake and act on the GUEST when the host is far away (host-only range checks, docs/spikes/anomwake.md).
--   The guest stands next to a map Tesla, 40000+ uu from the awake host: it takes the discharge, the host does not.
--   Then, with the Tesla gone, a bunny and a pickpocket spawned next to the guest: the bunny notices the guest (state leaves idle),
--   the pickpocket takes a backpack item.
-- Run: tools/run-test.ps1 -Scenario anomwake -Fixture zone -Headless ; mutation noanomtesla = host-range-only hazards (old behaviour).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local CLS = {
        stealer = "/Game/Gameplay/Hazards/PartStealer/BP_Hazard_PartStealer.BP_Hazard_PartStealer_C",
        bunny = "/Game/Gameplay/Boons/ChubbyBunny/BP_Boon_LootCreature.BP_Boon_LootCreature_C",
    }
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local function health()
        local rm = T.first("BP_ResourceManager_C")
        local h = rm and rm.PlayerHealth
        return (h and h:IsValid()) and h.Current or -1
    end
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
        local gpc, tesla, guestHp, guestBag = nil, nil, -1, 0
        local hostHp0 = -1
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.hp" then guestHp = tonumber(data) or guestHp end
                if kind == "t.bag" then guestBag = tonumber(data) or guestBag end
            end
        end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        local gl
        add({ run = function()
            gpc = L.remotePCs()[1]
            for _, o in ipairs(FindAllOf("BP_Hazard_Tesla_C") or {}) do
                if T.inWorld(o) and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then tesla = tesla or o end
            end
            assert(tesla, "no map Tesla")
            local l = tesla:K2_GetActorLocation()
            hostHp0 = health()
            gl = { X = l.X + 400, Y = l.Y, Z = l.Z + 150 }
            PTNative_MsgToGuest(gpc:GetAddress(), "t.tp", string.format("%.0f\t%.0f\t%.0f", gl.X, gl.Y, gl.Z))
            pcall(function() L.guestChar():K2_TeleportTo(gl, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
        end })
        add({ check = "host_far_from_guest", timeout = 30, cond = function()
            local d = T.dist(L.guestChar(), T.myPawn())
            T.log("PT|info host-guest distance %.0f", d)
            return d > 6000
        end })
        add({ check = "guest_hurt_by_tesla", timeout = 150, cond = function()
            poll()
            T.log("PT|info guest hp=%.0f host hp=%.0f tesla tick=%s", guestHp, health(), tostring(tesla:IsActorTickEnabled()))
            return guestHp >= 0 and guestHp < 99
        end })
        add({ check = "host_not_hurt_by_tesla", timeout = 8, cond = L.holds(6, function() local h = health(); T.log("PT|info host hp=%.1f (start %.1f)", h, hostHp0); return h >= hostHp0 - 0.5 end) })
        -- the Tesla leaves; the other anomalies come to the guest
        add({ run = function()
            tesla:K2_SetActorLocation({ X = gl.X + 30000, Y = gl.Y, Z = gl.Z + 3000 }, false, {}, true)
            tesla:K2_DestroyActor()
        end })
        add({ wait = 3 })
        local bunny, bst0
        local function bstate() local ok, v = pcall(function() return bunny["Current State"] end); return ok and v or -1 end
        add({ run = function()
            bunny = spawn(CLS.bunny, gl.X, gl.Y + 500, gl.Z)
            bst0 = bstate()
            T.log("PT|info bunny %s spawned near the guest, state %s tick=%s", T.name(bunny), tostring(bst0), tostring(bunny:IsActorTickEnabled()))
        end })
        add({ check = "bunny_notices_guest", timeout = 60, cond = function()
            -- the bunny's own range check (host-camera based in the game) asked directly, as its tick does
            local o = {}; local car, cd, pin, pd = o, o, o, o
            local ok, err = pcall(function() bunny:IsPlayerInRange(1500, car, cd, pin, pd) end)
            T.log("PT|info bunny IsPlayerInRange ok=%s %s in=%s dist=%s state=%s dist guest %.0f host %.0f", tostring(ok), ok and "" or tostring(err),
                tostring(pin.PlayerInRange), tostring(pd.playerDistance), tostring(bstate()), T.dist(bunny, L.guestChar()), T.dist(bunny, T.myPawn()))
            return ok and pin.PlayerInRange == true
        end })
        local stealer, bagBefore
        add({ check = "guest_has_items", timeout = 30, cond = function() poll(); return guestBag >= 1 end })
        add({ run = function()
            poll(); bagBefore = guestBag
            stealer = spawn(CLS.stealer, gl.X, gl.Y - 600, gl.Z + 200)
            -- the stealer idles in state 0 with its floating core 1000-1700 uu from where it spawned (the mod's reach is 1200 from the CORE), so the steal only fired when it hung close enough: put the core 400 uu from the guest
            pcall(function()
                local core, g = stealer.CoreFloatingMesh, L.guestChar():K2_GetActorLocation()
                core:K2_SetWorldLocation({ X = g.X, Y = g.Y - 400, Z = g.Z + 150 }, false, {}, true)
            end)
            T.log("PT|info stealer %s spawned near the guest, bag=%d", T.name(stealer), bagBefore)
            LoopInGameThreadWithDelay(3000, function() -- diagnosis (2026-11-20): where the level's Abductors are while the stealer works
                if not stealer:IsValid() then return true end
                pcall(function()
                    local g, c = L.guestChar(), stealer.CoreFloatingMesh:K2_GetComponentLocation()
                    local gl = g:K2_GetActorLocation()
                    local parts = {}
                    for _, o in ipairs(FindAllOf("BP_Hazard_PhysicsGrabber_C") or {}) do
                        if T.inWorld(o) and not o:GetFullName():find("Default__", 1, true) then
                            local l = o:K2_GetActorLocation()
                            parts[#parts + 1] = string.format("st%s d_guest=%.0f d_stealer=%.0f", tostring(o.CurrentPatStealerState), T.dist(o, g), math.sqrt((l.X - c.X) ^ 2 + (l.Y - c.Y) ^ 2 + (l.Z - c.Z) ^ 2))
                        end
                    end
                    T.log("PT|info diag stealer core->guest %.0f, grabbers: %s", math.sqrt((gl.X - c.X) ^ 2 + (gl.Y - c.Y) ^ 2 + (gl.Z - c.Z) ^ 2), table.concat(parts, " | "))
                end)
                return false
            end)
        end })
        add({ check = "guest_item_stolen", timeout = 90, cond = function()
            poll()
            T.log("PT|info stealer state=%s guest bag=%d (was %d)", tostring(stealer:IsValid() and stealer.State), guestBag, bagBefore)
            return guestBag < bagBefore
        end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    local finished = false
    LoopInGameThreadWithDelay(1000, function() pcall(function()
        if T.netMode() ~= "client" then return end
        local me = T.myPawn()
        PTNative_MsgToHost(T.localPC():GetAddress(), "t.hp", string.format("%.0f", health()))
        local bag, im = 0, T.first("BP_InventoryManager_C")
        if im then pcall(function() bag = im.Inventory_Player:GetNumItems() end) end
        PTNative_MsgToHost(T.localPC():GetAddress(), "t.bag", tostring(bag))
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then break end
            if kind == "t.end" then finished = true end
            if kind == "t.tp" and me and me:IsValid() then
                local x, y, z = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                me:K2_SetActorLocation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, false, {}, true)
            end
        end
    end) end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { wait = 12 },
        { run = function()
            local A = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
            local a = StaticFindObject(A)
            if not a:IsValid() then LoadAsset(A); a = StaticFindObject(A) end
            local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
            for _ = 1, 3 do T.first("BP_InventoryManager_C").Inventory_Player:AddItem(lib:CreateItemInstance(T.world(), a, 0), true) end
        end },
        { check = "client_stays_until_host_done", timeout = 600, cond = function() return finished end },
    }
end
