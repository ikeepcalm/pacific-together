-- Abductor (BP_Hazard_PhysicsGrabber) and Can Opener (BP_Hazard_SawBlade) move for the guest like on the host (W6, owner playtest 2026-11-17).
-- Why the guest saw nothing: the saw is a pure host-driven puppet. Its Mount component rides a spline on timelines started by its state machine
--   (PlayerRange of the HOST camera), the actor root never moves, so nothing replicates and the guest copy (tick off) stood still.
--   The Abductor's floating Core and its Magnet are simulated physics bodies detached from the root: on the guest they fell to the ground
--   under their own gravity (copy root z 9818, core z 9147 in the probe) because nothing drives them there.
-- The host (authority) sends, 10 times a second, for every saw and grabber within NEAR of a player: Mount position + blade rotation + visibility,
-- or Core and Magnet world transforms + the arm angle. The guest matches the copy by the (static) root position, turns the grabber's physics off
-- and shows the received transforms smoothed; the cable is the game's own UpdateCableMesh. Whatever the Abductor carries (the car, an item) is
-- moved by the host's physics and reaches the guest through car.lua / item replication as before.
-- The saw's hit on a guest pawn is the game's own overlap on the host (damage message to the pawn, forwarded by anomalies.lua).
-- Inert outside a session (Q7). Mutation noanommove switches the module off.
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local safety = require("safety")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "noanommove" }
local SAW, GRAB = "BP_Hazard_SawBlade_C", "BP_Hazard_PhysicsGrabber_C"
local NEAR = 15000 -- uu from any player
local function live(o) return o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and not o:GetFullName():find("Default__", 1, true) end
local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error anommove %s %s", what, tostring(err)) end
end
local function fetch(class)
    local r = {}
    for _, o in ipairs(FindAllOf(class) or {}) do if live(o) then r[#r + 1] = o end end
    return r
end

-- ---------------------------------------------------------------- host

local hostList, hostAt, sent, beat = {}, -99, {}, 0
RegisterLoadMapPreHook(function() hostList, hostAt, sent = {}, -99, {} end)

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
local function changed(a, b) -- a, b: arrays of numbers
    if not a then return true end
    for i = 1, #b do if math.abs(a[i] - b[i]) > 1 then return true end end
end

local function sawRow(o)
    local l, m, r = o:K2_GetActorLocation(), o.Mount.RelativeLocation, o.StaticMesh.RelativeRotation
    return { l.X, l.Y, m.X, m.Y, m.Z, r.Pitch, r.Yaw, r.Roll, o.StaticMesh:IsVisible() and 1 or 0 }
end
local function grabRow(o)
    local l, c, cr = o:K2_GetActorLocation(), o.CoreFloatingMesh:K2_GetComponentLocation(), o.CoreFloatingMesh:K2_GetComponentRotation()
    local g, gr = o.SM_PG_Magnet:K2_GetComponentLocation(), o.SM_PG_Magnet:K2_GetComponentRotation()
    return { l.X, l.Y, c.X, c.Y, c.Z, cr.Pitch, cr.Yaw, cr.Roll, g.X, g.Y, g.Z, gr.Pitch, gr.Yaw, gr.Roll, o.armAnim }
end

LoopInGameThreadWithDelay(100, function()
    if not (M.enabled and safety.active() and not safety.guest()) then return end
    try("host", function()
        if #net.guests() == 0 then return end
        beat = beat + 1
        local now = os.clock()
        if now - hostAt > 2 then -- the lists are refetched every 2 s, a spawned one shows up late
            hostList, hostAt = {}, now
            for _, o in ipairs(fetch(SAW)) do hostList[#hostList + 1] = { o = o, k = "S", row = sawRow } end
            for _, o in ipairs(fetch(GRAB)) do hostList[#hostList + 1] = { o = o, k = "G", row = grabRow } end
        end
        if #hostList == 0 then return end
        local pts, L = players(), {}
        for _, h in ipairs(hostList) do
            if h.o:IsValid() and near(h.o:K2_GetActorLocation(), pts) then
                local row = h.row(h.o)
                local key = h.o:GetAddress()
                if beat % 10 == 0 or changed(sent[key], row) then
                    sent[key] = row
                    local f = {}
                    for i, v in ipairs(row) do f[i] = string.format("%.1f", v) end
                    L[#L + 1] = h.k .. "\t" .. table.concat(f, "\t")
                end
            end
        end
        if #L > 0 then net.toGuests("g.anom.move", table.concat(L, "\n")); M.sent = (M.sent or 0) + #L end
    end)
end)

-- The saw's Logic Driver state machine does not run in a listen session (network config 0 = client only, like the garage doors, PT1-garage.md):
-- the blade stood at its start even for the host (probe 2026-11-18). The game's own steps stay: IDLE -> StartPreMove, PreMove done (state 1)
-- -> OnMoveStart, the rest (HitEndPoint, OnEndMove, state 0) chains by itself. A saw that has stood still in the same state for 2.5 s (the machine's
-- own tick is 1 s, so a working one never waits that long) is pushed to its next step. Only saws the game's range check has armed.
local still = {} -- address -> { sig, since }
LoopInGameThreadWithDelay(500, function()
    if not (M.enabled and M.drive ~= false and safety.active() and not safety.guest()) or #net.guests() == 0 then return end
    try("drive", function()
        local now = os.clock()
        for _, h in ipairs(hostList) do
            local o = h.o
            if h.k == "S" and o:IsValid() and o.DataBlock_PlayerInRange then
                local st = o.SawbladeState
                local busy = o.PreMoveTimeline:IsPlaying() or o.MovingTimeline:IsPlaying() or o.EndMoveTimeline:IsPlaying() or o.Timeline_0:IsPlaying()
                local sig, key = st .. (busy and "b" or "i"), o:GetAddress()
                local s = still[key]
                if busy or not s or s.sig ~= sig then still[key] = { sig = sig, since = now }
                elseif now - s.since > 2.5 then
                    s.since = now
                    if st == 0 then o:StartPreMove() elseif st == 1 then o:OnMoveStart() else o:OnEndMove() end
                    M.driven = (M.driven or 0) + 1
                end
            end
        end
    end)
end)

-- ---------------------------------------------------------------- guest

local copies, copiesAt = { S = {}, G = {} }, -99 -- the guest's own copies by kind
local target = {} -- copy address -> { o, k, v = row, t = when it arrived, shown = { ... } }
RegisterLoadMapPostHook(function() copies, copiesAt, target = { S = {}, G = {} }, -99, {} end)

local function copyAt(k, x, y)
    local now = os.clock()
    if now - copiesAt > 1 then
        copies.S, copies.G, copiesAt = fetch(SAW), fetch(GRAB), now
    end
    local best, bd = nil, 80 ^ 2
    for _, o in ipairs(copies[k == "S" and "S" or "G"]) do
        if o:IsValid() then
            local l = o:K2_GetActorLocation()
            local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
            if d < bd then best, bd = o, d end
        end
    end
    return best
end

net.on("g.anom.move", function(_, data)
    if not (M.enabled and safety.guest()) then return end
    try("recv", function()
        for line in data:gmatch("[^\n]+") do
            local f = {}
            for v in line:gmatch("[^\t]+") do f[#f + 1] = v end
            local k = table.remove(f, 1)
            local v = {}
            for i, s in ipairs(f) do v[i] = tonumber(s) or 0 end
            local o = #v >= 2 and copyAt(k, v[1], v[2])
            if o then
                local key = o:GetAddress()
                local t = target[key]
                if not t then t = { o = o, k = k }; target[key] = t end
                t.v, t.t = v, os.clock()
                M.applied = (M.applied or 0) + 1
            end
        end
    end)
end)

local function vec(a, i) return { X = a[i], Y = a[i + 1], Z = a[i + 2] } end
local function glide(cur, to, k) return { X = cur.X + (to.X - cur.X) * k, Y = cur.Y + (to.Y - cur.Y) * k, Z = cur.Z + (to.Z - cur.Z) * k } end

local lastFrame = os.clock()
LoopInGameThreadWithDelay(16, function()
    if not (M.enabled and safety.guest() and next(target)) then lastFrame = os.clock(); return end
    local now = os.clock()
    local k = math.min(1, (now - lastFrame) / 0.1) -- close the gap to the newest update over ~0.1 s
    lastFrame = now
    for key, t in pairs(target) do
        try("frame", function()
            local o, v = t.o, t.v
            if not (o:IsValid() and live(o)) or now - t.t > 5 then target[key] = nil return end
            if t.k == "S" then
                local m = o.Mount
                local cur = m.RelativeLocation
                local to = vec(v, 3)
                local d = (cur.X - to.X) ^ 2 + (cur.Y - to.Y) ^ 2 + (cur.Z - to.Z) ^ 2
                m:K2_SetRelativeLocation(d > 1500 ^ 2 and to or glide(cur, to, k), false, {}, true)
                o.StaticMesh:K2_SetRelativeRotation({ Pitch = v[6], Yaw = v[7], Roll = v[8] }, false, {}, true)
                local vis = v[9] == 1
                if t.vis ~= vis then t.vis = vis; o.StaticMesh:SetVisibility(vis, false) end
            else
                local core, mag = o.CoreFloatingMesh, o.SM_PG_Magnet
                if not t.off then -- the host's physics decides: the guest's bodies must not fall by themselves
                    t.off = true
                    core:SetSimulatePhysics(false); mag:SetSimulatePhysics(false)
                end
                local function put(c, i)
                    local cur, to = c:K2_GetComponentLocation(), vec(v, i)
                    local d = (cur.X - to.X) ^ 2 + (cur.Y - to.Y) ^ 2 + (cur.Z - to.Z) ^ 2
                    c:K2_SetWorldLocationAndRotation(d > 3000 ^ 2 and to or glide(cur, to, k), { Pitch = v[i + 3], Yaw = v[i + 4], Roll = v[i + 5] }, false, {}, true)
                end
                put(core, 3); put(mag, 9)
                if t.arm ~= v[15] then t.arm = v[15]; o:AnimateArm(v[15]) end
                o:UpdateCableMesh()
            end
            M.shown = (M.shown or 0) + 1
        end)
    end
end)

return M
