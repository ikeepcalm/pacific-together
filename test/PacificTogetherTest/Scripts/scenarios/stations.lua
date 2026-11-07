-- PT2 garage stations (PLAN G2): the guest uses the stations with its own game's functions, the HOST performs each action once.
--   shredder   the guest puts a spare wheel in its shredder and runs it (OnTransactionEnd, what closing the container does): the host's shredder
--              takes the wheel, the products appear in the host's world once and the guest sees the same products
--   research   the guest buys a research node that costs items (graph state PurchaseNode, what the invent button calls): the host has it purchased,
--              its resources fell by exactly the cost, the guest shows it purchased and sees the same resources
--   upgrade    the guest builds a garage station at its spawner (InstallSpecificUpgrade): the host has it installed once, both sides show it
--   fabricate  the guest crafts a tool (Craft Recipe Asset): it owns the tool, the host's garage lost exactly the inputs once, both sides agree
-- Run: tools/run-test.ps1 -Scenario stations -Fixture garage -Headless      Mutation nostations: stations.lua inert.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function real(o) return alive(o) and not o:GetFullName():find("/Engine/Transient", 1, true) end
    local function im() return T.first("BP_InventoryManager_C") end
    local function graph() return im().UnlockState end
    local function arch(o) return o.Archetype:GetFName():ToString() end

    -- owned items (backpack, hand, garage, car) by archetype name
    local function owned()
        local o, c = {}, {}
        im():GetOwnedItems(true, true, true, o)
        for _, e in ipairs(o) do local k = arch(e:get()); c[k] = (c[k] or 0) + 1 end
        return c
    end
    local function resources(c) -- one comparable string of every resource count
        local r = {}
        for k, v in pairs(c) do if k:find("^IA_Resource") then r[#r + 1] = k .. "=" .. v end end
        table.sort(r)
        return table.concat(r, " ")
    end
    local function garageRes() -- resource counts in the garage storage containers only (the shared part; backpacks are per player)
        local c = {}
        im().Inventories_Garage:ForEach(function(_, v)
            local a = {}
            v:get():GetAllItems(a)
            for _, e in ipairs(a) do local k = arch(e:get()); c[k] = (c[k] or 0) + 1 end
        end)
        local keep = {}
        for _, k in ipairs({ "IA_Resource_Raw_Plasma", "IA_Resource_Raw_Battery", "IA_Resource_Raw_Copper", "IA_Resource_Raw_Electronics" }) do keep[#keep + 1] = k .. "=" .. (c[k] or 0) end
        return table.concat(keep, " ") -- shared storage counts of what the checks spend (one fixture container is not mirrored, not ours)
    end
    local function worldRes() -- resource pickups lying in this side's world
        local t, n = {}, 0
        for _, w in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
            if real(w) then
                local ok, a = pcall(function() return w.Instance.Archetype:GetFName():ToString() end)
                if ok and a:find("^IA_Resource") then n = n + 1; t[#t + 1] = a end
            end
        end
        table.sort(t)
        return n, table.concat(t, ",")
    end
    local function shredder() return T.first("BP_Garage_PartShredder_C") end
    local function shredderItems()
        local a = {}
        shredder().BP_InventoryContainerComponent:GetAllItems(a)
        return #a
    end

    -- research: the first node that costs items and can be bought now
    local function costNode()
        local g = graph()
        im():SetActiveTier(3, true, true) -- the station screen sets this; without it nothing can be bought
        for _, x in ipairs(FindAllOf("GenericGraphRecipeNode") or {}) do
            if real(x) or x:GetFullName():find("RecipeResearchGraph", 1, true) then
                if g:IsNodeUnlockable(x) and not g:HasNodeBeenPurchased(x) then
                    local r = {}
                    if g:CanUnlockNode(x, r) and #r.ComponentsToBeConsumed > 0 then
                        local cost = {}
                        for i = 1, #r.ComponentsToBeConsumed do
                            local e = r.ComponentsToBeConsumed[i]:get()
                            local k = arch(e)
                            cost[k] = (cost[k] or 0) + e.Quantity
                        end
                        return x, cost
                    end
                end
            end
        end
    end
    local function nodeByName(n)
        for _, x in ipairs(FindAllOf("GenericGraphRecipeNode") or {}) do
            if x:GetFName():ToString() == n then return x end
        end
    end
    local function costStr(c) local r = {} for k, v in pairs(c) do r[#r + 1] = k .. "=" .. v end table.sort(r) return table.concat(r, " ") end

    -- upgrades
    local UP = {
        fax = { "BP_GarageStation_Fax", "/Game/Gameplay/CarGarage/Stations/FaxMachine/UP_Garage_FaxMachine_Install.UP_Garage_FaxMachine_Install_C" },
        destabilizer = { "BP_GarageStation_Destabilizer", "/Game/Gameplay/CarGarage/Stations/Destabilizer/UP_Garage_Destabilizer_Install.UP_Garage_Destabilizer_Install_C" },
    }
    local function spawner(name)
        for _, s in ipairs(FindAllOf("BP_GarageInstallation_Spawner_C") or {}) do
            if real(s) and s:GetFName():ToString() == name then return s end
        end
    end
    local function upCount(key) -- how many times the station's upgrade effect sits in its slot
        local s, sm = spawner(UP[key][1]), T.first("BP_StatusEffectManager_C")
        if not (s and sm) then return -1 end
        local a = {}
        s:GetUpgradeArchetype(a)
        local item = im():FindOrCreateGarageUpgradeSlot(a.Archetype, s.StationInstallTag):GetItem(0)
        if not (item and item:IsValid()) then return 0 end
        local n, want = 0, UP[key][2]:match("[^.]+$")
        local list = sm:GetStatusEffects(item)
        for i = 1, #list do if list[i]:get():GetClass():GetFName():ToString() == want then n = n + 1 end end
        return n
    end

    -- Tinker: the car's quirks (status effects on the car's soul), as "condition|behavior" names
    local function sm() return FindFirstOf("BP_StatusEffectManager_C") end
    local function quirkNames()
        local r = {}
        for i = 1, #sm().CarQuirks do
            local q = sm().CarQuirks[i]
            if alive(q) and alive(q.QuirkCondition) then r[#r + 1] = q.QuirkCondition:GetClass():GetFName():ToString() .. "|" .. q.QuirkBehavior:GetClass():GetFName():ToString() end
        end
        table.sort(r)
        return table.concat(r, ",")
    end
    local function cured()
        local v = 0
        FindFirstOf("BP_ProgressionManager_C").GlobalWhiteboard.Entries:ForEach(function(k, x)
            if k:get().TagName:ToString() == "WB.Statistics.Quirks.QuirksCured" then v = x:get() end
        end)
        return v
    end
    local RECIPE = "/Game/Gameplay/Inventory/Items/Tools/FixStatusEffect/FixElectronic/CR_Tool_Target_FixElectronics.CR_Tool_Target_FixElectronics"
    local function tools() return owned()["IA_Tool_Target_FixElectronics"] or 0 end

    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind] ~= nil
    end
    local function g(kind) has(kind); return got[kind] end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        local st = {}
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 20 }) -- the garage storage and progression reach the guest
        add({ check = "host_has_shredder_and_bench", timeout = 30, cond = function()
            return shredder() ~= nil and T.first("BP_Garage_InventingBench_C") ~= nil and T.first("BP_Garage_CraftingTable_01_New_C") ~= nil
        end })

        -- shredder
        add({ run = function()
            st.worldBefore = worldRes()
            T.log("PT|info host world resources before shred: %d", st.worldBefore)
            toGuest("t.go.shred")
        end })
        add({ check = "host_shredder_took_the_wheel_and_ran", timeout = 90, cond = function()
            if g("t.shredded") == nil then return false end
            local n, list = worldRes()
            if n > st.worldBefore then st.products = n; st.list = list end
            return st.products ~= nil
        end })
        -- the dispenser lets the products out one by one: wait until the count has not moved for 20 s
        add({ check = "host_products_settle_and_shredder_empty", timeout = 120, cond = function()
            local n, list = worldRes()
            if n ~= st.lastN then st.lastN, st.since, st.list = n, os.clock(), list end
            if n > st.worldBefore and shredderItems() == 0 and os.clock() - st.since > 20 then st.products = n; return true end
            return false
        end })
        add({ run = function() T.log("PT|info host products: %s", st.list); toGuest("t.shreddone") end })
        add({ check = "guest_sees_same_products", timeout = 60, cond = function()
            local n = tonumber(g("t.gres") or "-1")
            return n == st.products
        end })

        -- research
        add({ run = function()
            local node, cost = costNode()
            st.node, st.cost, st.before = node, cost, owned()
            T.log("PT|info host research node %s cost %s", node and T.name(node) or "none", cost and costStr(cost) or "")
            if node then toGuest("t.go.buy", node:GetFName():ToString()) end
        end })
        add({ check = "host_research_node_found", timeout = 1, cond = function() return st.node ~= nil end })
        add({ check = "host_has_node_purchased", timeout = 60, cond = function() return graph():HasNodeBeenPurchased(st.node) end })
        add({ check = "host_resources_fell_by_exactly_the_cost_once", timeout = 60, cond = L.holds(15, function()
            local now = owned()
            for k, v in pairs(st.cost) do
                if (now[k] or 0) ~= (st.before[k] or 0) - v then T.log("PT|info host %s %d -> %d (cost %d)", k, st.before[k] or 0, now[k] or 0, v) return false end
            end
            return true
        end) })
        add({ run = function() st.after = garageRes(); toGuest("t.buydone") end })
        add({ check = "guest_shows_node_purchased", timeout = 60, cond = function() return g("t.bought") == "1" end })
        add({ check = "guest_bench_printed_nothing", timeout = 60, cond = function() return g("t.benchprints") == "0" end })
        add({ check = "guest_resources_equal_host", timeout = 60, cond = function()
            local r = g("t.gresources")
            if r ~= st.after and r ~= st.shownA then st.shownA = r; T.log("PT|info guest garage %s | host %s", tostring(r), st.after) end
            return r == st.after
        end })

        -- garage upgrade
        add({ run = function()
            for _, k in ipairs({ "fax", "destabilizer" }) do
                if not st.up and upCount(k) == 0 then st.up = k end
            end
            st.up = st.up or "fax" -- an advanced fixture may already have both; check reinstallation stays idempotent
            T.log("PT|info host upgrade to build: %s", tostring(st.up))
            if st.up then toGuest("t.go.up", st.up) end
        end })
        add({ check = "host_upgrade_candidate_exists", timeout = 1, cond = function() return st.up ~= nil end })
        add({ check = "host_has_upgrade_installed_once", timeout = 120, cond = function()
            local n = upCount(st.up)
            if n == 1 then st.upSince = st.upSince or os.clock() else st.upSince = nil end
            return n == 1 and os.clock() - st.upSince > 10
        end })
        add({ check = "guest_shows_upgrade_once", timeout = 60, cond = function() return g("t.upcount") == "1" end })

        -- tinker: a quirk the host's game rolled shows on the guest; the guest cures it (its own CureCarQuirk, what the station UI calls)
        add({ run = function()
            sm():DbgActEvt_RollRandomQuirk_Execute()
            st.q, st.cured0, st.garage0 = quirkNames(), cured(), garageRes()
            T.log("PT|info host quirk %s cured so far %s", st.q, tostring(st.cured0))
            toGuest("t.go.quirk")
        end })
        add({ check = "host_has_one_quirk", timeout = 10, cond = function() return st.q ~= "" and not st.q:find(",", 1, true) end })
        add({ check = "guest_shows_the_same_quirk", timeout = 60, cond = function() return g("t.q") == st.q end })
        add({ check = "guest_keeps_the_quirk", timeout = 90, cond = L.holds(15, function() return g("t.q") == st.q end) })
        add({ run = function() toGuest("t.go.cure") end })
        add({ check = "guest_cured_it", timeout = 60, cond = function() return g("t.qcured") == "1" end })
        add({ check = "host_quirk_gone_and_stays_gone", timeout = 60, cond = L.holds(15, function() return quirkNames() == "" end) })
        add({ check = "host_counts_one_cure_and_paid_nothing_itself", timeout = 20, cond = function()
            return cured() == st.cured0 + 1 and garageRes() == st.garage0
        end })
        add({ check = "guest_quirk_list_empty_too", timeout = 30, cond = function() return g("t.qafter") == "" end })

        -- fabrication
        add({ run = function()
            st.fb = owned()
            T.log("PT|info host before craft: %s", resources(st.fb))
            toGuest("t.go.craft")
        end })
        add({ check = "guest_crafted_the_tool", timeout = 60, cond = function() return g("t.crafted") == "1" end })
        add({ check = "host_garage_lost_exactly_the_inputs_once", timeout = 60, cond = L.holds(15, function()
            local now = owned()
            local want = { IA_Resource_Raw_Battery = 1, IA_Resource_Raw_Copper = 2, IA_Resource_Raw_Electronics = 1 }
            for k, v in pairs(want) do
                if (now[k] or 0) ~= (st.fb[k] or 0) - v then T.log("PT|info host %s %d -> %d (inputs %d)", k, st.fb[k] or 0, now[k] or 0, v) return false end
            end
            return true
        end) })
        add({ run = function() st.after2 = garageRes(); toGuest("t.craftdone") end })
        add({ check = "guest_resources_equal_host_after_craft", timeout = 60, cond = function()
            local r = g("t.gresources2")
            if r ~= st.after2 and r ~= st.shownB then st.shownB = r; T.log("PT|info guest garage %s | host %s", tostring(r), st.after2) end
            return r == st.after2
        end })
        add({ run = function() toGuest("t.done") end })
        add({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local function say(k, v) PTNative_MsgToHost(T.localPC():GetAddress(), k, v or "") end
    local st = {}
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })

    -- shredder: a spare wheel into the guest's own shredder, then the game's end-of-transaction event
    add({ check = "guest_go_shred", timeout = 300, cond = function() return has("t.go.shred") end })
    add({ run = function()
        local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
        local a = StaticFindObject("/Game/Gameplay/Inventory/Items/Car/Wheels/Wheel_Spare_01/IA_Attach_Wheel_Spare.IA_Attach_Wheel_Spare")
        local s = shredder()
        local c, r = s.BP_InventoryContainerComponent, {}
        c:AddItem(lib:CreateItemInstance(T.myPawn():GetWorld(), a, 0), r)
        T.log("PT|info guest wheel added to its shredder: %s", tostring(r.Added))
        s:OnTransactionEnd(c)
        say("t.shredded")
    end })
    add({ check = "guest_go_shreddone", timeout = 180, cond = function() return has("t.shreddone") end })
    add({ check = "guest_report_world_products", timeout = 400, cond = function()
        local n, list = worldRes()
        say("t.gres", tostring(n))
        return has("t.go.buy")
    end })

    -- research
    add({ check = "guest_go_buy", timeout = 400, cond = function() return has("t.go.buy") end })
    add({ run = function()
        local node = nodeByName(g("t.go.buy"))
        st.node = node
        im():SetActiveTier(3, true, true)
        st.benchPrints = 0 -- the bench prints the blueprint / kit from OnNodePurchased: only the host's bench may
        T.log("PT|info guest bench hook registered: %s", tostring(pcall(RegisterHook, "/Game/Gameplay/CarGarage/Stations/ResearchStation/BP_Garage_InventingBench.BP_Garage_InventingBench_C:OnNodePurchased", function() st.benchPrints = st.benchPrints + 1 end)))
        local ok = graph():PurchaseNode(node)
        T.first("BP_Garage_InventingBench_C"):OnNodePurchased(node) -- the station UI also emits this delegate
        T.log("PT|info guest PurchaseNode(%s) -> %s", g("t.go.buy"), tostring(ok))
    end })
    add({ check = "guest_go_buydone", timeout = 180, cond = function() return has("t.buydone") end })
    add({ check = "guest_reports_purchase", timeout = 90, cond = function()
        say("t.bought", graph():HasNodeBeenPurchased(st.node) and "1" or "0")
        say("t.gresources", garageRes())
        say("t.benchprints", tostring(st.benchPrints))
        return has("t.go.up")
    end })

    -- upgrade
    add({ check = "guest_go_up", timeout = 400, cond = function() return has("t.go.up") end })
    add({ run = function()
        local key = g("t.go.up")
        st.up = key
        spawner(UP[key][1]):InstallSpecificUpgrade(StaticFindObject(UP[key][2]), false)
        T.log("PT|info guest installed %s", key)
    end })
    add({ check = "guest_reports_upgrade", timeout = 400, cond = function()
        say("t.upcount", tostring(upCount(st.up)))
        return has("t.go.quirk")
    end })

    -- tinker
    add({ check = "guest_reports_quirks", timeout = 400, cond = function()
        say("t.q", quirkNames())
        return has("t.go.cure")
    end })
    add({ run = function()
        local q = sm().CarQuirks[1]
        local ing
        q.CureIngredients:ForEach(function(k) ing = k:get() end)
        local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
        im().Inventory_Player:AddItem(lib:CreateItemInstance(T.myPawn():GetWorld(), ing, 0), true) -- the cure's ingredient, in the guest's own pack
        im():SetActiveTier(3, true, true)
        local o = {}
        sm():CureCarQuirk(q, o)
        T.log("PT|info guest cured quirk: %s", tostring(o.Removed))
        say("t.qcured", o.Removed and "1" or "0")
    end })
    add({ check = "guest_reports_quirks_after", timeout = 400, cond = L.holds(15, function()
        say("t.qafter", quirkNames())
        return quirkNames() == ""
    end) })

    -- fabrication
    add({ check = "guest_go_craft", timeout = 400, cond = function() return has("t.go.craft") end })
    add({ run = function()
        local m = im()
        m:SetActiveTier(3, true, true)
        local o = {}
        m["Craft Recipe Asset"](m, StaticFindObject(RECIPE), true, true, o)
        T.log("PT|info guest craft success=%s", tostring(o.Success))
        st.crafted = tools() == 1
        say("t.crafted", st.crafted and "1" or "0")
    end })
    add({ check = "guest_reports_resources_after_craft", timeout = 180, cond = function()
        say("t.gresources2", garageRes())
        return has("t.done")
    end })
    return steps
end
