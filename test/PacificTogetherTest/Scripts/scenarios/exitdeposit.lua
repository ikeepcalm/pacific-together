-- Playtest 2026-11-15 (finding 5): 0 energy after a setpiece run. Anchors fed to the ARC are banked as garage energy (CurrencyTable)
-- by BP_InventoryManager:DepositPostRunItems, which only the failure return calls; the gateway/setpiece exit (TravelToGarage(2))
-- never did, and an anchor the guest fed (g.act.anchor) never reached the host's anchor inventory at all.
--   host_anchor_in_arc_inventory    the guest's deposit intent leaves the anchor item in the host's anchor inventory (once)
--   host_energy_banked_by_exit      after the host's gateway return the garage energy rose by that anchor's value
--   host_energy_banked_once         a second return-to-garage deposit changes nothing
--   guest_energy_matches_host       the guest's research-screen energy equals the host's
-- Run: tools/run-test.ps1 -Scenario exitdeposit -Fixture garage -Headless      Mutation noexitdeposit: the exit deposit is off.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local ANCHOR = "/Game/Gameplay/Inventory/Items/Resources/Anchor/AnchorBlue/IA_Resource_Anchor_Unstable_M.IA_Resource_Anchor_Unstable_M"
    local function helpers() return StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C") end
    local function pm() return T.first("BP_ProgressionManager_C") end
    local function im() return T.first("BP_InventoryManager_C") end
    local function inZone() return T.map() ~= "RB_Garage" and T.map() ~= "RB_MainMenu" and L.gameplay(T.map()) end
    local function energy()
        local m, r = im(), {}
        if not m then return "nil" end
        pcall(function()
            m.CurrencyTable:ForEach(function(k, v)
                local n = k:get():GetFullName():match("CA_AnchorJuice_(%a+)")
                if n then r[#r + 1] = n .. "=" .. tostring(v:get()) end
            end)
        end)
        table.sort(r)
        return table.concat(r, ",")
    end
    local function anchors()
        local o = {}
        im():GetAnchorInventories(o)
        local n = 0
        local c = o.GobblerInventory
        if c and c:IsValid() then n = c:GetNumItems() end
        return n
    end
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end
    local function selectGateway()
        local sm = T.first("BP_StormManager_C")
        for _, p in ipairs(FindAllOf("BP_LevelTransition_ExitPortal_C") or {}) do
            if p:IsValid() and not T.name(p):find("Engine/Transient", 1, true) then sm["Select Exit Portal Actor"](sm, p); return end
        end
        T.log("PT|info no exit portal found")
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local before
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ run = function() helpers():TravelToNextLeg(T.world()) end })
        add({ check = "host_listens_zone", timeout = 240, cond = function() return inZone() and T.netMode() == "listen" and T.listening() and T.myPawn() ~= nil end })
        add({ check = "host_guest_in_zone", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 15 })
        add({ run = function()
            before = energy()
            T.log("PT|info host energy before %s anchors=%d", before, anchors())
            PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.feed", ANCHOR)
        end })
        add({ check = "host_anchor_in_arc_inventory", timeout = 60, cond = function() poll(); return got["t.fed"] ~= nil and anchors() == 1 end })
        add({ run = function()
            selectGateway()
            pm():TravelToGarage(2, false, false, false, 1, {})
        end })
        add({ check = "host_back_in_garage", timeout = 300, cond = function() return T.map() == "RB_Garage" and T.netMode() == "listen" and T.listening() and T.myPawn() ~= nil end })
        add({ check = "host_guest_in_garage_again", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 5 })
        local after
        add({ check = "host_energy_banked_by_exit", timeout = 20, cond = function()
            after = energy()
            T.log("PT|info host energy after %s (before %s) anchors=%d", after, tostring(before), anchors())
            return after ~= before and anchors() == 0
        end })
        add({ check = "host_energy_banked_once", timeout = 5, cond = function()
            pcall(function() im():DepositPostRunItems(false) end)
            return energy() == after
        end })
        add({ check = "guest_energy_matches_host", timeout = 60, cond = function() poll(); return got["t.energy"] == energy() end })
        add({ run = function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.done", "1") end })
        add({ wait = 2 })
        return steps
    end

    local fed = false
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end },
        { check = "guest_reports", timeout = 1500, cond = function()
            poll()
            if got["t.feed"] and not fed and inZone() then
                fed = true
                T.intent("g.act.anchor", got["t.feed"])
                PTNative_MsgToHost(T.localPC():GetAddress(), "t.fed", "1")
            end
            pcall(function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.energy", energy()) end)
            return got["t.done"] ~= nil
        end },
    }
end
