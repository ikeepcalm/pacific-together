-- Playtest 1 bug A: the loot inside a world vehicle (a wreck's trunk contents, a box truck's cargo) is the host's too.
-- The guest opens such a part with interact, takes every stack out with the loot menu's own transfers, closes the menu ->
-- the host's container is empty and the guest carries each item once.
-- Run: tools/run-test.ps1 -Scenario lootcar -Fixture zone -Headless
-- Mutation nocarloot: loot.lua does not carry a part's container: the host still has the items -> FAILS.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function im() return T.first("BP_InventoryManager_C") end
    local function carried() local m = im(); return m.Inventory_Player:GetNumItems() + m.Inventory_PlayerHand:GetNumItems() end
    local function menuOpen() local o = {}; local ok = pcall(function() im():IsPlayerMenuOpen(o, {}) end); return ok and o.IsOpen == true end
    local function path(o) return o:GetFullName():match("^%S+ (.+)$") end
    local function box(a) -- the part's own item container
        local o = {}
        FindObject("BFL_ItemPropertyUtilityFns_C", "Default__BFL_ItemPropertyUtilityFns_C"):GetInstanceContainer(a.ItemInstance, a, o)
        return o.Container
    end
    local function cars() -- cargo parts with something in them, off the Transient duplicates
        local r = {}
        for _, a in ipairs(FindAllOf("BP_TemplatePart_TrunkContents_C") or {}) do
            local l = alive(a) and alive(a.ItemInstance) and a:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) then
                local c = box(a)
                if alive(c) and c:GetNumItems() > 0 then r[#r + 1] = { a = a, x = l.X, y = l.Y, z = l.Z, n = c:GetNumItems() } end
            end
        end
        return r
    end
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
    local function placeGuest(x, y, z)
        L.guestChar():K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local A
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 12 })
        add({ run = function()
            A = cars()[1]
            assert(A, "no cargo part with items on the host")
            placeGuest(A.x + 150, A.y, A.z + 60)
            log("PT|info lootcar part %s n=%d at %.0f,%.0f,%.0f", A.a:GetFullName():sub(1, 90), A.n, A.x, A.y, A.z)
            sendGuest("t.car", string.format("%.0f|%.0f|%.0f|%d", A.x, A.y, A.z, A.n))
        end })
        -- the fixture pack holds only a few items: the guest takes what fits; the host lost exactly that, once
        add({ check = "guest_took_some", timeout = 120, cond = function() return has("t.carok") end })
        add({ check = "host_cargo_lost_what_guest_took", timeout = 60, cond = function()
            local taken = tonumber(got["t.carok"])
            -- >= 1: the fixture's one-slot bag often takes a single item (seen since 2026-11-01); the host's count is the point
            return taken >= 1 and alive(A.a) and box(A.a):GetNumItems() == A.n - taken
        end })
        add({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local copy, n0, want
    local function actSteps(n, name, opts, timeout)
        local id
        add({ run = function() id = T.act_begin(name, opts()) end })
        add({ check = string.format("act%d_%s", n, name), timeout = timeout, cond = function()
            local done, text, ok = T.act_done(id)
            if done then log("PT|info act%d %s: %s", n, name, (text or ""):gsub("\n", " | "):sub(1, 600)) end
            return done and ok
        end })
    end
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_told_car", timeout = 240, cond = function() return has("t.car") end })
    add({ check = "guest_has_cargo_copy", timeout = 60, cond = function()
        local x, y, z, n = got["t.car"]:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
        want = tonumber(n)
        for _, a in ipairs(FindAllOf("BP_TemplatePart_TrunkContents_C") or {}) do
            local l = alive(a) and a:K2_GetActorLocation()
            if l and math.abs(l.X - x) < 80 and math.abs(l.Y - y) < 80 and math.abs(l.Z - z) < 80 then copy = a; return true end
        end
    end })
    -- the copy carries the host's items (the part's own container)
    -- wreck contents (C rows) come once the guest's baseline is applied, ~38 s after the join in this zone (1200+ visual props)
    add({ check = "guest_copy_has_hosts_items", timeout = 60, cond = function() return alive(copy) and box(copy):GetNumItems() == want end })
    add({ wait = 2 })
    actSteps(1, "move_to", function() return { actor = path(copy), radius = 60, timeout = 12 } end, 40)
    -- the fixture character's pack has no slots until it holds something
    add({ run = function()
        local m = im()
        m:GiveItemToPlayer(StaticFindObject("/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"))
        log("PT|info lootcar pack slots=%d items=%d", m.Inventory_Player:GetNumSlots(), m.Inventory_Player:GetNumItems())
        n0 = carried()
    end })
    -- the cargo's highlight is not hit by a headless aim (as the car trunk's, M6-playpath): the highlight component's own interact
    add({ run = function()
        local me = T.myPawn()
        copy.Highlight:InteractPressed(me)
        copy.Highlight:InteractReleased(me)
    end })
    add({ check = "guest_menu_open_after_interact", timeout = 10, cond = menuOpen })
    add({ run = function()
        local w
        for _, x in ipairs(FindAllOf("UMG_PlayerMenu_Inventory_C") or {}) do if x.TransferContainer:IsValid() then w = x end end
        assert(w, "no inventory menu with a transfer container")
        local tc, m = w.TransferContainer, im()
        log("PT|info lootcar tc=%s same=%s items=%d slots=%d", tc:GetFullName(), tostring(tc:GetFullName() == box(copy):GetFullName()), tc:GetNumItems(), tc:GetNumSlots())
        -- every stack out through the loot menu's own moves: container -> hand -> backpack
        for _ = 1, 200 do
            local s
            for i = 0, tc:GetNumSlots() - 1 do
                local sl = tc:GetSlot(i)
                if sl:IsValid() and sl:GetNumItems() > 0 then s = sl; break end
            end
            if not s then break end
            local before = tc:GetNumItems()
            s:TransferStackIntoContainer(m.Inventory_Player, {})
            if tc:GetNumItems() == before then -- no room in the pack: the hand, then retry
                s:TransferStackIntoContainer(m.Inventory_PlayerHand, {})
                if tc:GetNumItems() == before then break end
            end
        end
    end })
    add({ run = function()
        local m = im()
        log("PT|info lootcar after: box=%d hand=%d bag=%d/%d slots", box(copy):GetNumItems(), m.Inventory_PlayerHand:GetNumItems(), m.Inventory_Player:GetNumItems(), m.Inventory_Player:GetNumSlots())
    end })
    add({ check = "guest_container_lost_items", timeout = 10, cond = function() return box(copy):GetNumItems() < want end })
    add({ run = function() im():RequestPlayerMenuClose() end })
    add({ check = "guest_menu_closed", timeout = 10, cond = function() return not menuOpen() end })
    add({ run = function() sendHost("t.carok", tostring(carried() - n0)) end })
    add({ wait = 5 })
    return steps
end
