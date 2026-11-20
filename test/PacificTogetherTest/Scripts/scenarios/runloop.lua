-- D4, the v1.0 core: the whole run loop with a guest, driven through the game's own functions. Fixture garage.
--   garage -> zone       BFL_ProgressionHelpers:TravelToNextLeg (W3: same map, time of day and weather on both)
--   zone -> garage (a)   gateway: BP_StormManager "Select Exit Portal Actor" (the ARC screen's call), then the portal's
--                        TravelToGarage(2) (W4/W11)
--   garage -> zone       again
--   zone -> garage (b)   run failure as the emergency protocol makes it (RunFinished_Failure): RemoveItemsPenalty,
--                        DepositPostRunItems(false), SetPlayerCarState(1), TravelToGarage(3) (W5)
-- At every arrival the guest reports map, body, car, backpack count, time of day and weather; the host compares with its own
-- world (and, after the failure, the guest's backpack with the file the host keeps for it).
-- Run: tools/run-test.ps1 -Scenario runloop -Fixture garage -Headless [-Root .. -Port ..]
-- Mutation nokeep: the host's keep-listen / auto-listen are switched off after the first join: the guest never comes back.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local G = require("scenarios.guestchar")
    local C = require("scenarios.carlib")(T)
    local M = T.MUTATE
    local slow = (M == "nokeep") and 0.25 or 1
    local function to(s) return math.max(30, math.floor(s * slow)) end
    local STEEL = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
    local function helpers() return StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C") end
    local function pm() return T.first("BP_ProgressionManager_C") end
    local function sceneReady() return T.myPawn() ~= nil and T.first("BP_PlayerCarNew_C") ~= nil end
    local function world()
        local tod, o = T.first("BP_ToDManager_C"), {}
        tod["Get Current Time Of Day"](tod, o)
        return o["Returned Time Of Day"], tod.TargetWeatherOverrideArray:GetArrayNum()
    end
    local function circ(a, b) local d = math.abs(a - b); return math.min(d, 1 - d) end
    local function selectGateway()
        local sm = T.first("BP_StormManager_C")
        for _, p in ipairs(FindAllOf("BP_LevelTransition_ExitPortal_C") or {}) do
            if p:IsValid() and not T.name(p):find("Engine/Transient", 1, true) then sm["Select Exit Portal Actor"](sm, p); return end
        end
        T.log("PT|info no exit portal found")
    end
    local function failure()
        local cm = T.first("BP_CarManager_C")
        pm():RemoveItemsPenalty(-1, {})
        T.first("BP_InventoryManager_C"):DepositPostRunItems(false)
        cm["Set PlayerCarState"](cm, 1)
        pm():TravelToGarage(3, false, false, false, 1, {})
    end
    local function arrived(st) -- both sides: on the stage's kind of map
        return L.gameplay(T.map()) and ((T.map() == "RB_Garage") ~= st.zone)
    end

    local stages = {
        { id = "g0", zone = false },
        { id = "z1", zone = true, from = function() helpers():TravelToNextLeg(T.world()) end },
        { id = "g1", zone = false, from = function() selectGateway(); pm():TravelToGarage(2, false, false, false, 1, {}) end },
        { id = "z2", zone = true, from = function() helpers():TravelToNextLeg(T.world()) end },
        { id = "g2", zone = false, penalty = true, from = failure },
    }
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end
    local function parse(s) return s:match("^(.-)|(%d)|(%d)|(%d+)|([%-%d%.]+)|(%d+)$") end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local n0
        for _, s in ipairs(T.loadFixture((os.getenv("PT_FIXTURE") or ""):match("[^,]+") or "garage")) do add(s) end -- -Fixture coop-garage: the owner's own save (bigger lists)
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ run = function()
            if M == "nokeep" then PTNative_SetAutoListen(false); if PTNative_SetKeepListen then PTNative_SetKeepListen(false) end end
        end })
        local function fileCount()
            local name = L.guestName():gsub("[^%w_%-]", "_")
            local f = io.open(string.format("../../Saved/SaveGames/odsave%d.pt-%s.txt", T.saveMgr():GetCurrentSlot(), name), "r")
            if not f then return nil end
            local l = f:read("l"); f:close()
            local n = 0
            for k in (l or ""):gmatch(",(%d+),%-?%d+,%-?%d+,[01],") do n = n + tonumber(k) end
            return n
        end
        for i, st in ipairs(stages) do
            if st.from then
                add({ run = function() T.log("PT|info %s: leaving %s", stages[i - 1].id, T.map()); st.from() end })
                add({ check = st.id .. "_host_arrived", timeout = 240, cond = function() return arrived(st) and sceneReady() end })
                add({ check = st.id .. "_host_listens", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
                add({ check = st.id .. "_guest_back", timeout = to(300), cond = function() return L.guestChar() ~= nil and L.managerIsMine() end })
            else
                add({ wait = 5 })
            end
            add({ check = st.id .. "_guest_report", timeout = to(120), cond = function() poll(); return got["t." .. st.id] ~= nil end })
            add({ check = st.id .. "_same_world", timeout = 10, cond = function()
                poll() -- the guest re-reports every 3 s: compare its latest, not the first (a weather change in between failed the check)
                local gmap, gbody, gcar, ginv, gtod, gov = parse(got["t." .. st.id])
                T.log("PT|info %s guest map=%s body=%s car=%s inv=%s tod=%s ov=%s | host map=%s car=%s", st.id, gmap, gbody, gcar, ginv, gtod, gov, T.map(), tostring(C.car() ~= nil))
                assert(gmap == T.map(), "guest on another map: " .. tostring(gmap))
                assert(gbody == "1", "guest has no character")
                assert(gcar == "1" and C.car() ~= nil, "car missing on a side")
                if st.zone then
                    local ht, hov = world()
                    assert(circ(ht, tonumber(gtod)) < 0.03, "time of day differs")
                    assert(hov == tonumber(gov), "weather differs")
                end
                ginv = tonumber(ginv)
                if st.id == "g0" then n0 = ginv end
                if st.penalty then
                    T.log("PT|info %s guest backpack %d, host file %s, before the run %d", st.id, ginv, tostring(fileCount()), n0)
                    assert(ginv <= n0, "backpack grew")
                else
                    assert(ginv == n0, "backpack not intact: " .. ginv .. " vs " .. tostring(n0))
                end
                return true
            end })
            if st.id == "g0" then add({ wait = 10 }) end -- the host keeps the guest's backpack file
            add({ run = function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.ack", st.id) end })
            add({ wait = 4 })
        end
        add({ check = "host_file_matches_guest_after_failure", timeout = 60, cond = function()
            local _, _, _, g = parse(got["t.g2"] or "")
            return g ~= nil and fileCount() == tonumber(g)
        end })
        add({ check = "host_alive_at_end", timeout = 45, cond = L.holds(15, function() return T.netMode() == "listen" and T.pcs() == 2 end) })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local lastSend = 0
    for _, st in ipairs(stages) do
        add({ check = st.id .. "_client_arrived", timeout = to(300) + 240, cond = function()
            return T.netMode() == "client" and arrived(st) and T.cls(T.myPawn()) == T.CHAR
        end })
        if st.id == "g0" then
            add({ wait = 12 })
            add({ run = function()
                local bag, a = T.first("BP_InventoryManager_C").Inventory_Player, StaticFindObject(STEEL)
                local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
                for _ = 1, 10 do bag:AddItem(lib:CreateItemInstance(T.world(), a, 0), true) end
            end })
            add({ check = "guest_filled", timeout = 5, cond = function() return G.invCount(T) >= 10 end })
        else
            add({ wait = 10 }) -- the backpack comes back from the host's file
        end
        add({ check = st.id .. "_ack", timeout = to(120), cond = function()
            poll()
            if got["t.ack"] == st.id then return true end
            if os.time() - lastSend >= 3 then
                lastSend = os.time()
                local tod, ov = world()
                PTNative_MsgToHost(T.localPC():GetAddress(), "t." .. st.id, string.format("%s|%d|%d|%d|%.5f|%d", T.map(),
                    (T.cls(T.myPawn()) == T.CHAR) and 1 or 0, C.car() and 1 or 0, G.invCount(T), tod, ov))
            end
            return false
        end })
    end
    add({ wait = 20 })
    return steps
end
