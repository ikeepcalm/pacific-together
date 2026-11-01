-- Rescue menu (rescue.lua): the guest teleports to the host, then completes the host's stuck Q01 task "GrabbedAnchor" from its
-- own side (the friend's softlock 2026-10-25: Q01 restarted after every run). Driven through the console (ptrescue), same handlers
-- as F9 and the number keys.
-- Run: tools/run-test.ps1 -Scenario rescue -Fixture pt8-q01 -Headless      Mutation norescue: both host checks FAIL.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local got = {}
    local function g(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind]
    end
    local function grabbed()
        local q = T.first("BP_QuestManager_C")
        local a = q and q.ActiveObjectives
        for i = 1, a and a:GetArrayNum() or 0 do
            local ms = a[i].ActiveMissionState
            if ms:IsValid() and ms.Data:GetFName():ToString() == "QD_Q01_Mission_C" then
                for j = 1, ms.Tasks:GetArrayNum() do
                    if ms.Tasks[j].UniqueName:ToString() == "GrabbedAnchor" then return ms.TaskStates[j].bCompleted end
                end
            end
        end
    end
    local function near()
        local g0, me = L.guestChar(), L.own()
        if not (g0 and me) then return false end
        local a, b = g0:K2_GetActorLocation(), me:K2_GetActorLocation()
        T.log("PT|rescuetest guest %.0f,%.0f,%.0f host %.0f,%.0f,%.0f", a.X, a.Y, a.Z, b.X, b.Y, b.Z)
        return T.dist(g0, me) < 400
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        for _, s in ipairs(T.loadFixture("pt8-q01")) do add(s) end
        add({ check = "host_on_q01_mission_c", timeout = 30, cond = function() return grabbed() == false end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 5 })
        -- F9's menu is drawn (the overlay once read its text from an undeclared global: the menu ran, nothing showed)
        add({ run = function() T.console("ptrescue menu") end })
        add({ check = "host_menu_shown", timeout = 5, cond = function()
            for _, t in ipairs(FindAllOf("TextBlock") or {}) do
                -- the menu's card (overlay.lua): its title, shown while the frame around it is visible
                if t:IsValid() and t:GetFName():ToString() == "PTCardTitle" then
                    local frame = FindFirstOf("Border")
                    for _, b in ipairs(FindAllOf("Border") or {}) do if b:IsValid() and b:GetFName():ToString() == "PTCardFrame" then frame = b end end
                    return frame:GetVisibility() == 3 and t:GetText():ToString() == "RESCUE"
                end
            end
        end })
        add({ run = function() T.console("ptrescue menu") end })
        -- the guest away from the host first, so the teleport has something to prove
        add({ run = function()
            local l = L.own():K2_GetActorLocation()
            L.own():K2_SetActorLocation({ X = l.X + 1500, Y = l.Y, Z = l.Z + 20 }, false, {}, true)
        end })
        add({ wait = 3 })
        add({ check = "host_guest_far_before", timeout = 10, cond = function() return not near() end })
        add({ run = function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.go", "1") end })
        add({ check = "host_guest_teleported", timeout = 30, cond = near })
        add({ check = "host_task_done_by_rescue", timeout = 30, cond = function() return grabbed() == true end })
        add({ run = function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.done", "1") end })
        add({ wait = 3 })
        return steps
    end

    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end },
        { check = "guest_told_go", timeout = 300, cond = function() return g("t.go") ~= nil end },
        { run = function() T.console("ptrescue tp") end },
        { wait = 3 },
        { run = function() T.console("ptrescue tasks") end },
        { wait = 3 }, -- the host's task list comes back
        { run = function() T.console("ptrescue do GrabbedAnchor") end },
        { check = "guest_task_mirrored", timeout = 30, cond = function() return grabbed() == true end },
        { check = "guest_done", timeout = 120, cond = function() return g("t.done") ~= nil end },
    }
end
