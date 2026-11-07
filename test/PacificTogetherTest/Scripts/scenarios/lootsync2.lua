-- M4 shared items, second pass, zone fixture, host and guest in one session:
--   1. item details: an item put in the car trunk keeps its durability (host -> guest), one with fuel keeps it (guest -> host)
--   2. wrecks: the host's abandoned-car parts exist on the guest (same class, spot, item state); a part the guest scraps is gone on
--      the host; a part the host removes is gone on the guest; a part's item state (siphoned fuel) set on the guest reaches the host
--   3. lootable visuals: a container the host opened and emptied looks opened and empty on the guest
--   4. garage storage: an item the host puts in the garage storage (Inventories_Garage by tag) is in the guest's
-- Run: tools/run-test.ps1 -Scenario lootsync2 -Fixture zone -Headless
-- Mutation nolootsync2: item state, wreck parts and lootable visuals are not synced (loot.lua / ids.lua): the checks FAIL.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local I = "/Game/Gameplay/Inventory/Items/"
    local SCRAPPER = I .. "Tools/Scrapper/IA_Tool_Target_ItemHarvest_Scrapper.IA_Tool_Target_ItemHarvest_Scrapper"
    local FUELCAN = I .. "Tools/FuelCan/FuelCan5G/IA_Tool_Target_FuelCan_5Gal.IA_Tool_Target_FuelCan_5Gal"
    local STEEL = I .. "Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
    local TAPE = I .. "Resources/Basic/RawTape/IA_Resource_Raw_Tape.IA_Resource_Raw_Tape"
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function im() return T.first("BP_InventoryManager_C") end
    local lib = function() return StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary") end
    local function bfl() return FindObject("BFL_ItemPropertyUtilityFns_C", "Default__BFL_ItemPropertyUtilityFns_C") end
    local function p2(o) return o:GetFullName():match("^%S+ (.+)$") end
    local function bits(f) return (string.unpack("<i4", string.pack("<f", f))) end

    local function propAsset(arch, name)
        local r
        arch.Properties:ForEach(function(_, e) local s = e:get(); if s:GetFName():ToString() == name then r = s end end)
        return r
    end
    -- the property components exist once the item is in a container: add first, then set
    local function addItem(c, path, setter)
        local a = StaticFindObject(path)
        local it = lib():CreateItemInstance(T.world(), a, 0)
        c:AddItem(it, true)
        if setter then setter(a, it) end
        return it
    end
    local GARAGE = os.getenv("PT_FIXTURE") == "garage"
    local STORE = "Stations.Install.Inventory.BackRoom"
    local base
    local function count(c, path)
        local items, n = {}, 0
        if not c then return 0 end
        c:GetAllItems(items)
        for _, it in ipairs(items) do if p2(it:get().Archetype):find((path:match("[^/]+$"):gsub("%.[^.]+$", "")), 1, true) then n = n + 1 end end
        return n
    end
    local function garage(tag)
        local r
        im().Inventories_Garage:ForEach(function(k, v) if k:get().TagName:ToString() == tag then r = v:get() end end)
        return r
    end
    local function setDur(a, it, d) lib():SetItemProperty(propAsset(a, "IP_Durability"), it, FName("Durability"), d) end
    local function setFuel(a, it, f) lib():SetItemProperty(propAsset(a, "IP_Fuelable"), it, FName("Fuel"), bits(f)) end
    local function durOf(it) local o = { {}, {}, {}, {}, {} }; bfl():GetDurability(it, T.world(), o[1], o[2], o[3], o[4], o[5]); return o[3].Durability end
    local function fuelOf(it) local o = { {}, {}, {}, {}, {}, {} }; bfl():GetFuelableInfo(it, T.world(), o[1], o[2], o[3], o[4], o[5], o[6]); return o[1].Fuel end
    local function find(c, path, read)
        local items = {}
        c:GetAllItems(items)
        for _, it in ipairs(items) do
            local x = it:get()
            if p2(x.Archetype):find((path:match("[^/]+$"):gsub("%.[^.]+$", "")), 1, true) then return x end
        end
    end

    local function parts()
        local r = {}
        for _, a in ipairs(FindAllOf("LootableTemplatePart") or {}) do
            if alive(a) and alive(a.ItemInstance) and not a:GetFullName():find("/Engine/Transient", 1, true) then
                local l = a:K2_GetActorLocation()
                r[#r + 1] = { a = a, class = a:GetClass():GetFName():ToString(), x = l.X, y = l.Y, z = l.Z }
            end
        end
        table.sort(r, function(p, q) return p.x * 3 + p.y * 7 + p.z < q.x * 3 + q.y * 7 + q.z end)
        return r
    end
    local function pack(e) return string.format("%s|%.0f|%.0f|%.0f", e.class, e.x, e.y, e.z) end
    local function unpack(s)
        local c, x, y, z = s:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)")
        return { class = c, x = tonumber(x), y = tonumber(y), z = tonumber(z) }
    end
    local function at(list, e, tol)
        for _, o in ipairs(list) do
            if o.class == e.class and math.abs(o.x - e.x) < (tol or 40) and math.abs(o.y - e.y) < (tol or 40) and math.abs(o.z - e.z) < (tol or 40) then return o end
        end
    end
    local function lootables()
        local r = {}
        for _, a in ipairs(FindAllOf("BP_Lootable_Base_C") or {}) do
            if alive(a) then
                local l = a:K2_GetActorLocation()
                r[#r + 1] = { a = a, class = a:GetClass():GetFName():ToString(), x = l.X, y = l.Y, z = l.Z, n = a.InventoryContainer:GetNumItems() }
            end
        end
        return r
    end
    -- a part whose item has state we can change: fuel first, else durability
    local function stateful(list)
        for _, e in ipairs(list) do
            local a = e.a.ItemInstance.Archetype
            if propAsset(a, "IP_Fuelable") and fuelOf(e.a.ItemInstance) > 0 then return e, "fuel" end
        end
        for _, e in ipairs(list) do
            local a = e.a.ItemInstance.Archetype
            if propAsset(a, "IP_Durability") then return e, "dur" end
        end
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

    if T.ROLE == "host" then
        local steps = {}
        local function step(s) steps[#steps + 1] = s end
        local function zstep(s) if not GARAGE then step(s) end end
        local function gstep(s) if GARAGE then step(s) end end
        local P1, P2, PS, mode, LA, scrapperN
        for _, s in ipairs(T.loadFixture(GARAGE and "garage" or "zone")) do step(s) end
        step({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() end })
        step({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        step({ wait = 10 })
        -- 2. wrecks
        zstep({ run = function()
            local list = parts()
            local rows, rest = {}, {}
            for i = 1, 10 do rows[#rows + 1] = pack(list[i * 4]) end
            P1, P2 = list[3], list[5]
            for i, e in ipairs(list) do if i % 4 ~= 0 and i ~= 3 and i ~= 5 then rest[#rest + 1] = e end end
            PS, mode = stateful(rest)
            T.log("PT|info host parts=%d state part=%s mode=%s", #list, PS and PS.class or "none", tostring(mode))
            sendGuest("t.parts", #list .. "\n" .. table.concat(rows, "\n"))
        end })
        zstep({ check = "host_guest_has_parts", timeout = 120, cond = function() return has("t.partsok") end })
        zstep({ run = function() sendGuest("t.scrap", pack(P1)) end })
        -- the guest's scrap waits for its baseline (~45 s after a zone join here, net.lua held intents)
        zstep({ check = "host_part_gone_after_guest_scrap", timeout = 90, cond = function() return not alive(P1.a) end })
        zstep({ run = function() P2.a:K2_DestroyActor(); sendGuest("t.gone", pack(P2)) end })
        zstep({ check = "host_guest_part_gone_after_host_removal", timeout = 30, cond = function() return has("t.goneok") end })
        zstep({ run = function()
            if PS and alive(PS.a) then sendGuest("t.state", pack(PS) .. "|" .. mode) end
        end })
        zstep({ check = "host_part_state_after_guest_change", timeout = 30, cond = function()
            if not PS or not alive(PS.a) then return false end
            local it = PS.a.ItemInstance
            if mode == "fuel" then return math.abs(fuelOf(it) - 1.25) < 0.01 end
            return durOf(it) == 5
        end })
        -- 1. item details through the trunk
        step({ run = function() im().Inventory_Trunk:RemoveAllItems() end })
        step({ wait = 3 })
        step({ run = function()
            local c = im().Inventory_Trunk
            addItem(c, SCRAPPER, function(a, it) setDur(a, it, 37) end)
            T.log("PT|info host trunk n=%d scrapper durability=%s", c:GetNumItems(), tostring(durOf(find(c, SCRAPPER))))
            sendGuest("t.items1")
        end })
        step({ check = "host_guest_sees_durability", timeout = 30, cond = function() return has("t.items1ok") end })
        step({ check = "host_trunk_has_guest_fuel", timeout = 30, cond = function()
            local f = find(im().Inventory_Trunk, FUELCAN)
            return f ~= nil and math.abs(fuelOf(f) - 3.5) < 0.01
        end })
        -- 3. lootable visuals
        zstep({ run = function()
            for _, e in ipairs(lootables()) do if e.n > 0 then LA = e; break end end
            LA.a.DataBlock_WasOpened = true
            pcall(function() LA.a:SwitchToOpenedVisuals() end)
            sendGuest("t.open", pack(LA))
        end })
        zstep({ check = "host_guest_lootable_opened", timeout = 30, cond = function() return has("t.openok") end })
        zstep({ run = function() LA.a.InventoryContainer:RemoveAllItems() end })
        zstep({ wait = 2 })
        zstep({ run = function()
            T.log("PT|info host lootable Empty after emptying: %s", tostring(LA.a.Empty))
            if not LA.a.Empty then LA.a.Empty = true; pcall(function() LA.a:UpdateVisualsForEmpty() end) end
            sendGuest("t.empty", pack(LA))
        end })
        zstep({ check = "host_guest_lootable_empty", timeout = 30, cond = function() return has("t.emptyok") end })
        -- 4. garage storage
        gstep({ run = function()
            local c = garage(STORE)
            addItem(c, STEEL)
            sendGuest("t.garage", tostring(c:GetNumItems()))
        end })
        gstep({ check = "host_guest_sees_garage_item", timeout = 30, cond = function() return has("t.garageok") end })
        step({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function step(s) steps[#steps + 1] = s end
    local function zstep(s) if not GARAGE then step(s) end end
    local function gstep(s) if GARAGE then step(s) end end
    step({ check = "client_in", timeout = 240, cond = function() return T.netMode() == "client" and T.cls(T.myPawn()) == T.CHAR end })
    step({ run = function()
        local n, tags = 0, {}
        pcall(function() im().Inventories_Garage:ForEach(function(k, v) n = n + 1; if v:get():GetNumItems() > 0 then tags[#tags + 1] = k:get().TagName:ToString() .. "=" .. v:get():GetNumItems() end end) end)
        T.log("PT|info %s garage containers=%d filled: %s trunk=%s", T.ROLE, n, table.concat(tags, ","), tostring(alive(im().Inventory_Trunk)))
    end })
    gstep({ run = function() base = { count(garage(STORE), STEEL) } end })
    zstep({ check = "guest_got_parts", timeout = 120, cond = function() return has("t.parts") end })
    local why, whyT = "", 0
    zstep({ check = "guest_parts_match_host", timeout = 120, cond = function()
        local mine = parts()
        local rows = {}
        for r in got["t.parts"]:gmatch("[^\n]+") do rows[#rows + 1] = r end
        local n = tonumber(table.remove(rows, 1))
        local ok = #mine == n
        why = string.format("mine=%d host=%d", #mine, n)
        if ok then
            for _, r in ipairs(rows) do if not at(mine, unpack(r)) then ok = false; why = why .. " missing " .. r; break end end
        end
        if not ok and os.time() - whyT >= 10 then whyT = os.time(); T.log("PT|info part match: %s", why) end
        return ok
    end })
    zstep({ run = function() sendHost("t.partsok") end })
    zstep({ check = "guest_cmd_scrap", timeout = 60, cond = function() return has("t.scrap") end })
    zstep({ run = function()
        local o = at(parts(), unpack(got["t.scrap"]))
        T.log("PT|info guest scraps part %s found=%s", got["t.scrap"], tostring(o ~= nil))
        if o then o.a:K2_DestroyActor() end
    end })
    zstep({ check = "guest_part_gone_after_host_removal", timeout = 60, cond = function()
        return has("t.gone") and at(parts(), unpack(got["t.gone"])) == nil
    end })
    zstep({ run = function() sendHost("t.goneok") end })
    zstep({ check = "guest_cmd_state", timeout = 60, cond = function() return has("t.state") end })
    zstep({ run = function()
        local e = unpack(got["t.state"])
        local mode = got["t.state"]:match("|(%a+)$")
        local o = at(parts(), e)
        local a = o.a.ItemInstance.Archetype
        if mode == "fuel" then setFuel(a, o.a.ItemInstance, 1.25) else setDur(a, o.a.ItemInstance, 5) end
    end })
    step({ check = "guest_cmd_items1", timeout = 60, cond = function() return has("t.items1") end })
    step({ check = "guest_trunk_item_has_durability", timeout = 60, cond = function()
        local it = find(im().Inventory_Trunk, SCRAPPER)
        return it ~= nil and durOf(it) == 37
    end })
    step({ run = function()
        addItem(im().Inventory_Trunk, FUELCAN, function(a, it) setFuel(a, it, 3.5) end)
        sendHost("t.items1ok")
    end })
    zstep({ check = "guest_cmd_open", timeout = 60, cond = function() return has("t.open") end })
    zstep({ check = "guest_lootable_looks_opened", timeout = 30, cond = function()
        local o = at(lootables(), unpack(got["t.open"]))
        return o ~= nil and o.a.DataBlock_WasOpened
    end })
    zstep({ run = function() sendHost("t.openok") end })
    zstep({ check = "guest_lootable_looks_empty", timeout = 30, cond = function()
        if not has("t.empty") then return false end
        local o = at(lootables(), unpack(got["t.empty"]))
        return o ~= nil and o.a.Empty and o.n == 0
    end })
    zstep({ run = function() sendHost("t.emptyok") end })
    gstep({ check = "guest_garage_has_host_item", timeout = 60, cond = function()
        if not has("t.garage") then return false end
        local s = count(garage(STORE), STEEL)
        return s > base[1]
    end })
    gstep({ run = function() sendHost("t.garageok") end })
    step({ wait = 5 })
    return steps
end
