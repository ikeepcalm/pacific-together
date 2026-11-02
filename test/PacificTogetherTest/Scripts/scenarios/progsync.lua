-- M5 progression (D6, guest managers): the guest joins from the main menu with fresh-game state. After joining, its garage
-- upgrades / story flags (whiteboard), research unlocks, logbook and ARC route legs equal the host's; a change on the host
-- (a new tag, an unlocked node) reaches it; and the host's run-failure item penalty also hits the guest's backpack, in the file
-- the host keeps for it too.
-- Run: tools/run-test.ps1 -Scenario progsync -Fixture zone -Headless     Mutation noprog: progression.lua inert.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local G = require("scenarios.guestchar")
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local ITEMS = "/Game/Gameplay/Inventory/Items/"
    local STEEL = ITEMS .. "Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
    local TAG = "WB.GarageUpgrades.PtTest"
    -- a player upgrade (armour: less impact damage), as the equipment station adds it (owner 2026-10-24: backpack and armour stayed the guest's own)
    local UPG = ITEMS .. "PlayerEquipment/Armor/IA_PlayerEquipment_Armor_Impact_T1.IA_PlayerEquipment_Armor_Impact_T1"
    local function hasUpgrade()
        local found = false
        T.first("BP_MainCharacterManager_C").PlayerUpgradesUnlocked:ForEach(function(_, o) if o:get():GetFullName():find(UPG, 1, true) then found = true end end)
        return found
    end
    local function pm() return T.first("BP_ProgressionManager_C") end
    local function im() return T.first("BP_InventoryManager_C") end

    -- this side's progression as strings: garage tags, unlock counts, route legs, logbook
    local function digest()
        local wb = {}
        pm().GlobalWhiteboard.Entries:ForEach(function(k, v)
            local t = k:get().TagName:ToString()
            if t:find("^WB%.GarageUpgrades%.") then wb[#wb + 1] = string.format("%s=%.2f", t, v:get()) end
        end)
        table.sort(wb)
        local gs, un, pu = im().UnlockState, 0, 0
        gs.UnlockedNodes:ForEach(function() un = un + 1 end)
        gs.PurchasedNodes:ForEach(function() pu = pu + 1 end)
        local legs = {}
        local rs = pm().WorldState
        rs.LegStates:ForEach(function(k, v)
            local l = v:get()
            if l.RevealState ~= 0 or l.Visited or l.Discovered then
                legs[#legs + 1] = string.format("%s:%d%d%d", k:get():GetFName():ToString(), l.RevealState, l.Visited and 1 or 0, l.Discovered and 1 or 0)
            end
        end)
        table.sort(legs)
        local lbn = #pm().LogBook.Entries
        return { wb = table.concat(wb, ","), nwb = #wb, un = un, pu = pu, legs = table.concat(legs, ","), nlegs = #legs, lb = lbn, phase = rs.CurrentPhase }
    end
    local function pack(d) return string.format("%s|%d|%d|%d|%s|%d|%d|%d", d.wb, d.nwb, d.un, d.pu, d.legs, d.nlegs, d.lb, d.phase) end
    local function unpack(s)
        local wb, nwb, un, pu, legs, nlegs, lb, phase = s:match("^(.-)|(%d+)|(%d+)|(%d+)|(.-)|(%d+)|(%d+)|(%d+)$")
        return { wb = wb, nwb = tonumber(nwb), un = tonumber(un), pu = tonumber(pu), legs = legs, nlegs = tonumber(nlegs), lb = tonumber(lb), phase = tonumber(phase) }
    end
    local function carried() return G.invCount(T) end
    local function lib() return StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary") end

    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind] ~= nil
    end
    local function sendGuest(kind, data) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), kind, data or "") end
    local function sendHost(kind, data) PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local name, filePath
        local function line()
            local f = io.open(filePath, "r")
            if not f then return nil end
            local l = f:read("l"); f:close()
            return l
        end
        local function items(l) local n = 0; for k in (l or ""):gmatch(",(%d+),%-?%d+,%-?%d+,[01],") do n = n + tonumber(k) end; return n end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ run = function()
            local d = digest()
            T.log("PT|info host progression garage/story tags=%d unlocked=%d purchased=%d legs=%d logbook=%d phase=%d", d.nwb, d.un, d.pu, d.nlegs, d.lb, d.phase)
        end })
        add({ check = "host_state_not_trivial", timeout = 2, cond = function() local d = digest(); return d.nwb >= 5 and d.un > 0 and d.nlegs >= 1 and d.lb > 0 end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ run = function()
            name = L.guestName():gsub("[^%w_%-]", "_")
            filePath = string.format("../../Saved/SaveGames/odsave%d.pt-%s.txt", T.saveMgr():GetCurrentSlot(), name)
            os.remove(filePath)
            sendGuest("t.sum", pack(digest()))
        end })
        add({ check = "host_guest_equal_ack", timeout = 120, cond = function() return has("t.equal") end })
        -- a change on the host reaches the guest
        add({ run = function()
            pm().GlobalWhiteboard:SetTagFloat({ TagName = FName(TAG) }, 7)
            -- and one more research node (the fixture's unlock set is the fresh-game default)
            local gs, have = im().UnlockState, {}
            gs.UnlockedNodes:ForEach(function(n) have[n:get():GetFullName()] = true end)
            local pick
            StaticFindObject("/Game/Gameplay/Inventory/Items/RecipeResearchGraph.RecipeResearchGraph").Nodes:ForEach(function(_, n)
                local o = n:get()
                if not pick and not have[o:GetFullName()] then pick = o end
            end)
            if pick then
                gs:UnlockNode(pick, true)
                sendGuest("t.node", pick:GetFullName())
                T.log("PT|info host unlocked %s", pick:GetFullName())
            end
            sendGuest("t.tag", TAG)
            local u = StaticFindObject(UPG)
            if not (u and u:IsValid()) then pcall(LoadAsset, UPG); u = StaticFindObject(UPG) end
            local m = T.first("BP_MainCharacterManager_C")
            m["Add Player Upgrade"](m, u)
            T.log("PT|info host player upgrade added=%s", tostring(hasUpgrade()))
        end })
        add({ check = "host_guest_got_change_ack", timeout = 60, cond = function() return has("t.changed") end })
        add({ check = "host_file_has_guest_items", timeout = 120, cond = function() return has("t.filled") and items(line()) == 10 end })
        -- run failure: the game's own penalty call on the host (what TravelToGarage's failed-run path and a death make)
        add({ run = function()
            local before = carried()
            pm():RemoveItemsPenalty(-1, {})
            T.log("PT|info host penalty applied: host backpack %d -> %d", before, carried())
        end })
        add({ check = "host_guest_penalty_ack", timeout = 60, cond = function() return has("t.penalty") end })
        add({ check = "host_file_matches_guest_after_penalty", timeout = 30, cond = function()
            return has("t.penalty") and items(line()) == tonumber(got["t.penalty"])
        end })
        add({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end })
    local want
    add({ check = "guest_got_host_sum", timeout = 60, cond = function() if has("t.sum") then want = unpack(got["t.sum"]); return true end end })
    add({ check = "guest_garage_story_tags_equal", timeout = 60, cond = function() return digest().wb == want.wb end })
    add({ check = "guest_unlocks_equal", timeout = 30, cond = function() local d = digest(); return d.un == want.un and d.pu == want.pu end })
    add({ check = "guest_route_legs_equal", timeout = 30, cond = function() local d = digest(); return d.legs == want.legs and d.phase == want.phase end })
    add({ check = "guest_logbook_equal", timeout = 30, cond = function() return digest().lb == want.lb end })
    add({ run = function() sendHost("t.equal") end })
    add({ check = "guest_got_host_change", timeout = 60, cond = function()
        if not has("t.tag") then return false end
        local v = 0
        pm().GlobalWhiteboard.Entries:ForEach(function(k, x) if k:get().TagName:ToString() == TAG then v = x:get() end end)
        return v == 7
    end })
    add({ check = "guest_got_host_player_upgrade", timeout = 30, cond = hasUpgrade })
    add({ check = "guest_got_host_unlock", timeout = 30, cond = function()
        if not has("t.node") then return false end
        local found = false
        im().UnlockState.UnlockedNodes:ForEach(function(n) if n:get():GetFullName() == got["t.node"] then found = true end end)
        return found
    end })
    add({ run = function() sendHost("t.changed") end })
    -- fill the backpack, wait until the host holds the record, then the host's penalty
    add({ wait = 12 })
    add({ run = function()
        local bag, a = im().Inventory_Player, StaticFindObject(STEEL)
        for _ = 1, 10 do bag:AddItem(lib():CreateItemInstance(T.world(), a, 0), true) end
    end })
    add({ check = "guest_filled", timeout = 5, cond = function() return carried() >= 10 end })
    add({ wait = 8 })
    add({ run = function() sendHost("t.filled") end })
    local n0
    add({ run = function() n0 = carried() end })
    add({ check = "guest_penalty_applied", timeout = 60, cond = function() return carried() < n0 end })
    add({ run = function() sendHost("t.penalty", tostring(carried())) end })
    add({ wait = 8 })
    return steps
end
