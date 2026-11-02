-- Messages between host and guest for features (intents up, state down), on the native channel (msg.cpp).
-- Kinds start with "g." (the test mod owns "t."). Handlers run on the game thread: fn(fromPC, data); on the guest
-- fromPC is its own controller (the host is the only sender).
--   local net = require("net")
--   net.on("g.car", function(pc, data) ... end)
--   net.toHost("g.repair", data)   guest      net.toGuests("g.car", data)   host
local UEHelpers = require("UEHelpers")
local common = require("common")
local log = common.log
assert(type(PTNative_MsgReset) == "function", "PacificTogetherNative is outdated: update main.dll together with the Lua mod")

local M = {}
local handlers = {}

function M.on(kind, fn) handlers[kind] = fn end
M.heardAt = {} -- kind -> os.clock() when its last message was handled

local function localPC()
    local pc = UEHelpers.GetPlayerController()
    return pc and pc:IsValid() and pc or nil
end

-- every send and every received message looked the controllers up (1340 times a minute on a host, PT|perf 2026-10-22):
-- the list is reused for 100 ms; a sender not in it looks again
local pcs, pcsAt = {}, -1
RegisterLoadMapPreHook(function()
    pcs, pcsAt, M.heardAt = {}, -1, {}
    -- Native queues outlive Lua worlds; no fragment or pending message belongs to the next map.
    if os.getenv("PT_MUTATE") ~= "nomessageepoch" then PTNative_MsgReset() end
end)
local function controllers(fresh)
    if fresh or os.clock() - pcsAt > 0.1 then pcs, pcsAt = FindAllOf("PlayerController") or {}, os.clock() end
    return pcs
end

