-- Co-op rescue menu (owner request 2026-10-30: a glitch or a softlock, such as Q01's antenna run restarting, needs a way out
-- without quitting). F9 opens it during a session, number keys pick:
--   1 teleport to the partner (beside the car when they sit in it)
--   2 resync: the host sends its progression and story again, the guest reports its done tasks again
--   3 reset controls (the guest's car unstick; on the host the input flags and view target)
--   4 story tasks: the host's open tasks of its active missions; a number twice force-completes that task on the host
--     (the host owns the story, story.lua mirrors the result to the guest). For a task the mod missed, e.g. "Take the Anchor".
--   g.rescue.ask    guest -> host  send me your open tasks        g.rescue.tasks  host -> guest  "obj\tmis\tidx\tname\tclass" rows
--   g.rescue.do     guest -> host  "obj\tmis\tidx" complete it    g.rescue.sync   either way     resync that side too
--   g.rescue.tp     guest -> host  move me to you                 g.rescue.at     host -> guest  "x,y,z" where the host put it
-- Console (tests, players with a console): ptrescue menu | tp | sync | unstick | tasks | do <n or task name>. Inert outside a session (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local ov = require("overlay")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "norescue" }

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function path(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function short(p) return p:match("([^./]+)$") or p end

-- our character and the partner's (as desync.lua finds them)
local function chars()
    local pc = UEHelpers.GetPlayerController()
    local me = valid(pc) and pc.Pawn or nil
    if not valid(me) then return nil end
    for _, c in ipairs(FindAllOf("PDP_MainCharacter_C") or {}) do
        if valid(c) and c:GetAddress() ~= me:GetAddress() and not c:GetFullName():find("/Engine/Transient", 1, true) then return me, c end
    end
    return me, nil
end
local function parent(c) local ok, p = pcall(function() return c:GetAttachParentActor() end); return ok and valid(p) and p or nil end

-- actions ------------------------------------------------------------------------------------------------------------------

-- where to put a player who wants to join `other`: beside the car on its left when they sit in it, else just behind them
local function spotBy(other)
    local car = parent(other)
    if car then -- a little up so the drop settles on the ground
        local l, r = car:K2_GetActorLocation(), car:GetActorRightVector()
        return { X = l.X - r.X * 350, Y = l.Y - r.Y * 350, Z = l.Z + 120 }
    end
    local l, f = other:K2_GetActorLocation(), other:GetActorForwardVector()
    return { X = l.X - f.X * 120, Y = l.Y - f.Y * 120, Z = l.Z + 20 }
end
local function fmt(l) return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end

-- the guest's own move is not sent while it stands still (the host's copy stayed behind, rescue test 2026-10-30): the host moves
-- its copy of the guest and tells the guest the same spot
local function teleport()
    local me, other = chars()
    if not valid(other) then return "Partner not found" end
    if parent(me) then return "Leave the car first (or 3 to reset controls)" end
    if safety.guest() then net.toHost("g.rescue.tp", "") return "Teleporting to partner" end
    local to = spotBy(other)
    me:K2_SetActorLocation(to, false, {}, true)
    log("PT|rescue teleport to %s", fmt(to))
    return "Teleported to partner"
end
net.on("g.rescue.tp", function(pc)
    if not M.enabled or safety.guest() then return end
    local g, me = pc.Pawn, (chars())
    if not (valid(g) and valid(me)) or parent(g) then return end
    local to = spotBy(me)
    g:K2_SetActorLocation(to, false, {}, true)
    net.toGuest(pc, "g.rescue.at", fmt(to))
    log("PT|rescue host puts the guest at %s", fmt(to))
end)
net.on("g.rescue.at", function(_, data)
    if not M.enabled or not safety.guest() then return end
    local x, y, z = data:match("^(-?[%d.]+),(-?[%d.]+),(-?[%d.]+)$")
    local me = chars()
    if x and valid(me) and not parent(me) then
        me:K2_SetActorLocation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, false, {}, true)
        log("PT|rescue guest teleported to %s", data)
    end
end)

-- the guest asks for progression and reports its done tasks again; the host sends its story again
local function resyncHere()
    local st = package.loaded["story"]
    if safety.guest() then
        net.toHost("g.prog.hi", "")
        if st and st.rereport then st.rereport() end
    elseif st and st.resend then st.resend() end
