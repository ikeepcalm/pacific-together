-- PT2 visual sync: things one player sees that the other did not (docs/spikes/PT2-visual.md). Messages g.vis.*.
--   levels  the host's run-time streaming sublevels (the Fig DLC garage dressing: 876 props, candles, graffiti) are loaded on the guest too
--           (g.vis.lv, ULevelStreamingDynamic::LoadLevelInstance, the call the game made on the host).
--   paint   paint, decal palette and tinting of every installed car part: the guest builds its parts from archetypes, so a part the host
--           repainted stayed stock on the guest (g.vis.paint, BP_TintableComponent SetPaint/SetDecal/SetTintingEnabled, the game's own setters).
--   props   the zone's procedural dressing exists on the host only (the run's spawn pass never runs on a guest): buildings (BuildingFrame),
--           prefab meshes (StaticMeshActor), doors, destructibles, lights, posters, decals, poles. The host lists them (class or mesh,
--           transform, door state, broken flag) and the guest spawns and keeps copies (g.vis.p, g.vis.hello). Copies have no gameplay of their
--           own, except doors: the guest's E on a door copy is pressed on the host's door (g.vis.door). Smashing a crate does not reach
--           the host (known gap).
-- Inert in single player (Q7): nothing runs without a listening host with a guest, or a guest.
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local safety = require("safety")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "novisual", mutate = os.getenv("PT_MUTATE") } -- the test mutation switches the module off
M.zone = os.getenv("PT_VISUAL_ZONE") ~= "0" -- the zone props mirror: on (2026-10-23, host sweep cached and spread, guest 8 ms per tick); PT_VISUAL_ZONE=0 turns it off

local RF_WasLoaded = 0x00080000 -- placed in the map file: the guest has it already

