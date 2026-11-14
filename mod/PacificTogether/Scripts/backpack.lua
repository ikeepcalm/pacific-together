-- P5/D7/D6 the guest's backpack. The guest's own game keeps its backpack in its own process; the HOST stores a copy per guest
-- (one line of text: items, counts, grid spot, rotation, durability, hand, quick slots) next to its save slot,
-- Saved/SaveGames/odsave<slot>.pt-<guest>.txt, and hands it back on the guest's next join. The game's .sav files are never touched.
-- The guest id is the guest's player name (what the host's PlayerState has; a Steam id replaces it when Steam lands).
-- Death (D6): health.lua's die() calls M.died(): the guest's items go to the host, which drops them at the death spot as a
-- BP_Lootable_Backpack the host owns (loot.lua shows it to both) and the guest's backpack is emptied.
-- Messages (net.lua): g.bp.hi guest asks, g.bp.rec host answers ("none" or the line), g.bp.save guest's current line,
-- g.bp.death guest's line at death. Inert in single player (Q7). Format and API facts: docs/spikes/X12.md.
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local log = common.log
local ov = require("overlay")

local M = {}
-- test mutation: the feature off
if os.getenv("PT_MUTATE") == "nobackpack" then function M.died() end; return M end

local BAG = "/Game/Gameplay/Resources/ItemContainers/Crate/BP_Lootable_Crate_Large.BP_Lootable_Crate_Large_C"
local DUR_FIELD = "Durability"

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function lib() return StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary") end
local function bfl() return FindObject("BFL_ItemPropertyUtilityFns_C", "Default__BFL_ItemPropertyUtilityFns_C") end
local function world() return UEHelpers.GetWorld() end
local function path(o) return o:GetFullName():match("^%S+ (.+)$") end
local function im() local m = FindFirstOf("BP_InventoryManager_C"); return valid(m) and m or nil end

-- record: { bag = {slot...}, hand = {slot...}, hot = { [i] = "bag@x,y" } }, slot = { a = archetype path, n, x, y, r, d = {...} }
local durProp = {}
local function durOf(a)
    local p = path(a)
    if durProp[p] == nil then
        durProp[p] = false
        a.Properties:ForEach(function(_, e) local s = e:get(); if s:GetFName():ToString() == "IP_Durability" then durProp[p] = s end end)
    end
    return durProp[p]
end
local function getDur(it)
    local o = { {}, {}, {}, {}, {} }
    bfl():GetDurability(it, world(), o[1], o[2], o[3], o[4], o[5])
    return o[3].Durability
end
local function setDur(a, it, d) lib():SetItemProperty(durOf(a), it, FName(DUR_FIELD), d) end

