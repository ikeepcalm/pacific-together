-- PT2 garage stations (PLAN G2, D21): the guest uses the stations with its own game's UI, the HOST performs each action on the shared
-- resources, and the result reaches both sides through the syncs that already exist (loot.lua world items and garage storage, progression.lua
-- research graph, garage.lua installed upgrades). Notes: docs/spikes/PT2-stations.md.
--   g.st.shred  spec<LF>spec...  Part Shredder: items the guest put in and shredded; the host puts them in ITS shredder and runs it,
--                                the products come out of the host's dispenser (world items, loot.lua shows them to the guest)
--   g.st.buy    node path        Research: the guest's PurchaseNode on a node; the host pays and unlocks (PurchaseNode + the bench's own
--                                OnNodePurchased, which prints the blueprint or upgrade kit); progression.lua then shows it as purchased on the guest
--   g.st.up     spawner<TAB>cls  Garage upgrade the guest built at a spawner (InstallSpecificUpgrade); the host installs it too, garage.lua shows it back
-- Guest side, what must NOT happen locally: the shredder's products (they would be a second copy), the research cost (the host pays).
--   g.st.q / g.st.cure  Tinker: the car's quirks (host list down, guest's cure up), see below
-- Fabrication (craft, "Craft Recipe Asset") stays local on the guest: its garage materials ride loot.lua's storage sync, the product is the guest's.
-- Inert in single player (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local ids = require("ids")
local garage = require("garage")
local ov = require("overlay")
local log = common.log

local M = {}
if os.getenv("PT_MUTATE") == "nostations" then return M end

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function guest() return common.netMode() == "client" and safety.active() end
local function host() return common.netMode() == "listen" and safety.active() end
local function real(o) return valid(o) and not o:GetFullName():find("/Engine/Transient", 1, true) end
local function first(class)
    for _, o in ipairs(FindAllOf(class) or {}) do if real(o) then return o end end
end
local function fullpath(o) return o:GetFullName():match("^%S+ (.+)$") end

-- Part Shredder -------------------------------------------------------------------------------------------------------------

local SHRED = "/Game/Gameplay/CarGarage/Stations/PartShredder/BP_Garage_PartShredder.BP_Garage_PartShredder_C"
local shredded, shredAt = {}, 0 -- guest: specs of what the local shredder took, sent once the run is over

local function shredHook(self, inst)
    if not guest() then return end
    local i = inst:get()
    if not valid(i) then return end
    shredded[#shredded + 1] = ids.spec(i)
    shredAt = os.clock()
    -- the local products would be a second copy of what the host's shredder makes
    local s = self:get()
    pcall(function() s.SmashedProducts:Empty() end)
end

local kick = false
net.on("g.st.shred", function(pc, data)
    if not host() then return end
    local sh = first("BP_Garage_PartShredder_C")
    local back, n = {}, 0 -- specs the host could not take: they go back to the guest, who already lost them
    local c, lib
    if sh then c, lib = sh.BP_InventoryContainerComponent, StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary") end
    for spec in data:gmatch("[^\n]+") do
        local a = c and ids.archetype(spec:match("^[^:]+"))
        local r = {}
        if a then
            local inst = lib:CreateItemInstance(UEHelpers.GetWorld(), a, 0)
            ids.setProps(inst, spec)
            c:AddItem(inst, r)
        end
        if r.Added then n = n + 1 else back[#back + 1] = spec end
    end
    if not sh then log("PT|st shred: host has no shredder installed") end
    if #back > 0 then
        net.toGuest(pc, "g.st.shredback", table.concat(back, "\n"))
        log("PT|st shred: %d items sent back to the guest", #back)
    end
    kick = n > 0
    log("PT|st shred %d items put in the host's shredder", n)
    if n > 0 then ov.post(ov.other() .. " is using the part shredder", "good", "st.shred") end
end)

-- guest: what the host's shredder refused goes back into the backpack
net.on("g.st.shredback", function(_, data)
    if not guest() then return end
    local im = FindFirstOf("BP_InventoryManager_C")
    local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
    if not (valid(im) and valid(lib)) then return end
    for spec in data:gmatch("[^\n]+") do
        local a = ids.archetype(spec:match("^[^:]+"))
        if a then
            local inst = lib:CreateItemInstance(UEHelpers.GetWorld(), a, 0)
            ids.setProps(inst, spec)
            local ok = im.Inventory_Player:AddItem(inst, true)
            log("PT|st shred item returned to the backpack: %s", tostring(ok))
        end
    end
end)

local function hostShredder()
    if not (kick and host()) then return end
    local s = first("BP_Garage_PartShredder_C")
    if not s or s.IsShredding then return end
    kick = false
    s:OnTransactionEnd(s.BP_InventoryContainerComponent) -- what closing the shredder's container does
end

-- Research ------------------------------------------------------------------------------------------------------------------

local buying = false -- guest: inside the game's own PurchaseNode, whose cost recipe must not run here

net.on("g.st.buy", function(_, data)
    if not host() then return end
    local node = StaticFindObject(data)
    local im = FindFirstOf("BP_InventoryManager_C")
    local g = valid(im) and im.UnlockState
    if not (valid(node) and valid(g) and valid(im)) then log("PT|st buy: no node or graph %s", data); return end
    if g:HasNodeBeenPurchased(node) then return end
    im:SetActiveTier(3, true, true) -- what the research station's screen sets: pay from backpack, garage and car
    local ok = g:PurchaseNode(node)
    log("PT|st buy %s -> %s", data:match("[^:]+$"), tostring(ok))
    if ok then
        local bench = first("BP_Garage_InventingBench_C")
        if bench then pcall(function() bench:OnNodePurchased(node) end) end -- the printed blueprint / upgrade kit
        ov.post(ov.other() .. " researched " .. data:match("[^:]+$"), "good", "st.buy")
    end
end)

local function buyPre(self, node)
    if not guest() then return end
    local im = FindFirstOf("BP_InventoryManager_C")
    if not (valid(im) and valid(im.UnlockState) and self:get():GetAddress() == im.UnlockState:GetAddress()) then return end
    local n = node:get()
    if not valid(n) then return end
    buying = true
    log("PT|st buy intent %s", n:GetFullName():match("[^:]+$"))
    net.toHost("g.st.buy", fullpath(n))
end
local function buyPost() buying = false end

local function execPre(_, _, _, inputs, outputs)
    if not buying then return end
    inputs:get():Empty(); outputs:get():Empty()
end

-- Currencies (anchor energy stable/unstable/corrupted, mechanic XP): the research screen and the tinker read the inventory
-- manager's CurrencyTable (archetype -> hundredths); the guest's stayed empty, so it showed 0 0 0 and could research nothing
-- (live 2026-11-04). The host's table goes down on change and every 10 s; the guest writes it as is (no CurrencyAdjust: that
-- would count as earning). The guest never pays itself (execPre), so the host's value is the only truth.
--   g.st.cur  path=hundredths lines
local curSent, curAt = nil, 0
local function hostCurrencies()
    local im = FindFirstOf("BP_InventoryManager_C")
    if not valid(im) then return end
    local L = {}
    im.CurrencyTable:ForEach(function(k, v)
        local ca = k:get()
        if valid(ca) then L[#L + 1] = fullpath(ca) .. "=" .. tostring(v:get()) end
    end)
    table.sort(L)
    local msg = table.concat(L, "\n")
    if msg ~= curSent or os.clock() - curAt >= 10 then curSent, curAt = msg, os.clock(); net.toGuests("g.st.cur", msg) end
end
net.on("g.st.cur", function(_, data)
    if not guest() then return end
    local im = FindFirstOf("BP_InventoryManager_C")
    if not valid(im) then return end
    local listed, stale = {}, {}
    for path, v in data:gmatch("([^=\n]+)=(%-?%d+)") do
        local ca = StaticFindObject(path)
        if not ca:IsValid() then pcall(LoadAsset, path); ca = StaticFindObject(path) end
        if ca:IsValid() then im.CurrencyTable:Add(ca, tonumber(v)); listed[path] = true end
    end
    im.CurrencyTable:ForEach(function(k) local ca = k:get(); if valid(ca) and not listed[fullpath(ca)] then stale[#stale + 1] = ca end end)
    for _, ca in ipairs(stale) do im.CurrencyTable:Add(ca, 0) end -- one the host no longer has
    -- the energy board beside the research machine is set by the bench on OnCurrencyAdjusted, which a direct write skips
    local bench = first("BP_Garage_InventingBench_C")
    if bench then bench:UpdateAnchorCounts() end
end)

-- Garage upgrades -----------------------------------------------------------------------------------------------------------

net.on("g.st.up", function(_, data)
    if not host() then return end
    local name, cls = data:match("^([^\t]+)\t(.+)$")
    local s
    for _, o in ipairs(FindAllOf("BP_GarageInstallation_Spawner_C") or {}) do
        if real(o) and o:GetFName():ToString() == name then s = o end
    end
    local c = ids.asset(cls)
    if not (s and c) then log("PT|st up: no spawner or class %s", tostring(data)); return end
    for _, h in ipairs(garage.installedOn(s)) do if h == cls then return end end -- already there: a level default the guest built too
    s:InstallSpecificUpgrade(c, false)
    log("PT|st up installed %s on %s", cls:match("[^.]+$"), name)
    ov.post(ov.other() .. " built " .. cls:match("[^.]+$"):gsub("^UP_Garage_", ""), "good", "st.up")
end)

local function upHook(self, cls)
    if not guest() or garage.applying then return end
    local c = cls:get()
    if not valid(c) then return end
    local path = fullpath(c)
    -- the guest's own level-default installs (and what the host already has) are not its work; the host's list must have arrived
    if garage.hostHas(self:get():GetFName():ToString(), path) ~= false then return end
    log("PT|st up intent %s on %s", path:match("[^.]+$"), self:get():GetFName():ToString())
    net.toHost("g.st.up", self:get():GetFName():ToString() .. "\t" .. path)
end


-- Tinker: the car's quirks ----------------------------------------------------------------------------------------------------
-- Quirks are SE_Quirk_MixAndMatch status effects on the car's soul item, rolled at random on each side. The host's list is the truth:
-- g.st.q lines "cond<TAB>beh<TAB>diagnosed<TAB>ingredient" (class paths); the guest builds the same ones with the game's own
-- BFL_StatusEffectQuirkUtils.BuildAndApplyQuirk (re-rolled until the cure ingredient matches, SetQuirkRank picks it at random) and drops the rest.
-- A cure the guest does in its own UI (CureCarQuirk, paid from its backpack and the synced garage) is sent as g.st.cure cond|beh; the host does the
-- rest of the cure (bounty XP, graveyard, remove, stats) WITHOUT paying again. Hints (anchor juice) are not synced.
-- shortcut: identity is condition+behavior (two identical quirks on a car are treated as one); hints and the logbook are not mirrored.
local function qmgr() local m = FindFirstOf("BP_StatusEffectManager_C"); return valid(m) and m or nil end
local function qKey(q) return q.QuirkCondition:GetClass():GetFullName():match("^%S+ (.+)$") .. "|" .. q.QuirkBehavior:GetClass():GetFullName():match("^%S+ (.+)$") end
local function qIng(q)
    local t = {}
    q.CureIngredients:ForEach(function(k, v) t[#t + 1] = fullpath(k:get()) .. "=" .. v:get() end)
    table.sort(t)
    return table.concat(t, ",")
end
local function quirks(sm)
    local r = {}
    for i = 1, #sm.CarQuirks do
        local q = sm.CarQuirks[i]
        if valid(q) and valid(q.QuirkCondition) and valid(q.QuirkBehavior) then r[#r + 1] = q end
    end
    return r
end

local lastQ, lastQAt = nil, 0
local function hostQuirks()
    local sm = qmgr()
    if not sm then return end
    local L = {}
    for _, q in ipairs(quirks(sm)) do
        L[#L + 1] = table.concat({ qKey(q):gsub("|", "\t"), q.Diagnosed and "1" or "0", qIng(q) }, "\t")
    end
    table.sort(L)
    local data = table.concat(L, "\n")
    if data ~= lastQ or os.clock() - lastQAt > 6 then
        lastQ, lastQAt = data, os.clock()
        net.toGuests("g.st.q", data == "" and "-" or data)
    end
end

local wantQ, cured = nil, {} -- guest: the host's last list; key -> os.clock of the guest's own cure
net.on("g.st.q", function(_, data) if guest() then wantQ = data end end)
-- upgrades.lua: a quirk effect on the guest that mirrors one of the host's stays (its behaviours are still never run here)
function M.mirrored(q)
    if not wantQ then return false end
    local ok, k = pcall(qKey, q)
    if not ok then return false end
    local c, b = k:match("^(.-)|(.+)$")
    return wantQ:find(c .. "\t" .. b .. "\t", 1, true) ~= nil
end

local byAddr = {} -- guest: quirk object address -> key (the cured quirk is already gone when CureCarQuirk's hook runs)
local function guestQuirks()
    local sm, cm, bfl = qmgr(), FindFirstOf("BP_CarManager_C"), FindObject("BFL_StatusEffectQuirkUtils_C", "Default__BFL_StatusEffectQuirkUtils_C")
    if not (wantQ and sm and cm and valid(bfl)) then return end
    local want = {}
    for line in wantQ:gmatch("[^\n]+") do
        local c, b, d, ing = line:match("^([^\t]*)\t([^\t]*)\t([01])\t?(.*)$")
        if c then want[c .. "|" .. b] = { c = c, b = b, d = d == "1", ing = ing } end
    end
    local have = {}
    for _, q in ipairs(quirks(sm)) do
        local k = qKey(q)
        byAddr[q:GetAddress()] = k
        local w = want[k]
        if w and not have[k] then
            have[k] = q
            if q.Diagnosed ~= w.d then q.Diagnosed = w.d end
        else
            pcall(function() sm:RemoveStatusEffect(q) end) -- the host has no such quirk (cured there, or a random one of this side)
            log("PT|st quirk dropped %s", k:match("[^|]+$"))
        end
    end
    for k, w in pairs(want) do
        if not have[k] and not (cured[k] and os.clock() - cured[k] < 12) then
            local cc, bc = ids.asset(w.c), ids.asset(w.b)
            if cc and bc then
                for try = 1, 40 do
                    bfl:BuildAndApplyQuirk(cc, bc, cm)
                    local list = quirks(sm)
                    local q = list[#list]
                    if q and qKey(q) == k and (qIng(q) == w.ing or try == 40) then
                        q.Diagnosed = w.d
                        log("PT|st quirk mirrored %s after %d tries, ingredient match=%s", k:match("[^|]+$"), try, tostring(qIng(q) == w.ing))
                        break
                    end
                    if q then pcall(function() sm:RemoveStatusEffect(q) end) end
                end
            end
        end
    end
end

local function cureHook(self, quirk, removed)
    if not guest() or not removed:get() then return end
    local k = byAddr[quirk:get():GetAddress()]
    if not k then return end
    cured[k] = os.clock()
    log("PT|st cure intent %s", k:match("[^|]+$"))
    net.toHost("g.st.cure", k)
end

net.on("g.st.cure", function(_, data)
    if not host() then return end
    local sm, im = qmgr(), FindFirstOf("BP_InventoryManager_C")
    if not (sm and valid(im)) then return end
    for _, q in ipairs(quirks(sm)) do
        if qKey(q) == data then
            local xp = {}
            q:GetMechBounty(xp)
            local ca = StaticFindObject("/Game/Gameplay/StatusEffects/Quirks/CA_MechXP.CA_MechXP")
            if xp.XP and valid(ca) then im:CurrencyAdjust(ca, xp.XP) end
            sm:SendQuirkToGraveyard(q, false)
            sm:RemoveStatusEffect(q)
            local pm = FindFirstOf("BP_ProgressionManager_C")
            if valid(pm) then pcall(function() pm.GlobalWhiteboard:IncrementTagFloat({ TagName = FName("WB.Statistics.Quirks.QuirksCured") }, 1.0, true) end) end
            local qm = FindFirstOf("BP_QuestManager_C")
            if valid(qm) then pcall(function() qm:OnCuredQuirk() end) end
            log("PT|st cure %s: removed on the host", data:match("[^|]+$"))
            ov.post(ov.other() .. " cured a car quirk", "good", "st.cure")
            return
        end
    end
    log("PT|st cure: host has no quirk %s", data)
end)

-- hooks: the Blueprint classes load after the main menu, so they are retried ------------------------------------------------------

local HOOKS = {
    { SHRED .. ":ShredItem", nil, shredHook },
    { "/Script/PenDriverPro.BaseGenericGraphState:PurchaseNode", buyPre, buyPost },
    { "/Script/PenDriverInventory.InventoryRecipe:ExecuteRecipe", execPre },
    { "/Game/Systems/Managers/BP_StatusEffectManager.BP_StatusEffectManager_C:CureCarQuirk", nil, cureHook },
    { "/Game/Gameplay/CarGarage/BP_GarageInstallation_Spawner.BP_GarageInstallation_Spawner_C:InstallSpecificUpgrade", nil, upHook },
}
local done = {}
local mutedBench
RegisterLoadMapPreHook(function() mutedBench = nil end)
local function hookAll()
    for i, h in ipairs(HOOKS) do
        if not done[i] then
            local function wrap(fn)
                return fn and function(...)
                    local ok, err = pcall(fn, ...)
                    if not ok then log("PT|error stations hook %d %s", i, tostring(err)) end
                end
            end
            -- Blueprint functions: one callback (it runs after the function, as in guestact.lua); the native PurchaseNode takes pre and post
            local ok
            if h[2] and h[3] then ok = pcall(RegisterHook, h[1], wrap(h[2]), wrap(h[3])) else ok = pcall(RegisterHook, h[1], wrap(h[2] or h[3])) end
            if ok then done[i] = true; log("PT|stations hooked %d", i) end
        end
    end
end

-- Research screen white on its first open (friend's host 2026-11-03, both sides 2026-11-04): ActivateScreen gives the widget component
-- its widget and at once puts the component's render target on the monitor (ScreenMID SlateUI), but the component makes that target
-- only when it first draws, so the monitor got none. After the game's ActivateScreen, set it once the target exists.
local BENCH = "/Game/Gameplay/CarGarage/Stations/ResearchStation/BP_Garage_InventingBench.BP_Garage_InventingBench_C"
local SLATE = FName("SlateUI")
local function fixScreen(bench, tries)
    if not valid(bench) or not valid(bench.ScreenMID) then return end
    local rt = bench.Widget:GetRenderTarget()
    if not valid(rt) then
        if tries > 0 then common.defer(16, function() pcall(fixScreen, bench, tries - 1) end) end
        return
    end
    if not valid(bench.ScreenMID:K2_GetTextureParameterValue(SLATE)) then
        bench.ScreenMID:SetTextureParameterValue(SLATE, rt)
        log("PT|stations research screen given its render target")
    end
end
local screenHooked = false
local function hookScreen()
    if screenHooked then return end
    screenHooked = pcall(RegisterHook, BENCH .. ":ActivateScreen", function(self)
        if not safety.active() then return end
        local bench = self:get() -- a hook parameter must not outlive the callback
        common.defer(0, function() pcall(fixScreen, bench, 200) end)
    end)
end

LoopInGameThreadWithDelay(500, function()
    if safety.active() then pcall(hookScreen) end
    if common.netMode() == "client" then
        local bench = first("BP_Garage_InventingBench_C")
        if bench and bench ~= mutedBench and PTNative_Mute then
            PTNative_Mute(bench:GetAddress(), "OnNodePurchased")
            mutedBench = bench
        end
        local ok, err = pcall(hookAll)
        if not ok then log("PT|error stations hook %s", tostring(err)) end
        local ok2, err2 = pcall(guestQuirks)
        if not ok2 then log("PT|error stations quirks %s", tostring(err2)) end
        if #shredded > 0 and os.clock() - shredAt > 0.4 then
            net.toHost("g.st.shred", table.concat(shredded, "\n"))
            log("PT|st shred intent %d items", #shredded)
            shredded = {}
        end
    elseif host() then
        local okc, errc = pcall(hostCurrencies)
        if not okc then log("PT|error stations currencies %s", tostring(errc)) end
        local okq, errq = pcall(hostQuirks)
        if not okq then log("PT|error stations host quirks %s", tostring(errq)) end
        local ok, err = pcall(hostShredder)
        if not ok then log("PT|error stations host %s", tostring(err)) end
    end
end)

return M
