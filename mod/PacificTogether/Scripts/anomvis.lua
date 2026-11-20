-- The hazards smhost.lua un-froze (Blacksmith, Titan's Bone, Bollard, Bubblegum Buddy, Ticking Tumbler, Pufferfish) move for the guest too (W6).
-- Why the guest saw them still: their moving parts are COMPONENTS (the Blacksmith's Cylinder, the spears, the bollard's mesh ...) set by timelines of
-- the host's state machine; the guest's replicated copy has tick off and only its root replicated (smhost.md: copy Cylinder z 0 for ever).
-- Generic, like anommove.lua: the host sends, 10 times a second, for every hazard of those classes within NEAR of a player, the relative
-- transform + visibility of every SceneComponent (not the root, not physics bodies) that changed since the last row (all every 1 s), plus the
-- root position (Tumbler and Pufferfish travel). The guest matches its copy by the (static) root position at first sight and applies the rows.
-- Inert outside a session (Q7). Mutation noanomvis switches the module off.
local common = require("common")
local net = require("net")
local safety = require("safety")
local UEHelpers = require("UEHelpers")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "noanomvis", rot = os.getenv("PT_MUTATE") ~= "nobollardyaw" } -- nobollardyaw: the guest ignores the root rotation
local CLASSES = { "BP_Hazard_RockPounder_C", "BP_Hazard_ImpactSpear_C", "BP_Hazard_Bollard_C", "BP_Hazard_Spore_C", "BP_Hazard_BombRock_C", "BP_Boon_LootCreature_C" }
local NEAR = 15000 -- uu from any player
local function live(o) return o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and not o:GetFullName():find("Default__", 1, true) end
local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error anomvis %s %s", what, tostring(err)) end
end
local function fetch()
    local r = {}
    for _, c in ipairs(CLASSES) do
        for _, o in ipairs(FindAllOf(c) or {}) do if live(o) then r[#r + 1] = o end end
    end
    return r
end
local SCENE = StaticFindObject("/Script/Engine.SceneComponent")
-- the actor's scene components except the root (shortcut: a simulating body is not told apart, none of the six classes was seen to have one): { name = , c = }
local function parts(o)
    local r, root = {}, o:K2_GetRootComponent()
    for _, w in ipairs(o:K2_GetComponentsByClass(SCENE)) do
        local c = w:get()
        if c:IsValid() and c:GetAddress() ~= root:GetAddress() then
            r[#r + 1] = { name = c:GetFName():ToString(), c = c }
        end
    end
    return r
end

-- ---------------------------------------------------------------- host

local hostList, hostAt, sent, homes, beat = {}, -99, {}, {}, 0
RegisterLoadMapPreHook(function() hostList, hostAt, sent, homes = {}, -99, {}, {} end)

local function players()
    local r = {}
    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() and pc.Pawn:IsValid() then r[1] = pc.Pawn:K2_GetActorLocation() end
    for _, g in ipairs(net.guests()) do if g:IsValid() and g.Pawn:IsValid() then r[#r + 1] = g.Pawn:K2_GetActorLocation() end end
    return r
end
local function near(l, pts)
    for _, p in ipairs(pts) do if (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 < NEAR ^ 2 then return true end end
end
local function differs(a, b)
    if not a then return true end
    for i = 1, #b do if math.abs(a[i] - b[i]) > 0.5 then return true end end
end
-- a simulating mesh (Tumbler body, Pufferfish cube, Bubblegum body) is detached from the root: its relative transform means nothing, send world
local function isMesh(c) return c:GetClass():GetFName():ToString():find("MeshComponent", 1, true) ~= nil end
local function row(c)
    local sim = false -- IsSimulatingPhysics("None") crashed the host (anomtail.lua): the body flag is read
    if isMesh(c) then local ok, b = pcall(function() return c.BodyInstance.bSimulatePhysics end); sim = ok and b end
    local l, r, s = c.RelativeLocation, c.RelativeRotation, c.RelativeScale3D
    if sim then l, r = c:K2_GetComponentLocation(), c:K2_GetComponentRotation() end
    return { l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, s.X, s.Y, s.Z, c:IsVisible() and 1 or 0, sim and 1 or 0 }
end

LoopInGameThreadWithDelay(100, function()
    if not (M.enabled and safety.active() and not safety.guest()) or #net.guests() == 0 then return end
    try("host", function()
        beat = beat + 1
        local now = os.clock()
        if now - hostAt > 2 then -- the lists are refetched every 2 s, a spawned one shows up late
            hostList, hostAt = {}, now
            for _, o in ipairs(fetch()) do
                local key = o:GetAddress()
                if not homes[key] then local l = o:K2_GetActorLocation(); homes[key] = { l.X, l.Y } end
                hostList[#hostList + 1] = { o = o, key = key, parts = parts(o) }
            end
        end
        local pts, L = players(), {}
        for _, h in ipairs(hostList) do
            local l = live(h.o) and h.o:K2_GetActorLocation() -- live(): a BombRock the Blacksmith's slam spawns can explode and go within the 2 s list age
            if l and near(l, pts) then
                local s = sent[h.key]
                if not s then s = {}; sent[h.key] = s end
                local full, f = (beat + h.key % 50) % 50 == 0, {} -- all parts every 5 s (late copies), staggered
                for _, p in ipairs(h.parts) do
                    local ok, r = false, nil
                    if p.c:IsValid() and not p.c:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then ok, r = pcall(row, p.c) end
                    if ok and (full or differs(s[p.name], r)) then
                        s[p.name] = r
                        local v = {}
                        for i, x in ipairs(r) do v[i] = string.format("%.1f", x) end
                        f[#f + 1] = p.name .. "=" .. table.concat(v, ",")
                    end
                end
                local ar = h.o:K2_GetActorRotation() -- a spawned Bollard picks a random yaw the guest's copy does not get (docs/spikes/anomfin.md)
                local root = { l.X, l.Y, l.Z, ar.Pitch, ar.Yaw, ar.Roll }
                if #f > 0 or differs(s.root, root) then
                    s.root = root
                    L[#L + 1] = string.format("%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.1f\t%.1f\t%.1f\t%s", homes[h.key][1], homes[h.key][2], l.X, l.Y, l.Z, ar.Pitch, ar.Yaw, ar.Roll, table.concat(f, "\t"))
                end
            end
        end
        local chunk, n = {}, 0
        for _, line in ipairs(L) do -- messages stay small
            chunk[#chunk + 1] = line; n = n + #line
            if n > 900 then net.toGuests("g.anomvis", table.concat(chunk, "\n")); chunk, n = {}, 0 end
        end
        if #chunk > 0 then net.toGuests("g.anomvis", table.concat(chunk, "\n")) end
        M.sent = (M.sent or 0) + #L
    end)
end)

-- ---------------------------------------------------------------- guest

local copies, copiesAt, claim, taken, state = {}, -99, {}, {}, {} -- claim[host home key] = copy; taken[copy address] = true; state[address] = { names, vals, off }
local pending = {}
RegisterLoadMapPostHook(function() copies, copiesAt, claim, taken, state, pending = {}, -99, {}, {}, {}, {} end)

-- The copy a host hazard (identified by its first-seen position hx, hy) stands for. A level-placed one has not moved: its copy is at the row's
-- root rx, ry (within 80 uu) at once. A spawned one may not match (Spore, Tumbler, Pufferfish move before either side sees it, a spawned spear's copy
-- sits at 0, 0 until its root replicates): after 1 s without a match the row claims the nearest unclaimed copy within 3000 uu, else one at the
-- origin, and keeps it. shortcut: two spawned hazards of one class within 3000 uu of each other (or two at the origin) may swap copies.
local function copyAt(hx, hy, rx, ry)
    local key = hx .. "," .. hy
    local c = claim[key]
    if c then return c:IsValid() and c or nil end
    if os.clock() - copiesAt > 1 then copies, copiesAt = fetch(), os.clock() end
    local now = os.clock()
    pending[key] = pending[key] or now
    local late = now - pending[key] > 1
    local best, bd, orig = nil, 3000 ^ 2, nil
    for _, o in ipairs(copies) do
        if o:IsValid() and not taken[o:GetAddress()] then
            local l = o:K2_GetActorLocation()
            local d = (l.X - rx) ^ 2 + (l.Y - ry) ^ 2
            if d < 80 ^ 2 then best, bd = o, -1 break end
            if late and d < bd then best, bd = o, d end
            if late and l.X ^ 2 + l.Y ^ 2 < 100 ^ 2 then orig = o end
        end
    end
    best = best or orig
    if best then claim[key], taken[best:GetAddress()] = best, true end
    return best
end

net.on("g.anomvis", function(_, data)
    if not (M.enabled and safety.guest()) then return end
    try("recv", function()
        for line in data:gmatch("[^\n]+") do
            local f = {}
            for v in line:gmatch("[^\t]+") do f[#f + 1] = v end
            local o = #f >= 8 and copyAt(f[1], f[2], tonumber(f[3]), tonumber(f[4]))
            if o and live(o) then
                local key = o:GetAddress()
                local st = state[key]
                if not st then
                    st = { names = {}, vals = {}, off = {} }
                    state[key] = st
                    for _, p in ipairs(parts(o)) do st.names[p.name] = p.c end
                    -- a rolling or flying root (Tumbler, Bubblegum Buddy, Pufferfish) is a body the host's physics moves: the copy's must not move itself
                    local rc = o:K2_GetRootComponent()
                    local okb, sim = pcall(function() return isMesh(rc) and rc.BodyInstance.bSimulatePhysics end)
                    if okb and sim then rc:SetSimulatePhysics(false) end
                end
                local l, to = o:K2_GetActorLocation(), { X = tonumber(f[3]), Y = tonumber(f[4]), Z = tonumber(f[5]) }
                if (l.X - to.X) ^ 2 + (l.Y - to.Y) ^ 2 + (l.Z - to.Z) ^ 2 > 1 then o:K2_SetActorLocation(to, false, {}, true) end
                local r, tr = o:K2_GetActorRotation(), { Pitch = (tonumber(f[6]) or 0), Yaw = (tonumber(f[7]) or 0), Roll = (tonumber(f[8]) or 0) }
                if M.rot and math.abs(r.Pitch - tr.Pitch) + math.abs(r.Yaw - tr.Yaw) + math.abs(r.Roll - tr.Roll) > 0.5 then o:K2_SetActorRotation(tr, false) end
                for i = 9, #f do
                    local name, nums = f[i]:match("^(.-)=(.*)$")
                    local c = name and st.names[name]
                    if c and c:IsValid() then
                        local v = {}
                        for x in nums:gmatch("[^,]+") do v[#v + 1] = tonumber(x) or 0 end
                        local old = st.vals[name] or {}
                        local function moved(a, b) for j = a, b do if math.abs((old[j] or 1e9) - v[j]) > 0.05 then return true end end end
                        if v[11] == 1 then -- host's body simulates: the guest's must not (it would roll or fall on its own)
                            if not st.off[name] then st.off[name] = true; c:SetSimulatePhysics(false) end
                            if moved(1, 6) then c:K2_SetWorldLocationAndRotation({ X = v[1], Y = v[2], Z = v[3] }, { Pitch = v[4], Yaw = v[5], Roll = v[6] }, false, {}, true) end
                        else
                            if moved(1, 3) then c:K2_SetRelativeLocation({ X = v[1], Y = v[2], Z = v[3] }, false, {}, true) end
                            if moved(4, 6) then c:K2_SetRelativeRotation({ Pitch = v[4], Yaw = v[5], Roll = v[6] }, false, {}, true) end
                        end
                        if moved(7, 9) then c:SetRelativeScale3D({ X = v[7], Y = v[8], Z = v[9] }) end
                        if moved(10, 10) then c:SetVisibility(v[10] == 1, false) end
                        st.vals[name] = v
                        M.applied = (M.applied or 0) + 1
                    end
                end
            end
        end
    end)
end)

return M