local function readC(c)
    local r = {}
    for i = 0, c:GetNumSlots() - 1 do
        local s = c:GetSlot(i)
        local n = s:GetNumItems()
        if n > 0 then
            local a = s:GetCurrentArchetype()
            local e = { a = path(a), n = n, x = 0, y = 0, r = false, d = {} }
            pcall(function()
                local x, y = s.Location.X, s.Location.Y
                if type(x) == "number" and type(y) == "number" then e.x, e.y, e.r = x, y, s.bRotated == true end -- the hand slot has no grid spot
            end)
            for k = 0, n - 1 do e.d[#e.d + 1] = durOf(a) and getDur(s:GetItem(k)) or -1 end
            r[#r + 1] = e
        end
    end
    table.sort(r, function(p, q) if p.y ~= q.y then return p.y < q.y end; if p.x ~= q.x then return p.x < q.x end; return p.a < q.a end)
    return r
end
local function hotbar()
    local cm = FindFirstOf("BP_MainCharacterManager_C")
    return valid(cm) and cm.HotbarShortcuts:GetShortcuts() or {}
end
local function read()
    local m = im()
    local rec = { bag = readC(m.Inventory_Player), hand = readC(m.Inventory_PlayerHand), hot = {} }
    for i, sc in ipairs(hotbar()) do
        -- a shortcut can still point at an item that left the backpack
        pcall(function()
            local s = sc:get():GetShortcutItem():GetOuterSlot()
            local where = s:GetContainer():GetFullName() == m.Inventory_PlayerHand:GetFullName() and "hand" or "bag"
            local ok, x, y = pcall(function() return s.Location.X, s.Location.Y end)
            rec.hot[i] = string.format("%s@%d,%d", where, ok and x or 0, ok and y or 0)
        end)
    end
    return rec
end

-- one line: sec:a,n,x,y,r,d1/d2;...|sec:...|hot:i=where;...
local function encode(rec)
    local parts = {}
    for _, sec in ipairs({ "bag", "hand" }) do
        local es = {}
        for _, e in ipairs(rec[sec]) do
            local ds = {}
            for _, d in ipairs(e.d) do ds[#ds + 1] = tostring(math.floor(d)) end
            es[#es + 1] = string.format("%s,%d,%d,%d,%d,%s", e.a, e.n, e.x, e.y, e.r and 1 or 0, table.concat(ds, "/"))
        end
        parts[#parts + 1] = sec .. ":" .. table.concat(es, ";")
    end
    local hs = {}
    for i = 1, 8 do if rec.hot[i] then hs[#hs + 1] = i .. "=" .. rec.hot[i] end end
    parts[#parts + 1] = "hot:" .. table.concat(hs, ";")
    return table.concat(parts, "|")
end
-- the line crosses a trust boundary (guest -> host, file -> game): parsed field by field, never load()ed
local function decode(s)
    local rec = { bag = {}, hand = {}, hot = {} }
    for sec, body in s:gmatch("(%a+):([^|]*)") do
        for item in body:gmatch("[^;]+") do
            if sec == "hot" then
                local i, where = item:match("^(%d)=(%a+@%-?%d+,%-?%d+)$")
                if i then rec.hot[tonumber(i)] = where end
            elseif rec[sec] then
                local a, n, x, y, r, ds = item:match("^([%w_/%.]+),(%d+),(%-?%d+),(%-?%d+),([01]),([%-%d/]*)$")
                n = tonumber(n)
                if a and n and n >= 1 and n <= 100 and a:sub(1, 1) == "/" then
                    local e = { a = a, n = n, x = tonumber(x), y = tonumber(y), r = r == "1", d = {} }
                    for d in ds:gmatch("%-?%d+") do e.d[#e.d + 1] = tonumber(d) end
                    rec[sec][#rec[sec] + 1] = e
                end
            end
        end
    end
    return rec
end
local function count(rec) local n = 0; for _, sec in ipairs({ "bag", "hand" }) do for _, e in ipairs(rec[sec]) do n = n + e.n end end; return n end

-- rebuild a list of slots into a container; returns "x,y" -> the slot made
local function writeC(c, list, emplace)
    c:RemoveAllItems()
    local placed = {}
    for _, e in ipairs(list) do
        local a = StaticFindObject(e.a)
        if not a:IsValid() then pcall(LoadAsset, e.a); a = StaticFindObject(e.a) end
        if not a:IsValid() then log("PT|error bp unknown archetype %s", e.a) else
            local slot
            for k = 1, e.n do
                local it = lib():CreateItemInstance(world(), a, 0)
                local d = e.d[k] or -1
                if d >= 0 and durOf(a) then setDur(a, it, d) end
                if emplace and not slot then
                    local ok, s = pcall(function() return c.Layout:EmplaceSlot(c, it, { X = e.x, Y = e.y }, e.r, false) end)
                    if ok and s:IsValid() then slot = s else c:AddItem(it, true); slot = it:GetOuterSlot() end
                elseif emplace and slot then
                    if not slot:AddItem(it) then c:AddItem(it, true) end
                else
                    local added = c:AddItem(it, true)
                    if not added then log("PT|bp AddItem refused %s (container has %d)", e.a:match("[^/]+$"), c:GetNumItems()) end
                end
            end
            placed[string.format("@%d,%d", e.x, e.y)] = slot
        end
    end
    return placed
end
local function write(rec)
    local m = im()
    local placed = { bag = writeC(m.Inventory_Player, rec.bag, true), hand = writeC(m.Inventory_PlayerHand, rec.hand, true) }
    local shortcuts = hotbar()
    for i, where in pairs(rec.hot) do
        local sec, at = where:match("^(%a+)(@.+)$")
        local s = placed[sec] and placed[sec][at]
        if s and shortcuts[i] then shortcuts[i]:get():SetShortcutItem(s:GetItem(0)) end
    end
end
local function clear()
    local m = im()
    m.Inventory_Player:RemoveAllItems(); m.Inventory_PlayerHand:RemoveAllItems()
    for _, sc in ipairs(hotbar()) do pcall(function() sc:get():SetShortcutItem(CreateInvalidObject()) end) end
end

-- host ---------------------------------------------------------------------------------------------------------------

local stored = {} -- guest id -> record
local slotSeen

local function slot()
    if slotSeen then return slotSeen end
    local mgr = FindFirstOf("BP_SaveGameManager_C")
    local ok, s = pcall(function() return valid(mgr) and mgr:GetCurrentSlot() end)
    return ok and tonumber(s) or 0
end
local function file(s, id) return string.format("../../Saved/SaveGames/odsave%d.pt-%s.txt", s, id) end
-- S2: a guest that said hello with a SteamID is keyed by it, without Steam by its player_id.txt; the key before both was
-- the login name (second result)
local function idOf(pc)
    local info = package.loaded["session"] and package.loaded["session"].guestInfo(pc)
    local name = info and info.login or (valid(pc.PlayerState) and pc.PlayerState:GetPlayerName():ToString() or "Guest")
    local old = name:gsub("[^%w_%-]", "_")
    return info and (info.sid or info.pid and "p" .. info.pid) or old, old
end
local function writeFile(s, id)
    local f = io.open(file(s, id), "w")
    if not f then log("PT|bp cannot write %s (no save folder yet)", file(s, id)); return end
    f:write(encode(stored[id]), "\n"); f:close()
end
local function readFile(s, id)
    local f = io.open(file(s, id), "r")
    if not f then return nil end
    local line = f:read("l"); f:close()
    return line
end

net.on("g.bp.hi", function(pc)
    local id, old = idOf(pc)
    local line = readFile(slot(), id) or (stored[id] and encode(stored[id]))
    if not line and old ~= id then
        line = readFile(slot(), old)
        if line then
            log("PT|bp host adopts the old backpack of %s for %s", old, id)
            -- a second SteamID with the same login name must not adopt it again
            stored[id] = decode(line)
            writeFile(slot(), id)
            if readFile(slot(), id) then os.rename(file(slot(), old), file(slot(), old) .. ".adopted") end
        end
    end
    if line then stored[id] = decode(line) end
    log("PT|bp host answers %s slot=%d %s", id, slot(), line and (count(stored[id]) .. " items") or "new guest")
    net.toGuest(pc, "g.bp.rec", line or "none")
end)

net.on("g.bp.save", function(pc, line)
    local id = idOf(pc)
    stored[id] = decode(line)
    writeFile(slot(), id)
end)

-- the guest's items as a bag at the death spot: a normal lootable of the host, loot.lua's scan finds it and tells the guest
net.on("g.bp.death", function(pc, line)
    local rec, id = decode(line), idOf(pc)
    if count(rec) == 0 then return end
    local pawn = valid(pc.Pawn) and pc.Pawn or FindFirstOf("BP_MainCharacterManager_C").CharacterActor
    local l = pawn:K2_GetActorLocation()
    local cls = StaticFindObject(BAG)
    if not cls:IsValid() then pcall(LoadAsset, BAG); cls = StaticFindObject(BAG) end
    local gs = UEHelpers.GetGameplayStatics()
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = l.X, Y = l.Y, Z = l.Z + 30 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local a = gs:BeginDeferredActorSpawnFromClass(world(), cls, xf, 1, nil)
    pcall(function() a.ForceSpawnEvenifFailedChanceToLive = true end)
    a = gs:FinishSpawningActor(a, xf)
    if not valid(a) or not valid(a.InventoryContainer) then log("PT|error bp death bag not spawned for %s", id); return end
    local all = {}
    for _, e in ipairs(rec.bag) do all[#all + 1] = e end
    for _, e in ipairs(rec.hand) do all[#all + 1] = e end
    writeC(a.InventoryContainer, all, false) -- shortcut: stack grid spots are the game's, durability is kept on the host's bag only
    a.RolledOnOpenItems = true -- no random loot on top of the guest's
    ov.post(ov.nameOf(pc) .. "'s death crate dropped", "warn")
    log("PT|bp death bag for %s at %.0f,%.0f,%.0f with %d items", id, l.X, l.Y, l.Z, count(rec))
end)

-- with the host's own save, the same slot (X12)
local saving
pcall(RegisterHook, "/Script/PenDriverPro.BaseSaveGameManager:SaveGame", function(self, s) saving = s:get() end, function(self, ok)
    if safety.guest() or not ok:get() or not saving then return end
    slotSeen = saving
    for id in pairs(stored) do pcall(writeFile, saving, id) end
end)
pcall(RegisterHook, "/Script/PenDriverPro.BaseSaveGameManager:LoadGame", function(self, s) slotSeen = s:get() end)
pcall(RegisterHook, "/Script/PenDriverPro.BaseSaveGameManager:UserLoadGame", function(self, s) slotSeen = s:get() end)
pcall(RegisterHook, "/Script/PenDriverPro.BaseSaveGameManager:UserNewGame", function(self, s) slotSeen = s:get() end)

-- guest --------------------------------------------------------------------------------------------------------------

local synced, last, lastAsk = false, nil, 0
local unsaved -- the line of a flush the host may not have got (a run-failure penalty right before the host's travel)

net.on("g.bp.rec", function(_, line)
    if synced then return end
    if unsaved and encode(read()) == unsaved then
        -- our backpack is newer than the host's record: the penalty's save was lost in the travel
        net.toHost("g.bp.save", unsaved)
        log("PT|bp guest keeps its backpack over the host's older record")
        synced, last, unsaved = true, nil, nil
        return
    end
    if line ~= "none" then
        local ok, err = pcall(write, decode(line))
        if not ok then log("PT|error bp restore %s", tostring(err)); return end
        log("PT|bp guest restored %d bytes", #line)
        ov.post("Backpack restored from the host", "good")
    else
        log("PT|bp guest is new to this host")
    end
    synced, last = true, nil
end)

-- called by health.lua when the guest dies
function M.died(pre)
    if not (safety.guest() and synced) then return end
    local line = pre or encode(read())
    net.toHost("g.bp.death", line)
    clear()
    last = nil
    log("PT|bp guest dropped its backpack (%d bytes)", #line)
    ov.post("Backpack dropped as a death crate", "warn")
end

-- health.lua: the backpack line of the last tick, from before the game's own death penalty ran on the guest
function M.pre() return last end

-- progression.lua: the guest's backpack changed outside its own tick (run-failure penalty); tell the host now
function M.flush()
    if not (safety.guest() and synced) then return end
    last = encode(read())
    unsaved = last
    net.toHost("g.bp.save", last)
end

local function tick()
    if not safety.guest() then synced, last = false, nil; return end
    local pc = UEHelpers.GetPlayerController()
    local pawn = valid(pc) and pc.Pawn
    if not (pawn and valid(pawn) and pawn:GetClass():GetFName():ToString() == "PDP_MainCharacter_C" and im()) then return end
    if not synced then
        if os.time() - lastAsk >= 3 then lastAsk = os.time(); net.toHost("g.bp.hi", "") end
        return
    end
    local line = encode(read())
    if line ~= last then last, unsaved = line, nil; net.toHost("g.bp.save", line) end
end

-- a map change (the host's, or ours) frees what we hold; ask again once the new character is there
RegisterLoadMapPostHook(function() synced, last = false, nil end)

LoopInGameThreadWithDelay(1000, function()
    local ok, err = pcall(tick)
    if not ok then log("PT|error bp %s", tostring(err)) end
end)

return M
