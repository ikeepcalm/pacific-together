-- M5 progression: the guest never loads a save, so its managers hold fresh-game state. The host sends its progression
-- (global whiteboard: garage upgrades, stations, story flags; research/recipe unlock graph; ARC route legs; logbook) and the
-- guest writes it into its own managers, in memory only (S7: the guest's saves stay blocked). Sent on join and whenever it
-- changes. D6: the host's run-failure item penalty (ProgressionManager:RemoveItemsPenalty) is applied to the guest's backpack too.
-- Messages (net.lua): g.prog.hi guest asks; g.prog.wb / .un / .rt / .lb host's sections ("a;b;c", chunked under the 32 KB cap);
-- g.prog.pen host's resolved penalty mode. Inert in single player (Q7). Notes: docs/spikes/M5-progression.md.
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local log = common.log
local ov = require("overlay")

local M = {}
if os.getenv("PT_MUTATE") == "noprog" then return M end

local CHUNK = 28000
local SKIP = { ["WB.WorldState.TimeOfDay"] = true, ["WB.Statistics.Fuel.Spent"] = true } -- change every frame while driving; world.lua owns time and weather; WB.Quests/Missions belong to story.lua

-- WB.Quests/WB.Missions tags are the guest's own mirror of the active story (story.lua); only the finished flags travel (pt2-story)
local STORYDONE = os.getenv("PT_MUTATE") ~= "nostoryprog"
local function skipTag(tag)
    if SKIP[tag] or tag:find("^WB%.Statistics%.") then return true end -- the guest counts its own statistics (playtest #4: mileage and radiation damage rewritten every 2 s)
    if tag:find("^WB%.Quests%.") or tag:find("^WB%.Missions%.") then return not (STORYDONE and tag:find("%.Completed$")) end
    return false
end

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function pm() local m = FindFirstOf("BP_ProgressionManager_C"); return valid(m) and m or nil end
local function gstate()
    local im = FindFirstOf("BP_InventoryManager_C")
    local g = valid(im) and im.UnlockState
    return valid(g) and g or nil
end
local function mcm() local m = FindFirstOf("BP_MainCharacterManager_C"); return valid(m) and m or nil end
local function path(o) return o:GetFullName():match("^%S+ (.+)$") end
local function short(o) return o:GetFName():ToString() end
local function split(s) local r = {}; for p in s:gmatch("[^;]+") do r[#r + 1] = p end; return r end

-- host: the four sections as arrays of strings ------------------------------------------------------------------------

local function snapshot()
    local m = pm()
    local s = { wb = {}, un = {}, rt = {}, lb = {}, pu = {} }
    if not m then return s end
    -- player upgrades (backpack size, hotbar, insulated gloves, radiation curve) are archetypes the save gives the host's
    -- character manager; the guest's list stays empty (owner, 2026-10-24)
    local c = mcm()
    if c then
        c.PlayerUpgradesUnlocked:ForEach(function(_, o) local a = o:get(); if valid(a) then s.pu[#s.pu + 1] = path(a) end end)
    end
    m.GlobalWhiteboard.Entries:ForEach(function(k, v)
        local tag = k:get().TagName:ToString()
        if not skipTag(tag) then s.wb[#s.wb + 1] = string.format("%s=%.4f", tag, v:get()) end
    end)
    local g = gstate()
    if g then
        g.UnlockedNodes:ForEach(function(n) s.un[#s.un + 1] = "U" .. path(n:get()) end)
        g.PurchasedNodes:ForEach(function(n) s.un[#s.un + 1] = "P" .. path(n:get()) end)
    end
    local rs = m.WorldState
    if valid(rs) then
        local cur = valid(rs.CurrentLeg) and short(rs.CurrentLeg.ShapeLeg) or "-"
        s.rt[1] = string.format("@%d,%s", rs.CurrentPhase, cur)
        rs.LegStates:ForEach(function(k, v)
            local l = v:get()
            if l.RevealState ~= 0 or l.Visited or l.Discovered then
                s.rt[#s.rt + 1] = string.format("%s:%d%d%d%d", short(k:get()), l.RevealState, l.Visited and 1 or 0, l.Discovered and 1 or 0, l.Active and 1 or 0)
            end
        end)
    end
    local lb = m.LogBook
    if valid(lb) then
        for i = 1, #lb.Entries do
            local o = lb.Entries[i].DataObject
            if valid(o) then s.lb[#s.lb + 1] = path(o) end
        end
    end
    for _, t in pairs(s) do table.sort(t) end
    return s
end

local function send(sec, list, to)
    local i, n = 1, #list
    repeat
        local buf, len = {}, 0
        while i <= n and len + #list[i] + 1 <= CHUNK do buf[#buf + 1] = list[i]; len = len + #list[i] + 1; i = i + 1 end
        if #buf == 0 and i <= n then i = i + 1 end -- one entry larger than a chunk cannot happen with paths; skip rather than loop
        local data = table.concat(buf, ";")
        if sec == "lb" then data = "@" .. n .. ";" .. data end
        if to then net.toGuest(to, "g.prog." .. sec, data) else net.toGuests("g.prog." .. sec, data) end
    until i > n
end

local lastSent = {}
local function broadcast(force, to)
    local s = snapshot()
    for sec, list in pairs(s) do
        local h = table.concat(list, ";")
        if force or lastSent[sec] ~= h then
            lastSent[sec] = h
            send(sec, list, to)
        end
    end
end

net.on("g.prog.hi", function(pc)
    log("PT|prog host answers %s", pc:GetFullName():sub(1, 40))
    broadcast(true, pc)
end)

-- D6: the host's penalty hits the guest's backpack too. The mode is resolved here (-1 = the setting), the guest rolls its own items.
local penaltyHooked = false
local function hookPenalty()
    penaltyHooked = pcall(RegisterHook, "/Game/Systems/Managers/BP_ProgressionManager.BP_ProgressionManager_C:RemoveItemsPenalty", function(self, mode)
        if safety.guest() or #net.guests() == 0 then return end -- host only: on the guest the local game's own penalty must not be broadcast
        local x = mode:get()
        if x == -1 then
            local st = FindFirstOf("DrivingGameUserSettings")
            x = valid(st) and st.HardcoreMode or 0
        end
        log("PT|prog host penalty mode=%d", x)
        net.toGuests("g.prog.pen", tostring(x))
    end)
    if penaltyHooked then log("PT|prog penalty hook registered") end
end

-- host loop: push what changed
LoopInGameThreadWithDelay(2000, function()
    if not penaltyHooked and pm() then hookPenalty() end -- the Blueprint class loads after the main menu
    if safety.guest() or #net.guests() == 0 then lastSent = {}; return end
    local ok, err = pcall(broadcast, false)
    if not ok then log("PT|error prog host %s", tostring(err)) end
end)

-- guest: write into our own managers -----------------------------------------------------------------------------------

local got = false

-- the host's tags as last received (a section comes in several chunks): garage.lua's InstallSpecificUpgrade on the guest counts
-- its installs on top of the copied WB.GarageUpgrades.* values (Inventory.InstallCount 8 vs the host's 4), so they are written again
local hostWb = {}
RegisterLoadMapPreHook(function() hostWb = {} end)
local function applyWb(data)
    local m = pm()
    if not m then return end
    for _, e in ipairs(split(data or "")) do
        local tag, v = e:match("^([%w_%.]+)=(%-?[%d%.]+)$")
        if tag and tonumber(v) then hostWb[tag] = tonumber(v) end
    end
    local w, have = m.GlobalWhiteboard, {}
    w.Entries:ForEach(function(k, v) have[k:get().TagName:ToString()] = v:get() end)
    local n = 0
    for tag, v in pairs(hostWb) do
        if not skipTag(tag) and (have[tag] == nil or math.abs(have[tag] - v) > 0.001) then
            w:SetTagFloat({ TagName = FName(tag) }, v)
            n = n + 1
            if n <= 3 then log("PT|prog guest tag %s %s -> %.2f", tag, tostring(have[tag]), v) end
        end
    end
    if n > 0 then log("PT|prog guest whiteboard %d tags set", n) end
end

local unFirst -- os.clock() of the first graph chunk since the map load: the join's full graph (several chunks) stays quiet
RegisterLoadMapPostHook(function() unFirst = nil end)
local function applyUn(data)
    local g = gstate()
    if not g then return end
    unFirst = unFirst or os.clock()
    local loud = os.clock() - unFirst > 5
    local have = { U = {}, P = {} }
    g.UnlockedNodes:ForEach(function(n) have.U[path(n:get())] = true end)
    g.PurchasedNodes:ForEach(function(n) have.P[path(n:get())] = true end)
    local nu, miss = 0, 0
    for _, e in ipairs(split(data)) do
        local kind, p = e:sub(1, 1), e:sub(2)
        if have[kind] and not have[kind][p] then
            local node = StaticFindObject(p)
            if not valid(node) then pcall(LoadAsset, p); node = StaticFindObject(p) end -- a node asset not loaded yet was skipped for good
            if valid(node) then
                -- after the first sync the game's own events run, like the host's unlock: the guest's benches and crafting
                -- lists refresh (playtest 2026-11-01: new blueprints only showed after a rejoin)
                if kind == "U" then g:UnlockNode(node, not loud) else g:MarkAsPurchased(node) end
                nu = nu + 1
            else
                miss = miss + 1
            end
        end
    end
    if nu > 0 or miss > 0 then log("PT|prog guest unlock graph %d nodes set, %d not found", nu, miss) end
end

local function applyRt(data)
    local m = pm()
    local rs = m and m.WorldState
    if not valid(rs) then return end
    local byName = {}
    rs.LegStates:ForEach(function(k, v) byName[short(k:get())] = v:get() end)
    for _, e in ipairs(split(data)) do
        local ph, cur = e:match("^@(%d+),(.+)$")
        if ph then
            rs.CurrentPhase = tonumber(ph)
            if cur ~= "-" and byName[cur] and rs.CurrentLeg ~= byName[cur] then rs.CurrentLeg = byName[cur] end
        else
            local name, a, b, c, d = e:match("^(.-):(%d)([01])([01])([01])$")
            local l = byName[name or ""]
            if l then
                l.RevealState, l.Visited, l.Discovered, l.Active = tonumber(a), b == "1", c == "1", d == "1"
            end
        end
    end
end

local lbSeen, lbCount, lbExpected, lbReady = {}, 0, nil, false
RegisterLoadMapPostHook(function() lbSeen, lbCount, lbExpected, lbReady = {}, 0, nil, false end)
local function applyLb(data)
    local m = pm()
    local lb = m and m.LogBook
    if not valid(lb) then return end
    local have = {}
    for i = 1, #lb.Entries do local o = lb.Entries[i].DataObject; if valid(o) then have[path(o)] = true end end
    local rows = split(data)
    local expected = tonumber((rows[1] or ""):match("^@(%d+)$"))
    if expected then lbExpected = expected end
    local muted = {}
    if lbExpected and not lbReady and os.getenv("PT_MUTATE") ~= "noprogressquiet" and PTNative_Mute then
        -- Native AddEntry broadcasts this widget delegate; restored history must not look like hundreds of new discoveries.
        for _, w in ipairs(FindAllOf("UMG_LogBook_NotifMain_C") or {}) do
            if valid(w) and PTNative_Mute(w:GetAddress(), "OnLogbookEntryAdded") then muted[#muted + 1] = w end
        end
    end
    local ok, err = pcall(function()
        for _, p in ipairs(rows) do
            if p:sub(1, 1) ~= "@" then
                if not lbSeen[p] then lbSeen[p], lbCount = true, lbCount + 1 end
                if not have[p] then
                    local o = StaticFindObject(p)
                    if valid(o) then
                        local added = pcall(function() lb:AddEntry(o) end)
                        if added then have[p] = true end
                    end
                end
            end
        end
    end)
    for _, w in ipairs(muted) do PTNative_Unmute(w:GetAddress()) end
    if not ok then error(err) end
    if lbExpected and lbCount >= lbExpected then lbReady = true end
end

local function applyPu(data)
    local c = mcm()
    if not c then return end
    local have = {}
    c.PlayerUpgradesUnlocked:ForEach(function(_, o) local a = o:get(); if valid(a) then have[path(a)] = true end end)
    for _, p in ipairs(split(data)) do
        if not have[p] then
            local o = StaticFindObject(p)
            if not valid(o) then pcall(LoadAsset, p); o = StaticFindObject(p) end
            if valid(o) then
                c["Add Player Upgrade"](c, o) -- the game's own: adds it and rebuilds pack layout, hotbar and damage curves
                log("PT|prog guest player upgrade %s", p:match("[^.]+$"))
            end
        end
    end
end

function M.reapplyWb() if safety.guest() and next(hostWb) then pcall(applyWb, nil) end end

-- The guest's work is queued and done a few ms a frame: a long save's logbook and whiteboard came as three 28 KB messages each and
-- one message held a rendered guest's frame 300-500 ms (AddEntry and SetTagFloat notify the game's listeners each time, 2026-10-24)
local work, head = {}, 1
local pending = {} -- section and chunk queued and not done yet: the host's resend of the same chunk does not queue it twice
LoopInGameThreadWithDelay(16, function()
    if head > #work then return end
    local t = os.clock()
    while head <= #work and os.clock() - t < 0.004 do
        local w = work[head]
        work[head], head = nil, head + 1
        pending[w.key] = nil
        local ok, err = pcall(w.fn, w.data)
        if not ok then log("PT|error prog apply %s %s", w.sec, tostring(err)) end
    end
    if head > #work then work, head = {}, 1 end
end)
RegisterLoadMapPostHook(function() work, head, pending = {}, 1, {} end)

for sec, fn in pairs({ wb = applyWb, un = applyUn, rt = applyRt, lb = applyLb, pu = applyPu }) do
    net.on("g.prog." .. sec, function(_, data)
        if not safety.guest() then return end
        if not got then ov.post("Host progress applied", "good") end
        got = true
        local key = sec .. "|" .. data
        if pending[key] then return end
        pending[key] = true
        work[#work + 1] = { sec = sec, fn = fn, data = data, key = key }
    end)
end

-- the penalty, as the game rolls it for the host (RemoveItemsPenalty, PenaltyMode switch): 1 and 3 keep crafted items, 3 rolls as 0
net.on("g.prog.pen", function(_, data)
    if not safety.guest() then return end
    local m, im = pm(), FindFirstOf("BP_InventoryManager_C")
    local bfl = FindObject("BFL_ItemPropertyUtilityFns_C", "Default__BFL_ItemPropertyUtilityFns_C")
    local lib = StaticFindObject("/Script/PenDriverUtils.Default__TuningFloatLibrary")
    if not (m and valid(im) and valid(bfl) and valid(lib)) then return end
    local mode = tonumber(data) or 0
    local keep = mode == 1 or mode == 3
    if mode == 3 then mode = 0 end
    local ret = lib:Conv_TuningFloatToFloat(m.RetentionPlayerInv)
    local world = UEHelpers.GetWorld()
    for _, c in ipairs({ im.Inventory_Player, im.Inventory_PlayerHand }) do
        local before = c:GetNumItems()
        bfl:RemoveRandomItems(c, ret, keep, mode, world, {})
        log("PT|prog guest penalty mode=%d retention=%.2f %d -> %d items", mode, ret, before, c:GetNumItems())
        ov.post("Failed run: some of your items were lost", "warn", "pen")
    end
    local bp = package.loaded["backpack"]
    if bp and bp.flush then bp.flush() end -- the host keeps the record: tell it now, a travel may follow within the second
end)

-- ask until the host answers; again after every map change (the host's travel, ours)
local lastAsk = 0
LoopInGameThreadWithDelay(1000, function()
    if not safety.guest() then got = false; return end
    local pc = UEHelpers.GetPlayerController()
    local pawn = valid(pc) and pc.Pawn
    if not (pawn and valid(pawn) and pm() and gstate()) then return end
    if not got and os.time() - lastAsk >= 3 then lastAsk = os.time(); net.toHost("g.prog.hi", "") end
end)
RegisterLoadMapPostHook(function() got = false end)

return M
