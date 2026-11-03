-- M6 overlay (overlay.lua of the shipping mod): the version label top right from the menu on, its session status, and the
-- feed of what the other player does. Read from the outside, through the UMG widget the mod builds (PTOverlayBox):
--   menu: label present, in the viewport, anchored bottom right, never hit-testable; host: no status alone; guest: "Joining ...";
--   garage: host "Host . 1 guest . N ms" and "<name> joined"; guest "Guest . <host> . N ms" and "Connected to <host>";
--   quiet feed (2026-10-30): what the world already shows is not narrated: the host puts an item into the trunk and takes it out
--   again, the guest enters the car -> no feed line for any of it (mutation loudfeed: the old feed, these checks FAIL); lines expire (6 s);
--   after the host's run start (map change on both sides) the label and the status are back.
-- Run: tools/run-test.ps1 -Scenario overlay -Fixture garage -Headless
-- Mutation nooverlay: overlay.lua does nothing (no widget): every check FAILS. Mutation loudfeed: the quiet checks FAIL.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local STEEL = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
    local function im() return T.first("BP_InventoryManager_C") end

    -- what the widget shows now: { label, status, lines = {...}, anchored, hitInvisible }
    local function snap()
        for _, b in ipairs(FindAllOf("VerticalBox") or {}) do
            if b:IsValid() and b:GetFName():ToString() == "PTOverlayBox" then
                local w = b:GetOuter():GetOuter()
                if w:IsValid() and w:IsInViewport() then
                    local r = { lines = {}, hitInvisible = w:GetVisibility() == 3 and b:GetVisibility() == 3 }
                    local a = b.Slot:GetAnchors()
                    r.anchored = a.Minimum.X == 1 and a.Minimum.Y == 1 and a.Maximum.X == 1 and a.Maximum.Y == 1
                    for i = 0, b:GetChildrenCount() - 1 do
                        local t = b:GetChildAt(i)
                        local s = t:GetText():ToString()
                        if i == 0 then r.label = s
                        elseif i == 1 then r.status = t:GetVisibility() ~= 1 and s or ""
                        elseif t:GetVisibility() ~= 1 and s ~= "" then r.lines[#r.lines + 1] = s end
                    end
                    return r
                end
            end
        end
    end
    local function labelOk(id)
        return { check = id, timeout = 30, cond = function()
            local s = snap()
            T.log("PT|info overlay %s label=%s status=%s lines=%d anchored=%s hit=%s", id, s and s.label or "-", s and s.status or "-", s and #s.lines or -1, s and tostring(s.anchored) or "-", s and tostring(s.hitInvisible) or "-")
            return s ~= nil and s.label:match("^Pacific Together %d+%.%d+%.%d+") ~= nil and s.anchored and s.hitInvisible
        end }
    end
    local function line(id, pattern, timeout)
        return { check = id, timeout = timeout or 40, cond = function()
            local s = snap()
            for _, l in ipairs(s and s.lines or {}) do if l:find(pattern) then T.log("PT|info overlay line '%s'", l); return true end end
            return false
        end }
    end
    -- no line matching pattern for 6 s
    local function quiet(id, pattern)
        local since, seen
        return { check = id, timeout = 12, cond = function()
            since = since or os.clock()
            local s = snap()
            for _, l in ipairs(s and s.lines or {}) do if l:find(pattern) then T.log("PT|info overlay unwanted line '%s'", l); seen = true end end
            return not seen and os.clock() - since > 6
        end }
    end
    local function status(id, pattern, timeout)
        return { check = id, timeout = timeout or 60, cond = function() local s = snap(); return s ~= nil and s.status:find(pattern) ~= nil end }
    end
    local function expired(id)
        return { check = id, timeout = 15, cond = function() local s = snap(); return s ~= nil and #s.lines == 0 end }
    end
    local function inZone() return L.gameplay(T.map()) and T.map() ~= "RB_Garage" end

    local got = {}
    local function drain()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then return end
            got[kind] = data
        end
    end
    local function has(kind) drain(); return got[kind] ~= nil end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function sendGuest(kind) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), kind, "") end
        add(T.onMap("RB_MainMenu", 90))
        add(labelOk("host_label_on_menu"))
        add({ check = "host_no_status_on_menu", timeout = 5, cond = function() local s = snap(); return s ~= nil and s.status == "" end })
        for i, s in ipairs(T.loadFixture("garage", false)) do add(s) end
        add(labelOk("host_label_after_map"))
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add(status("host_status_session", "^Host.* 1 guest.* %d+ ms$"))
        add(line("host_feed_joined", " joined$", 10))
        -- the first full sync is not news: the mod waits a few seconds into a session before it relays container changes
        add({ wait = 9 })
        add({ run = function()
            local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
            im().Inventory_Trunk:AddItem(lib:CreateItemInstance(T.world(), StaticFindObject(STEEL), 0), true)
            sendGuest("t.put")
        end })
        add({ check = "host_guest_saw_put", timeout = 30, cond = function() return has("t.putok") end })
        add({ run = function()
            local c = im().Inventory_Trunk
            for i = 0, c:GetNumSlots() - 1 do
                local s = c:GetSlot(i)
                if s:IsValid() and s:GetNumItems() > 0 then s:TransferStackIntoContainer(im().Inventory_PlayerHand, {}); break end
            end
        end })
        add({ check = "host_guest_saw_take", timeout = 30, cond = function() return has("t.takeok") end })
        add(quiet("host_no_entered_car_line", " entered the car$"))
        add(expired("host_feed_expires"))
        add({ run = function()
            StaticFindObject("/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C"):TravelToNextLeg(T.world())
        end })
        add({ check = "host_listens_zone", timeout = 240, cond = function() return inZone() and T.netMode() == "listen" and T.listening() end })
        add(labelOk("host_label_after_travel"))
        add({ check = "host_guest_back_zone", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add(status("host_status_after_travel", "^Host.* 1 guest"))
        add({ wait = 3 })
        return steps
    end

    local steps = {}
    local function add(s) steps[#steps + 1] = s end
    add(T.onMap("RB_MainMenu", 90))
    add(labelOk("client_label_on_menu"))
    add(status("client_status_joining", "^Joining ", 20))
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add(labelOk("client_label_after_map"))
    add(status("client_status_session", "^Guest.* %d+ ms$"))
    add(line("client_feed_connected", "^Connected to ", 15))
    add({ check = "client_told_put", timeout = 90, cond = function() return has("t.put") end })
    add(quiet("client_no_trunk_put_line", "^%d+ items? put into .*trunk"))
    add({ run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.putok", "") end })
    add(quiet("client_no_trunk_take_line", "^%d+ items? taken from .*trunk"))
    add({ run = function()
        PTNative_MsgToHost(T.localPC():GetAddress(), "t.takeok", "")
        -- the car intent the door hook sends (car.lua)
        T.intent("g.car.enter", "")
    end })
    add(expired("client_feed_expires"))
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and inZone() and T.cls(T.myPawn()) == T.CHAR end })
    add(labelOk("client_label_after_travel"))
    add(status("client_status_after_travel", "^Guest.* %d+ ms$"))
    add({ wait = 3 })
    return steps
end
