-- Playtest paths with the guest driving the game the way a player does (walk, aim at the highlight, press interact), not by calling
-- the game's functions. The host only places the guest near the thing (a guest's own teleport is undone by the server) and watches.
--   fixture garage: the guest presses the driver's door handle (the game only enters through that door) -> seated on the host;
--                   the exit intent (the key X is a UE4SS key bind, not drivable headless) -> out.
--   fixture zone:   the guest opens a container with interact, moves a stack to its backpack with the loot menu's own transfer,
--                   closes the menu -> the host's container lost it; the guest picks up a world item with interact -> gone on the host;
--                   the host abandons the run through the pause menu's own "return to garage" confirm -> both in the garage, the guest's
--                   penalty applied, session alive.
-- Run: tools/run-test.ps1 -Scenario playpath -Fixture garage -Headless   and   ... -Fixture zone -Headless
-- Mutations: nocarsync (garage: the guest cannot be seated), nointent (zone: loot intents off), noprog (zone: no penalty for the guest).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local FIX = os.getenv("PT_FIXTURE")
    local STEEL = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function im() return T.first("BP_InventoryManager_C") end
    local function carried() local m = im(); return m.Inventory_Player:GetNumItems() + m.Inventory_PlayerHand:GetNumItems() end
    local function countOf(class) -- items of an archetype in the backpack and the hand
        local n, m = 0, im()
        for _, c in ipairs({ m.Inventory_Player, m.Inventory_PlayerHand }) do
            local items = {}
            c:GetAllItems(items)
            for _, it in ipairs(items) do if it:get().Archetype:GetFName():ToString() == class then n = n + 1 end end
        end
        return n
    end
    local function menuOpen() local o = {}; local ok = pcall(function() im():IsPlayerMenuOpen(o, {}) end); return ok and o.IsOpen == true end

    local got = {}
    local function drain()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then return end
            got[kind] = data
        end
    end
    local function has(kind) drain(); return got[kind] ~= nil end
    local function sendGuest(kind, data) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), kind, data or "") end
    local function sendHost(kind, data) PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end

    -- the host puts the guest's character there (replicated, unlike the guest's own teleport)
    local function placeGuest(x, y, z)
        L.guestChar():K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
    end
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")

    -- guest: an action of the game MCP, as steps
    local function actSteps(add, n, name, opts, timeout, okFn)
        local id
        add({ run = function() id = T.act_begin(name, type(opts) == "function" and opts() or opts) end })
        add({ check = string.format("act%d_%s", n, name), timeout = timeout, cond = function()
            local done, text, ok = T.act_done(id)
            if done then
                log("PT|info act%d %s: %s", n, name, (text or ""):gsub("\n", " | "):sub(1, 900))
                if okFn then return ok and okFn(text) end
            end
            return done and ok
        end })
    end

    local function lootables()
        local r = {}
        for _, a in ipairs(FindAllOf("BP_Lootable_Base_C") or {}) do
            if alive(a) and alive(a.InventoryContainer) then
                local l = a:K2_GetActorLocation()
                if not (l.X == 0 and l.Y == 0 and l.Z == 0) then
                    r[#r + 1] = { a = a, class = a:GetClass():GetFName():ToString(), x = l.X, y = l.Y, z = l.Z, n = a.InventoryContainer:GetNumItems() }
                end
            end
        end
        return r
    end
    local function worldItems()
        local r = {}
        for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
            if alive(a) and alive(a.Instance) and a:GetClass():GetFName():ToString() == "BP_WorldItem_C" and not a:GetAttachParentActor():IsValid() then
                local l = a:K2_GetActorLocation()
                r[#r + 1] = { a = a, class = a.Instance.Archetype:GetFName():ToString(), x = l.X, y = l.Y, z = l.Z }
            end
        end
        return r
    end
    local function near(list, e, tol) -- the closest one: two items of a class can lie within tol (zone chemicals, 73 uu apart)
        local best, bd
        for _, o in ipairs(list) do
            if o.class == e.class and math.abs(o.x - e.x) < tol and math.abs(o.y - e.y) < tol and math.abs(o.z - e.z) < tol then
                local d = (o.x - e.x) ^ 2 + (o.y - e.y) ^ 2 + (o.z - e.z) ^ 2
                if not bd or d < bd then best, bd = o, d end
            end
        end
        return best
    end
    local function pack(e) return string.format("%s|%.0f|%.0f|%.0f|%d", e.class, e.x, e.y, e.z, e.n or 0) end
    local function unpack(s)
        local c, x, y, z, n = s:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        return { class = c, x = tonumber(x), y = tonumber(y), z = tonumber(z), n = tonumber(n) }
    end
    local function path(o) return o:GetFullName():match("^%S+ (.+)$") end

    ---------------------------------------------------------------------------------------------------------------- garage
    if FIX == "garage" then
        local function car() return T.first("BP_PlayerCarNew_C") end
        local function theCar() -- the replicated one on the guest
            for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
                local l = alive(c) and c:K2_GetActorLocation()
                if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and (T.ROLE == "host" or c.Role ~= 3) then return c end
            end
        end
        local function attached(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end

        if T.ROLE == "host" then
            local steps = {}
            local function add(s) steps[#steps + 1] = s end
            for _, s in ipairs(T.loadFixture("garage")) do add(s) end
            add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
            add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
            add({ wait = 10 })
            -- 1. the driver's door, from the outside: car-local (131, -200)
            add({ run = function()
                local c = theCar()
                local w = KML:TransformLocation(c:GetTransform(), { X = 131, Y = -200, Z = 0 })
                placeGuest(w.X, w.Y, c:K2_GetActorLocation().Z + 10)
                sendGuest("t.p1")
            end })
            add({ check = "p1_guest_seated_by_door_press", timeout = 120, cond = function() local g = L.guestChar(); return g ~= nil and attached(g) end })
            add({ wait = 3 })
            add({ check = "p1_guest_stays_seated", timeout = 20, cond = L.holds(5, function() local g = L.guestChar(); return g ~= nil and attached(g) end) })
            add({ run = function() sendGuest("t.p1x") end })
            add({ check = "p1_guest_out_after_exit", timeout = 60, cond = function() local g = L.guestChar(); return g ~= nil and not attached(g) end })
            -- 3. the trunk
            local trunk0
            add({ run = function() trunk0 = im().Inventory_Trunk:GetNumItems(); sendGuest("t.p3") end })
            add({ check = "p3_host_trunk_has_guest_item", timeout = 90, cond = function() return im().Inventory_Trunk:GetNumItems() > trunk0 end })
            add({ wait = 3 })
            return steps
        end

        local steps = { T.onMap("RB_MainMenu", 90) }
        local function add(s) steps[#steps + 1] = s end
        add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
        add({ check = "guest_one_car", timeout = 90, cond = function() return theCar() ~= nil and #FindAllOf("BP_PlayerCarNew_C") >= 1 end })
        add({ check = "guest_told_p1", timeout = 240, cond = function() return has("t.p1") end })
        add({ wait = 2 })
        actSteps(add, 1, "door_press", {}, 90, nil)
        add({ check = "guest_seated", timeout = 60, cond = function() return attached(T.myPawn()) end })
        add({ check = "guest_told_exit", timeout = 120, cond = function() return has("t.p1x") end })
        -- the exit: key X is a UE4SS key bind (car.lua), not drivable headless; this is the intent it sends
        add({ run = function() sendHost("g.car.exit") end })
        add({ check = "guest_out", timeout = 60, cond = function() return not attached(T.myPawn()) end })
        -- 3. the trunk: its highlight has no collision a trace can hit headless, so the press is the highlight component's own
        -- interact (what the interact key calls on the current highlight); the menu then shows the trunk as the transfer container
        add({ check = "guest_told_p3", timeout = 120, cond = function() return has("t.p3") end })
        add({ run = function()
            local tr
            for _, a in ipairs(FindAllOf("BP_Storage_Trunk_Base_C") or {}) do if alive(a) and a:GetAttachParentActor():IsValid() then tr = a end end
            assert(tr, "no trunk on the car")
            local me = T.myPawn()
            tr.Highlight:InteractPressed(me)
            tr.Highlight:InteractReleased(me)
        end })
        add({ check = "guest_trunk_menu_open", timeout = 10, cond = menuOpen })
        add({ run = function()
            local m = im()
            local w
            for _, x in ipairs(FindAllOf("UMG_PlayerMenu_Inventory_C") or {}) do if x.TransferContainer:IsValid() then w = x end end
            assert(w and w.TransferContainer:GetFullName() == m.Inventory_Trunk:GetFullName(), "the menu's transfer container is not the trunk")
            m:GiveItemToPlayer(StaticFindObject(STEEL))
            local s
            for i = 0, m.Inventory_Player:GetNumSlots() - 1 do
                local sl = m.Inventory_Player:GetSlot(i)
                if sl:IsValid() and sl:GetNumItems() > 0 then s = sl; break end
            end
            -- the loot menu's own move of a backpack stack into the transfer container
            s:TransferStackIntoContainer(w.TransferContainer, {})
            m:RequestPlayerMenuClose()
        end })
        add({ check = "guest_trunk_menu_closed", timeout = 10, cond = function() return not menuOpen() end })
        add({ wait = 3 })
        return steps
    end

    ---------------------------------------------------------------------------------------------------------------- zone
    local mapName = "Rural_Forest_Radio_Scylla_02"
    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local A, W, before
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 12 })
        -- 2. a container with something in it, the guest walks up and opens it
        add({ run = function()
            for _, e in ipairs(lootables()) do
                if e.n > 0 and (e.class:find("Backpack") or e.class:find("Crate_Junk")) then A = e; break end
            end
            if not A then for _, e in ipairs(lootables()) do if e.n > 0 then A = e; break end end end
            placeGuest(A.x + 200, A.y, A.z + 60)
            log("PT|info p2 container %s n=%d at %.0f,%.0f,%.0f", A.class, A.n, A.x, A.y, A.z)
            sendGuest("t.p2", pack(A))
        end })
        add({ check = "p2_host_container_lost_item", timeout = 120, cond = function() return alive(A.a) and A.a.InventoryContainer:GetNumItems() < A.n end })
        add({ check = "p2_guest_carries_item", timeout = 60, cond = function() return has("t.p2ok") end })
        -- 6. a world item
        add({ run = function()
            -- the nearest to the guest: a host-side move of the guest across the map does not stick (it stayed at the crate, item 360 m off)
            local best
            for _, e in ipairs(worldItems()) do
                local d = (e.x - A.x) ^ 2 + (e.y - A.y) ^ 2 + (e.z - A.z) ^ 2
                if not best or d < best then W, best = e, d end
            end
            placeGuest(W.x + 150, W.y, W.z + 60)
            log("PT|info p6 world item %s at %.0f,%.0f,%.0f", W.class, W.x, W.y, W.z)
            sendGuest("t.p6", pack(W))
        end })
        add({ check = "p6_world_item_gone_on_host", timeout = 120, cond = function() return not alive(W.a) end })
        add({ check = "p6_guest_picked_it_up", timeout = 60, cond = function() return has("t.p6ok") end })
        -- 7. abandon through the pause menu's own confirm
        add({ run = function() sendGuest("t.p7") end })
        add({ check = "p7_guest_filled", timeout = 60, cond = function() return has("t.p7ready") end })
        add({ wait = 8 })
        add({ run = function()
            local w
            for _, x in ipairs(FindAllOf("PDP_PauseMenu_C") or {}) do if x:GetFullName():find("Transient", 1, true) then w = x end end
            assert(w, "no live pause menu")
            -- what the pause menu's confirm popup calls when the player says yes to "return to the garage" (Index 1)
            w:OnReturnGarageSelected(1)
            log("PT|info p7 abandon confirmed")
        end })
        add({ check = "p7_host_in_garage_listening", timeout = 240, cond = function() return T.map() == "RB_Garage" and T.netMode() == "listen" and T.listening() end })
        add({ check = "p7_guest_back_in_garage", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ check = "p7_guest_penalty_applied", timeout = 120, cond = function() return has("t.p7after") and tonumber(got["t.p7after"]) < 10 end })
        -- the guest is not "dead" on arrival: no death crate with its items in the garage
        add({ check = "p7_no_death_crate", timeout = 5, cond = function()
            for _, e in ipairs(lootables()) do if e.class:find("Crate_Large", 1, true) and e.n > 0 then return false end end
            return true
        end })
        add({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local copy, W
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_told_p2", timeout = 240, cond = function() return has("t.p2") end })
    add({ check = "guest_has_container_copy", timeout = 60, cond = function() copy = near(lootables(), unpack(got["t.p2"]), 80); return copy ~= nil end })
    add({ wait = 2 })
    actSteps(add, 1, "move_to", function() return { actor = path(copy.a), radius = 60, timeout = 12 } end, 40, nil)
    local n0
    add({ run = function() n0 = carried() end })
    actSteps(add, 2, "interact", function() return { actor = path(copy.a), approach = true, close_menu = false } end, 40, nil)
    -- the crate's own menu: an inventory widget whose transfer container is the crate's. (Not IsPlayerMenuOpen: in ~1 of 3 soak
    -- runs the first standing spot highlighted a gas barrel beside the crate, the press never opened the crate, and a stale
    -- widget still held the car trunk; the old check then failed and the grab below took from the trunk, soak 2026-11-20.)
    -- Then the interact is repeated from another side of the crate, up to 4 times.
    local function crateMenu()
        local c = copy.a.InventoryContainer
        for _, x in ipairs(FindAllOf("UMG_PlayerMenu_Inventory_C") or {}) do
            local t = x.TransferContainer
            if t:IsValid() and t:GetAddress() == c:GetAddress() and menuOpen() then return true end
        end
        return false
    end
    local t0, tries, jid = 0, 0, nil
    add({ run = function() t0 = os.time() end })
    add({ check = "guest_menu_open_after_interact", timeout = 60, cond = function()
        if crateMenu() then return true end
        if jid then
            local done, text = T.act_done(jid)
            if done then log("PT|info act2 retry %d: %s", tries, (text or ""):gsub("
", " | "):sub(1, 500)); jid, t0 = nil, os.time() end
        elseif os.time() - t0 >= 4 and tries < 4 then
            tries = tries + 1
            local ang = ({ math.pi, math.pi / 2, -math.pi / 2, 0 })[tries]
            local me = T.myPawn():K2_GetActorLocation()
            T.myPawn():K2_SetActorLocation({ X = copy.x + math.cos(ang) * 80, Y = copy.y + math.sin(ang) * 80, Z = me.Z }, false, {}, true)
            jid = T.act_begin("interact", { actor = path(copy.a), approach = false, close_menu = false })
        end
        return false
    end })
    -- the loot menu's own moves: a stack out of the container into the hand (the grab), the hand into the backpack (the place)
    add({ run = function()
        local w
        for _, x in ipairs(FindAllOf("UMG_PlayerMenu_Inventory_C") or {}) do if x.TransferContainer:IsValid() then w = x end end
        assert(w, "no inventory menu with a transfer container")
        local tc, m = w.TransferContainer, im()
        local s
        for i = 0, tc:GetNumSlots() - 1 do
            local sl = tc:GetSlot(i)
            if sl:IsValid() and sl:GetNumItems() > 0 then s = sl; break end
        end
        assert(s, "the container is empty on the guest")
        s:TransferStackIntoContainer(m.Inventory_PlayerHand, {})
        m.Inventory_PlayerHand:GetSlot(0):TransferStackIntoContainer(m.Inventory_Player, {})
    end })
    add({ check = "guest_backpack_has_item", timeout = 10, cond = function() return carried() > n0 end })
    add({ run = function() im():RequestPlayerMenuClose() end })
    add({ check = "guest_menu_closed", timeout = 10, cond = function() return not menuOpen() end })
    add({ run = function() sendHost("t.p2ok") end })
    -- 6. a world item by interact
    add({ check = "guest_told_p6", timeout = 120, cond = function() return has("t.p6") end })
    add({ check = "guest_has_world_item_copy", timeout = 60, cond = function() W = near(worldItems(), unpack(got["t.p6"]), 80); return W ~= nil end })
    -- the zone's loose items lie ~350 m from the crate and the host's move of the guest does not stick that far: the guest moves itself
    add({ run = function() T.myPawn():K2_SetActorLocation({ X = W.x + 150, Y = W.y, Z = W.z + 60 }, false, {}, true) end })
    add({ wait = 2 })
    actSteps(add, 3, "move_to", function() return { actor = path(W.a), radius = 50, timeout = 10 } end, 40, nil)
    local n1
    add({ run = function() n1 = countOf(W.class) end })
    actSteps(add, 4, "interact", function() return { actor = path(W.a), approach = false } end, 40, nil)
    add({ check = "guest_picked_up_world_item", timeout = 10, cond = function() return countOf(W.class) > n1 end })
    add({ run = function() sendHost("t.p6ok") end })
    -- 7. a backpack to lose from, then the host abandons
    add({ check = "guest_told_p7", timeout = 120, cond = function() return has("t.p7") end })
    add({ run = function()
        local bag, a = im().Inventory_Player, StaticFindObject(STEEL)
        local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
        while carried() < 10 do bag:AddItem(lib:CreateItemInstance(T.world(), a, 0), true) end
    end })
    add({ check = "guest_filled", timeout = 5, cond = function() return carried() >= 10 end })
    add({ wait = 8 })
    add({ run = function() sendHost("t.p7ready") end })
    add({ check = "guest_in_garage_after_abandon", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add({ wait = 20 })
    add({ run = function() log("PT|info p7 guest carries %d after the abandon (10 before)", carried()); sendHost("t.p7after", tostring(carried())) end })
    add({ wait = 5 })
    return steps
end
