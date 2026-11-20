-- M4 shared items (W1, W2, C6, G1, P2, P3) in the zone fixture, host and guest in one session:
--   the guest's lootables are the host's (same classes, spots, contents); the guest takes from a host container through the game's
--   own transfer -> the host's container lost it and the guest carries it; the host takes from another one -> the guest's copy lost it;
--   a world pickup by the guest is gone on the host; one by the host is gone on the guest; the host puts an item in the car trunk ->
--   the guest sees it; the guest puts one in -> the host has it.
-- Run: tools/run-test.ps1 -Scenario lootsync -Fixture zone -Headless
-- Mutation nointent: loot.lua sends and applies nothing (the guest keeps its own world): the checks FAIL.
-- Mutation hold: both sides stay in the session after joining (for the live console).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local STEEL = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
    local TAPE = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawTape/IA_Resource_Raw_Tape.IA_Resource_Raw_Tape"
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function im() return T.first("BP_InventoryManager_C") end
    local function cname(a) return a:GetClass():GetFName():ToString() end
    local function carried() local m = im(); return m.Inventory_Player:GetNumItems() + m.Inventory_PlayerHand:GetNumItems() end
    local function countOf(c, path)
        local items, n = {}, 0
        c:GetAllItems(items)
        for _, it in ipairs(items) do if it:get().Archetype:GetFullName():find(path:match("[^/]+$"), 1, true) then n = n + 1 end end
        return n
    end
    local function lootables()
        local r = {}
        for _, a in ipairs(FindAllOf("BP_Lootable_Base_C") or {}) do
            if alive(a) then
                local l = a:K2_GetActorLocation()
                r[#r + 1] = { a = a, class = cname(a), x = l.X, y = l.Y, z = l.Z, n = a.InventoryContainer:GetNumItems() }
            end
        end
        return r
    end
    local function worldItems()
        local r = {}
        for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
            if alive(a) and alive(a.Instance) and cname(a) == "BP_WorldItem_C" and not a:GetAttachParentActor():IsValid() then
                local l = a:K2_GetActorLocation()
                r[#r + 1] = { a = a, class = a.Instance.Archetype:GetFName():ToString(), x = l.X, y = l.Y, z = l.Z }
            end
        end
        return r
    end
    local function at(list, e, tol)
        for _, o in ipairs(list) do
            if o.class == e.class and math.abs(o.x - e.x) < (tol or 50) and math.abs(o.y - e.y) < (tol or 50) and math.abs(o.z - e.z) < (tol or 50) then return o end
        end
    end
    local function pack(e) return string.format("%s|%.0f|%.0f|%.0f|%s", e.class, e.x, e.y, e.z, tostring(e.n or 0)) end
    local function unpack(s)
        local c, x, y, z, n = s:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        return { class = c, x = tonumber(x), y = tonumber(y), z = tonumber(z), n = tonumber(n) }
    end
    local function add(inst, path, container)
        local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
        container:AddItem(lib:CreateItemInstance(T.world(), StaticFindObject(path), 0), true)
    end
    -- the first stack of a container into the empty hand slot (the game's own transfer the loot UI uses)
    local function takeStack(c)
        for i = 0, c:GetNumSlots() - 1 do
            local s = c:GetSlot(i)
            if s:IsValid() and s:GetNumItems() > 0 then s:TransferStackIntoContainer(im().Inventory_PlayerHand, {}); return end
        end
    end

    -- messages between the two test processes ("t." kind, latest data per kind)
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

    if T.MUTATE == "hold" then
        local hold = { check = "hold_stopped", timeout = 86400, cond = T.replStopped }
        if T.ROLE == "host" then
            local steps = T.loadFixture("zone")
            steps[#steps + 1] = { check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() end }
            steps[#steps + 1] = { check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end }
            steps[#steps + 1] = hold
            return steps
        end
        return { T.onMap("RB_MainMenu", 90), { check = "client_in", timeout = 240, cond = function() return T.netMode() == "client" and T.cls(T.myPawn()) == T.CHAR end }, hold }
    end

    if T.ROLE == "host" then
        local steps = {}
        local function step(s) steps[#steps + 1] = s end
        local A, B, W1, W2, before2, trunkN
        for _, s in ipairs(T.loadFixture("zone")) do step(s) end
        step({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() end })
        step({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        step({ wait = 8 })
        -- what the guest must see
        step({ run = function()
            local list, rows = lootables(), {}
            for _, e in ipairs(list) do
                local items, t = {}, {}
                e.a.InventoryContainer:GetAllItems(items)
                for _, it in ipairs(items) do t[#t + 1] = it:get().Archetype:GetFName():ToString() end
                table.sort(t)
                rows[#rows + 1] = pack(e) .. "|" .. table.concat(t, ",")
            end
            T.log("PT|info host lootables=%d", #list)
            sendGuest("t.snap", table.concat(rows, "\n"))
        end })
        step({ check = "host_guest_sees_lootables", timeout = 90, cond = function() return has("t.snapok") end })
        -- 1. the guest takes from a host container
        step({ run = function()
            for _, e in ipairs(lootables()) do if e.n > 0 then A = e; break end end
            T.log("PT|info take1 from %s n=%d", A.class, A.n)
            sendGuest("t.take1", pack(A))
        end })
        step({ check = "host_container_lost_guest_take", timeout = 30, cond = function() return A.a.InventoryContainer:GetNumItems() < A.n end })
        step({ check = "host_guest_carries_take", timeout = 30, cond = function() return has("t.take1ok") end })
        -- 2. the host takes from another one
        step({ run = function()
            for _, e in ipairs(lootables()) do if e.n > 0 and e.a:GetFullName() ~= A.a:GetFullName() then B = e; break end end
            takeStack(B.a.InventoryContainer)
            T.log("PT|info take2 from %s n=%d -> %d", B.class, B.n, B.a.InventoryContainer:GetNumItems())
            sendGuest("t.take2", pack(B))
        end })
        step({ check = "host_guest_sees_host_take", timeout = 30, cond = function() return has("t.take2ok") end })
        -- 3. the guest picks up a world item
        step({ run = function()
            local w = worldItems()
            W1, W2 = w[1], w[2]
            T.log("PT|info world items=%d pick1=%s", #w, W1.class)
            sendGuest("t.pick1", pack(W1))
        end })
        step({ check = "host_world_item_gone_after_guest_pickup", timeout = 30, cond = function() return not alive(W1.a) end })
        step({ check = "host_guest_carries_pickup", timeout = 30, cond = function() return has("t.pick1ok") end })
        -- 4. the host picks one up
        step({ run = function()
            local own = L.own()
            own["Pickup Actor"](own, W2.a, false)
            sendGuest("t.pick2", pack(W2))
        end })
        step({ check = "host_pickup_done", timeout = 30, cond = function() return not alive(W2.a) end })
        step({ check = "host_guest_copy_gone_after_host_pickup", timeout = 30, cond = function() return has("t.pick2ok") end })
        -- 5. the host puts an item into the trunk, 6. the guest puts one in
        step({ run = function()
            add(nil, STEEL, im().Inventory_Trunk)
            trunkN = im().Inventory_Trunk:GetNumItems()
            sendGuest("t.trunk1", tostring(trunkN))
        end })
        step({ check = "host_guest_sees_trunk_item", timeout = 30, cond = function() return has("t.trunk1ok") end })
        step({ check = "host_trunk_has_guest_item", timeout = 30, cond = function()
            return countOf(im().Inventory_Trunk, TAPE) >= 1
        end })
        step({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function step(s) steps[#steps + 1] = s end
    local c0
    step({ check = "client_in", timeout = 240, cond = function() return T.netMode() == "client" and T.cls(T.myPawn()) == T.CHAR end })
    step({ check = "guest_got_snapshot", timeout = 120, cond = function() return has("t.snap") end })
    -- the guest's lootables are the host's: same class, spot and contents, and nothing else
    local why, whyT = "", 0
    step({ check = "guest_lootables_match_host", timeout = 90, cond = function()
        local mine, rows = lootables(), {}
        for r in got["t.snap"]:gmatch("[^\n]+") do rows[#rows + 1] = r end
        local ok = #mine == #rows
        why = string.format("mine=%d host=%d", #mine, #rows)
        if not ok then
            for _, r in ipairs(rows) do if not at(mine, unpack(r)) then why = why .. " hostonly " .. r:sub(1, 90) end end
            for _, o in ipairs(mine) do
                local f = false
                for _, r in ipairs(rows) do if at({ o }, unpack(r)) then f = true; break end end
                if not f then why = why .. " guestonly " .. pack(o) end
            end
        end
        if ok then
            for _, r in ipairs(rows) do
                local e = unpack(r)
                local o = at(mine, e)
                if not o then why = why .. " missing " .. pack(e); ok = false; break end
                local items, t = {}, {}
                o.a.InventoryContainer:GetAllItems(items)
                for _, it in ipairs(items) do t[#t + 1] = it:get().Archetype:GetFName():ToString() end
                table.sort(t)
                if not r:find("|" .. table.concat(t, ",") .. "$") then why = why .. " contents " .. r .. " vs " .. table.concat(t, ","); ok = false; break end
            end
        end
        if not ok and os.time() - whyT >= 10 then whyT = os.time(); T.log("PT|info lootable match: %s", why) end
        return ok
    end })
    step({ run = function() sendHost("t.snapok") end })
    -- 1
    step({ check = "guest_cmd_take1", timeout = 60, cond = function() return has("t.take1") end })
    step({ run = function()
        c0 = carried()
        local e = unpack(got["t.take1"])
        local o = at(lootables(), e)
        takeStack(o.a.InventoryContainer)
    end })
    step({ check = "guest_carries_taken_stack", timeout = 10, cond = function() return carried() > c0 end })
    step({ run = function() sendHost("t.take1ok") end })
    -- 2
    step({ check = "guest_sees_host_take", timeout = 60, cond = function()
        if not has("t.take2") then return false end
        local e = unpack(got["t.take2"])
        local o = at(lootables(), e)
        return o ~= nil and o.n < e.n
    end })
    step({ run = function() sendHost("t.take2ok") end })
    -- 3
    step({ check = "guest_cmd_pick1", timeout = 60, cond = function() return has("t.pick1") end })
    step({ run = function()
        c0 = carried()
        local e = unpack(got["t.pick1"])
        local o = at(worldItems(), e)
        local me = T.myPawn()
        me["Pickup Actor"](me, o.a, false)
    end })
    step({ check = "guest_pickup_carried", timeout = 10, cond = function() return carried() > c0 end })
    step({ run = function() sendHost("t.pick1ok") end })
    -- 4
    step({ check = "guest_copy_gone_after_host_pickup", timeout = 60, cond = function()
        if not has("t.pick2") then return false end
        return at(worldItems(), unpack(got["t.pick2"])) == nil
    end })
    step({ run = function() sendHost("t.pick2ok") end })
    -- 5, 6
    step({ check = "guest_trunk_matches_host", timeout = 60, cond = function()
        return has("t.trunk1") and countOf(im().Inventory_Trunk, STEEL) >= 1
    end })
    step({ run = function()
        add(nil, TAPE, im().Inventory_Trunk)
        sendHost("t.trunk1ok")
    end })
    step({ wait = 5 })
    return steps
end
