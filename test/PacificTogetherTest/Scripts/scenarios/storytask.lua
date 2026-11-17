-- storytask (G3): a tutorial step only the guest's UI does ("open the route planner") advances the host's objective.
-- Fixture `garage`, the guest joins by itself. The host starts the expedition tutorial's route-planner mission; the guest's planner
-- fires its task event (what BP_UIManager.OnWorldRoutePlannerUsed does); the host's task must complete.
-- Run: tools/run-test.ps1 -Scenario storytask -Fixture garage -Headless
-- Mutation nostorytask: the guest does not report UI-only tasks: host_task_done_by_guest FAILS.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local P = "/Game/Gameplay/Quests/"
    local function qm() return T.first("BP_QuestManager_C") end
    local function strip(o) return (o:GetFullName():gsub("^%S+ ", "")) end
    local function load(p)
        local o = StaticFindObject(p)
        if not (o and o:IsValid()) then pcall(LoadAsset, p); o = StaticFindObject(p) end
        return o
    end
    -- the route-planner task of the active tutorial objective on this side: task, state
    local function rpTask()
        local q = qm()
        for i = 1, q.ActiveObjectives:GetArrayNum() do
            local s = q.ActiveObjectives[i]
            local ms = s.ActiveMissionState
            if strip(s.Objective):find("ExpeditionTutorial") and ms and ms:IsValid() and ms.Data:IsValid() then
                for j = 1, ms.Tasks:GetArrayNum() do
                    local t = ms.Tasks[j]
                    if t:IsValid() and t:GetClass():GetFName():ToString() == "BPMT_RoutePlannerOpen_C" then return t, ms.TaskStates[j] end
                end
            end
        end
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 15 })
        add({ run = function()
            local q = qm()
            q:StartObjective(load(P .. "ExpeditionFlow/QD_ExpeditionTutorial.QD_ExpeditionTutorial"), true, true)
            for i = 1, q.ActiveObjectives:GetArrayNum() do
                local s = q.ActiveObjectives[i]
                if strip(s.Objective):find("ExpeditionTutorial") then
                    s:StartNextMission(load(P .. "ExpeditionFlow/QO_ExpeditionTutorial_UseRoutePlanner.QO_ExpeditionTutorial_UseRoutePlanner"))
                end
            end
        end })
        add({ check = "host_planner_task_open", timeout = 30, cond = function()
            local t, st = rpTask()
            return t ~= nil and not st.bCompleted
        end })
        add({ wait = 15 })
        add({ run = function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.go", "1") end })
        add({ check = "host_task_done_by_guest", timeout = 60, cond = function()
            local t, st = rpTask()
            return t ~= nil and st.bCompleted
        end })
        add({ check = "host_guest_alive", timeout = 20, cond = L.holds(8, function() return T.netMode() == "listen" and T.pcs() == 2 end) })
        add({ check = "host_guest_finished", timeout = 120, cond = function()
            while true do
                local kind = PTNative_MsgPoll("t.")
                if not kind then return false end
                if kind == "t.done" then return true end
            end
        end })
        return steps
    end

    local go
    local function drain()
        while true do
            local kind = PTNative_MsgPoll("t.")
            if not kind then return end
            if kind == "t.go" then go = true end
        end
    end
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in", timeout = 400, cond = function() return T.netMode() == "client" and T.cls(T.myPawn()) == T.CHAR end },
        { check = "guest_sees_planner_task", timeout = 120, cond = function() return (rpTask()) ~= nil end },
        { check = "guest_told_to_open", timeout = 120, cond = function() drain(); return go == true end },
        -- the planner event the real UI raises on the guest's own UI manager
        { run = function()
            local t = rpTask()
            local ui = T.first("BP_UIManager_C")
            T.log("PT|info planner task requireOffers=%s offersDisplayed=%s", tostring(t.RequireExpeditionOffersDisplayed), tostring(ui.RunOffersDisplayed))
            ui.RunOffersDisplayed = true -- the task asks for the planner's offers to be on screen
            t:RoutePlannerUsed(true)
            T.log("PT|info planner after offersDisplayed=%s inUse=%s", tostring(ui.RunOffersDisplayed), tostring(t.RoutePlannerInUse))
            local q = qm()
            for i = 1, q.ActiveObjectives:GetArrayNum() do
                local ms = q.ActiveObjectives[i].ActiveMissionState
                if ms and ms:IsValid() then
                    local c = {}
                    for j = 1, ms.Tasks:GetArrayNum() do c[#c + 1] = ms.Tasks[j]:GetClass():GetFName():ToString() .. "=" .. tostring(ms.TaskStates[j].bCompleted) end
                    T.log("PT|info planner ms %s active=%s tasks=%s", strip(q.ActiveObjectives[i].Objective), tostring(ms.ActiveTaskIndex), table.concat(c, ","))
                end
            end
        end },
        { check = "guest_task_done_locally", timeout = 20, cond = function()
            local t, st = rpTask()
            local ok, r = pcall(function() return t:K2_CheckCompletion() end)
            T.log("PT|info planner poll check=%s %s completed=%s", tostring(ok), tostring(r), tostring(st and st.bCompleted))
            return ok and r == true
        end },
        { wait = 8 }, -- the guest's report goes out within a second
        { check = "guest_alive_after", timeout = 30, cond = L.holds(10, function() drain(); return T.netMode() == "client" and T.myPawn() ~= nil end) },
        { run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.done", "1") end },
        { wait = 3 },
    }
end
