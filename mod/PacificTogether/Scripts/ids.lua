-- Item containers as plain data: "path:d12:f7.5*count,..." strings (archetype + durability/fuel/battery/health per item)
-- that both players can compare, send and apply.
-- shortcut: tints, upgrades and chart data do not travel; add them to PROPS when playtests show it matters.
local UEHelpers = require("UEHelpers")

local M = {}

function M.alive(o) return o and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end

-- "ItemArchetype /Game/x/IA_A.IA_A" -> "/Game/x/IA_A"
local function path(a) return (a:GetFullName():match("^%S+ (.+)$"):gsub("%.[^%./]+$", "")) end

local archs = {} -- path -> archetype object
local function archetype(p)
    local a = archs[p]
    if a and a:IsValid() then return a end
    local full = p .. "." .. p:match("[^/]+$")
    a = StaticFindObject(full)
    if not a:IsValid() then pcall(LoadAsset, full); a = StaticFindObject(full) end
    if a:IsValid() then archs[p] = a end
    return a:IsValid() and a or nil
end

local function system()
    local s = FindFirstOf("InventorySystem")
    if s and s:IsValid() then return s end
    return StaticFindObject("/Script/PenDriverInventory.Default__InventorySystem")
end

-- per-item state that travels: durability (int), fuel, battery, health (floats). The game's setter takes an int32,
-- so a float goes in as its bits.
local PROPS = { -- key, property asset, member name, reader, float?
    { "d", "IP_Durability", "Durability", function(b, it, w) local o = { {}, {}, {}, {}, {} }; b:GetDurability(it, w, o[1], o[2], o[3], o[4], o[5]); return o[3].Durability end },
    { "f", "IP_Fuelable", "Fuel", function(b, it, w) local o = { {}, {}, {}, {}, {}, {} }; b:GetFuelableInfo(it, w, o[1], o[2], o[3], o[4], o[5], o[6]); return o[1].Fuel end, true },
    { "b", "IP_Battery", "Battery", function(b, it, w) local o = { {}, {}, {}, {}, {} }; b:GetBattery(it, w, o[1], o[2], o[3], o[4], o[5]); return o[3].BATTERY end, true },
    { "h", "IP_Health", "Health", function(b, it, w) local o = { {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {} }; b:GetHealth(it, w, o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8], o[9], o[10], o[11]); return o[3].Health end, true },
}
-- tests only (a mutation without item state); players never set PT_MUTATE
if os.getenv("PT_MUTATE") == "nolootsync2" then PROPS = {} end
local propAssets = {} -- archetype path -> { property name -> IP_ struct asset }
local function assets(a, p)
    local t = propAssets[p]
    if not t then
        t = {}
        a.Properties:ForEach(function(_, e) local s = e:get(); t[s:GetFName():ToString()] = s end)
        propAssets[p] = t
    end
    return t
end
-- FindObject walks the objects (0.18 ms) and spec() needs it per item: keep it
local bflObj
local function bfl()
    if not (bflObj and bflObj:IsValid()) then bflObj = FindObject("BFL_ItemPropertyUtilityFns_C", "Default__BFL_ItemPropertyUtilityFns_C") end
    return bflObj
end
local function lib() return StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary") end

-- "path:d12:f7.5" for one item
local function spec(it, p)
    local t, w, b = assets(it.Archetype, p), UEHelpers.GetWorld(), bfl()
    local s = p
    for _, pr in ipairs(PROPS) do
        if t[pr[2]] then
            local ok, v = pcall(pr[4], b, it, w)
            if ok and type(v) == "number" then s = s .. ":" .. pr[1] .. string.format(pr[5] and "%.5g" or "%d", v) end
        end
    end
    return s
end

local function setProps(it, p, s)
    local t = assets(it.Archetype, p)
    for _, pr in ipairs(PROPS) do
        local v = tonumber(s:match(":" .. pr[1] .. "(-?[%d%.e+-]+)"))
        if v and t[pr[2]] then
            lib():SetItemProperty(t[pr[2]], it, FName(pr[3]), pr[5] and (string.unpack("<i4", string.pack("<f", v))) or math.floor(v))
        end
    end
end

