-- Playtest 2026-11-15 (finding 11): the guest's trunk had no cells after the transition into the next zone until a rejoin.
-- The host upgrades its trunk to Tier 2 (the game's own UpgradeCarStorageTrunk) and puts an item in; the guest's trunk grid and
-- contents match before the travel and after the host's TravelToNextLeg (the guest's car there is built fresh).
--   guest_trunk_matches_in_garage     same slot count and item count as the host (Tier 2 grid)
--   guest_trunk_matches_after_travel  the same in the zone, the guest's container alive with the host's grid
-- Run: tools/run-test.ps1 -Scenario trunktravel -Fixture garage -Headless      Mutation notrunkfix: the guest's trunk repair is off.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local STEEL = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
    local function im() return T.first("BP_InventoryManager_C") end
    local function stat()
        local m = im()
        local c = m and m.Inventory_Trunk
        if not (c and c:IsValid()) then return "nil" end
        return string.format("%d/%d", c:GetNumSlots(), c:GetNumItems())
    end
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end
    local function inZone() return T.map() ~= "RB_Garage" and T.map() ~= "RB_MainMenu" and L.gameplay(T.map()) end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function same(tag)
            poll()
            local mine, theirs = stat(), got["t.tr"]
            if mine ~= theirs then T.log("PT|info %s host %s guest %s", tag, mine, tostring(theirs)) end
            return mine ~= "nil" and mine == theirs
        end
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 12 })
        add({ run = function()
            T.first("BP_CarManager_C"):UpgradeCarStorageTrunk(2)
            local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
            im().Inventory_Trunk:AddItem(lib:CreateItemInstance(T.world(), StaticFindObject(STEEL), 0), true)
            T.log("PT|info host trunk %s", stat())
        end })
        add({ check = "guest_trunk_matches_in_garage", timeout = 90, cond = function() return same("garage") end })
        add({ run = function()
            StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(T.world())
        end })
        add({ check = "host_listens_zone", timeout = 240, cond = function() return inZone() and T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_back_zone", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ check = "guest_trunk_matches_after_travel", timeout = 60, cond = function() return same("zone") end })
        add({ run = function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.done", "1") end })
        add({ wait = 2 })
        return steps
    end

    local LAST = {}
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end },
        { check = "guest_reports", timeout = 1200, cond = function()
            poll()
            local st = stat()
            if st ~= LAST[1] then LAST[1] = st; T.log("PT|info guest trunk %s map=%s", st, T.map()) end
            pcall(function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.tr", st) end)
            return got["t.done"] ~= nil
        end },
    }
end
