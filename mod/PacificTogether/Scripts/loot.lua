-- M4 shared items (W1, W2, C6, G1, P2, P3). The host's world is the truth; the guest's own loot is replaced by copies of it.
--   L lootable containers, W world pickups, I the game's single containers (car trunk, garage storage),
--   R scrappable resources (PCs, TVs, lights, gas cylinders: BP_Spawn_ResourceBase_C; the zone's spawn pass makes them on the host only).
-- Host: finds them, gives each an id, tells the guest (A add, S contents, D gone). Guest: spawns or claims a local copy
-- per id and removes its own random loot; its own changes go back as intents (S contents, T "I picked this up") and the
-- host applies them. The guest's backpack stays its own: a pickup lands there through the game's own code.
-- Messages (net.lua kind g.loot.b): lines "A|id|class-or-archetype|x|y|z|yaw|state", "S|id|state", "D|id", "T|id", "F" (end of
-- the full dump), "H" (guest asks for the full dump). state = "<flags>;<contents>" (ids.lua);
-- flags is one digit: 1 rolled on open, 2 was opened, 4 empty (the two visuals), "-" for non-lootables.
-- Inert in single player: nothing runs without a listening host with a guest, or a guest.
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local ids = require("ids")
local log = common.log
local ov = require("overlay")
local alive = ids.alive
local function entityAlive(e) return e and common.resolve(e.lease) ~= nil end
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
-- a garage pump's nozzle is a world item on a cable: each game keeps its own (the guest's was purged and the host's copied onto
-- its pump, three nozzles and none to take, playtest 2026-10-31)
local function tethered(a) return a:GetClass():GetFName():ToString():find("GasPumpHandle", 1, true) ~= nil end


-- tests only (a mutation that makes this module send and apply nothing); players never set PT_MUTATE
local DEAF = os.getenv("PT_MUTATE") == "nointent"
-- tests only: no wreck parts and no lootable visuals (item state: ids.lua)
local NO2 = os.getenv("PT_MUTATE") == "nolootsync2"

-- tests only: a template part's own container (a wreck's trunk contents, a box truck's cargo) is not carried
local NOCAR = os.getenv("PT_MUTATE") == "nocarloot"

-- tests only: the host sends no positions of moving world items
local NOFALL = os.getenv("PT_MUTATE") == "nofall"
local NOROTATE = os.getenv("PT_MUTATE") == "norotationsync"
local NOITEMSTATE = os.getenv("PT_MUTATE") == "noitemstate"

local INV = { "Inventory_Trunk", "Inventory_LargeTrunk", "Inventory_Garage", "Inventory_GarageLarge", "Inventory_GarageExpansion1",
              "Inventory_GarageExpansion1_Large", "Inventory_Garage_BackRoom", "Inventory_Tubes_In", "Inventory_Tubes_Out", "Inventory_GarageTransfer" }
if os.getenv("PT_MUTATE") == "nomailsync" then
    for _ = 1, 3 do table.remove(INV) end
end
local DROP = 500 -- uu: an unknown pickup this close to the guest is its own drop
local MATCH = 60 -- uu: a local actor this close to the host's, same class, is the same thing

local replica = require("replica")
local itemMotion = require("itemmotion")
local replicas = replica.new(nil)
local M = {}
local ents, byName, nextId = {}, {}, 1 -- id -> entity; actor full name -> id (host)
local partIds = {} -- wreck part actor full name -> id, both sides (idOf), checked on lookup
local reported = {} -- guest: dropped items already told to the host
local ADOPT = os.getenv("PT_MUTATE") ~= "nodropadopt" -- tests only: the guest's drop is replaced by the host's copy
local pendingDrops, dropKey = {}, 0 -- guest: key -> its own dropped actor, until the host's "K" makes it an entity
local claimed = {} -- guest: local actors that are some entity's copy
local function isClaimed(a) return common.resolve(claimed[a:GetFullName()]) ~= nil end
local out = {} -- lines for the other side, sent at the end of the tick
local validItemSpec
local tickN, hostScanned, fullAt = 0, false, nil
local skip = {} -- host: address -> class address of an actor that never qualifies (an /Engine/Transient template): its name is not read again
local function known(a)
    local id = byName[a:GetAddress()]
    if id and entityAlive(ents[id]) then return true end
    if id then byName[a:GetAddress()] = nil end
    return false
end
local listening = false -- host with a guest (the 500 ms tick sets it; the 50 ms backlog loop reads it)
-- host: the guest controller that asked for the full list (H) = loaded and acking. Nothing goes out before: a loading guest acks
-- late, and lines sent meanwhile overflowed its reliable channel and dropped it (lootsync 2026-10-22, NumOutRec 254). The full
-- list it asks for carries everything registered before.
-- shortcut: one ready guest (PLAN D1: 2 players); per-guest readiness before 3-4 players
local readyFor
local lastRx = -math.huge -- guest: when the host's last loot line came in