-- the host's controllers for its guests
function M.guests()
    local list = {}
    for _, pc in ipairs(controllers()) do
        if pc:IsValid() and not pc:IsLocalController() then list[#list + 1] = pc end
    end
    return list
end

function M.toHost(kind, data)
    local pc = localPC()
    return pc ~= nil and PTNative_MsgToHost ~= nil and PTNative_MsgToHost(pc:GetAddress(), kind, data or "")
end

-- Host -> guest flow control: every message is reliable RPCs on the guest's controller (1000-byte chunks, msg.cpp), and the
-- engine closes the connection once 256 reliable bunches wait for an ack ("Reliable buffer overflow", the guest dropped on joining
-- a zone from a big save, 2026-10-24; netflow: "Reliable partial bunch overflows reliable buffer! NumOutRec: 254"). A chunk is 2
-- bunches (3 when a byte is >= 0x80: the FString goes out as UTF-16). The guest reports how many messages it got (g.net.ack, also
-- every 2 s); past WINDOW unacked bunches the rest waits here, in order. Nothing goes out before the guest's first ack on this
-- connection: a guest still loading the map has no channel for them (10 s at most, then sent anyway).
local WINDOW = 160 -- of 256: the game's own RPCs on the controller share the channel
local flow = {} -- controller address -> { pc, queue = { {kind, data, cost} }, inflight = { cost... }, acked, ackAt, at }
RegisterLoadMapPreHook(function() flow = {} end)
local function costOf(data) return math.ceil((#data + 40) / 1000) * (data:find("[\128-\255]") and 3 or 2) end
local function flowFor(pc)
    local key = pc:GetAddress()
    local f = flow[key]
    if not f or not f.pc:IsValid() or f.name ~= pc:GetFullName() then
        f = { pc = pc, name = pc:GetFullName(), queue = {}, inflight = {}, at = os.clock(), ackAt = os.clock() }
        flow[key] = f
    end
    return f
end
-- Until the guest's own character has arrived (g.net.ready) only these go out; the rest waits. After a junction the host pushed ~1 MB
-- of loot lists, world positions and radiation volumes at a guest still loading: its character came 48 s late and it left the car
-- into a half-loaded world and fell through it (zoneexit, 2026-10-24).
local URGENT = { "g.car.", "g.pause.", "g.health.", "g.net.", "g.ping." }
local function urgent(kind)
    for _, p in ipairs(URGENT) do if kind:sub(1, #p) == p then return true end end
    return false
end
local function drain(f)
    if f.acked == nil then
        if os.clock() - f.at < 10 then return end
        f.acked = 0
        log("PT|net no ack from the guest 10 s after its controller appeared, sending")
    end
    if not f.ready and (os.getenv("PT_MUTATE") == "noready" or os.clock() - f.at > 90) then
        f.ready = true
        log("PT|net guest not ready 90 s after its controller appeared, sending everything")
    end
    while #f.queue > 0 do
        local i = 1
        if not f.ready then
            while i <= #f.queue and not urgent(f.queue[i][1]) do i = i + 1 end
            if i > #f.queue then return end
        end
        local m = f.queue[i]
        local out = 0
        for _, c in ipairs(f.inflight) do out = out + c end
        if out > 0 and out + m[3] > WINDOW then return end
        table.remove(f.queue, i)
        if not PTNative_MsgToGuest(f.pc:GetAddress(), m[1], m[2]) then return end
        f.inflight[#f.inflight + 1] = m[3]
    end
end
-- bytes sent per kind, logged every 30 s (the guest's pawn waited minutes behind our traffic, hand play 2026-10-24)
local byKind, byAt = {}, os.clock()
function M.toGuest(pc, kind, data)
    if not (pc:IsValid() and PTNative_MsgToGuest ~= nil) then return false end
    data = data or ""
    byKind[kind] = (byKind[kind] or 0) + #data
    if os.clock() - byAt > 30 then
        local L = {}
        for k, v in pairs(byKind) do L[#L + 1] = { k, v } end
        table.sort(L, function(a, b) return a[2] > b[2] end)
        local s = {}
        for i = 1, math.min(8, #L) do s[i] = string.format("%s=%.0fK", L[i][1], L[i][2] / 1024) end
        log("PT|net bytes per kind in %.0f s: %s", os.clock() - byAt, table.concat(s, " "))
        byKind, byAt = {}, os.clock()
    end
    if os.getenv("PT_MUTATE") == "noflow" then return PTNative_MsgToGuest(pc:GetAddress(), kind, data) end
    -- transition.lua's one-word notices skip the queue: after a map load they would wait behind the loot lists for the guest
    if kind == "g.trans" then return PTNative_MsgToGuest(pc:GetAddress(), kind, data) end
    local f = flowFor(pc)
    f.queue[#f.queue + 1] = { kind, data, costOf(data) }
    drain(f)
    return true
end
-- queued messages also go out between sends; no ack for 20 s while some wait (a lost ack, or a long load on the guest): the
-- engine would have dropped a really full buffer by now, so the window starts over
LoopInGameThreadWithDelay(100, function()
    for key, f in pairs(flow) do
        if not f.pc:IsValid() then flow[key] = nil
        elseif #f.queue > 0 then
            if f.acked and #f.inflight > 0 and os.clock() - f.ackAt > 20 then
                f.inflight, f.ackAt = {}, os.clock()
                log("PT|net no ack from the guest for 20 s, window reset (%d queued)", #f.queue)
            end
            pcall(drain, f)
        end
    end
end)
M.on("g.net.ready", function(pc)
    local f = flowFor(pc)
    if not f.ready then
        f.ready = true
        log("PT|net guest ready after %.1f s, %d messages waiting", os.clock() - f.at, #f.queue)
        drain(f)
        if M.ready then pcall(M.ready, pc) end -- transition.lua lets go of the held loading screen
    end
end)
M.on("g.net.ack", function(pc, data)
    local n = tonumber(data) or 0
    local f = flowFor(pc)
    if f.acked == nil or n < f.acked then -- first ack on this connection (or the guest's count restarted): nothing of ours in flight
        f.acked, f.inflight = n, {}
    end
    for _ = 1, n - f.acked do if #f.inflight > 0 then table.remove(f.inflight, 1) end end
    f.acked = n
    f.ackAt = os.clock()
    drain(f)
end)

-- netflow scenario only (PT_SCENARIO is set by the test runner, never by players): the host bursts 400 x 1 KB at a guest 10 s
-- after it joined, the guest reports its count to the host's test mod
if os.getenv("PT_SCENARIO") == "netflow" then
    local got, since, done = 0, nil, false
    M.on("g.net.test", function(pc)
        got = got + 1
        if got % 100 == 0 then log("PT|net test got %d (%s)", got, PTNative_MsgStats and PTNative_MsgStats() or "") end
        if got == 400 then log("PT|net test report sent=%s", tostring(PTNative_MsgToHost(pc:GetAddress(), "t.netflow", tostring(got)))) end
    end)
    LoopInGameThreadWithDelay(500, function()
        if done or common.netMode() ~= "listen" then return end
        if #M.guests() == 0 then since = nil; return end
        since = since or os.clock()
        if os.clock() - since < 10 then return end
        done = true
        local blob = string.rep("x", 1000)
        for _ = 1, 400 do M.toGuests("g.net.test", blob) end
        log("PT|net test burst sent (%s)", PTNative_MsgStats and PTNative_MsgStats() or "")
        ExecuteInGameThreadWithDelay(20000, function() log("PT|net test 20 s later (%s)", PTNative_MsgStats and PTNative_MsgStats() or "") end)
    end)
end

function M.toGuests(kind, data)
    local n = 0
    for _, pc in ipairs(M.guests()) do if M.toGuest(pc, kind, data) then n = n + 1 end end
    return n
end

local function sender(address)
    for _, fresh in ipairs({ false, true }) do
        for _, pc in ipairs(controllers(fresh)) do
            if pc:IsValid() and pc:GetAddress() == address then return pc end
        end
    end
end

-- guest: messages got from the host since this map's connection, reported for the host's flow control
local received, ackSent, readySent = 0, -1, false
RegisterLoadMapPreHook(function() received, ackSent, readySent = 0, -1, false end)
local function dispatch()
    if not PTNative_MsgPoll then return end
    while true do
        local kind, data, from = PTNative_MsgPoll("g.")
        if not kind then return end
        if common.netMode() == "client" then received = received + 1 end -- every one, handled or not: the host counts them all
        local fn, pc = handlers[kind], sender(from)
        if not fn then
            log("PT|error net no handler for %s", kind)
        elseif pc then
            local t0 = os.clock()
            local ok, err = pcall(fn, pc, data)
            if not ok then log("PT|error net %s %s", kind, tostring(err)) end
            M.heardAt[kind] = os.clock()
            -- which handler holds the frame (playtest 2026-10-24: this loop took 0.7-2.2 s at a time on both sides)
            if M.heardAt[kind] - t0 > 0.05 then log("PT|slow net %s %.0f ms %d bytes", kind, (M.heardAt[kind] - t0) * 1000, #data) end
            if M.tap then pcall(M.tap, kind) end -- after the handler: car.lua drops its part cache once a guest changed a part
        end
    end
end

-- every frame: intents should feel instant
LoopInGameThreadWithDelay(16, function()
    local ok, err = pcall(dispatch)
    if not ok then log("PT|error net dispatch %s", tostring(err)) end
end)
-- the guest's ack: ten times a second while messages come in, every 2 s anyway (the host holds its messages until the first)
local ackAt = 0
LoopInGameThreadWithDelay(100, function()
    if common.netMode() ~= "client" then return end
    if not readySent then -- the host holds everything but urgent messages until our own character is here
        local p = localPC() and localPC().Pawn
        if p and p:IsValid() and p:IsA(StaticFindObject("/Script/PenDriverPro.BaseCharacter")) then
            readySent = M.toHost("g.net.ready", "") and true or false
        end
    end
    if received == ackSent and os.clock() - ackAt < 2 then return end
    ackSent, ackAt = received, os.clock()
    pcall(M.toHost, "g.net.ack", tostring(received))
end)

-- A connection may send CurrentNetSpeed bytes per second, but its budget grows per net tick by a clamped frame time (our
-- reading of UNetConnection::Tick, not checked in the binary): at 16 fps (two rendered games on the owner's laptop) the 100000
-- the game negotiates was far less in practice. One window of our chunks
-- (~48 KB) or a joining guest's state saturated it, and a saturated connection gets no actor replication and no move acks:
-- the host stood still on the guest's screen for minutes and the guest hit "96 saved moves" (rendered lane 2026-10-24, engine
-- log "Saturated. Mark PDP_MainCharacter_C NetUpdateTime"). 1 MB/s drained a 300 KB burst in under 3 s; at 100000 the
-- guest saw nothing for 15 s and more. Real bandwidth stays what the game and we actually send.
local SPEED = os.getenv("PT_MUTATE") == "oldspeed" and 0 or 1000000
LoopInGameThreadWithDelay(500, function()
    if SPEED == 0 then return end
    pcall(function()
        for _, pc in ipairs(controllers()) do
            local nc = pc:IsValid() and pc.NetConnection
            if nc and nc:IsValid() and nc.CurrentNetSpeed < SPEED then
                nc.CurrentNetSpeed = SPEED
                local d = nc.Driver
                if d and d:IsValid() and d.MaxClientRate < SPEED then d.MaxClientRate, d.MaxInternetClientRate = SPEED, SPEED end
                log("PT|net speed %s raised to %d", pc:IsLocalController() and "to host" or "to guest", SPEED)
            end
        end
    end)
end)

return M