local function live(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
-- where the time goes, one line a minute (FPS hunt 2026-11-01: ~1.1 s a minute on the host in a zone)
local spent, spentAt = {}, os.clock()
local function try(what, fn, ...)
    local t = os.clock()
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error visual %s %s", what, tostring(err)) end
    spent[what] = (spent[what] or 0) + os.clock() - t
    if t - spentAt > 60 then
        local l = {}
        for k, v in pairs(spent) do l[#l + 1] = string.format("%s=%.0f", k, v * 1000) end
        table.sort(l)
        log("PT|visual time ms/min %s", table.concat(l, " "))
        spent, spentAt = {}, t
    end
end
local function fpath(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function world() return UEHelpers.GetWorld() end
local function netted() local m = common.netMode(); return m == "listen" or m == "client" end
local function mapName()
    local w = world()
    return w:IsValid() and UEHelpers.GetGameplayStatics():GetCurrentLevelName(w, true):ToString() or ""
end
local function loadObj(path) -- "/Game/x/Y.Y_C" -> object, loading the package when needed
    local o = StaticFindObject(path)
    if not (o and o:IsValid()) then
        pcall(LoadAsset, path)
        o = StaticFindObject(path)
    end
    return (o and o:IsValid()) and o or nil
end
local function vec(x, y, z) return { X = x, Y = y, Z = z } end

-- ---------------------------------------------------------------- levels

local function levelPackages()
    local r = {}
    for _, s in ipairs(FindAllOf("LevelStreamingDynamic") or {}) do
        if live(s) and s:IsLevelLoaded() then
            local ok, p = pcall(function() return s:GetWorldAssetPackageFName():ToString() end)
            if ok and p ~= "" then r[#r + 1] = p end
        end
    end
    table.sort(r)
    return r
end

local asked = {} -- guest: package -> map it was requested in
local function applyLevels(data)
    local have = {}
    for _, s in ipairs(FindAllOf("LevelStreaming") or {}) do
        if live(s) then
            local ok, p = pcall(function() return s:GetWorldAssetPackageFName():ToString() end)
            if ok then have[p] = true end
        end
    end
    local map = mapName()
    local lib = StaticFindObject("/Script/Engine.Default__LevelStreamingDynamic")
    for p in data:gmatch("[^\n]+") do
        if not have[p] and asked[p] ~= map and lib:IsValid() then
            asked[p] = map
            local out = {}
            lib:LoadLevelInstance(world(), p, vec(0, 0, 0), { Pitch = 0, Yaw = 0, Roll = 0 }, out, "")
            log("PT|visual level %s requested ok=%s", p, tostring(out.bOutSuccess))
        end
    end
end

-- ---------------------------------------------------------------- paint

local TINT = "/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_TintableComponent.BP_TintableComponent_C"
local NOTAG = { TagName = FName("None") }

local function tintOf(m)
    local cls = loadObj(TINT)
    local l = cls and m:K2_GetComponentsByClass(cls)
    return (l and #l > 0) and l[1]:get() or nil
end
local function props(tc)
    local a, b, c, d = {}, {}, {}, {}
    tc:GetTintableProperties(a, b, c, d)
    if not d.Valid then return nil end
    local function cp(x) return (x and x:IsValid()) and fpath(x) or "" end
    return cp(a.Paint), b.TintingEnabled and "1" or "0", cp(c.DecalPalette)
end

local function eachPart(fn)
    local car = require("car")
    local cm, cont = car.carManager(), car.equipped()
    if not (cm and cont) then return end
    cont.Slots:ForEach(function(_, e)
        local slot = e:get()
        if car.itemOf(slot) then
            local name = car.slotName(slot)
            local m = car.manifestation and car.manifestation(cm, name)
            local tc = m and tintOf(m)
            if tc then fn(name, tc) end
        end
    end)
end

local function paintLines()
    local L = {}
    eachPart(function(name, tc)
        local p, en, d = props(tc)
        if p then L[#L + 1] = table.concat({ name, p, en, d }, "\t") end
    end)
    table.sort(L)
    return table.concat(L, "\n")
end

local function applyPaint(data)
    local want = {}
    for line in data:gmatch("[^\n]+") do
        local n, p, en, d = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if n then want[n] = { p, en, d } end
    end
    eachPart(function(name, tc)
        local w = want[name]
        if not w then return end
        local p, en, d = props(tc)
        if not p then return end
        if w[1] ~= p and w[1] ~= "" then
            local c = loadObj(w[1])
            if c then tc:SetPaint(c, NOTAG); log("PT|visual paint %s %s", name, w[1]:match("[^.]+$")) end
        end
        if w[3] ~= d and w[3] ~= "" then
            local c = loadObj(w[3])
            if c then tc:SetDecal(c, NOTAG); log("PT|visual decal %s %s", name, w[3]:match("[^.]+$")) end
        end
        if w[2] ~= en then tc:SetTintingEnabled(w[2] == "1") end
    end)
end

-- ---------------------------------------------------------------- props

-- what the host lists: run-time spawned (not placed in the map file) dressing. Wreck parts, loot, hazards, items and car parts have their
-- own modules, so they are not here. A static mesh that moves (debris, a wreck's loose part) is skipped.
local ALLOW = { "BP_Destruct_", "BP_Door_", "BP_Prop_", "BP_Poster_", "BP_Decal_", "BP_TpoleTool_", "BP_RoadObstruct_", "BP_BuildingFrame_", "BP_Spawn_Anchor_",
    -- Ida's trailer: the guest had none (playtest 2026-10-31). shortcut: the copy rolls its own stock and the guest trades from its
    -- own backpack; share the stock if players ask for it
    -- shortcut: the Zone's fuel barrels (BP_Spawn_GasBarrel) are missing on the guest too; mirrored copies blocked the guest's way
    -- to a container in playpath (2026-11-01), so they wait for a proper fix
    "BP_ZoneTrader",
    -- door keypads and hand-dryer locks (the red light by a locked door): without a copy the guest had nothing to press and its E on the
    -- locked door went to the host's door, which stayed locked (friend session 2026-11-01, "red doors do not open for the guest")
    "BP_ExternalDoorLock_" }
local function allowed(cn)
    for _, p in ipairs(ALLOW) do
        if cn:sub(1, #p) == p then return not cn:find("Part_", 1, true) end
    end
end
local function nums(s) local a, b, c = (s or ""):match("^([^,]+),([^,]+),([^,]+)$"); return tonumber(a), tonumber(b), tonumber(c) end
-- paths go over the wire once ("M" lines: id, path); lines carry the ids. Messages are reliable RPCs (256 outstanding bunches per
-- channel): a burst overflowed it and closed the guest's connection, so the host sends one small message per tick.
local ids, nextId, newDefs = {}, 0, {}
local function intern(path)
    local id = ids[path]
    if not id then
        nextId = nextId + 1
        id = nextId
        ids[path] = id
        newDefs[#newDefs + 1] = id .. "\t" .. path
    end
    return id
end
local function xform(o)
    local p, r, s = o:K2_GetActorLocation(), o:K2_GetActorRotation(), o:GetActorScale3D()
    local sc = (math.abs(s.X - 1) + math.abs(s.Y - 1) + math.abs(s.Z - 1) < 0.001) and "-" or string.format("%.3f,%.3f,%.3f", s.X, s.Y, s.Z)
    return string.format("%.1f,%.1f,%.1f", p.X, p.Y, p.Z), string.format("%.1f,%.1f,%.1f", r.Pitch, r.Yaw, r.Roll), sc
end
local function state(o)
    local t = {}
    local ok, v = pcall(function() return o.CurrentState end)
    if ok and type(v) == "number" then t[#t + 1] = "st=" .. v end
    ok, v = pcall(function() return o.currentRotOtherDoor end) -- a double door's second leaf (BP_Door_Double): not in CurrentState
    if ok and type(v) == "number" then t[#t + 1] = string.format("ot=%.0f", v) end
    ok, v = pcall(function() return o.IsBroken end)
    if ok and v then t[#t + 1] = "br=1" end
    ok, v = pcall(function() return o.SuccessfullyGrabbed end) -- an ARC anchor structure someone pulled: the other side's copy goes
    if ok and v == true then t[#t + 1] = "tk=1" end
    return table.concat(t, ";")
end
local function smaLine(o, name)
    local sm = o.StaticMeshComponent
    if not live(sm) or sm.Mobility == 2 then return end
    local mesh = sm.StaticMesh
    if not (mesh and mesh:IsValid()) then return end
    local par = o:GetAttachParentActor()
    if par and par:IsValid() and par:GetClass():GetFName():ToString():find("^BP_Template_") then return end
    local ov = {}
    local def = mesh.StaticMaterials
    for i = 0, sm:GetNumMaterials() - 1 do
        local m = sm:GetMaterial(i)
        local d = def[i + 1]
        if m and m:IsValid() and d and d.MaterialInterface:IsValid() then
            local mp = fpath(m)
            if mp ~= fpath(d.MaterialInterface) and not mp:find("/Engine/Transient", 1, true) then ov[#ov + 1] = i .. "=" .. intern(mp) end
        end
    end
    local l, r, s = xform(o)
    return table.concat({ "S", (name:gsub("^StaticMeshActor_", "#")), intern(fpath(mesh)), l, r, s, intern(sm:GetCollisionProfileName():ToString()), table.concat(ov, ";") }, "\t")
end
local function bpLine(o, cn, name)
    local l, r, s = xform(o)
    return table.concat({ "B", name, intern(fpath(o:GetClass())), l, r, s, "", state(o) }, "\t")
end

local cache = {} -- host: actor name -> { addr, line } of static meshes (they never change)
-- host: actor address -> { class address, verdict }, verdict false (not dressing) or { class, name }. Reading class, flags and
-- name of all ~2600 actors every second cost 30-60 ms per scan (playtest 2026-10-22); each actor is read once. The class
-- address is checked every time: a freed address reused by an actor of another class is read again.
-- shortcut: reuse by an actor of the same class keeps the old name and cached mesh line until the next map
local kinds = {}
local function kindOf(o)
    local addr = o:GetAddress()
    -- live first: GetClass reads the object, and a sweep's list can hold actors destroyed since (IsValid does not read it)
    if not live(o) then return false, addr end -- and no verdict for a dying actor (its address may come back as a prop)
    -- the class is read for every actor: skipping it for "not dressing" verdicts lost a removed mesh (visual 2 of 3, 2026-10-23)
    local cls = o:GetClass():GetAddress()
    local e = kinds[addr]
    if e and e[1] == cls then return e[2], addr end
    local k = false
    if not o:HasAnyFlags(RF_WasLoaded) then
        local cn = o:GetClass():GetFName():ToString()
        if (cn == "StaticMeshActor" or allowed(cn)) and not fpath(o):find("/Engine/Transient", 1, true) then k = { cn, o:GetFName():ToString() } end
    end
    kinds[addr] = { cls, k }
    return k, addr
end
local function lineOf(o, k, addr)
    local cn, name = k[1], k[2]
    if cn ~= "StaticMeshActor" then return bpLine(o, cn, name) end
    local c = cache[name]
    if c and c.addr == addr then return c.line end
    local line = smaLine(o, name)
    cache[name] = line and { addr = addr, line = line } or nil
    return line
end
-- one sweep over the actors, spread over ticks (a few ms each); returns the lines once a sweep is complete
local sweep, sweeps, restAt = nil, 0, 0
local function scanStep(budget)
    -- a sweep paused for a while (guest busy) or running long holds stale actors: start over (the verdicts in kinds stay)
    if sweep and (os.clock() - sweep.at > 5 or os.clock() - sweep.born > 60) then sweep = nil end
    if not sweep then
        -- 5 s between sweeps: back to back they were ~1 s of every minute on the host (2298 actors, 5.1 s a sweep; FPS hunt
        -- 2026-11-01). Doors pressed by a player go at once through their hooks; the sweep catches the rest.
        if os.clock() < restAt then return nil end
        sweep = { list = FindAllOf("Actor") or {}, i = 1, cur = {}, born = os.clock() }
    end
    sweep.at = os.clock()
    local t0 = os.clock()
    while sweep.i <= #sweep.list and os.clock() - t0 < budget do
        local o = sweep.list[sweep.i]
        sweep.i = sweep.i + 1
        local k, addr = kindOf(o)
        if k then
            local line = lineOf(o, k, addr)
            if line then sweep.cur[line:match("^%a\t([^\t]*)")] = line end
        end
    end
    if sweep.i <= #sweep.list then return nil end
    sweeps = sweeps + 1
    if sweeps % 20 == 1 then log("PT|visual sweep %d actors in %.1f s", #sweep.list, os.clock() - sweep.born) end
    local cur = sweep.cur
    sweep, restAt = nil, os.clock() + 5
    return cur
end

local sent, queue, lastMap, lastGuests = {}, {}, nil, 0
local function reset() sent, queue, cache, ids, nextId, newDefs, kinds, sweep = {}, {}, {}, {}, 0, {}, {}, nil end
local function propsHost()
    local guests = #net.guests()
    local map = mapName()
    if map ~= lastMap or guests ~= lastGuests or M.hello then
        reset()
        lastMap, lastGuests, M.hello = map, guests, nil
    end
    if not M.ready or #queue > 40 then return end -- the guest is still working through the last scan
    local cur = scanStep(0.004)
    if not cur then return end -- the sweep goes on next tick
    local add, del = {}, {}
    for key, line in pairs(cur) do
        if sent[key] ~= line then add[#add + 1] = line; sent[key] = line end
    end
    for key in pairs(sent) do
        if not cur[key] then del[#del + 1] = key; sent[key] = nil end
    end
    -- what is near the players first (the guest builds slowly: every new mesh is a synchronous asset load)
    local at = {}
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local p = live(pc) and live(pc.Pawn) and pc.Pawn:K2_GetActorLocation()
        if p then at[#at + 1] = p end
    end
    if #at > 0 and #add > 1 then
        local key = {}
        for _, line in ipairs(add) do
            local x, y, z = nums(line:match("^%a\t[^\t]*\t[^\t]*\t([^\t]*)"))
            local d = math.huge
            for _, p in ipairs(at) do d = math.min(d, (p.X - (x or 0)) ^ 2 + (p.Y - (y or 0)) ^ 2) end
            key[line] = d
        end
        table.sort(add, function(a, b) return key[a] < key[b] end)
    end
    -- small messages, each complete in itself; definitions first (the queue keeps its order)
    local function batch(kind, list)
        local buf, n = {}, 0
        for _, line in ipairs(list) do
            if n + #line > 2500 then queue[#queue + 1] = kind .. "\n" .. table.concat(buf, "\n"); buf, n = {}, 0 end
            buf[#buf + 1] = line; n = n + #line + 1
        end
        if #buf > 0 then queue[#queue + 1] = kind .. "\n" .. table.concat(buf, "\n") end
    end
    if #add + #del > 0 then log("PT|visual host props add=%d gone=%d defs=%d", #add, #del, #newDefs) end
    batch("M", newDefs)
    newDefs = {}
    batch("A", add)
    batch("D", del)
end
net.on("g.vis.hello", function() M.hello, M.ready = true, true; log("PT|visual hello from the guest") end)

local mine, todo, specs, guestMap = {}, {}, {}, nil -- guest: host actor key -> our copy; lines to apply; the line each copy was made from
local dict, gone = {}, {} -- guest: id -> path (the host's "M" lines); keys the host removed

local function dropAll()
    for _, a in pairs(mine) do if live(a) then a:K2_DestroyActor() end end
    mine, todo, specs, dict, gone = {}, {}, {}, {}, {}
end

local function fields(line)
    local f = {}
    for x in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
    return f
end

-- A door follows the host's state the way a player moves it: its own highlight is pressed here, so the game plays the swing and the
-- sound; "Set Door from State" snapped it open or shut (owner: doors sync "in jerks", 2026-10-28). Locks and anything else still snap. A double door
-- (BP_Door_Double) has a second leaf with its own highlight and angle (currentRotOtherDoor, not in CurrentState: it never synced, and
-- the guest's E on it never reached the host). A door just pressed (here or by the guest) is left alone while it swings.
local OTHER_INTERACT = "BndEvt__Highlight_OtherDoor_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature"
local SWING_S = 2
local swingHold = {} -- door address -> os.clock() until which it is left alone
local leafTweens = {} -- door address -> { d, from, to, t0 }: a double door's second leaf turning on the guest
local LEAF_S = 0.8
local fromHost = false -- our own press: the door hooks must not send it back
local function press(h)
    fromHost = true
    pcall(function() h:InteractPressed(nil); h:InteractReleased(nil) end)
    fromHost = false
end
local function applyDoor(d, hs, ho, placed)
    local key = d:GetAddress()
    if (swingHold[key] or 0) > os.clock() then return end
    local snap = os.getenv("PT_MUTATE") == "nodoorswing"
    local gs = d.CurrentState
    if hs and gs ~= hs then
        if placed and gs >= 3 and hs < 3 then
            pcall(function() d:ForceUnlockDoor() end)
            log("PT|visual host unlocked placed door %s", d:GetFName():ToString())
        elseif not snap and gs < 3 and hs < 3 and (gs == 0) ~= (hs == 0) then
            press(d.Highlight)
            swingHold[key] = os.clock() + SWING_S
        elseif not placed or (gs < 3 and hs < 3) then
            pcall(function() d["Set Door from State"](d, hs) end)
        end
    end
    if ho then
        -- the leaf's real angle: a guest's own press sets currentRotOtherDoor to the new value without turning the leaf
        local ok, go = pcall(function() return d.OtherDoor.RelativeRotation.Yaw end)
        if ok and type(go) == "number" then go = ho + ((go - ho + 180) % 360) - 180 end -- the same turn, nearest to the host's
        if ok and type(go) == "number" and math.abs(go - ho) > 5 then
            -- the second leaf ignores a press on the guest (its own timeline never starts there, live 2026-10-28): it is turned here,
            -- its component's relative yaw being currentRotOtherDoor
            if snap then
                pcall(function() d.OtherDoor:K2_SetRelativeRotation({ Pitch = 0, Yaw = ho, Roll = 0 }, false, {}, true) end)
                d.currentRotOtherDoor = ho
            else
                leafTweens[key] = { d = d, from = go, to = ho, t0 = os.clock() }
            end
            swingHold[key] = os.clock() + SWING_S
        end
    end
end
RegisterLoadMapPreHook(function() swingHold, leafTweens = {}, {} end)
LoopInGameThreadWithDelay(16, function()
    if not next(leafTweens) then return end
    for key, tw in pairs(leafTweens) do
        local ok = pcall(function()
            local u = math.min(1, (os.clock() - tw.t0) / LEAF_S)
            u = u * u * (3 - 2 * u)
            tw.d.OtherDoor:K2_SetRelativeRotation({ Pitch = 0, Yaw = tw.from + (tw.to - tw.from) * u, Roll = 0 }, false, {}, true)
            if u >= 1 then tw.d.currentRotOtherDoor = tw.to; leafTweens[key] = nil end
        end)
        if not ok then leafTweens[key] = nil end
    end
end)

local function applyState(a, st)
    if st:find("tk=1", 1, true) then
        -- already taken here by the host's g.vis.anchortaken (its sound and fade still playing): left as the game leaves a pulled one
        local ok, taken = pcall(function() return a.SuccessfullyGrabbed == true end)
        if not (ok and taken) then pcall(function() a:K2_DestroyActor() end) end
        return
    end
    if st:find("br=1", 1, true) then
        pcall(function() -- crates and fences are "complex", cones and signs "simple" destructibles; both take the break impulse
            local z = vec(0, 0, 0)
            if not a.IsBroken and not pcall(function() a:ComplexBreak(z, a.BaseMesh) end) then a:SimpleBreak(z) end
        end)
    end
    local s, o = tonumber(st:match("st=(%d+)")), tonumber(st:match("ot=(%-?%d+)"))
    if s or o then pcall(applyDoor, a, s, o, false) end -- 0 closed, 1 and 2 open (either way), 3 and up shut
end

-- the host's actor is gone: a destructible that broke there breaks here (debris, sound), then goes; everything else just goes
local function dispose(a)
    if not live(a) then return end
    if a:GetClass():GetFName():ToString():find("^BP_Destruct_") then
        applyState(a, "br=1")
        ExecuteInGameThreadWithDelay(8000, function() if live(a) then a:K2_DestroyActor() end end)
    else
        a:K2_DestroyActor()
    end
end

-- The guest's E on a door, and a lock it opens (prybar): the door swings here, the host's door gets the same (its state comes back in
-- g.vis.p for zone copies). Doors placed in the map (the garage's chained side doors) exist on both sides and are not mirrored: the host's
-- stayed shut and locked and its collision blocked the guest (first Steam play, #1). The events are declared on a parent class
-- (BP_Door_Single_C, BP_Door_Sliding_Single_C), hooked there once.
local INTERACT = "BndEvt__Highlight_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature"
local UNLOCK = "OnLockOpened_Event_0"
local doorHooks = {} -- class path .. ":" .. event -> true (hooked or not declared in its chain)
local function doorName(d) -- the host's name for this door: a copy's key, or a map-placed door's own name
    for name, a in pairs(mine) do
        if live(a) and a:GetAddress() == d:GetAddress() then return name end
    end
    -- the full path: placed doors in different sublevels can share an FName (BP_Door_Single_C_2)
    if d:HasAnyFlags(RF_WasLoaded) and not fpath(d):find("/Engine/Transient", 1, true) then return fpath(d) end
end
local function hookDoor(cls, event, msg)
    local start = fpath(cls) .. ":" .. event
    if doorHooks["seen " .. start] then return end
    doorHooks["seen " .. start] = true
    for _ = 1, 6 do
        if not (cls and cls:IsValid()) then return end
        local at = fpath(cls) .. ":" .. event
        local fn = StaticFindObject(at)
        if fn and fn:IsValid() then
            if doorHooks[at] then return end
            doorHooks[at] = true
            local ok, err = pcall(RegisterHook, at, function(self)
                if not (M.enabled and safety.guest()) or fromHost then return end
                local d = self:get()
                -- our own swing: the host's state catches up meanwhile (a second leaf: the host turns its own after our message, and its
                -- state comes back a list later, so a little longer)
                swingHold[d:GetAddress()] = os.clock() + SWING_S + (msg == "g.vis.door2" and 1 or 0)
                local name = doorName(d)
                if name and msg == "g.vis.door2" then
                    -- the second leaf goes by value (the host's press from a distance, with no player, took its locked shake: live
                    -- 2026-10-28). Our own game turns it here only sometimes, and AnimTargetOther is not where it ends up: 1.2 s later
                    -- the angle it has is sent, or, if it did not move, the toggle (shut <-> 90 degrees open) is done here and sent
                    local before = d.OtherDoor.RelativeRotation.Yaw
                    ExecuteInGameThreadWithDelay(1200, function()
                        local ok, err = pcall(function()
                            local now, shut = d.OtherDoor.RelativeRotation.Yaw, d.AnimTargetClosedOther
                            local function same(a, b) return math.abs(((a - b + 180) % 360) - 180) < 5 end
                            local to = now
                            if same(now, before) then
                                to = same(now, shut) and shut - 90 or shut
                                leafTweens[d:GetAddress()] = { d = d, from = to + ((now - to + 180) % 360) - 180, to = to, t0 = os.clock() }
                            end
                            swingHold[d:GetAddress()] = os.clock() + SWING_S + 1
                            net.toHost(msg, name .. "|" .. string.format("%.0f", to))
                            log("PT|visual guest %s door %s from %.0f to %.0f", msg, name, before, to)
                        end)
                        if not ok then log("PT|error visual second leaf %s", tostring(err)) end
                    end)
                elseif name then
                    net.toHost(msg, name)
                    log("PT|visual guest %s door %s", msg, name)
                end
            end)
            log("PT|visual door hook %s %s", at, ok and "ok" or tostring(err))
            return
        end
        cls = cls:GetSuperStruct()
    end
end
local function hookPlacedDoors()
    for _, c in ipairs({ "BP_Door_Single_C", "BP_Door_Sliding_Single_C" }) do
        for _, d in ipairs(FindAllOf(c) or {}) do
            if live(d) then
                hookDoor(d:GetClass(), INTERACT, "g.vis.door")
                hookDoor(d:GetClass(), UNLOCK, "g.vis.unlock")
                if os.getenv("PT_MUTATE") ~= "nodoubledoor" then hookDoor(d:GetClass(), OTHER_INTERACT, "g.vis.door2") end -- double doors only
            end
        end
    end
end
local function hostDoor(name)
    for _, c in ipairs({ "BP_Door_Single_C", "BP_Door_Sliding_Single_C" }) do -- FindAllOf includes child classes
        for _, d in ipairs(FindAllOf(c) or {}) do
            if live(d) and (fpath(d) == name or d:GetFName():ToString() == name) and not fpath(d):find("/Engine/Transient", 1, true) then return d end
        end
    end
end
net.on("g.vis.door", function(_, name)
    if not M.enabled then return end
    local d = hostDoor(name)
    if d then
        d.Highlight:InteractPressed(nil)
        d.Highlight:InteractReleased(nil)
    end
    log("PT|visual guest used door %s: %s, state=%s", name, d and "pressed on the host" or "not on the host", d and tostring(d.CurrentState) or "?")
end)
-- the guest pressed its copy of a door keypad / hand-dryer lock: the host's own lock is pressed (it checks and unlocks its door; the door's
-- state reaches the guest with the props). shortcut: the guest's copy keeps its red light; mirror Success/Fail if players notice
local keypadAt = {}
net.on("g.vis.keypad", function(_, name)
    if not M.enabled or os.clock() - (keypadAt[name] or -9) < 1 then return end -- one press fires several of the lock's events
    keypadAt[name] = os.clock()
    local k
    for _, c in ipairs({ "BP_ExternalDoorLock_Keypad_C", "BP_ExternalDoorLock_HandDryer_C" }) do
        for _, o in ipairs(FindAllOf(c) or {}) do
            if live(o) and o:GetFName():ToString() == name and not fpath(o):find("/Engine/Transient", 1, true) then k = o end
        end
    end
    if k then pcall(function() k.Highlight:InteractPressed(nil); k.Highlight:InteractReleased(nil) end) end
    log("PT|visual guest pressed lock %s: %s", name, k and "pressed on the host" or "not on the host")
end)
net.on("g.vis.door2", function(_, data) -- the guest turned a double door's second leaf: "name|angle"
    if not M.enabled then return end
    local name, to = data:match("^(.*)|(%-?%d+)$")
    local d = name and hostDoor(name)
    if d then
        local from = d.OtherDoor.RelativeRotation.Yaw
        to = tonumber(to)
        leafTweens[d:GetAddress()] = { d = d, from = to + ((from - to + 180) % 360) - 180, to = to, t0 = os.clock() }
    end
    log("PT|visual guest turned the second leaf of %s to %s: %s", tostring(name), tostring(to), d and "turning on the host" or "not on the host")
end)
net.on("g.vis.unlock", function(_, name)
    if not M.enabled then return end
    local d = hostDoor(name)
    if d and d.CurrentState >= 3 then d:ForceUnlockDoor() end -- the game's own unlock (WorkLock); it opens the door as it does for the guest
    log("PT|visual guest unlocked door %s: %s, state=%s", name, d and "unlocked on the host" or "not on the host", d and tostring(d.CurrentState) or "?")
end)

-- ARC anchor structures (BP_Spawn_Anchor_*): the guest's pull of its copy gives the guest the anchor item, so the host's structure must be
-- taken too, else the host pulls it again and the same anchor is deposited twice (hand play 2026-10-24). The host marks its structure taken
-- the way the game does after a pull (no item); its "tk=1" state removes the guest's copy, which also covers the host pulling one first.
local ANCHOR_FN = "/Game/Gameplay/Resources/AnchorBase/BP_Spawn_Anchor_Base_01.BP_Spawn_Anchor_Base_01_C:Long Grab Complete"
local anchorHooked = false
local function hookAnchors()
    if anchorHooked or M.mutate == "noanchorsync" then return end
    -- a post hook never fires for this Blueprint function: the pre hook looks again once the pull has run
    anchorHooked = pcall(RegisterHook, ANCHOR_FN, function(self)
        if not (M.enabled and safety.active()) then return end
        local a = self:get()
        local guest = safety.guest()
        ExecuteInGameThreadWithDelay(300, function()
            if not (live(a) and a.SuccessfullyGrabbed == true) then return end -- inventory full: nothing was taken
            if not guest then
                -- the host's pull reaches the guest at once (the prop sweep's tk=1 came seconds later, and removed the copy silently)
                if M.mutate ~= "noanchorfx" then net.toGuests("g.vis.anchortaken", a:GetFName():ToString()) end
                return
            end
            local name = doorName(a)
            if name then
                net.toHost("g.vis.anchor", name)
                log("PT|visual guest pulled anchor %s", name)
            end
        end)
    end)
end
-- guest: the host pulled this anchor; our copy runs the game's own take (sound, beam fade, goo) without giving us the item
-- guess: AnchorTaken/PlayPrySound carry the effects (names in BP_Spawn_Anchor_Base_01); confirm by ear in a live session
net.on("g.vis.anchortaken", function(_, name)
    local a = mine[name]
    if not (M.enabled and live(a)) or a.SuccessfullyGrabbed == true then return end
    a.SuccessfullyGrabbed = true
    for _, f in ipairs({ "PlayPrySound", "AddAnchorPulledTag", "AnchorTaken", "removeAnchorGoo" }) do pcall(a[f], a) end
    pcall(function() a.Highlight:SetActive(false, false) end)
    pcall(function() a.GrabbableMesh:K2_DestroyComponent(a) end)
    log("PT|visual host pulled anchor %s: taken here", name)
end)
net.on("g.vis.anchor", function(_, name)
    if not M.enabled then return end
    for _, o in ipairs(FindAllOf("BP_Spawn_Anchor_Base_01_C") or {}) do
        if live(o) and (fpath(o) == name or o:GetFName():ToString() == name) and not fpath(o):find("/Engine/Transient", 1, true) then
            if not o.SuccessfullyGrabbed then
                o.SuccessfullyGrabbed = true
                for _, f in ipairs({ "AddAnchorPulledTag", "AnchorTaken", "removeAnchorGoo" }) do pcall(o[f], o) end
                pcall(function() o.Highlight:SetActive(false, false) end)
                pcall(function() o.GrabbableMesh:K2_DestroyComponent(o) end)
            end
            log("PT|visual guest pulled anchor %s: taken on the host", name)
            return
        end
    end
    log("PT|visual guest pulled anchor %s: not on the host", name)
end)

-- The host's map-placed doors (garage side rooms: chains broken with the impact hammer or a prybar, open or shut) go the other way
-- too: the guest's copy stayed chained and shut (owner, 2026-10-24). The host lists "path=state" (g.vis.pd), the guest applies a
-- door's state when the host's changes: a lock with the game's ForceUnlockDoor (chain break sound and particles), open or shut with
-- "Set Door from State".
local function placedDoors()
    local r = {}
    for _, c in ipairs({ "BP_Door_Single_C", "BP_Door_Sliding_Single_C" }) do
        for _, d in ipairs(FindAllOf(c) or {}) do
            if live(d) and d:HasAnyFlags(RF_WasLoaded) and not fpath(d):find("/Engine/Transient", 1, true) then r[fpath(d)] = d end
        end
    end
    return r
end
local function doorStates()
    local L = {}
    for name, d in pairs(placedDoors()) do
        local ok, o = pcall(function() return d.currentRotOtherDoor end) -- a double door's second leaf
        L[#L + 1] = name .. "=" .. tostring(d.CurrentState) .. ((ok and type(o) == "number") and string.format("/%.0f", o) or "")
    end
    table.sort(L)
    return table.concat(L, "\n")
end
-- every list: each door that differs from the host's moves (a door left alone while it swings catches up with a later list)
net.on("g.vis.pd", function(_, data)
    if not M.enabled then return end
    local doors = placedDoors()
    for name, st, ot in data:gmatch("([^\n=]+)=(%d+)/?(%-?%d*)") do
        local d = doors[name]
        if d then pcall(applyDoor, d, tonumber(st), tonumber(ot), true) end
    end
end)

local function make(f)
    local asset, l, r, s = dict[f[3]], f[4], f[5], f[6]
    local x, y, z = nums(l)
    local pi, ya, ro = nums(r)
    local sx, sy, sz = 1, 1, 1
    if s ~= "-" then sx, sy, sz = nums(s) end
    if not (x and pi and sx and asset) then return nil, "line" end
    local cls = f[1] == "S" and StaticFindObject("/Script/Engine.StaticMeshActor") or loadObj(asset)
    if not cls then return nil, "class " .. asset end
    local mesh = f[1] == "S" and loadObj(asset)
    if f[1] == "S" and not mesh then return nil, "mesh " .. asset end
    local rot = { Pitch = pi, Yaw = ya, Roll = ro }
    local a = world():SpawnActor(cls, vec(x, y, z), rot)
    if not live(a) then return nil, "spawn " .. asset end
    a:K2_SetActorLocationAndRotation(vec(x, y, z), rot, false, {}, true) -- the spawn may have nudged it off a blocker
    a:SetActorScale3D(vec(sx, sy, sz))
    if f[1] == "S" then
        local sm = a.StaticMeshComponent
        sm:SetMobility(2)
        sm:SetStaticMesh(mesh)
        if dict[f[7]] then sm:SetCollisionProfileName(FName(dict[f[7]]), true) end
        for i, id in (f[8] or ""):gmatch("(%d+)=(%d+)") do
            local m = dict[id] and loadObj(dict[id])
            if m then sm:SetMaterial(tonumber(i), m) end
        end
    else
        applyState(a, f[8] or "")
    end
    local door = f[1] == "B" and asset:find("/BP_Door_", 1, true) ~= nil
    if door then hookDoor(cls, INTERACT, "g.vis.door"); hookDoor(cls, UNLOCK, "g.vis.unlock") end
    local lock = f[1] == "B" and asset:find("/BP_ExternalDoorLock_", 1, true) ~= nil and M.mutate ~= "nokeypad"
    if lock then -- the guest's press goes to the host's lock (which of its four highlight events is the press is not known: all of them)
        for i = 0, 3 do hookDoor(cls, "BndEvt__Highlight_K2Node_ComponentBoundEvent_" .. i .. "_OnHighlightInteract__DelegateSignature", "g.vis.keypad") end
        door = true -- keeps the interact trace
    end
    -- copies block pawns and the car but not the interaction/camera traces: a guest's interact, pickup and aim trace must not hit a copy
    -- (playpath, lootsync2 failed with the copies blocking them). Doors keep the interact trace: the guest's E on one goes to the host.
    pcall(function()
        for _, c in ipairs(a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))) do
            local p = c:get()
            if not door then p:SetCollisionResponseToChannel(0, 0) end -- ECC_Visibility
            p:SetCollisionResponseToChannel(1, 0) -- ECC_Camera
        end
    end)
    return a
end

local nextApply, applyBatch = 0, nil
local function applyProps()
    if os.clock() < nextApply then return end -- duty cycle: a mesh load blocks the game thread, the guest's other work (loot copies) must get its share
    local started = os.clock()
    local ok, err = pcall(applyBatch)
    nextApply = os.clock() + (os.clock() - started)
    if not ok then error(err) end
end

function applyBatch()
    local t0 = os.clock() -- a time budget per tick: loading a mesh package can take long, spawns are cheap
    for _ = 1, 200 do
        if os.clock() - t0 > 0.008 then return end -- 30 ms here was a visible hitch every few ticks (PT|slow visual.lua, 2026-10-22)
        local line = table.remove(todo, 1)
        if not line then return end
        local f = fields(line)
        local name, a = f[2], mine[f[2]]
        if gone[name] then
            -- the host removed it after this line was sent
        elseif live(a) and specs[name] == line then
            -- nothing new
        elseif live(a) and f[1] == "B" and specs[name] and specs[name]:gsub("\t[^\t]*$", "") == line:gsub("\t[^\t]*$", "") then
            specs[name] = line
            applyState(a, f[8] or "") -- only the door state or the broken flag changed
        else
            if live(a) then a:K2_DestroyActor() end
            local ok, na, why = pcall(make, f)
            mine[name] = ok and na or nil
            specs[name] = ok and na and line or nil
            if not ok then log("PT|error visual make %s %s", f[3] or "?", tostring(na))
            elseif not na then
                M.failed = (M.failed or 0) + 1
                if M.failed <= 5 then log("PT|visual could not make %s: %s", f[2], tostring(why)) end
            end
        end
    end
end

net.on("g.vis.p", function(_, data)
    if not M.zone then return end
    if not M.enabled then return end
    local kind, rest = data:match("^(%a)\n(.*)$")
    if kind == "M" then
        for id, p in rest:gmatch("(%d+)\t([^\n]+)") do dict[id] = p end
    elseif kind == "A" then
        for line in rest:gmatch("[^\n]+") do
            todo[#todo + 1] = line
            gone[line:match("^%a\t([^\t]*)")] = nil
            M.rx = (M.rx or 0) + 1
        end
    elseif kind == "D" then
        for name in rest:gmatch("[^\n]+") do
            dispose(mine[name])
            mine[name], specs[name], gone[name] = nil, nil, true -- a line for it that is still waiting must not bring it back
        end
    end
end)

-- ---------------------------------------------------------------- loops

local wantLevels, wantPaint
net.on("g.vis.lv", function(_, data) wantLevels = data end)
net.on("g.vis.paint", function(_, data) wantPaint = data end)

local beat, lastLv, lastPaint = 0, nil, nil
-- paint is read on a hook (garage paint: SetPaint, SetDecal, SetTintingEnabled on the tintable component) or every 5 s, not every
-- 500 ms (the part walk was ~1 ms of every 5 ms host tick); PT|probe lines show whether the hooks fire on the host
local paintDirty, paintHooked, paintProbe = true, false, 0
local paintHooks = {} -- SetPaint etc. -> registered
local function hookPaint()
    if paintHooked then return end
    local ok = true
    for _, fn in ipairs({ "SetPaint", "SetDecal", "SetTintingEnabled" }) do
        local okh = paintHooks[fn] or pcall(RegisterHook, TINT .. ":" .. fn, function()
            paintDirty = true
            paintProbe = paintProbe + 1
            if paintProbe <= 3 then log("PT|probe visual paint hook %s n=%d", fn, paintProbe) end
        end)
        paintHooks[fn] = okh -- a hook that registered is never registered again (one per tick piled up)
        ok = ok and okh
    end
    paintHooked = ok
end
local lastDoors
local function hostTick()
    beat = beat + 1
    if not M.ready then return end
    hookPaint()
    if beat % 40 == 5 then try("anchorhook", hookAnchors) end -- the host's own pulls go to the guest at once
    if beat % 8 == 1 then
        local s = table.concat(levelPackages(), "\n")
        if s ~= lastLv or beat % 40 == 1 then lastLv = s; net.toGuests("g.vis.lv", s) end
    end
    if paintDirty or beat % 20 == 0 then
        paintDirty = false
        local p = paintLines()
        if p ~= "" and (p ~= lastPaint or beat % 120 == 0) then lastPaint = p; net.toGuests("g.vis.paint", p) end
    end
    if M.zone and (beat % 4 == 2 or sweep) then try("scan", propsHost) end -- shortcut: a 10 s rescan broke "door follows the host within 3 s"
    if beat % 4 == 0 and mapName() == "RB_Garage" then -- zone doors are the game's prefab copies above (and a zone's list could pass the 32 KB message cap)
        local d = doorStates()
        if d ~= "" and (d ~= lastDoors or beat % 40 == 0) then lastDoors = d; net.toGuests("g.vis.pd", d) end
    end
    if beat % 2 == 0 then -- one small message per 500 ms: see intern()
        local q = table.remove(queue, 1)
        if q then net.toGuests("g.vis.p", q) end
    end
end

local helloFor, mapSince, lastCopies, paintDone = nil, 0, -1, nil
local function guestTick()
    beat = beat + 1
    local map = mapName()
    if map ~= guestMap then
        guestMap, mapSince = map, os.clock()
        dropAll()
        asked, wantLevels, wantPaint, helloFor, paintDone = {}, nil, nil, nil, nil
    end
    -- the host waits for this before it sends anything: a guest that is still loading acks late, and the reliable channel overflows
    local pc = UEHelpers.GetPlayerController()
    local pawn = (pc and pc:IsValid()) and pc.Pawn or nil
    if helloFor ~= map and map ~= "" and map ~= "RB_MainMenu" and live(pawn) and os.clock() - mapSince > 5 then
        helloFor = map
        log("PT|visual hello sent=%s map=%s", tostring(net.toHost("g.vis.hello", "")), map)
    end
    if wantLevels and beat % 8 == 0 then try("levels", applyLevels, wantLevels) end
    -- a new list, and every 10 s for parts installed since (each pass reads every part's tint)
    if wantPaint and (wantPaint ~= paintDone or beat % 40 == 0) then paintDone = wantPaint; try("paint", applyPaint, wantPaint) end
    if #todo > 0 then try("props", applyProps) end
    if beat % 40 == 3 then try("doorhooks", hookPlacedDoors) end -- map-placed doors (garage)
    if beat % 40 == 5 then try("anchorhook", hookAnchors) end -- ARC anchor structures (zones)
    for name, a in pairs(mine) do if not live(a) then mine[name], specs[name] = nil, nil end end
    if beat % 20 == 0 then
        local n = 0
        for _ in pairs(mine) do n = n + 1 end
        if n ~= lastCopies or #todo > 0 then lastCopies = n; log("PT|visual guest copies=%d queued=%d received=%d failed=%d", n, #todo, M.rx or 0, M.failed or 0) end
    end
end

LoopInGameThreadWithDelay(250, function()
    if not M.enabled or not netted() or not safety.active() then
        if next(mine) then dropAll() end
        guestMap, lastMap, sent, queue, M.ready = nil, nil, {}, {}, false
        return
    end
    if safety.guest() then guestTick() else hostTick() end
end)

return M