-- a big container (a garage's storage can hold hundreds of stacks) does not fit one message (32 KB): its state goes as numbered pieces
-- "P|id|i|n|keys", put together again on the other side
local PIECE = 5000
local function say(line)
    if #line > PIECE * 1.5 and line:sub(1, 2) == "S|" then
        local id, s = line:match("^S|([^|]*)|(.*)$")
        local pieces, cur, size = {}, {}, 0
        for k in s:gmatch("[^,]+") do
            if size > PIECE then pieces[#pieces + 1] = table.concat(cur, ","); cur, size = {}, 0 end
            cur[#cur + 1] = k
            size = size + #k + 1
        end
        pieces[#pieces + 1] = table.concat(cur, ",")
        for i, p in ipairs(pieces) do out[#out + 1] = string.format("P|%s|%d|%d|%s", id, i, #pieces, p) end
        return
    end
    out[#out + 1] = line
end
local partial = {} -- id -> { piece index -> text } (guest and host)
local inbox, head = {}, 1 -- lines from the other side, worked off a few ms per frame (below)
local function flush()
    if #out == 0 then return end
    if common.netMode() == "listen" and not readyFor then out = {}; return end
    local buf, size = {}, 0
    local function send()
        if #buf == 0 then return end
        local data = table.concat(buf, "\n")
        if common.netMode() == "client" then net.toHost("g.loot.b", data) else net.toGuests("g.loot.b", data) end
        buf, size = {}, 0
    end
    for _, l in ipairs(out) do
        if size + #l > 8000 then send() end
        buf[#buf + 1] = l
        size = size + #l + 1
    end
    send()
    out = {}
end

LoopInGameThreadWithDelay(500, function()
    if common.netMode() ~= "client" or os.getenv("PT_MUTATE") == "nomailsync" then return end
    for _, tube in ipairs(FindAllOf("BP_GarageTransferTube_C") or {}) do
        if alive(tube) then tube:SetActorTickEnabled(false) end
    end
end)

local function inventoryManager()
    local m = FindFirstOf("BP_InventoryManager_C")
    return alive(m) and m or nil
end

local function flagsOf(e)
    local a = e.actor
    if e.kind ~= "L" or not alive(a) then return nil end
    if NO2 then return a.RolledOnOpenItems and 1 or 0 end
    return (a.RolledOnOpenItems and 1 or 0) + (a.DataBlock_WasOpened and 2 or 0) + (a.Empty and 4 or 0)
end

local LAYOUT = os.getenv("PT_MUTATE") ~= "nolayout" -- slot by slot (ids.layout) instead of a bag of items
local function stateOf(e)
    local c = e.get()
    if not alive(c) then return nil end
    return (flagsOf(e) or "-") .. ";" .. (LAYOUT and ids.layout(c) or ids.encode(ids.count(c)))
end
-- a move inside a container (same items, other slots) changes no count: the container's own slot events mark it for the next scan
-- (PDCoopNet's events.lua hooks the same two). Our own apply fires them too; its state then equals e.last and nothing is sent.
local dirty = {} -- container address -> true
for _, fn in ipairs({ "HandleSlotItemAdded", "HandleSlotItemRemoved" }) do
    local ok, err = pcall(RegisterHook, "/Script/PenDriverInventory.ItemContainer:" .. fn, function(self)
        pcall(function() dirty[self:get():GetAddress()] = true end)
    end)
    if not ok then log("PT|error loot hook %s %s", fn, tostring(err)) end
end

-- opened and emptied look: the game's own visual switches
local function applyFlags(a, f)
    a.RolledOnOpenItems = f & 1 ~= 0
    if f & 2 ~= 0 and not a.DataBlock_WasOpened then
        a.DataBlock_WasOpened = true
        pcall(function() a:SwitchToOpenedVisuals() end)
    end
    if f & 4 ~= 0 and not a.Empty then
        a.Empty = true
        pcall(function() a:UpdateVisualsForEmpty() end)
    end
end

-- a template part (abandoned-car door, wheel, gas cap): "pitch,roll,item spec,mesh"
-- some parts hold items (their ItemInstance has a container): "spec;contents", contents "-" when there is none
local function partBox(a)
    if NOCAR or not alive(a)or not alive(a.ItemInstance)then return nil end
    local cls=StaticFindObject('/Script/PenDriverInventory.ItemInstance')
    if not alive(cls)or not a.ItemInstance:IsA(cls)then return nil end
    local ok, c = pcall(function()
        local o = {}
        ids.bfl():GetInstanceContainer(a.ItemInstance, a, o)
        return o.Container
    end)
    return ok and alive(c) and c or nil
end
local function partContents(a, layout)
    local c = partBox(a)
    return c and (layout and ids.layout(c) or ids.encode(ids.count(c))) or "-"
end
local function partKey(a) return ids.spec(a.ItemInstance) .. ";" .. partContents(a) end
local function partState(a, layout)
    local r = a:K2_GetActorRotation()
    return string.format("%.1f,%.1f,%s,%s;%s", r.Pitch, r.Roll, ids.spec(a.ItemInstance), alive(a.RequestedMesh) and ids.path2(a.RequestedMesh) or "-", partContents(a,layout))
end

-- a plasma generator the host broke (harvested): the game sets Broken, swaps the glass mesh, kills the light and the highlight. The
-- guest's copy stayed whole (first Steam play #7b). Only broken -> whole is not undone.
local function brokenOf(a)
    local ok, v = pcall(function() return a.Broken end)
    return ok and v == true
end
local function applyBroken(a)
    if os.getenv("PT_MUTATE") == "noplasma" or brokenOf(a) then return end
    pcall(function()
        a.SM_Plasma_Generator_Glass:SetStaticMesh(a.BrokenMesh)
        a.SpotLight:SetIntensity(0.0)
        a.Highlight:SetActive(false, false)
        a.Broken = true -- last: brokenOf() stops retries, so only a finished swap may set it
    end)
    log("PT|loot plasma generator broken here too")
end

-- The container the open inventory menu shows (the loot tick looks every 500 ms). The partner's change to it was filled a few
-- items a frame while the menu hovered the slots being freed: the guest crashed in ContainerOnHoveredSlot (both in the trunk,
-- playtest 2026-10-31). Now the partner's change waits until this player closes the menu; this player's own changes still go
-- out. Closing the menu from Lua left the game unable to open container menus again, and a refill plus "Reconstruct Inventory"
-- lost a guest's take (lootcar, playpath 2026-11-01).
-- shortcut: both players changing the same container at once can duplicate or revert an item (no crash); merge per slot if seen
local menuBox = nil
local function watchMenu()
    -- the inventory page's other container while the game shows the mouse (a menu is up). The page keeps TransferContainer after
    -- the menu closes, and the menu widget stays in the viewport hidden; reading the menu widget itself (IsInViewport,
    -- Category_Inventory) every 500 ms kept the guest's container menu from opening now and then (lootcar, playpath 2026-11-01)
    local box = nil
    local pc = UEHelpers.GetPlayerController()
    if alive(pc) and pc.bShowMouseCursor then
        for _, w in ipairs(FindAllOf("UMG_PlayerMenu_Inventory_C") or {}) do
            local t = w.TransferContainer
            if t:IsValid() then box = t:GetAddress(); break end
        end
    end
    local was = menuBox
    menuBox = box
    return was ~= box and was or nil -- the container whose menu just closed
end
local function menuShows(c) return os.getenv("PT_MUTATE") ~= "nomenuwait" and menuBox ~= nil and menuBox == c:GetAddress() end

local filling = {} -- containers being filled a few steps a frame: { e, steps, i, finish, before, t0 }
RegisterLoadMapPreHook(function() filling, pendingDrops = {}, {} end) -- their containers (and our drops) go with the old world
local function applyState(e, s)
    if e.kind=="W" then
        if not NOITEMSTATE and net.hostSupports('item-state') and entityAlive(e) and alive(e.actor.Instance)
            and validItemSpec(s,ids.path(e.actor.Instance.Archetype)) then ids.setProps(e.actor.Instance,s) end
        return
    end
    if e.kind == "R" then
        if s == "br" and entityAlive(e) then applyBroken(e.actor) end
        return
    end
    if e.kind == "P" then
        local spec = s:match("^[^,]*,[^,]*,([^,]*),")
        if entityAlive(e) and alive(e.actor.ItemInstance) and spec then
            ids.setProps(e.actor.ItemInstance, spec)
            local body, box = s:match(";(.*)$"), partBox(e.actor)
            if box and body and body ~= "-" and not (common.netMode()=="client" and net.hostSupports("wreck-state") and body:sub(1,1)~="@") then
                if menuShows(box) and body:sub(1,1) ~= "@" then e.pendingPartState=s;return end
                if body:sub(1,1)=='@' then ids.applyLayout(box,body) else ids.apply(box, ids.decode(body)) end
            end
            e.last = partKey(e.actor)
        end
        return
    end
    local c = e.get()
    if not alive(c) then e.pending = s; return end
    local waiting = e.pending
    e.pending, e.box = nil, c:GetAddress()
    if menuShows(c) and s:sub(3,3) ~= "@" and s:sub(3,3) ~= "!" then
        if not waiting then log("PT|loot partner changed the open container %s: applied when the menu closes", e.id) end
        e.pending = s
        return
    end
    local flags, body = s:match("^(.);(.*)$")
    -- the item operations go into a list that the line loop below works off a few ms a frame (ids.lua: a 4165-item storage held a
    -- guest's frame 2.3 s); the container is busy meanwhile, so the change scan does not send it half done
    local steps = {}
    local sliced = os.getenv("PT_MUTATE") ~= "noslice"
    if body:sub(1, 1) == "@" or body:sub(1,1)=="!" then ids.applyLayout(c, body, sliced and steps or nil)
    else ids.apply(c, ids.decode(body), sliced and steps or nil) end
    local function finish()
        if not alive(c) then return end
        if e.kind == "L" and flags ~= "-" then applyFlags(e.actor, tonumber(flags)) end
        e.last, e.n, e.rolled = stateOf(e), ids.numItems(c), flagsOf(e)
    end
    if #steps == 0 then finish() return end
    e.busy = true
    filling[#filling + 1] = { e = e, steps = steps, i = 1, finish = finish, before = e.n, t0 = os.clock() }
end

-- car parts with their own storage (racks, crates on the car): "Car.<slot>" -> the installed part's container. Only the trunks were
-- shared, so what the guest stored on a rack was its own and was gone when the next zone rebuilt its car from the host's
-- (prybars and scrappers lost, playtest 2026-10-31)
local function carBoxes()
    local r = {}
    local m = inventoryManager()
    if not m then return r end
    pcall(function()
        local box = {}
        m:GetCarEquippedContainer(box)
        local c = box.Inventory_CarEquipped
        if not alive(c) then return end
        local car = FindFirstOf("BP_PlayerCarNew_C")
        local known = {} -- the trunks are shared under their own names already
        for _, n in ipairs(INV) do local x = m[n]; if alive(x) then known[x:GetAddress()] = true end end
        -- the slots as car.lua reads them (Slots / Items): GetSlot(i) on this container crashed the host (2026-11-01)
        c.Slots:ForEach(function(_, e)
            local sl = e:get()
            local it
            sl.Items:ForEach(function(_, x) it = x:get() end)
            if alive(it) then
                local o = {}
                ids.bfl():GetInstanceContainer(it, car, o)
                if alive(o.Container) and not known[o.Container:GetAddress()] then
                    r["Car." .. (sl.SlotName:ToString():gsub("^Car%.Equip%.", ""))] = o.Container
                end
            end
        end)
    end)
    return r
end

local function partLockers()
    if common.netMode()=="client" and not net.hostSupports("named-storage")then return {} end
    for _,pc in ipairs(net.guests())do if not net.peerSupports(pc,"named-storage")then return {} end end
    local boxes={}
    for _,s in ipairs(FindAllOf("BP_GarageInstallation_Spawner_C") or {}) do
        if alive(s) and not s:GetFullName():find("/Engine/Transient",1,true) then
            local name=s:GetFName():ToString()
            if name:find("^BP_GarageStation_PartStorage_") then
                local o={};s:GetUpgradeActor(o);local actor=o["Upgrade Actor"]
                if alive(actor) then
                    local c=actor.NamedPartsContainer
                    if alive(c)then boxes["PartsLocker."..name..".1"]=c end
                end
            end
        end
    end
    return boxes
end
local function register(id, kind, actor, invName)
    local e = { id = id, kind = kind, actor = actor, lease = common.lease(actor), name = actor and actor:GetFullName(), addr = actor and actor:GetAddress() }
    if kind == "L" then e.get = function() return entityAlive(e) and e.actor.InventoryContainer or nil end
    elseif kind == "I" and invName:find("^Stations%.") then
        -- garage storage and lockers: the manager's tag map
        e.get = function()
            if common.resolve(e.cacheLease) then return e.cache end
            local m = inventoryManager()
            if not m then return nil end
            pcall(function() m.Inventories_Garage:ForEach(function(k, v) if k:get().TagName:ToString() == invName then e.cache = v:get(); e.cacheLease = common.lease(e.cache) end end) end)
            return alive(e.cache) and e.cache or nil
        end
    elseif kind == "I" and invName:find("^PartsLocker%.") then
        e.get=function() return partLockers()[invName] end
    elseif kind == "I" and invName:find("^Car%.") then
        e.get = function()
            if common.resolve(e.cacheLease) then return e.cache end
            e.cache = carBoxes()[invName]; e.cacheLease = common.lease(e.cache)
            return alive(e.cache) and e.cache or nil
        end
    elseif kind == "I" then e.get = function() local m = inventoryManager(); return m and m[invName] or nil end
    else e.get = function() return nil end end
    e.rolled = flagsOf(e)
    ents[id] = e
    if kind == "P" then partIds[e.name] = id end
    return e
end

-- UE's FRotator -> quaternion
local function xform(x, y, z, yaw, pitch, roll)
    local sp, cp = math.sin(math.rad(pitch or 0) / 2), math.cos(math.rad(pitch or 0) / 2)
    local sy, cy = math.sin(math.rad(yaw) / 2), math.cos(math.rad(yaw) / 2)
    local sr, cr = math.sin(math.rad(roll or 0) / 2), math.cos(math.rad(roll or 0) / 2)
    return { Rotation = { X = cr * sp * sy - sr * cp * cy, Y = -cr * sp * cy - sr * cp * sy, Z = cr * cp * sy - sr * sp * cy, W = cr * cp * cy + sr * sp * sy },
             Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
end

validItemSpec=function(spec, path)
    if type(spec) ~= "string" or #spec > 2048 or spec:sub(1, #path) ~= path then return false end
    local rest, seen = spec:sub(#path + 1), {}
    while rest ~= "" do
        local field, tail = rest:match("^:([^:]+)(.*)$")
        if not field then return false end
        local key, raw = field:match("^([dfbhpct])(.*)$")
        if not key or seen[key] then return false end
        if key=="p" or key=="c" then
            if raw~="-" and (#raw>1024 or not raw:match("^/Game/BaseArt/Palettes/[%w_/%.-]+$")) then return false end
        elseif key=="t" then if raw~="0" and raw~="1" then return false end
        else
            if not raw:match("^[%d%.%+%-eE]+$") then return false end
            local value=tonumber(raw)
            if not value or value~=value or math.abs(value)>10000000 or (key=="d" and value%1~=0) then return false end
        end
        seen[key], rest = true, tail
    end
    if seen.p or seen.t or seen.c then return seen.p and seen.t and seen.c or false end
    return true
end

local function validLayout(body)
    if type(body)~='string'or #body>30000 or body:sub(1,1)~='@'then return false end
    local total=0
    for row in body:sub(2):gmatch('[^,]+')do
        local x,y,r,entry=row:match('^(%d+)%.(%d+)%.([01])=(.+)$')
        if not x or tonumber(x)>1024 or tonumber(y)>1024 then return false end
        for stack in entry:gmatch('[^+]+')do
            local spec,n=stack:match('^([^*]+)%*(%d+)$')
            local path=spec and spec:match('^(/Game/[%w_/%.-]+)')
            if not path or not validItemSpec(spec,path)or tonumber(n)<1 then return false end
            total=total+tonumber(n);if total>4096 then return false end
        end
    end
    return true
end

local function line(e)
    local a = e.actor
    local l, r = a:K2_GetActorLocation(), a:K2_GetActorRotation()
    local what, state
    if e.kind == "L" then what, state = ids.path2(a:GetClass()), stateOf(e)
    elseif e.kind == "R" then what, state = ids.path2(a:GetClass()), brokenOf(a) and "br" or "-"
    elseif e.kind == "B" then what, state = ids.path2(a:GetClass()), "-"
    elseif e.kind == "P" then what, state = ids.path2(a:GetClass()), partState(a)
    else what, state = ids.path(a.Instance.Archetype), ids.spec(a.Instance);e.itemState=state end
    local add = string.format("A|%s|%s|%.0f|%.0f|%.0f|%.0f|%s", e.id, what, l.X, l.Y, l.Z, r.Yaw, state)
    if e.kind == "W" and not NOROTATE and not NOFALL then
        add = add .. string.format("\nM|%s|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f", e.id, l.X, l.Y, l.Z, r.Yaw, r.Pitch, r.Roll)
    end
    return add
end

-- host ------------------------------------------------------------------------------------------------------------

-- known actors by address: a GetFullName of every lootable, item and wreck part per scan took 370-720 ms in a zone
-- (local playtest 2026-10-22); the name is only read for actors not seen before
-- work per tick for new actors (each costs ~1-2 ms: contents and part state); the rest waits for the next tick. A zone's first
-- scan or full list in one go took ~260 ms on the host (2026-10-22)
local BUDGET_HOST = 0.008 -- scan or list per call (the backlog loop runs one of them); the scan adds its fixed lookups
local function scanWorldItems(deadline)
    deadline = deadline or os.clock() + BUDGET_HOST
    for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
        if not known(a) and alive(a) and alive(a.Instance) and not a:GetFullName():find("/Engine/Transient", 1, true)
            and not a:GetAttachParentActor():IsValid() and not tethered(a) then
            if os.clock() >= deadline then return false end
            local e = register("W" .. nextId, "W", a)
            nextId, byName[a:GetAddress()] = nextId + 1, e.id
            e.hotUntil = os.clock() + 5
            say(line(e))
        end
    end
    return true
end

local function scanHost()
    -- the budget is checked first, so a cut scan stops costing at once; it only counts as cut when time ran out
    local t0, cut = os.clock(), false
    local function room()
        if os.clock() - t0 < BUDGET_HOST then return true end
        cut = true
        return false
    end
    local function transient(a, k)
        if not a:GetFullName():find("/Engine/Transient", 1, true) then return false end
        skip[k] = common.identity(a)
        return true
    end
    -- an address that comes back as an actor of another class is read again
    local function skipped(a, k) return skip[k] ~= nil and skip[k] == common.identity(a) end
    for _, a in ipairs(FindAllOf("BP_Lootable_Base_C") or {}) do
        local k = a:GetAddress()
        if not known(a) and room() and alive(a) and not transient(a, k) and alive(a.InventoryContainer) then
            local e = register("L" .. nextId, "L", a)
            nextId, byName[k] = nextId + 1, e.id
            e.last, e.n = stateOf(e), e.get():GetNumItems()
            say(line(e))
        end
    end
    if not scanWorldItems(t0 + BUDGET_HOST) then cut = true end
    -- abandoned cars: the body (B) and each part still on it (P); the guest has neither
    for _, a in ipairs(not NO2 and FindAllOf("LootableTemplate") or {}) do
        local k = a:GetAddress()
        if not known(a) and room() and alive(a) and not skipped(a, k) and not transient(a, k) then
            local e = register("B" .. nextId, "B", a)
            nextId, byName[k] = nextId + 1, e.id
            say(line(e))
        end
    end
    for _, a in ipairs(not NO2 and FindAllOf("LootableTemplatePart") or {}) do
        local k = a:GetAddress()
        if not known(a) and room() and alive(a) and not skipped(a, k) and alive(a.ItemInstance) and not transient(a, k) then
            local e = register("P" .. nextId, "P", a)
            nextId, byName[k] = nextId + 1, e.id
            e.last = partKey(a)
            say(line(e))
        end
    end
    -- scrappable resources: presence only (scrapping one destroys it, IP_Health_DestroyOnDead); its drops are world items.
    -- shortcut: the guest's copy rolls its own mesh variant (BiomeSwapMesh) and starts at full health
    for _, a in ipairs(FindAllOf("BP_Spawn_ResourceBase_C") or {}) do
        local k = a:GetAddress()
        -- not the class templates in /Engine/Transient: the guest made real copies of them at 0,0,0 (the PC in the middle of the
        -- garage, playtest 2026-10-31)
        if not known(a) and room() and alive(a) and not skipped(a, k) and not transient(a, k) then
            local e = register("R" .. nextId, "R", a)
            nextId, byName[k] = nextId + 1, e.id
            say(line(e))
        end
    end
    local names = { table.unpack(INV) }
    for name in pairs(partLockers()) do names[#names+1]=name end
    local m = inventoryManager()
    if m then
        pcall(function()
            m.Inventories_Garage:ForEach(function(k)
                local tag = k:get().TagName:ToString()
                -- the Toolbox locker is a lootable's container (synced as that lootable); the guest has no container under its tag
                -- Mount.NN: the picture frames' contents (neon signs, posters, trophies); the guest's frames stood empty (playtest
                -- 2026-10-24), an item put in a frame's container shows on the wall at once
                local frame = tag:find("^Stations%.Install%.Mount%.") and os.getenv("PT_MUTATE") ~= "noframes" -- tests only: frames off
                if (tag:find("^Stations%.Install%.Inventory%.") or frame) and not tag:find("Toolbox", 1, true) then
                    names[#names + 1] = tag
                end
            end)
        end)
    end
    if os.getenv("PT_MUTATE") ~= "nocarbox" and tickN % 8 == 2 then for k in pairs(carBoxes()) do names[#names + 1] = k end end
    for _, p in ipairs(names) do
        local id = "I:" .. p
        if not ents[id] then
            local e = register(id, "I", nil, p)
            local c = e.get()
            if alive(c) then
                e.last, e.n = stateOf(e), ids.numItems(c)
                log("PT|loot container %s items=%d state=%d bytes", id, e.n, #e.last)
                say("S|" .. id .. "|" .. e.last)
            else ents[id] = nil end
        end
    end
    for id, e in pairs(ents) do
        if e.kind ~= "I" and not entityAlive(e) then
            say("D|" .. id)
            byName[e.addr], ents[id] = nil, nil
        end
    end
    return not cut
end

-- the full list for a guest that asks (H), sent over several ticks like the scan; "F" ends it
local allQueue
local fullSentAt = -math.huge
local function sendAll()
    allQueue = {}
    for id in pairs(ents) do allQueue[#allQueue + 1] = id end
    log("PT|loot full list for the guest: %d entities", #allQueue)
end
local function sendSome()
    if not allQueue then return end
    local t0 = os.clock()
    while #allQueue > 0 and os.clock() - t0 < BUDGET_HOST do
        local id = table.remove(allQueue)
        local e = ents[id]
        if e and e.kind == "I" then say("S|" .. id .. "|" .. (stateOf(e) or "-;"))
        elseif e and entityAlive(e) then say(line(e)) end
    end
    -- F only once the host has registered everything: the guest purges what the list does not hold
    if #allQueue == 0 and hostScanned then allQueue, fullSentAt = nil, os.clock(); say("F"); log("PT|loot full list sent") end
end

-- guest -----------------------------------------------------------------------------------------------------------

local function near(a, x, y, z)
    local l = a:K2_GetActorLocation()
    return (l.X - x) ^ 2 + (l.Y - y) ^ 2 + (l.Z - z) ^ 2 < MATCH ^ 2
end

-- the guest's own actors of a class with their spots, read once for a burst of claims: the full list on a join claims ~300
-- entities, and reading every candidate's name and class per claim kept the guest busy for over 30 s (2026-10-22)
local cands = {} -- class -> { at = os.clock(), list = { { actor, x, y, z } } }
local function candidates(actors)
    local c = cands[actors]
    if c and os.clock() - c.at < 5 then return c.list end
    local list = {}
    for _, a in ipairs(FindAllOf(actors) or {}) do
        if alive(a) then local l = a:K2_GetActorLocation(); list[#list + 1] = { a, l.X, l.Y, l.Z, common.lease(a) } end
    end
    cands[actors] = { at = os.clock(), list = list }
    return list
end
local made = { claimed = 0, spawned = 0 } -- guest: how its copies came about (a spawned copy where the game had its own is a miss)
local function claim(actors, x, y, z, test)
    for pass = 1, 2 do
        for _, c in ipairs(candidates(actors)) do
            local a = c[1]
            -- the cached spot only narrows the search (items may still be settling); the live spot decides
            if (c[2] - x) ^ 2 + (c[3] - y) ^ 2 + (c[4] - z) ^ 2 < (10 * MATCH) ^ 2 and common.resolve(c[5]) and near(a, x, y, z) then
                local n = a:GetFullName()
                if not isClaimed(a) and test(a) then claimed[n] = common.lease(a); made.claimed = made.claimed + 1; return a end
            end
        end
        -- a miss reads the guest's actors again (its own loot keeps appearing after the load); FindAllOf is cheap
        if pass == 1 and os.clock() - cands[actors].at > 0.25 then cands[actors] = nil else break end
    end
    made.spawned = made.spawned + 1
end

local function spawnLootable(class, x, y, z, yaw)
    local cls = StaticFindObject(class)
    if not cls:IsValid() then pcall(LoadAsset, class); cls = StaticFindObject(class) end
    if not cls:IsValid() then log("PT|loot no class %s", class); return nil end
    local gs = UEHelpers.GetGameplayStatics()
    local xf = xform(x, y, z, yaw)
    local a = gs:BeginDeferredActorSpawnFromClass(UEHelpers.GetWorld(), cls, xf, 1, nil)
    pcall(function() a.ForceSpawnEvenifFailedChanceToLive = true end)
    a = gs:FinishSpawningActor(a, xf)
    if alive(a) then claimed[a:GetFullName()] = common.lease(a) end
    return alive(a) and a or nil
end

local function spawnPart(class, x, y, z, yaw, state)
    local pitch, roll, spec, mesh = state:match("^([^,]*),([^,]*),([^,]*),([^;]*)")
    local cls, arch = ids.asset(class), spec and ids.archetype(spec:match("^[^:]+"))
    if not cls or not arch then log("PT|loot no part class/archetype %s %s", class, tostring(spec)); return nil end
    local inst = ids.system() and StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary"):CreateItemInstance(UEHelpers.GetWorld(), arch, 0)
    ids.setProps(inst, spec)
    local gs = UEHelpers.GetGameplayStatics()
    local xf = xform(x, y, z, yaw, tonumber(pitch), tonumber(roll))
    local a = gs:BeginDeferredActorSpawnFromClass(UEHelpers.GetWorld(), cls, xf, 1, nil)
    a.ItemInstance = inst
    local m = mesh ~= "-" and ids.asset(mesh)
    if m then a.RequestedMesh = m end
    a = gs:FinishSpawningActor(a, xf)
    if alive(a) then claimed[a:GetFullName()] = common.lease(a) end
    return alive(a) and a or nil
end

local function spawnItem(arch, x, y, z, yaw)
    local a = ids.archetype(arch)
    if not a then log("PT|loot no archetype %s", arch); return nil end
    local w = ids.system():SpawnItemActor(UEHelpers.GetWorld(), xform(x, y, z, yaw), a, 0, 0)
    if alive(w) then claimed[w:GetFullName()] = common.lease(w) end
    return alive(w) and w or nil
end

-- guest: a wreck part copy goes on its wreck body copy (the host's parts are attached to theirs). Standalone, a trunk lid
-- could not be opened (hand playtest 2026-10-23). The body is the nearest body copy within 6 m.
-- body positions read once per pass: per part it walked all ~1500 entities and read every body's location, 115-130 ms on the
-- guest every 2 s for the whole session (parts lying away from any body retry forever; live1 2026-11-04 PT|slow loot.lua:960)
local function bodySpots()
    local l = {}
    for _, b in pairs(ents) do
        if b.kind == "B" and alive(b.actor) then l[#l + 1] = { b.actor, b.actor:K2_GetActorLocation() } end
    end
    return l
end
local function attachToBody(e, bodies)
    if e.attached or not entityAlive(e) then return end
    bodies = bodies or bodySpots()
    local l, best, bd = e.actor:K2_GetActorLocation(), nil, 600 ^ 2
    for _, b in ipairs(bodies) do
        local p = b[2]
        local d = (p.X - l.X) ^ 2 + (p.Y - l.Y) ^ 2 + (p.Z - l.Z) ^ 2
        if d < bd and alive(b[1]) then best, bd = b[1], d end
    end
    if not best then return end
    e.attached = pcall(function() e.actor:K2_AttachToActor(best, FName("None"), 1, 1, 1, false) end)
end

local function freezeItem(a)
    if NOROTATE then return end
    for _, wrapped in ipairs(a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))) do
        local c = wrapped.get and wrapped:get() or wrapped
        if alive(c) and c:IsSimulatingPhysics(FName("None")) then c:SetSimulatePhysics(false) end
    end
end

local function onAdd(id, what, x, y, z, yaw, state)
    local e = ents[id]
    if e then return end
    local kind = id:sub(1, 1)
    if not replica.adopt(replicas, id) then return end
    local a
    if kind == "L" then
        a = claim("BP_Lootable_Base_C", x, y, z, function(o) return ids.path2(o:GetClass()) == what end)
            or spawnLootable(what, x, y, z, yaw)
    -- wrecks are rolled per side, so a guest's own body or part is never the host's: always a fresh copy. Claiming them
    -- (the full list now comes after the guest's own wrecks spawned) took parts attached to an own body, and purging that
    -- body took the claimed parts with it (lootsync2, guestparts 2026-10-23)
    elseif kind == "R" then
        a = claim("BP_Spawn_ResourceBase_C", x, y, z, function(o) return ids.path2(o:GetClass()) == what end)
            or spawnLootable(what, x, y, z, yaw)
        if a and state == "br" then applyBroken(a) end
    elseif kind == "B" then
        a = spawnLootable(what, x, y, z, yaw)
        made.spawned = made.spawned + 1
    elseif kind == "P" then
        a = spawnPart(what, x, y, z, yaw, state)
        made.spawned = made.spawned + 1
        if a then local e = register(id, kind, a); applyState(e, state); e.last = partKey(a); attachToBody(e); return end
    else
        a = claim("BP_WorldItem_C", x, y, z, function(o) return alive(o.Instance) and ids.path(o.Instance.Archetype) == what end)
            or spawnItem(what, x, y, z, yaw)
    end
    if not a then log("PT|loot could not make %s %s", id, what); return end
    e = register(id, kind, a)
    if kind == "W" then
        if not NOITEMSTATE and alive(a.Instance) and validItemSpec(state, what) then ids.setProps(a.Instance, state) end
        freezeItem(a)
    end
    if kind == "L" then applyState(e, state) end
end

-- the guest's own random loot is not part of the host's world
local function purge()
    local n = 0
    for _, a in ipairs(FindAllOf("BP_Lootable_Base_C") or {}) do
        if alive(a) and not isClaimed(a) then a:K2_DestroyActor(); n = n + 1 end
    end
    for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
        if alive(a) and not isClaimed(a) and not a:GetAttachParentActor():IsValid() and not tethered(a) then a:K2_DestroyActor(); n = n + 1 end
    end
    for _, c in ipairs({ "LootableTemplatePart", "LootableTemplate", "BP_Spawn_ResourceBase_C" }) do
        for _, a in ipairs(FindAllOf(c) or {}) do
            if alive(a) and not isClaimed(a) then a:K2_DestroyActor(); n = n + 1 end
        end
    end
    log("PT|loot guest purged %d own actors, %d host actors (claimed %d, spawned %d)", n, (function() local c = 0; for _ in pairs(ents) do c = c + 1 end; return c end)(),
        made.claimed, made.spawned)
end

local PURGE = { "BP_Lootable_Base_C", "LootableTemplatePart", "LootableTemplate", "BP_Spawn_ResourceBase_C" }
local function scanGuest()
    local bodies
    for id, e in pairs(ents) do
        if e.kind == "W" and not entityAlive(e) then
            -- picked up here (the item sits in a slot now): tell the host once
            -- the item instance kept while the actor lived: a freed actor's fields are read natively and crash (pcall does not catch it)
            local ok, slot = pcall(function() return common.resolve(e.instLease) and e.inst:GetOuterSlot() end)
            if ok and slot and slot:IsValid() then say("T|" .. id) end
            replica.remove(replicas, id)
            ents[id] = nil
        elseif e.kind == "W" and not e.inst then
            local i = e.actor.Instance
            if alive(i) then e.inst, e.instLease = i, common.lease(i) end
        elseif (e.kind == "P" or e.kind == "R") and not entityAlive(e) then
            -- scrapped or taken here: the host removes its part
            say("T|" .. id)
            replica.remove(replicas, id)
            ents[id] = nil
        elseif e.pending then applyState(e, e.pending) end
        if e.kind == "P" and not e.attached and tickN % 4 == 0 then
            bodies = bodies or bodySpots()
            attachToBody(e, bodies)
        end
    end
    -- ask for the full list until one has come through to its end (F): a host that was not ready yet sent nothing. Not while
    -- lines still come in or wait in the inbox (a second list would flood the channel)
    if not fullAt and head > #inbox and ((tickN % 6 == 0 and os.clock() - lastRx > 5) or tickN % 20 == 0) then say("H") end
    -- the sweeps below destroy or report what no entity claims: only once the whole list is applied (code review 2026-10-23:
    -- with the list spread over seconds they turned unclaimed own items into drops, duplicates on the host)
    if not fullAt then return end
    -- pickups the guest's own game makes now (spawners): not the host's. Items the guest dropped lie next to it: they become the host's.
    local pawn = UEHelpers.GetPlayerController().Pawn
    local p = alive(pawn) and pawn:K2_GetActorLocation()
    -- its own random lootables keep appearing for a while after the join; every 2 s: these scans took 300-400 ms of each
    -- 500 ms tick in a zone and the guest could not even turn its camera (local playtest 2026-10-22, PT|slow loot.lua)
    -- still 330 ms every 2 s in play, and the game stops spawning its own loot soon after the join: the first 90 s only
    -- one class per tick, each every 2 s: all four in one tick held 150-240 ms frames for the whole 90 s (friend session
    -- 2026-11-03, guest PT|slow loot.lua:961 every 2 s after the join)
    if os.clock() - fullAt < 90 then
        local c = PURGE[tickN % #PURGE + 1]
        for _, a in ipairs(FindAllOf(c) or {}) do
            if alive(a) and not isClaimed(a) then a:K2_DestroyActor() end
        end
    end
end

local function scanDrops()
    -- A drop is reported once; keep it local until the host accepts gameplay intents.
    if not fullAt or (os.getenv("PT_MUTATE") ~= "nobaselinewait" and net.hostSupports("intents") and net.lifecycle() ~= "active") then return end
    local pc = UEHelpers.GetPlayerController()
    local pawn = alive(pc) and pc.Pawn
    local p = alive(pawn) and pawn:K2_GetActorLocation()
    for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
        local n = alive(a) and alive(a.Instance) and not isClaimed(a) and not a:GetAttachParentActor():IsValid() and not tethered(a) and common.identity(a)
        if n and not reported[n] then
            local l = a:K2_GetActorLocation()
            local adopt = ADOPT
            local v = adopt and not net.hostSupports("drop-velocity") and a:GetVelocity()
            if v and v.X ^ 2 + v.Y ^ 2 + v.Z ^ 2 > 100 then
                -- still falling: kept, the host's copy is spawned where it comes to rest (a mid-air report hung both copies in the air)
            elseif p and (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 + (l.Z - p.Z) ^ 2 < DROP ^ 2 then
                reported[n] = true
                local r, v, av = a:K2_GetActorRotation(), a:GetVelocity(), { X = 0, Y = 0, Z = 0 }
                for _, wrapped in ipairs(a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))) do
                    local c = wrapped:get()
                    if c:IsSimulatingPhysics(FName("None")) then
                        v, av = c:GetPhysicsLinearVelocity(FName("None")), c:GetPhysicsAngularVelocityInDegrees(FName("None"))
                        break
                    end
                end
                local drop = string.format("N|%s|%.1f|%.1f|%.1f|%.1f", ids.path(a.Instance.Archetype), l.X, l.Y, l.Z, r.Yaw)
                if net.hostSupports("drop-velocity") then
                    drop = drop .. string.format("|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f", r.Pitch, r.Roll, v.X, v.Y, v.Z, av.X, av.Y, av.Z)
                end
                if adopt then
                    dropKey = dropKey + 1
                    pendingDrops[tostring(dropKey)] = common.lease(a)
                    drop = drop .. "|" .. dropKey
                    if not NOITEMSTATE and net.hostSupports("drop-velocity") and net.hostSupports("item-state") then drop = drop .. "|" .. ids.spec(a.Instance) end
                end
                say(drop)
                log("PT|loot guest drop %s told the host", ids.path(a.Instance.Archetype):match("[^/]+$"))
                -- without adoption the host's copy comes back as an "A": keeping this one too left two tools on the ground (a dupe)
                if not adopt and os.getenv("PT_MUTATE") ~= "nodropfix" then a:K2_DestroyActor() end
            else
                a:K2_DestroyActor()
            end
        end
    end
end

local poseRows, poseBytes = {}, 0
local function sendPose(e, l, r, final)
    e.poseSerial = (e.poseSerial or 0) + 1
    local row = string.format("%s|%d|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f", e.id, e.poseSerial, l.X, l.Y, l.Z, r.Yaw, r.Pitch, r.Roll)..string.format("|%.5f",os.clock())
    local legacy = string.format("M|%s|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f", e.id, l.X, l.Y, l.Z, r.Yaw, r.Pitch, r.Roll)
    if not final then
        if poseBytes + #row < 850 then poseRows[#poseRows + 1], poseBytes = row, poseBytes + #row + 1
        else final = true end -- Overflow remains ordered and reliable, rather than replacing an earlier batch.
    end
    for _, pc in ipairs(net.guests()) do
        if net.peerSupports(pc, "motion") then
            if final then net.toGuest(pc, "g.loot.pose", net.worldToken() .. "\n" .. (net.peerSupports(pc,"item-clock")and row or row:match("^(.*)|[^|]*$"))) end
        else net.toGuest(pc, "g.loot.b", legacy) end
    end
end
local function acceptPoses(_, data)
    if common.netMode() ~= "client" or not net.hostSupports("motion") then return end
    local epoch, rows = data:match("^([^\n]+)\n(.+)$")
    if epoch ~= net.worldToken() then return end
    if replicas.epoch == nil then replicas.epoch = epoch end
    if replicas.epoch ~= epoch then
        replicas = replica.new(epoch)
        for id, e in pairs(ents) do if e.kind == "W" then replica.adopt(replicas, id) end end
    end
    for row in rows:gmatch("[^\n]+") do
        local f = {}; for v in row:gmatch("[^|]+") do f[#f + 1] = v end
        local valid = #f == 8 or (#f == 9 and net.hostSupports("item-clock"))
        for i = 2, #f do
            local n = tonumber(f[i]); if not n or n ~= n or math.abs(n) > (i == 2 and 9007199254740991 or 1e8) then valid = false end
            f[i] = n
        end
        if valid then replica.offer(replicas, epoch, f[1], f[2], f) end
    end
end
net.on("g.motion.items", acceptPoses)
net.on("g.loot.pose", acceptPoses)

-- host: world items send rotation too; a tire can tip over without moving its centre.
local function turned(a, b) return math.abs((a - b + 180) % 360 - 180) > 1 end
local function scanMoves()
    if NOFALL or not readyFor then return end
    poseRows, poseBytes = {}, 0
    -- a resting item is read every ~5 s, a new or moving one every tick (all of them each tick held host frames, playtest 2026-10-31)
    local now = os.clock()
    for id, e in pairs(ents) do
        if e.kind == "W" and (now < (e.hotUntil or 0) or now >= (e.moveAt or 0)) and entityAlive(e) then
            e.moveAt = now + 4 + math.random() * 2
            local l, r = e.actor:K2_GetActorLocation(), e.actor:K2_GetActorRotation()
            local p = e.pos
            if not p or (l.X - p[1]) ^ 2 + (l.Y - p[2]) ^ 2 + (l.Z - p[3]) ^ 2 > 9
                or (not NOROTATE and (turned(r.Pitch, p[4]) or turned(r.Yaw, p[5]) or turned(r.Roll, p[6]))) then
                e.pos, e.hotUntil = { l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll }, now + 5
                e.movedAt, e.moving = now, true
                if p or not NOROTATE then sendPose(e, l, r, false) end
            elseif e.moving and now - e.movedAt >= 0.3 then
                e.moving = false
                sendPose(e, l, r, true)
            end
        end
    end
    if #poseRows > 0 then
        for _,pc in ipairs(net.guests())do
            local rows=poseRows
            if not net.peerSupports(pc,'item-clock')then
                rows={};for _,row in ipairs(poseRows)do rows[#rows+1]=row:match('^(.*)|[^|]*$')end
            end
            net.toGuest(pc,'g.motion.items',net.worldToken()..'\n'..table.concat(rows,'\n'))
        end
    end
end

-- where this side's players stand (own pawn; on the host also the guests')
local function playerSpots()
    local spots = {}
    local pcs = net.guests()
    pcs[#pcs + 1] = UEHelpers.GetPlayerController()
    for _, pc in ipairs(pcs) do
        local pawn = alive(pc) and pc.Pawn
        if alive(pawn) then spots[#spots + 1] = pawn:K2_GetActorLocation() end
    end
    return spots
end
local REACH = 3000 -- uu: a wreck part changes only by a player's hands or tools, so farther ones are not read
local function inReach(a, spots)
    local l = a:K2_GetActorLocation()
    for _, p in ipairs(spots) do
        if (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 + (l.Z - p.Z) ^ 2 < REACH ^ 2 then return true end
    end
    return false
end

-- both: contents changed here since we last looked (the game moved items in or out)
local function scanChanges()
    local spots = tickN % 4 == 1 and playerSpots()
    -- the other parts, round robin: each one at least every ~30 s, 3 per tick (10 per tick, every 10 s, was ~0.5 s of each
    -- minute on both sides in a zone; FPS hunt 2026-11-01)
    local far, farR, farW = 3, 6, 3
    local now = os.clock()
    for id, e in pairs(ents) do
        if e.kind == "R" then
            -- a resource breaks under a player's tool: near ones every tick (the near list every 2 s), the rest round robin
            if spots and listening then e.near = entityAlive(e) and inReach(e.actor, spots) end
            local due = e.near or (farR > 0 and now - (e.at or 0) > 10)
            if due and not e.near then farR = farR - 1; e.at = now end
            if due and listening and entityAlive(e) then
                local b = brokenOf(e.actor)
                if b ~= (e.br or false) then e.br = b; say("S|" .. id .. "|" .. (b and "br" or "-")) end
            end
        elseif e.kind=="W" then
            if spots and listening then e.near=entityAlive(e) and inReach(e.actor,spots) end
            local due=e.near or (farW>0 and now-(e.stateAt or 0)>5)
            if due and not e.near then farW=farW-1 end
            if due and listening and entityAlive(e) and alive(e.actor.Instance) then
                e.stateAt=now
                local s=ids.spec(e.actor.Instance)
                if s~=e.itemState then
                    e.itemState=s
                    for _,pc in ipairs(net.guests())do if net.peerSupports(pc,'item-state')then net.toGuest(pc,'g.loot.b','S|'..id..'|'..s)end end
                end
            end
        elseif e.kind == "P" then
            -- a part's full key (fuel, wear, contents) is costly (~0.4 ms) and changes slowly: every 2 s near a player
            -- (all 206 parts of a zone took 60-250 ms per check, 2026-10-22)
            local close = spots and entityAlive(e) and inReach(e.actor, spots)
            local due = close or (far > 0 and now - (e.at or 0) > 30)
            if due and not close then far = far - 1 end
            if due then e.at = now end
            if due and entityAlive(e) and alive(e.actor.ItemInstance) then
                e.at = os.clock()
                -- siphoned fuel, worn durability: the part's item state
                local s = partKey(e.actor)
                if s ~= e.last then
                    e.last = s
                    say("S|" .. id .. "|" .. partState(e.actor))
                end
            end
        elseif not e.busy and not e.pending and (listening or e.last ~= nil) and ((e.box and dirty[e.box]) or now >= (e.nextAt or 0)) then
            -- an untouched container is read every ~5 s; its slot events (dirty) bring it in at once (all of them each tick
            -- held host frames 30-40 ms, playtest 2026-10-31)
            e.nextAt = now + 4 + math.random() * 2
            local c = e.get()
            if alive(c) then e.box = c:GetAddress() end
            local r = alive(c) and flagsOf(e) or nil
            if alive(c) then
                dirty[e.box] = nil
                e.n, e.rolled = ids.numItems(c), r
                local s = stateOf(e)
                if s and s ~= e.last then
                    e.last = s
                    log("PT|loot send S %s", id)
                    say("S|" .. id .. "|" .. s)
                end
            end
        end
    end
    dirty = {} -- containers nobody tracks (the player's own hands, crafting) are not kept
end

-- Active containers use the same wire state, but do not wait for the background discovery tick.
LoopInGameThreadWithDelay(100,function()
    local mode=common.netMode()
    if mode~='listen'and mode~='client'then return end
    if mode=='client'and (not fullAt or net.lifecycle()~='active')then return end
    if mode=='listen'and not readyFor then return end
    for id,e in pairs(ents)do
        if (e.kind=='I'or e.kind=='L')and not e.busy and not e.pending and e.last then
            local c=e.get()
            if alive(c)and(dirty[c:GetAddress()]or menuShows(c))then
                local state=stateOf(e)
                if state and state~=e.last then e.last=state;say('S|'..id..'|'..state)end
            end
        end
    end
    if not DEAF then flush()end
end)
-- overlay: what the other player took from or put into a container
local function announce(e, before)
    local d = (e.n or 0) - (before or 0)
    if d ~= 0 then log("PT|loot overlay %s %s -> %s settled=%s", e.id, tostring(before), tostring(e.n), tostring(ov.settled())) end
    if d == 0 or not ov.settled() then return end
    local what = "a container"
    pcall(function()
        what = e.kind == "I" and e.id:match("^I:Inventory_(.+)$"):gsub("_", " "):lower()
            or e.actor:GetClass():GetFName():ToString():gsub("^BP_Lootable_", ""):gsub("_C$", ""):gsub("_", " "):lower()
    end)
    if d < 0 then ov.post("%d item{s} taken from " .. what, "info", "loot.out." .. e.id, -d)
    else ov.post("%d item{s} put into " .. what, "info", "loot.in." .. e.id, d) end
end

-- messages --------------------------------------------------------------------------------------------------------

local function handle(l, guest, pc)
    local f = {}
    for p in (l .. "|"):gmatch("([^|]*)|") do f[#f + 1] = p end
    local op, id = f[1], f[2]
    if op == "P" then
        local buf = partial[id] or {}
        partial[id] = buf
        buf[tonumber(f[3])] = f[5] or ""
        local n = 0
        for _ in pairs(buf) do n = n + 1 end
        if n < tonumber(f[4]) then op = nil
        else
            partial[id] = nil
            local s = table.concat(buf, ",")
            op, f, l = "S", { "S", id, s }, "S|" .. id .. "|" .. s
        end
    end
    if op == nil then
    elseif op == "H" and not guest then
        -- a list under way is not restarted by the guest asking again, nor one just finished (its H crossed our F)
        if not allQueue and os.clock() - fullSentAt > 10 then sendAll() end
    elseif guest and op == "A" then
        onAdd(id, f[3], tonumber(f[4]), tonumber(f[5]), tonumber(f[6]), tonumber(f[7]), f[8])
    elseif guest and op == "F" then
        -- the purge (a sweep over every lootable) runs for the first full list only
        if not fullAt then fullAt = os.clock(); purge() end
        net.baselineComplete("loot")
    elseif op == "S" and ents[id] then
        local layoutIntent=not guest and ents[id].kind=='P' and f[3]:find(';@',1,true)
        if layoutIntent and (not pc or not net.peerSupports(pc,'wreck-state')or not validLayout(f[3]:match(';(.*)$')))then return end
        log("PT|loot got S %s (%s)", id, f[3]:sub(1, 80))
        local before = ents[id].n
        applyState(ents[id], f[3])
        announce(ents[id], before)
        -- the guest's change: the host applies it and the other players see it
        if not guest then say(layoutIntent and ('S|'..id..'|'..partState(ents[id].actor)) or l) end
    elseif op == "S" and guest then
        -- a container of the game's that the guest has not registered yet
        local name = id:match("^I:(.+)$")
        log("PT|loot got new container %s (%d bytes)", id, #f[3])
        if name then applyState(register(id, "I", nil, name), f[3]) end
    elseif op == "D" and guest then
        replica.remove(replicas, id)
        if not ents[id] then return end
        local e = ents[id]
        ents[id] = nil
        if entityAlive(e) then e.actor:K2_DestroyActor() end
        if e.kind == "W" and ov.settled() then ov.post(ov.other() .. " picked up an item", "info", "pick") end
    elseif op == "M" and guest and ents[id] and entityAlive(ents[id]) then
        if #f ~= 8 then return end
        for i = 3, 8 do
            local v = tonumber(f[i]); if not v or v ~= v or math.abs(v) > 1e8 then return end
        end
        pcall(function()
            if ents[id].kind == "W" then freezeItem(ents[id].actor) end
            local e = ents[id]
            local p, r = { X = tonumber(f[3]), Y = tonumber(f[4]), Z = tonumber(f[5]) }, { Pitch = tonumber(f[7]) or 0, Yaw = tonumber(f[6]), Roll = tonumber(f[8]) or 0 }
            e.motion = e.motion or {}
            itemMotion.push(e.motion, p, r, os.clock(), e.actor:K2_GetActorLocation(), e.actor:K2_GetActorRotation())
        end)
    elseif op == "N" and not guest then
        local count = #f
        local itemSpec
        if count == 16 then
            if not pc or not net.peerSupports(pc, "item-state") or not validItemSpec(f[16], f[2]) then return end
            itemSpec, count = f[16], 15
        end
        local key = (count == 7 or count == 15) and f[count] or nil
        if key then
            if not key:match("^%d+$") then return end
            if count == 15 and (not pc or not net.peerSupports(pc, "drop-velocity")) then return end
            count = count - 1
        end
        if count ~= 6 and count ~= 14 then return end
        for i = 3, count do
            local v = tonumber(f[i])
            if not v or v ~= v or math.abs(v) > (i <= 5 and 1e8 or 100000) then return end
        end
        local w = spawnItem(f[2], tonumber(f[3]), tonumber(f[4]), tonumber(f[5]), tonumber(f[6]))
        if w and itemSpec and alive(w.Instance) then ids.setProps(w.Instance, itemSpec) end
        if w and count == 14 then
            w:K2_SetActorRotation({ Pitch = tonumber(f[7]), Yaw = tonumber(f[6]), Roll = tonumber(f[8]) }, true)
            local v, av = { X = tonumber(f[9]), Y = tonumber(f[10]), Z = tonumber(f[11]) }, { X = tonumber(f[12]), Y = tonumber(f[13]), Z = tonumber(f[14]) }
            for _, wrapped in ipairs(w:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))) do
                local c = wrapped:get()
                if c:IsSimulatingPhysics(FName("None")) then
                    c:SetPhysicsLinearVelocity(v, false, FName("None"))
                    c:SetPhysicsAngularVelocityInDegrees(av, false, FName("None"))
                end
            end
        end
        log("PT|loot guest's drop %s spawned=%s", f[2]:match("[^/]+$"), tostring(w ~= nil))
        if w and key then -- Adoption keys follow the optional velocity fields; pitch is never an actor key.
            local e = register("W" .. nextId, "W", w)
            nextId, byName[w:GetAddress()] = nextId + 1, e.id
            e.hotUntil = os.clock() + 5
            say("K|" .. e.id .. "|" .. key)
        end
    elseif op == "K" and guest then
        local a = common.resolve(pendingDrops[f[3]])
        pendingDrops[f[3]] = nil
        if alive(a) and not ents[id] and replica.adopt(replicas, id) then
            claimed[a:GetFullName()] = common.lease(a)
            register(id, "W", a)
            freezeItem(a)
        end
    elseif op == "T" and not guest and ents[id] then
        local e = ents[id]
        ents[id], byName[e.addr] = nil, nil
        if entityAlive(e) then e.actor:K2_DestroyActor() end
        if e.kind == "W" then ov.post(ov.other() .. " picked up an item", "info", "pick") end
        say("D|" .. id)
    end
end

-- lines from the other side wait here and are worked off a few ms per frame: the host's full list on a join is hundreds of
-- lines and took 470-590 ms in one go (the guest froze, 2026-10-22)
net.on("g.loot.b", function(pc, data)
    if DEAF then return end
    lastRx = os.clock()
    local lease = common.lease(pc)
    for l in data:gmatch("[^\n]+") do
        if l == "H" then readyFor = pc:GetAddress() end
        inbox[#inbox + 1] = { line = l, lease = lease }
    end
end)
local BUDGET = 0.004
-- A container being filled (applyState's steps) goes first, a few ms a frame; the lines after it wait their turn.
LoopInGameThreadWithDelay(16, function()
    if head > #inbox and #filling == 0 then return end
    local guest, t = common.netMode() == "client", os.clock()
    while os.clock() - t < BUDGET do
        local f = filling[1]
        if f then
            local ok, err = pcall(f.steps[f.i])
            if not ok then log("PT|error loot fill %s %s", f.e.id, tostring(err)) end
            f.i = f.i + 1
            if f.i > #f.steps then
                table.remove(filling, 1)
                f.e.busy = nil
                pcall(f.finish)
                pcall(announce, f.e, f.before)
                log("PT|loot filled %s: %d steps over %.1f s", f.e.id, #f.steps, os.clock() - f.t0)
            end
        elseif head <= #inbox then
            local item = inbox[head]
            local l = item.line
            inbox[head], head = nil, head + 1
            local t1 = os.clock()
            local ok, err = pcall(handle, l, guest, common.resolve(item.lease))
            if not ok then log("PT|error loot line %s %s", l:sub(1, 40), tostring(err)) end
            -- one line that alone holds the frame (playtest 2026-10-24: up to 863 ms in this loop on a big save)
            if os.clock() - t1 > 0.05 then log("PT|slow loot line %.0f ms %d bytes %s", (os.clock() - t1) * 1000, #l, l:sub(1, 60)) end
        else
            break
        end
    end
    if head > #inbox then inbox, head = {}, 1 end
end)

-- where the tick's time goes, one line a minute (FPS hunt 2026-11-01: ~1 s a minute on both sides in a zone)
local spent, spentAt = {}, os.clock()
local function timed(name, fn, ...)
    local t = os.clock()
    local a, b = fn(...)
    spent[name] = (spent[name] or 0) + os.clock() - t
    return a, b
end
local function tick()
    tickN = tickN + 1
    if os.clock() - spentAt > 60 then
        local l = {}
        for k, v in pairs(spent) do l[#l + 1] = string.format("%s=%.0f", k, v * 1000) end
        table.sort(l)
        log("PT|loot time ms/min %s", table.concat(l, " "))
        spent, spentAt = {}, os.clock()
    end
    if listening or common.netMode() == "client" then -- sessions only (Q7)
        local ok, closed = pcall(timed, "menu", watchMenu)
        if ok and closed then
            for _, e in pairs(ents) do if e.pending and e.box == closed then applyState(e, e.pending) end end
        end
    end
    local mode = common.netMode()
    if mode == "listen" then
        local here = false
        for _, pc in ipairs(net.guests()) do here = here or pc:GetAddress() == readyFor end
        if not here then readyFor, allQueue, fullSentAt = nil, nil, -math.huge end
        listening = #net.guests() > 0
        if not listening then return end
        -- discovery every 2 s: it took ~340 ms of each 500 ms tick in a zone (local playtest 2026-10-22); until the guest's
        -- first full list it runs every tick
        if tickN % 4 == 2 or not hostScanned then hostScanned = timed("scanHost", scanHost) end
        timed("send", sendSome)
    elseif mode == "client" then
        listening = false
        if not ids.alive(UEHelpers.GetPlayerController()) then return end
        timed("scanGuest", scanGuest)
    else
        return
    end
    timed("changes", scanChanges)
    if not DEAF then timed("flush", flush) else out = {} end
end

local discoverAt, dropsDirty = 0, true
-- Native spawn entry points run on the game thread; object-allocation callbacks can run on the loading thread.
for _, name in ipairs({ "SpawnItemActor", "SpawnItemInstanceActor" }) do
    RegisterHook("/Script/PenDriverInventory.InventorySystem:" .. name, function() dropsDirty = true end)
end
LoopInGameThreadWithDelay(50, function()
    local mode, now = common.netMode(), os.clock()
    if mode == "listen" and listening then
        if dropsDirty or now >= discoverAt then dropsDirty = not scanWorldItems(); discoverAt = now + 1 end
        if not DEAF then flush() end -- Creation precedes any pose or final edge for that ID.
        scanMoves()
        if not DEAF then flush() end
    elseif mode == "client" and fullAt then
        if dropsDirty or now >= discoverAt then dropsDirty = false; scanDrops(); discoverAt = now + 1 end
        if not DEAF then flush() end
    end
end)
LoopInGameThreadWithDelay(16, function()
    if common.netMode() ~= "client" then return end
    for id, e in pairs(ents) do
        local pose = replica.take(replicas, id)
        if pose and entityAlive(e) then
            freezeItem(e.actor)
            e.motion = e.motion or {}
            e.motion.lastReceivedAt=os.clock()
            local p,r={X=pose[3],Y=pose[4],Z=pose[5]},{Pitch=pose[7],Yaw=pose[6],Roll=pose[8]}
            if pose[9]then itemMotion.pushTimed(e.motion,p,r,pose[9],os.clock(),e.actor:K2_GetActorLocation(),e.actor:K2_GetActorRotation())
            else itemMotion.push(e.motion,p,r,os.clock(),e.actor:K2_GetActorLocation(),e.actor:K2_GetActorRotation())end
        end
        local m = e.motion
        if m and entityAlive(e) then
            local a, b, u = itemMotion.sample(m, os.clock())
            local p = {}
            for _, k in ipairs({"X", "Y", "Z"}) do p[k] = a.p[k] + (b.p[k] - a.p[k]) * u end
            local r = KML:RLerp(a.r, b.r, u, true)
            e.actor:K2_SetActorLocationAndRotation(p, r, false, {}, true)
            if (not m.lastReceivedAt or os.clock()-m.lastReceivedAt>1) and (#m==1 or (u>=1 and b==m[#m]))then e.motion=nil end
        end
    end
end)

RegisterLoadMapPreHook(function() replicas = replica.new(nil) end)
RegisterLoadMapPostHook(function()
    hostScanned, fullAt, allQueue, readyFor, lastRx, fullSentAt = false, nil, nil, nil, -math.huge, -math.huge
    ents, byName, claimed, reported, out, partial, partIds, skip = {}, {}, {}, {}, {}, {}, {}, {}
    inbox, head, cands, made = {}, 1, {}, { claimed = 0, spawned = 0 }
end)

LoopInGameThreadWithDelay(500, function()
    local ok, err = pcall(tick)
    if not ok then log("PT|error loot %s", tostring(err)) end
end)

-- host: a backlog (the first scan, a full list) is worked off every 50 ms instead of every 500 ms, so a joining guest gets
-- the world in about a second without a long frame
LoopInGameThreadWithDelay(50, function()
    if not listening or (hostScanned and not allQueue) then return end
    local ok, err = pcall(function()
        if common.netMode() ~= "listen" or #net.guests() == 0 then return end
        -- one of the two per call: each has its own budget, both in one frame went past a frame's worth
        if not hostScanned then hostScanned = scanHost() else sendSome() end
        if not DEAF then flush() else out = {} end
    end)
    if not ok then log("PT|error loot backlog %s", tostring(err)) end
end)

-- for guestparts.lua: the shared id of a wreck part's actor, and the actor of an id
function M.idOf(a)
    local n = alive(a) and a:GetFullName()
    local id = n and partIds[n]
    local e = id and ents[id]
    if e and e.kind == "P" and e.name == n and entityAlive(e) and common.identity(a) == e.lease.key then return id end
end
function M.actorOf(id)
    local e = ents[id]
    return e and e.kind == "P" and entityAlive(e) and e.actor or nil
end

-- Wreck presentation/layout extends the author's inventory messages only for negotiated peers.
local wreckPending,wreckSent,wreckBodies,wreckActive={},{},{},false
RegisterLoadMapPreHook(function()wreckPending,wreckSent,wreckBodies,wreckActive={},{},{},false end)
local VEHICLE='/Game/Gameplay/Vehicles/Templates/BaseActors/BP_Template_BaseVehicle.BP_Template_BaseVehicle_C'
local TRUNK='/Game/Gameplay/Vehicles/Templates/BaseActors/BP_TemplatePart_Trunk.BP_TemplatePart_Trunk_C'
local function assetName(o)return alive(o) and ids.path2(o) or '-' end
local function safeAsset(p)return p=='-' or (#p<1024 and p:match('^/Game/[%w_/%.-]+$')~=nil) end
local function wreckTint(a)
    if #a.DynamicMaterialInstances == 0 then a:SetupMaterials() end
    a:SetupTintOnVehicleAndParts()
    local meshClass=StaticFindObject('/Script/Engine.StaticMeshComponent')
    for _,w in ipairs(a:GetAllTemplateParts())do
        local part=w:get()
        if alive(part)then
            for _,v in ipairs(part:K2_GetComponentsByClass(meshClass))do
                local mesh=v:get()
                for i=0,mesh:GetNumMaterials()-1 do
                    local mid=mesh:GetMaterial(i)
                    if not mid:IsA(StaticFindObject('/Script/Engine.MaterialInstanceDynamic'))then mid=mesh:CreateDynamicMaterialInstance(i,nil,FName('None'))end
                    require('itemtint').material(mid,a.SelectedPaintPalette,a.SelectedDecalPalette)
                end
            end
        end
    end
end
net.on('g.loot.wreck',function(_,data)
    if common.netMode()~='client' or not net.hostSupports('wreck-state') or #data>32000 then return end
    local epoch,id,kind,body=data:match('^([^|]+)|([BP]%d+)|([BJTC])|(.*)$')
    if epoch~=net.worldToken() or not id then return end
    if kind=='B' then
        local paint,decal=body:match('^([^|]+)|([^|]+)$')
        if not paint or not safeAsset(paint) or not safeAsset(decal) then return end
    elseif kind=='J' then
        if not body:match('^B%d+|[%w_. %-]+$') or #body>256 then return end
    elseif kind=='T' then
        local state,strength,opened=body:match('^(%d+),(%d+),([01])$')
        if not state or tonumber(state)>255 or tonumber(strength)>1000000 then return end
    elseif kind=='C' and not validLayout(body)then return end
    wreckPending[id..kind]={id=id,kind=kind,body=body}
end)
LoopInGameThreadWithDelay(16,function()
    if common.netMode()~='client' then return end
    local start=os.clock()
    local linking=false
    for _,row in pairs(wreckPending)do if row.kind=='B' or row.kind=='J'then linking=true;break end end
    for key,row in pairs(wreckPending)do
        local e=ents[row.id];local a=e and entityAlive(e) and e.actor
        if a then
            local done=true
            if row.kind=='B' and e.kind=='B' and a:IsA(StaticFindObject(VEHICLE))then
                local p,d=row.body:match('^([^|]+)|([^|]+)$')
                local paint=p~='-' and ids.asset(p);local decal=d~='-' and ids.asset(d)
                if (p=='-' or paint)and(d=='-' or decal)then
                    if paint then a.SelectedPaintPalette=paint end
                    if decal then a.SelectedDecalPalette=decal end
                    wreckTint(a)
                else done=false end
            elseif row.kind=='J' and e.kind=='P' then
                local parent,socket=row.body:match('^([^|]+)|(.+)$');local b=ents[parent]
                if b and entityAlive(b)then
                    a:K2_AttachToActor(b.actor,FName('None'),1,1,1,false);a.MySocket=FName(socket)
                    wreckBodies[parent]=common.lease(b.actor)
                else done=false end
            elseif row.kind=='T' and e.kind=='P' and a:IsA(StaticFindObject(TRUNK))and alive(a.BP_LockedComponent)then
                local state,strength,opened=row.body:match('^(%d+),(%d+),([01])$')
                a.BP_LockedComponent:SetLockStrength(tonumber(strength))
                local wasOpen=a.AnimStateOpened;a.AnimStateOpened=opened=='1'
                if a.AnimStateOpened and not wasOpen then a.OpenTrunkTimeline:PlayFromStart();a:SetHighlightOpened()
                elseif tonumber(state)~=0 then a:InitializeTrunk(1)end
                a:UpdateTrunkState()
            elseif row.kind=='C' and e.kind=='P' then
                local c=partBox(a)
                if c and not linking and not next(wreckBodies) then ids.applyLayout(c,row.body);e.wreckLayout=row.body;e.last=partKey(a)
                else done=false end
            end
            if done then wreckPending[key]=nil end
        end
        if os.clock()-start>0.002 then break end
    end
    for id,lease in pairs(wreckBodies)do
        local a=common.resolve(lease)
        local cls=StaticFindObject(VEHICLE)
        if a and alive(cls)and a:IsA(cls)then
            local e=ents[id]
            if not e.wreckLinked then a:LinkTrunkAndTrunkContents();e.wreckLinked=true end
            wreckTint(a)
        end
        wreckBodies[id]=nil
        if os.clock()-start>0.002 then break end
    end
end)
LoopInGameThreadWithDelay(500,function()
    local mode=common.netMode()
    if mode~='listen' and mode~='client' then return end
    if mode=='client' and not net.hostSupports('wreck-state')then return end
    local guests=mode=='listen' and net.guests() or {}
    local vehicle,trunk=StaticFindObject(VEHICLE),StaticFindObject(TRUNK)
    local spots,far,now=playerSpots(),3,os.clock()
    -- a guest's copy of a part with storage stays empty until its first C row. The round robin ran (and stamped wreckAt) while no
    -- guest could take rows yet, then sent 3 parts per tick: a far trunk stayed empty 20-30 s after the guest went active
    -- (lootcar 2026-11-07). Now each part's first row goes out as soon as a guest is active, 4 ms of layouts per tick.
    local active=false
    for _,pc in ipairs(guests)do active=active or (net.peerSupports(pc,'wreck-state')and net.lifecycle(pc)=='active')end
    if active and not wreckActive then for _,x in pairs(ents)do x.wreckAt=nil end end
    wreckActive=active
    local firstBudget=now+0.004
    local function send(id,kind,body)
        local data=net.worldToken()..'|'..id..'|'..kind..'|'..body
        for _,pc in ipairs(guests)do
            if net.peerSupports(pc,'wreck-state')and net.lifecycle(pc)=='active' then
                local key=common.identity(pc)..'|'..id..kind
                if wreckSent[key]~=data then net.toGuest(pc,'g.loot.wreck',data);wreckSent[key]=data end
            end
        end
    end
    for id,e in pairs(ents)do
        if (e.kind=='B' or e.kind=='P')and entityAlive(e)and(e.kind~='P' or alive(e.actor.ItemInstance))then
            local a=e.actor
            if e.pendingPartState then
                local c=partBox(a)
                if c and not menuShows(c)then local s=e.pendingPartState;e.pendingPartState=nil;applyState(e,s)end
            end
            -- paint, socket and trunk rows read only when the contents row is due: read for every body and part every 500 ms they
            -- were ~3.4 s of each minute on the host and a 30-77 ms hitch about every second (friend session 2026-11-08, loot.lua:1375)
            local near=mode=='listen' and active and inReach(a,spots)
            local first=mode=='listen' and active and not e.wreckAt and os.clock()<firstBudget
            if mode=='listen' and (near or first or (active and far>0 and now-(e.wreckAt or 0)>10)) then
                if not near and not first then far=far-1 end;e.wreckAt=now
                if e.kind=='B' and alive(vehicle)and a:IsA(vehicle)then
                    send(id,'B',assetName(a.SelectedPaintPalette)..'|'..assetName(a.SelectedDecalPalette))
                elseif e.kind=='P' then
                    local parent=a:GetAttachParentActor();local parentId=alive(parent)and byName[parent:GetAddress()]
                    if parentId and ents[parentId]and ents[parentId].kind=='B'then send(id,'J',parentId..'|'..a.MySocket:ToString())end
                    if alive(trunk)and a:IsA(trunk)then
                        local state,strength={},{};a:GetTrunkState(state);a.BP_LockedComponent:GetLockStrength(strength)
                        send(id,'T',state['Current State']..','..strength.Strength..','..(a.AnimStateOpened and '1'or '0'))
                    end
                    local c=partBox(a);if c then local body=ids.layout(c);if validLayout(body)then send(id,'C',body)end end
                end
            elseif mode=='client' and e.kind=='P' and e.wreckLayout and not wreckPending[id..'C']then
                local c=partBox(a)
                if c then local body=ids.layout(c);if body~=e.wreckLayout then
                    e.wreckLayout=body;net.toHost('g.loot.b','S|'..id..'|'..partState(a,true))
                end end
            end
        end
    end
end)
return M