end
local function resync()
    resyncHere()
    if safety.guest() then net.toHost("g.rescue.sync", "") else net.toGuests("g.rescue.sync", "") end
    log("PT|rescue resync (%s)", safety.guest() and "guest" or "host")
    return "Resync requested"
end
net.on("g.rescue.sync", function()
    if not M.enabled then return end
    resyncHere()
    log("PT|rescue resync asked by the %s", safety.guest() and "host" or "guest")
end)

-- An interact-camera screen (the ARC) turns highlights off, can force a holster and hides the HUD while focused; only its
-- unfocus end turns them back. Host in the ARC while the guest joined: no interaction prompts afterwards and 3 did not help
-- (owner 2026-11-07). Cause not reproduced yet; this undoes what a broken unfocus leaves and logs which part was stuck.
local function clearFocus()
    local fixed = {}
    for _, c in ipairs(FindAllOf("BP_InteractCameraComponent_C") or {}) do
        local ok, p = pcall(function() return c["Focused Player"] end)
        if valid(c) and ok and valid(p) then pcall(function() c:UnfocusPlayer() end); fixed[#fixed + 1] = "focus" end
    end
    local hm = FindFirstOf("BP_HighlightManager_C")
    if valid(hm) and not hm.Enabled then pcall(function() hm:EnableHighlights() end); fixed[#fixed + 1] = "highlights" end
    local cm = FindFirstOf("BP_MainCharacterManager_C")
    if valid(cm) and cm.ForcedHolsterActive then pcall(function() cm:EndForcedHolster() end); fixed[#fixed + 1] = "holster" end
    pcall(function()
        local w = FindObject("BFL_Widget_Utils_C", "Default__BFL_Widget_Utils_C")
        w["Set Player HUD Hidden"](w, false, cm)
    end)
    log("PT|rescue focus cleared: %s", #fixed > 0 and table.concat(fixed, " ") or "nothing stuck")
end

local function unstick()
    pcall(clearFocus)
    local car = package.loaded["car"]
    if safety.guest() then
        if car and car.unstick then car.unstick() end
    else
        local pc = UEHelpers.GetPlayerController()
        local me = valid(pc) and pc.Pawn
        if not valid(me) then return "No character" end
        pcall(function() pc:ResetIgnoreInputFlags() end)
        if not parent(me) then pcall(function() pc:SetViewTargetWithBlend(me, 0, 0, 0, false) end) end
        pcall(function() me:EnableInput(pc) end)
        pcall(function() StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(pc) end)
    end
    log("PT|rescue unstick")
    return "Controls reset"
end

-- story tasks (host) ---------------------------------------------------------------------------------------------------------

-- the objective BP_QuestDirector starts after each one (its ubergraph, local/atlas/bp/BP_QuestDirector.txt).
-- shortcut: only Q01 -> Q015 is listed (the softlock seen); add a pair when another quest is found stuck between objectives.
local NEXT = { QD_Q01_Objective = "/Game/Gameplay/Quests/Q015/QD_Q015_Objective.QD_Q015_Objective" }

-- The DLC chapters (Fig) put the main story to sleep through this switch, one state per chapter. A finished chapter whose
-- state stayed on keeps every main objective dormant: its missions never tick, tasks never complete and force-completing
-- does nothing (friend's save 2026-11-03: Fig Chapter01 done, Q03 "Return to Sierra" stuck; local/fixtures/pt11-q03).
local DORMANCY = "/Game/Systems/GlobalStateSwitches/GSS_MainQuestsDormancy.GSS_MainQuestsDormancy"
local function dormancySwitch()
    local sw = StaticFindObject(DORMANCY)
    if not sw:IsValid() then pcall(LoadAsset, DORMANCY); sw = StaticFindObject(DORMANCY) end
    local gi = FindFirstOf("DrivingGameInstance")
    if valid(sw) and valid(gi) then return sw, gi end
end
-- stuck = the switch is on while no DLC chapter objective runs and a main objective is dormant
local function storyAsleep(q)
    local sw, gi = dormancySwitch()
    if not (sw and gi:GetGlobalSwitch(sw)) then return false end
    local w, dormant = UEHelpers.GetWorld(), false
    for i = 1, q.ActiveObjectives:GetArrayNum() do
        local o = q.ActiveObjectives[i].Objective
        if valid(o) then
            if o:GetFName():ToString():find("^QO_Fig") then return false end
            if o:IsDormant(w) then dormant = true end
        end
    end
    return dormant
end
local wokeAt, woken = nil, {} -- os.clock() of the last wake on the host; objective paths that were dormant then
-- a woken mission completes on its first tick but the manager never moves on (Q03 A2 stayed the active mission, no Oppy line and
-- no waypoint; live 2026-11-04): for 10 s after a wake, advance each active objective whose mission is complete
local function advanceWoken()
    local q = FindFirstOf("BP_QuestManager_C")
    if not valid(q) then return end
    for i = 1, q.ActiveObjectives:GetArrayNum() do
        local s = q.ActiveObjectives[i]
        local ms = s.ActiveMissionState
        if valid(s.Objective) and woken[path(s.Objective)] and valid(ms) and valid(ms.Data) and ms:IsCompleted() then
            woken[path(s.Objective)] = nil -- once: the game's own director may still move it on later
            local was = path(ms.Data)
            q:AdvanceObjective(s.Objective, nil)
            log("PT|rescue host moves %s on from the woken %s", path(s.Objective), was)
            return -- the array changed
        end
    end
end
local function wakeStory()
    local sw, gi = dormancySwitch()
    if not sw then return false end
    local q = FindFirstOf("BP_QuestManager_C")
    if not (valid(q) and storyAsleep(q)) then return false end -- a stale menu row: a DLC chapter may have started since
    woken = {}
    local w = UEHelpers.GetWorld()
    for i = 1, q.ActiveObjectives:GetArrayNum() do
        local o = q.ActiveObjectives[i].Objective
        if valid(o) and o:IsDormant(w) then woken[path(o)] = true end
    end
    wokeAt = os.clock()
    for i = 1, sw.States:GetArrayNum() do gi:SetGlobalSwitch(sw, sw.States[i], 0) end -- 0 = DONTCARE: the chapter lets go
    log("PT|rescue host wakes the main story: dormancy switch now %s", tostring(gi:GetGlobalSwitch(sw)))
    return not gi:GetGlobalSwitch(sw)
end

local function openTasks()
    local q = FindFirstOf("BP_QuestManager_C")
    if not valid(q) then return {} end
    local rows, a = {}, q.ActiveObjectives
    if storyAsleep(q) then rows[1] = table.concat({ "wake", "main story", 0, "Wake the main story", "asleep after a DLC chapter" }, "\t") end
    for i = 1, a:GetArrayNum() do
        local s = a[i]
        local ms = s.ActiveMissionState
        if valid(s.Objective) and valid(ms) and valid(ms.Data) then
            for j = 1, ms.TaskStates:GetArrayNum() do
                local t = ms.Tasks[j]
                if valid(t) and not ms.TaskStates[j].bCompleted then
                    local ok, n = pcall(function() return t.UniqueName:ToString() end)
                    rows[#rows + 1] = table.concat({ path(s.Objective), path(ms.Data), j, (ok and n ~= "" and n ~= "None") and n or ("task " .. j),
                        (t:GetClass():GetFName():ToString():gsub("^BPMT_", ""):gsub("_C$", "")) }, "\t")
                end
            end
        end
    end
    -- nothing active after a forced finish: the game's quest director did not go on (Q01 forced done in the garage, 2026-10-30:
    -- its "Q01 complete" branch never ran). Offer the objective it would start, as a row of its own ("next" instead of a mission).
    if a:GetArrayNum() == 0 then
        local done = {}
        for i = 1, q.CompletedObjectives:GetArrayNum() do
            local o = q.CompletedObjectives[i]
            if valid(o) then done[path(o)] = o:GetFName():ToString() end
        end
        for _, n in pairs(done) do
            local nx = NEXT[n]
            if nx and not done[nx] then
                if not StaticFindObject(nx):IsValid() then pcall(LoadAsset, nx) end
                if StaticFindObject(nx):IsValid() then rows[#rows + 1] = table.concat({ "next", nx, 0, "Start " .. short(nx), "next quest" }, "\t") end
            end
        end
    end
    return rows
end

local function complete(obj, mis, idx)
    local q = FindFirstOf("BP_QuestManager_C")
    if obj == "wake" then return wakeStory() end
    if obj == "next" then
        local o = StaticFindObject(mis)
        local ok = valid(q) and valid(o) and q:StartObjective(o, false, true)
        log("PT|rescue host starts objective %s ok=%s", mis, tostring(ok))
        return ok
    end
    local a = valid(q) and q.ActiveObjectives
    for i = 1, a and a:GetArrayNum() or 0 do
        local s = a[i]
        local ms = s.ActiveMissionState
        if valid(s.Objective) and path(s.Objective) == obj and valid(ms) and valid(ms.Data) and path(ms.Data) == mis then
            local t = ms.Tasks[idx]
            if valid(t) and not ms.TaskStates[idx].bCompleted then
                ms:ForceCompleteTask(t)
                log("PT|rescue host force-completes task %d of %s", idx, mis)
                return true
            end
        end
    end
    log("PT|rescue no open task %d of %s", idx, mis)
    return false
end

-- menu -----------------------------------------------------------------------------------------------------------------------

local page, tasks, armed = nil, {}, nil -- nil | "main" | "tasks"; the host's open task rows; the task number pressed once

local function show(note)
    if page == nil then ov.panel(nil) return end
    local L = { page == "main" and "Rescue" or "Story tasks" } -- the card's title (overlay.lua)
    if page == "main" then
        L[#L + 1] = "[1]  Teleport to partner"
        L[#L + 1] = "[2]  Resync with host"
        L[#L + 1] = "[3]  Reset controls"
        L[#L + 1] = "[4]  Story tasks: fix a stuck objective"
        L[#L + 1] = "[5]  Performance mode: " .. (require("perf").enabled() and "on" or "off")
        L[#L + 1] = "[6]  Performance check (10 s)"
        local ga = package.loaded.guestauth
        -- guest only: the host switching it off would ignore a guest that still simulates
        if safety.guest() and type(ga) == "table" and ga.toggle then
            L[#L + 1] = "[7]  Guest drives own car: " .. (ga.off and "off" or "on")
        end
        L[#L + 1] = " "
        L[#L + 1] = "[F9]  Close"
    else
        if #tasks == 0 then L[#L + 1] = "No open story tasks (waiting for the host...)" end
        for i, r in ipairs(tasks) do
            if i > 9 then break end
            local _, mis, _, name, cls = r:match("^([^\t]+)\t([^\t]+)\t(%d+)\t([^\t]+)\t([^\t]+)$")
            L[#L + 1] = string.format("%d  %s  (%s, %s)", i, name or "?", cls or "?", mis and short(mis) or "?")
        end
        L[#L + 1] = armed and string.format("Press %d again to complete it for both", armed) or "A number twice completes that task.  0 back"
    end
    if note then L[#L + 1] = note end
    ov.panel(table.concat(L, "\n"))
end

local function askTasks()
    if safety.guest() then net.toHost("g.rescue.ask", "") else tasks = openTasks() end
end
net.on("g.rescue.ask", function(pc)
    if not M.enabled or safety.guest() then return end
    net.toGuest(pc, "g.rescue.tasks", table.concat(openTasks(), "\n"))
end)
net.on("g.rescue.tasks", function(_, data)
    if not M.enabled or not safety.guest() then return end
    tasks = {}
    for l in data:gmatch("[^\n]+") do tasks[#tasks + 1] = l end
    if page == "tasks" then show() end
end)
net.on("g.rescue.do", function(pc, data)
    if not M.enabled or safety.guest() then return end
    local obj, mis, idx = data:match("^([^\t]+)\t([^\t]+)\t(%d+)$")
    if obj then complete(obj, mis, tonumber(idx)) end
    net.toGuest(pc, "g.rescue.tasks", table.concat(openTasks(), "\n"))
end)

local function doTask(i)
    local obj, mis, idx, name = (tasks[i] or ""):match("^([^\t]+)\t([^\t]+)\t(%d+)\t([^\t]+)")
    if not obj then return "No task " .. tostring(i) end
    if safety.guest() then
        net.toHost("g.rescue.do", string.format("%s\t%s\t%s", obj, mis, idx))
    else
        complete(obj, mis, tonumber(idx))
        tasks = openTasks()
    end
    return "Completed: " .. name
end

local ACTIONS = { teleport, resync, unstick, nil, function() return require("perf").toggle() end,
    function() return require("perf").check(function(text) if page then show(text) else ov.post(text, "info", "perfcheck") end end) end,
    function() local ga = package.loaded.guestauth; if safety.guest() and type(ga) == "table" and ga.toggle then return ga.toggle() end end }
local function press(n)
    if page == "main" then
        if ACTIONS[n] then show(ACTIONS[n]())
        elseif n == 4 then page, armed = "tasks", nil; askTasks(); show() end
    elseif page == "tasks" then
        if n == 0 then page, armed = "main", nil; show()
        elseif armed == n then armed = nil; show(doTask(n))
        elseif tasks[n] then armed = n; show() end
    end
end

local wanted = {} -- keys and console commands run on the 100 ms game-thread loop below
-- a held key reads down/up every other 30 ms poll (rendered host 2026-10-30): one F9 toggled the menu open and shut within a tick,
-- and one number press would arm and confirm a task. A press counts only 0.4 s after the key's last down edge (a held key keeps it out).
local lastAt = {}
local function key(name, fn)
    common.onKey(name, function()
        local t = lastAt[name]
        lastAt[name] = os.clock()
        if not t or os.clock() - t >= 0.4 then fn() end
    end)
end
key("F9", function() wanted[#wanted + 1] = "menu" end)
local NUM = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
for i, k in ipairs(NUM) do key(k, function() if page then wanted[#wanted + 1] = i - 1 end end) end
-- the test mod is another Lua state: its scenario drives the same actions through the console
pcall(RegisterConsoleCommandHandler, "ptrescue", function(full) wanted[#wanted + 1] = tostring(full) return true end)

local function run(w)
    if w == "menu" then
        page, armed = (page == nil) and "main" or nil, nil
        show()
    elseif type(w) == "number" then press(w)
    else
        local cmd, arg = w:match("^%S+%s+(%S+)%s*(.*)$")
        local r
        if cmd == "menu" then run("menu"); r = page or "closed"
        elseif cmd == "tp" then r = teleport() elseif cmd == "sync" then r = resync() elseif cmd == "unstick" then r = unstick()
        elseif cmd == "tasks" then askTasks(); r = "tasks asked"
        elseif cmd == "do" then
            local n = tonumber(arg)
            if not n then for i, t in ipairs(tasks) do if select(4, t:match("^([^\t]+)\t([^\t]+)\t(%d+)\t([^\t]+)")) == arg then n = i break end end end
            r = n and doTask(n) or ("no task " .. arg)
        end
        log("PT|rescue console %s -> %s", w, tostring(r))
    end
end

-- the open tasks again every second while the page is up: a forced task finishes a moment later, and its row stayed (pressed twice
-- more, "no open task"; rendered host 2026-10-30); the next-quest row shows up the same way
local refreshAt = 0
LoopInGameThreadWithDelay(100, function()
    if page == "tasks" and not armed and os.clock() - refreshAt >= 1 and M.enabled and safety.active() then
        refreshAt = os.clock()
        local ok, err = pcall(function() askTasks(); if not safety.guest() then show() end end)
        if not ok then log("PT|error rescue refresh %s", tostring(err)) end
    end
    if wokeAt and os.clock() - wokeAt < 10 and M.enabled and safety.active() then
        local ok, err = pcall(advanceWoken)
        if not ok then log("PT|error rescue advance %s", tostring(err)) end
    end
    if #wanted == 0 then return end
    local list = wanted
    wanted = {}
    if not (M.enabled and safety.active()) then
        if page then page = nil; ov.panel(nil) end
        return
    end
    for _, w in ipairs(list) do
        local ok, err = pcall(run, w)
        if not ok then log("PT|error rescue %s", tostring(err)) end
    end
end)
RegisterLoadMapPostHook(function() page, armed, tasks = nil, nil, {}; ov.panel(nil) end)

return M
