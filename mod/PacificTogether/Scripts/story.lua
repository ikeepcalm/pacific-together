-- The guest experiences the host's story (G3, G4). The host owns the story; the guest's quest manager only shows it.
--   quest state   twice a second the host sends its active objectives (objective asset, active mission asset, completed-task mask);
--                 the guest starts/stops the same ones through its own quest manager so its HUD and journal show them. Only this
--                 module may start things on the guest ("applying"): the game's own StartMission/StartObjective/AdvanceObjective
--                 calls on a guest stay nulled, so the guest cannot start or branch a story of its own.
--   dialogue      the host's dialogue manager sequence (radio transmissions, voice lines) is played on the guest the same way
--                 (subtitles and audio are the game's own, played locally).
--   cutscenes     the host's playing level sequence is played on the guest (if the guest has it).
-- Everything is inert outside a session (Q7).
local common = require("common")
local net = require("net")
local safety = require("safety")
local log = common.log
local ov = require("overlay")

local M = { enabled = os.getenv("PT_MUTATE") ~= "nostory" } -- the test mutation switches the mirror off (the guest stays a bystander)
local PROG = os.getenv("PT_MUTATE") ~= "nostoryprog" -- nostoryprog: no journal history, no guest-done tasks (the pt2-story additions)

local function live(o) return o and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error story %s %s", what, tostring(err)) end
    return ok
end
local function path(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function load(p)
    local o = StaticFindObject(p)
    if o and o:IsValid() then return o end
    pcall(LoadAsset, p)
    o = StaticFindObject(p)
    if o and o:IsValid() then return o end
end
local function quests() local q = FindFirstOf("BP_QuestManager_C") return live(q) and q or nil end
local function dialogue() local d = FindFirstOf("BP_DialogueManager_C") return live(d) and d or nil end

local hostDone = { o = {}, m = {} } -- what the host finished (paths without the asset-name suffix)
local hostMask = {}                  -- objective path -> the host's completed-task mask
local UI_TASKS
local GUEST_TASKS -- set below (the host handler needs it too)
local applying = false -- true only while this module starts something on the guest

-- G3: the guest's own game starts nothing. A pre-hook cannot cancel a call, so the mission is nulled (unguarded, StartMission on a guest crashes).
for _, fn in ipairs({ "StartMission", "StartObjective", "AdvanceObjective" }) do
    local ok, err = pcall(RegisterHook, "/Script/PenDriverPro.BaseMissionManager:" .. fn, function(self, a)
        if not applying and safety.guest() then pcall(function() a:set(nil) end) end
    end)
    if not ok then log("PT|error story hook %s %s", fn, tostring(err)) end
end

-- ---------------------------------------------------------------- host

local function activeOn(q, objPath)
    local a = q.ActiveObjectives
    for i = 1, a:GetArrayNum() do
        local s = a[i]
        if live(s.Objective) and path(s.Objective) == objPath then return s end
    end
end


local lastQuest, lastSent = "", 0

local function questState()
    local q = quests()
    if not q then return "" end
    local L = {}
    local a = q.ActiveObjectives
    for i = 1, a:GetArrayNum() do
        local s = a[i]
        local ms = s.ActiveMissionState
        if live(s.Objective) and live(ms) and live(ms.Data) then
            local ts, mask = ms.TaskStates, {}
            for j = 1, ts:GetArrayNum() do mask[j] = ts[j].bCompleted and "1" or "0" end
            L[#L + 1] = string.format("o\t%s\t%s\t%s", path(s.Objective), path(ms.Data), table.concat(mask))
        end
    end
    return table.concat(L, "\n")
end


-- journal history: the objectives and missions the host has finished (the journal's "completed" list reads these arrays).
-- Paths drop the ".Name" suffix (the asset name repeats it) so a long game still fits the message cap; chunked, add-only on the guest.
local function doneRows()
    local q = quests()
    if not q then return {} end
    local R = {}
    for i = 1, q.CompletedObjectives:GetArrayNum() do
        local o = q.CompletedObjectives[i]
        if live(o) then R[#R + 1] = "o" .. path(o):gsub("%.[^./]+$", "") end
    end
    for i = 1, q.CompletedMissions:GetArrayNum() do
        local o = q.CompletedMissions[i]
        if live(o) then R[#R + 1] = "m" .. path(o):gsub("%.[^./]+$", "") end
    end
    table.sort(R)
    return R
end
-- Small chunks, one per tick: a long list sent in one frame overflows the reliable channel and drops the guest (seen in the zone fixture).
-- New entries go out at once (before the quest row that removed the objective from the active list); the whole list again every 10 s.
local sentDone, queue, lastCycle = {}, {}, 0
local CHUNK = 3000
local function chunks(R, out)
    local i = 1
    while i <= #R do
        local buf, len = {}, 0
        while i <= #R and (len == 0 or len + #R[i] + 1 <= CHUNK) do buf[#buf + 1] = R[i]; len = len + #R[i] + 1; i = i + 1 end
        out[#out + 1] = table.concat(buf, "\n")
    end
end
-- the finished list is read every 3 s and all of it sent again every 60 s: every 500 ms / 10 s it walked a long save's few hundred
-- finished objectives each time (0.8 s a minute on a host, rendered profile 2026-10-24)
local rows, rowsAt = {}, -10
local function doneTick()
    if os.clock() - rowsAt > 3 then rows, rowsAt = doneRows(), os.clock() end
    local R = rows
    local fresh = {}
    for _, r in ipairs(R) do if not sentDone[r] then fresh[#fresh + 1] = r; sentDone[r] = true end end
    local first = {}
    chunks(fresh, first)
    -- one chunk per tick, also for the first burst (all of the history is fresh then): the rest waits at the front of the queue
    local sent = #first > 0
    if sent then net.toGuests("g.story.done", table.remove(first, 1)) end
    for i, c in ipairs(first) do table.insert(queue, i, c) end
    if #queue == 0 and os.clock() - lastCycle > 60 then lastCycle = os.clock(); chunks(R, queue) end
    if not sent and #queue > 0 then net.toGuests("g.story.done", table.remove(queue, 1)) end
end

-- a task only the guest can do (it holds the item, stands at the place): the guest says so, the host completes it for the story
GUEST_TASKS = { BPMT_HasItem_PlayerInventory_C = true, BPMT_HasItem_HandSlot_C = true, BPMT_InRangeOfTag_C = true }
-- UI-only steps the guest does on its own screen (the host never sees them): open the route planner, the mechanic view
UI_TASKS = { BPMT_RoutePlannerOpen_C = true, BPMT_MechanicModeChanged_C = true, BPMT_MechanicModeSlotsViewed_C = true }
if os.getenv("PT_MUTATE") ~= "nostorytask" then
    for k in pairs(UI_TASKS) do GUEST_TASKS[k] = true end
end
net.on("g.story.task", function(_, data)
    if not (PROG and M.enabled) or safety.guest() then return end
    try("task", function()
        local obj, mis, idx = data:match("^([^	]+)	([^	]+)	(%d+)$")
        local q = quests()
        if not (q and obj) then return end
        local s = activeOn(q, obj)
        local ms = s and s.ActiveMissionState
        idx = tonumber(idx)
        if not (live(ms) and live(ms.Data) and path(ms.Data) == mis) then return end
        local t = ms.Tasks[idx]
        if live(t) and GUEST_TASKS[t:GetClass():GetFName():ToString()] and not ms.TaskStates[idx].bCompleted then
            ms:ForceCompleteTask(t)
            log("PT|story host completes task %d of %s for the guest", idx, mis)
        end
    end)
end)

local lastSay
local function hostTick()
    local s = questState()
    if s ~= lastQuest or os.clock() - lastSent > 3 then -- again every 3 s for a late guest
        lastQuest, lastSent = s, os.clock()
        net.toGuests("g.story.quest", s)
    end
end

local function dialogueTick()
    local d = dialogue()
    local seq = d and d.CurrentlyPlayingSequence
    if not live(seq) then lastSay = nil return end
    if seq == lastSay then return end
    lastSay = seq
    net.toGuests("g.story.say", string.format("%s\t%d", path(seq), seq.Priority))
end

local lastSeq = {}
local function cutsceneTick()
    for _, a in ipairs(FindAllOf("LevelSequenceActor") or {}) do
        if live(a) and not a:GetFullName():find("/Engine/Transient", 1, true) then
            local pl = a:GetSequencePlayer()
            local playing = live(pl) and pl:IsPlaying()
            local seq = playing and a:GetSequence()
            local n = a:GetFName():ToString()
            if playing and live(seq) and not lastSeq[n] then
                net.toGuests("g.story.cut", string.format("%s	%s", n, path(seq)))
                lastSeq[n] = true
            elseif not playing then lastSeq[n] = nil end
        end
    end
end

-- story props the host's story spawns (narrative resources): replicated like world.lua's hazards; the guest drops its own copies
local PROPS = { "BP_Resource_Narrative_Q01_RadioBitsGrabbable_C" }
local function propsTick()
    for _, class in ipairs(PROPS) do
        for _, o in ipairs(FindAllOf(class) or {}) do
            if live(o) and o.RemoteRole == 0 and o:HasAuthority() then
                o:SetReplicates(true)
                o.bAlwaysRelevant = true
                o:ForceNetUpdate()
            end
        end
    end
end
-- the guest's own copies are cleaned by world.lua (only those the host does not have): a level-placed copy the guest keeps is what the host's channel binds to

-- ---------------------------------------------------------------- guest

local function applyQuest(data)
    local q = quests()
    if not q then return end
    local want = {}
    hostMask = {}
    for line in data:gmatch("[^\n]+") do
        local _, obj, mis, mask = line:match("^(o)\t([^\t]+)\t([^\t]+)\t([01]*)$")
        if obj then
            want[obj] = true
            hostMask[obj] = mask
            local st = activeOn(q, obj)
            local o, m = load(obj), load(mis)
            if o and m then
                -- "applying" covers only our own two starts: what the guest's story script does in answer (it starts the next
                -- objective by itself) stays nulled, the host's rows start it
                local ok, err = pcall(function()
                    if not st then
                        applying = true
                        q:StartObjective(o, true, false)
                        applying = false
                        st = activeOn(q, obj)
                        log("PT|story guest start objective %s mission %s", obj, mis)
                        ov.post("New objective", "good", "story")
                    end
                    local cur = st and st.ActiveMissionState
                    if st and not (live(cur) and live(cur.Data) and path(cur.Data) == mis) then
                        applying = true
                        st:StartNextMission(m)
                        applying = false
                        log("PT|story guest mission -> %s", mis)
                        ov.post("Mission updated", "good", "story")
                    end
                    local ms = st and st.ActiveMissionState
                    if ms and live(ms) then -- the tasks the host completed (tasks run in parallel: a mask, not an index)
                        local ts = ms.TaskStates
                        for i = 1, math.min(#mask, ts:GetArrayNum()) do
                            if mask:sub(i, i) == "1" and not ts[i].bCompleted then pcall(ms.ForceCompleteTask, ms, ms.Tasks[i]) end
                        end
                    end
                end)
                applying = false
                if not ok then log("PT|error story apply %s %s", obj, tostring(err)) end
            end
        end
    end
    -- objectives the host no longer has active
    local drop = {}
    local a = q.ActiveObjectives
    for i = 1, a:GetArrayNum() do
        local s = a[i]
        if live(s.Objective) and not want[path(s.Objective)] then drop[#drop + 1] = s.Objective end
    end
    for _, o in ipairs(drop) do
        pcall(q.StopObjective, q, o, hostDone.o[(path(o):gsub("%.[^./]+$", ""))] == true)
        log("PT|story guest stop objective %s", path(o))
    end
end

local lastReported = {} -- "objective|mission|index" the guest already told the host about

-- tasks the guest completed on its own (it holds the item, stands at the place) that the host's mask does not have yet
local function reportTasks()
    local q = quests()
    if not q then return end
    local a = q.ActiveObjectives
    for i = 1, a:GetArrayNum() do
        local s = a[i]
        local ms = s.ActiveMissionState
        if live(s.Objective) and live(ms) and live(ms.Data) then
            local op, mp = path(s.Objective), path(ms.Data)
            local mask = hostMask[op] or ""
            for j = 1, ms.TaskStates:GetArrayNum() do
                local t = ms.Tasks[j]
                local cn = live(t) and t:GetClass():GetFName():ToString()
                -- a UI-only task on the guest is not always ticked to bCompleted (the game polls only the active task): ask its own check
                local done = ms.TaskStates[j].bCompleted
                if not done and cn and UI_TASKS[cn] and GUEST_TASKS[cn] then done = select(2, pcall(function() return t:K2_CheckCompletion() == true end)) == true end
                if done and mask:sub(j, j) == "0" and cn and GUEST_TASKS[cn] then
                    -- those two read the shared trunk: not the guest's doing. == true: a class without them returns a truthy TrivialObject
                    local ok, car = pcall(function() return t.CheckCar == true or t.CheckZETI == true end)
                    local key = op .. "|" .. mp .. "|" .. j
                    if not (ok and car) and not lastReported[key] then
                        lastReported[key] = true
                        net.toHost("g.story.task", string.format("%s\t%s\t%d", op, mp, j))
                        log("PT|story guest reports task %d of %s", j, mp)
                    end
                end
            end
        end
    end
end

-- the journal's history: add what the host finished. Loading an asset can stall the game thread, so the loads run two at a time from a
-- queue (a burst of them in the zone fixture got the guest dropped); the arrays themselves are plain data.
local pendingDone, queued = {}, {}
net.on("g.story.done", function(_, data)
    if not (PROG and M.enabled) or not safety.guest() then return end
    for line in data:gmatch("[^\n]+") do
        local k, p = line:sub(1, 1), line:sub(2)
        hostDone[k][p] = true
        if not queued[line] then queued[line] = true; pendingDone[#pendingDone + 1] = line end
    end
end)
local function doneStep()
    if #pendingDone == 0 then return end
    local q = quests()
    if not q then return end
    local have = { o = {}, m = {} }
    for i = 1, q.CompletedObjectives:GetArrayNum() do local o = q.CompletedObjectives[i]; if live(o) then have.o[(path(o):gsub("%.[^./]+$", ""))] = true end end
    for i = 1, q.CompletedMissions:GetArrayNum() do local o = q.CompletedMissions[i]; if live(o) then have.m[(path(o):gsub("%.[^./]+$", ""))] = true end end
    local n = 0
    while #pendingDone > 0 and n < 2 do
        local line = table.remove(pendingDone, 1)
        queued[line] = nil
        local k, p = line:sub(1, 1), line:sub(2)
        if not have[k][p] then
            local t1 = os.clock()
            local o = load(p .. "." .. p:match("[^/]+$"))
            if os.clock() - t1 > 0.05 then log("PT|slow story load %.0f ms %s", (os.clock() - t1) * 1000, p) end
            if o then
                local arr = k == "o" and q.CompletedObjectives or q.CompletedMissions
                arr[arr:GetArrayNum() + 1] = o
                n = n + 1
                log("PT|story guest journal history +1 (%d waiting)", #pendingDone)
            end
        end
    end
end
RegisterLoadMapPostHook(function() pendingDone, queued = {}, {} end)
LoopInGameThreadWithDelay(250, function()
    if PROG and M.enabled and safety.active() and safety.guest() then try("done", doneStep) end
end)

net.on("g.story.quest", function(_, data)
    if not M.enabled or not safety.guest() then return end
    try("quest", applyQuest, data)
end)

local lastSayAt = {} -- a line the host replays within 90 s is played once (playtest #4: the same line came every 6 s)
net.on("g.story.say", function(_, data)
    if not M.enabled or not safety.guest() then return end
    try("say", function()
        local p, pr = data:match("^([^\t]+)\t(%d+)$")
        local d, seq = dialogue(), p and load(p)
        if not (d and seq) then return end
        if d.CurrentlyPlayingSequence == seq or (lastSayAt[p] and os.clock() - lastSayAt[p] < 90) then return end
        lastSayAt[p] = os.clock()
        applying = true
        d:PlaySequence(seq, tonumber(pr), nil)
        applying = false
        log("PT|story guest dialogue %s", p)
    end)
end)

-- G3 cutscenes: the guest plays the host's level sequence when it has the same one placed; its own game triggers none
net.on("g.story.cut", function(_, data)
    if not M.enabled or not safety.guest() then return end
    try("cut", function()
        local n, p = data:match("^([^	]+)	([^	]+)$")
        for _, a in ipairs(FindAllOf("LevelSequenceActor") or {}) do
            if live(a) and a:GetFName():ToString() == n then
                local pl = a:GetSequencePlayer()
                if live(pl) and not pl:IsPlaying() then pl:Play() log("PT|story guest cutscene %s %s", n, p) end
                return
            end
        end
        log("PT|story guest has no cutscene %s", n)
    end)
end)

LoopInGameThreadWithDelay(500, function()
    if not M.enabled or not safety.active() then return end
    if safety.guest() then
        if PROG then try("report", reportTasks) end
        return
    end
    if PROG then try("done", doneTick) end -- the finished list first: the guest stops an objective as finished only if it knows the host finished it
    try("host", hostTick)
    try("cut", cutsceneTick)
    try("props", propsTick)
end)
LoopInGameThreadWithDelay(200, function()
    if not M.enabled or not safety.active() or safety.guest() then return end
    try("say", dialogueTick)
end)

-- rescue.lua: send all of it again (host), report the guest's done tasks again (guest)
function M.resend() lastQuest, sentDone, queue = "", {}, {} end
function M.rereport() lastReported = {} end

return M
