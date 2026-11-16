-- Owner 2026-11-16: the guest saw nothing while the host chose its route at a junction. transition.lua now opens the game's own route
-- map (player menu, drive page, read-only) on the guest when the host's Open Map UI fires and closes it when the host's menu closes.
-- Host opens the junction route UI -> guest has the menu visible within 3 s -> host closes it -> guest menu gone.
-- Run: tools/run-test.ps1 -Scenario routemap -Fixture coop-zone -Headless     Mutation: noroutemap (the guest does not open the map)
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind] ~= nil
    end
    local function menuOpen()
        for _, w in ipairs(FindAllOf("UMG_PlayerMenu_Main_C") or {}) do
            if w:IsValid() and w:IsInViewport() and w:IsVisible() then return true end
        end
        return false
    end
    local fixture = (os.getenv("PT_FIXTURE") or ""):match("[^,]+") or "coop-zone"

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        for _, s in ipairs(T.loadFixture(fixture)) do add(s) end
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() and T.map() ~= "RB_Garage" end })
        add({ check = "host_guest_in_zone", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 5 })
        add({ run = function()
            local pm = T.first("BP_ProgressionManager_C")
            pm["Open Map UI"](pm)
            log("PT|info host route menu opened, host menu open=%s", tostring(menuOpen()))
        end })
        add({ check = "host_route_menu_open", timeout = 5, cond = menuOpen })
        add({ check = "guest_saw_route_map", timeout = 20, cond = function() return has("t.opened") end })
        add({ run = function() local pm = T.first("BP_ProgressionManager_C"); pm:CloseMapUI() end })
        add({ check = "guest_route_map_closed", timeout = 20, cond = function() return has("t.closed") end })
        add({ wait = 2 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() ~= "RB_Garage" and T.map() ~= "RB_MainMenu" and T.cls(T.myPawn()) == T.CHAR end })
    local opened
    add({ check = "client_route_map_shown_after_host_opens", timeout = 120, cond = function()
        if menuOpen() then opened = opened or os.clock() end
        return opened ~= nil
    end })
    add({ run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.opened", "1") end })
    add({ check = "client_route_map_closed_with_host", timeout = 60, cond = function() return not menuOpen() end })
    add({ run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.closed", "1") end })
    add({ wait = 3 })
    return steps
end