-- spec string -> list of item instances
-- A big container is filled over several frames (the host's 4165-item Expansion storage held a guest's frame 2.3 s on joining,
-- 2026-10-28): apply and applyLayout take an optional `steps` list; given one, the item operations go into it as functions that the
-- caller runs a few ms a frame (loot.lua). A coroutine cannot do it: UE4SS refuses game calls from a coroutine's Lua state ("has no
-- instance inside lua_instances").
local function step(steps, fn) if steps then steps[#steps + 1] = fn else fn() end end

function M.count(container)
    local items, have = {}, {}
    container:GetAllItems(items)
    for _, it in ipairs(items) do
        local inst = it:get()
        local a = inst.Archetype
        local p = path(a)
        archs[p] = a
        local k = spec(inst, p)
        have[k] = have[k] or {}
        table.insert(have[k], inst)
    end
    return have
end

function M.encode(have)
    local keys = {}
    for k in pairs(have) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do keys[i] = k .. "*" .. #have[k] end
    return table.concat(keys, ",")
end

-- spec string -> count
function M.decode(s)
    local want = {}
    for k, n in s:gmatch("([^,*]+)%*(%d+)") do want[k] = tonumber(n) end
    return want
end

-- make the container hold exactly `want` (spec -> count): an item that differs only in state is changed in place
function M.apply(container, want, steps)
    local have = M.count(container)
    local extra, missing = {}, {}
    for k, list in pairs(have) do
        for i = (want[k] or 0) + 1, #list do extra[#extra + 1] = { k = k, inst = list[i] } end
    end
    for k, n in pairs(want) do
        for _ = 1, n - (have[k] and #have[k] or 0) do missing[#missing + 1] = k end
    end
    local create = {}
    for _, k in ipairs(missing) do
        local p = k:match("^[^:]+")
        local reuse
        for i, e in ipairs(extra) do if e.k:match("^[^:]+") == p then reuse = i; break end end
        if reuse then
            setProps(extra[reuse].inst, p, k)
            table.remove(extra, reuse)
        else
            create[#create + 1] = k
        end
    end
    -- remove before adding: a full container has no room for the new ones
    for _, e in ipairs(extra) do step(steps, function() container:RemoveItem(e.inst) end) end
    for _, k in ipairs(create) do
        step(steps, function()
            local p = k:match("^[^:]+")
            local a = archetype(p)
            if a then
                local inst = lib():CreateItemInstance(UEHelpers.GetWorld(), a, 0)
                if container:AddItem(inst, true) then setProps(inst, p, k) end
            end
        end)
    end
end

-- Where the items lie. A container with a tile layout (garage storage, lockers, trunks: ItemTileLayout, e.g. CL_Garage_V1 8x11)
-- is a grid: each stack is an ItemTileSlot at a cell (Location X,Y) and maybe turned (bRotated); slots come and go with their items,
-- so their order says nothing. "@x.y.r=spec*n+spec*n,..." per stack. The bag above (spec*count) let each side put items wherever
-- they fitted: the host's and the guest's storage looked different (owner's screenshot, 2026-10-28), and a move inside a container
-- did not count as a change at all. Containers without a tile layout keep the bag.
local function tiles(container) return container.Layout:IsValid() and container.Layout:IsA(StaticFindObject("/Script/PenDriverInventory.ItemTileLayout")) end
local function slotKey(s)
    local items, have = {}, {}
    s:GetItems(items)
    for _, it in ipairs(items) do
        local inst = it:get()
        local p = path(inst.Archetype)
        archs[p] = inst.Archetype
        local k = spec(inst, p)
        have[k] = (have[k] or 0) + 1
    end
    local keys = {}
    for k, n in pairs(have) do keys[#keys + 1] = k .. "*" .. n end
    table.sort(keys)
    return table.concat(keys, "+"), items
end
function M.layout(container)
    if not tiles(container) then return M.encode(M.count(container)) end
    local r = {}
    for i = 0, container:GetNumSlots() - 1 do
        local s = container:GetSlot(i)
        if s:IsValid() and s:GetNumItems() > 0 then
            local l = s.Location
            r[#r + 1] = string.format("%d.%d.%d=%s", l.X, l.Y, s.bRotated and 1 or 0, (slotKey(s)))
        end
    end
    table.sort(r)
    return "@" .. table.concat(r, ",")
end

-- make the container hold the other side's stacks at the same cells. When anything differs it is laid out again: the items are taken
-- out and put back with the layout's own EmplaceSlot (instances of the same archetype are used again, their state set; new ones are
-- created). A stack that does not fit its cell goes anywhere, as before.
function M.applyLayout(container, body, steps)
    if not tiles(container) then return M.apply(container, M.decode(body:sub(2)), steps) end
    if M.layout(container) == body then return end
    local pool = {} -- archetype path -> instances taken out
    step(steps, function()
        local all = {}
        container:GetAllItems(all)
        for _, it in ipairs(all) do
            local inst = it:get()
            local p = path(inst.Archetype)
            pool[p] = pool[p] or {}
            table.insert(pool[p], inst)
        end
        container:RemoveAllItems()
    end)
    for x, y, r, entry in body:sub(2):gmatch("(%d+)%.(%d+)%.(%d)=([^,]+)") do
        local stack = {} -- the slot this stack's first item made; the rest go on top
        for k, c in entry:gmatch("([^+*]+)%*(%d+)") do
            local p = k:match("^[^:]+")
            for _ = 1, tonumber(c) do
                step(steps, function()
                    -- the steps run over many frames: the container or its layout can be gone or replaced meanwhile (the host's
                    -- storage expansion install; guest crash in EmplaceSlot on CL_Garage_V1, 2026-11-01)
                    if not (container:IsValid() and container.Layout:IsValid()) then return end
                    local L = container.Layout
                    local inst = pool[p] and table.remove(pool[p])
                    if not inst then
                        local a = archetype(p)
                        inst = a and lib():CreateItemInstance(UEHelpers.GetWorld(), a, 0)
                    end
                    if not inst then return end
                    setProps(inst, p, k)
                    local placed = false
                    if stack.slot and stack.slot:IsValid() then placed = stack.slot:AddItem(inst) end
                    if not placed then
                        local ok, sl = pcall(function() return L:EmplaceSlot(container, inst, { X = tonumber(x), Y = tonumber(y) }, r == "1", true) end)
                        if ok and sl and sl:IsValid() then stack.slot, placed = sl, true end
                    end
                    if not placed then container:AddItem(inst, true) end
                end)
            end
        end
    end
end

function M.path2(o) return o:GetFullName():match("^%S+ (.+)$") end
M.path, M.archetype, M.system, M.bfl = path, archetype, system, bfl
function M.spec(it) return spec(it, path(it.Archetype)) end -- "path:d12:f7.5" of one item instance
function M.setProps(it, s) setProps(it, s:match("^[^:]+"), s) end
function M.asset(p) -- any asset by full path, loaded on demand
    local o = StaticFindObject(p)
    if not o:IsValid() then pcall(LoadAsset, p); o = StaticFindObject(p) end
    return o:IsValid() and o or nil
end
return M
