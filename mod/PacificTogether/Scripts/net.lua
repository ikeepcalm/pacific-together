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
-- Extensions ride the author's PT1/PT1A contract, only after both peers opt in.
local offered = "motion,door-motion,foliage,drop-velocity,item-state,intents,heap" .. (PTNative_TunnelMotionSend and ",datagrams" or "")
if os.getenv("PT_MUTATE")=="nodoormotion" then offered=offered:gsub(",door%-motion","") end
-- The simulated guest chassis fights pose correction; retain it only as a failing test control.
if os.getenv("PT_MUTATE") == "physicalcar" then offered = offered .. ",physical-car" end
if PTNative_MusicFinish then offered = offered .. ",music-files" end
local hostFeatures, hostEpoch, hostTicket, serial, baselineComplete = {}, nil, nil, 0, false
local peers = {}
local baselineParts, motionSeen = {}, {}
local worldEpoch = string.format("%x-%x", os.time(), math.random(1, 0x7fffffff))
local function features(s)
    local t = {}; for v in s:gmatch("[^,]+") do t[v] = true end; return t
end
function M.worldToken()
    if common.netMode() == "client" then return hostEpoch end
    return worldEpoch
end
function M.hostSupports(feature) return hostFeatures[feature] == true end
function M.peerSupports(pc, feature)
    local p = peers[pc:GetAddress()]
    return p and common.resolve(p.lease) and p.name == pc:GetFullName() and p.features[feature] == true or false
end
local function protected(kind)
    return kind == "g.heap.intent" or kind:find("^g%.parts%.") or kind == "g.rescue.do" or kind == "g.story.task"
        or kind:find("^g%.act%.") or kind:find("^g%.st%.") or kind == "g.loot.b" or kind == "g.swap.set"
        or kind == "g.garage.btn" or kind == "g.garage.charge" or kind == "g.car.ctl"
        or kind == "g.vis.keypad" or kind == "g.car.enter" or kind == "g.car.exit" or kind == "g.car.door"
end
local function permitted(pc, kind, data)
    if common.netMode() ~= "listen" or not protected(kind) then return true end
    local info = require("session").guestInfo(pc)
    return info and (info.caps ~= "mv" or (kind == "g.loot.b" and data == "H"))
end
RegisterLoadMapPreHook(function()
    hostFeatures, hostEpoch, hostTicket, serial, peers, baselineComplete, baselineParts = {}, nil, nil, 0, {}, false, {}
    worldEpoch = string.format("%x-%x", os.time(), math.random(1, 0x7fffffff))
    motionSeen = {}
    if PTNative_TunnelMotionReset then PTNative_TunnelMotionReset() end
end)

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
    if kind:sub(1, 13) == "g.radio.file." and not M.hostSupports("music-files") then return false end
    if kind == "g.heap.intent" and not M.hostSupports("heap") then return false end
    if protected(kind) and M.hostSupports("intents") then
        serial = serial + 1
        local pawn = pc and pc.Pawn
        if not (pawn and pawn:IsValid()) then return false end
        data, kind = hostEpoch .. "|" .. serial .. "|" .. hostTicket .. "|" .. kind .. "|" .. (data or ""), "g.net.intent"
    end
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
    if not f or not common.resolve(f.lease) or f.name ~= pc:GetFullName() then
        f = { pc = pc, name = pc:GetFullName(), lease = common.lease(pc), queue = {}, inflight = {}, at = os.clock(), ackAt = os.clock() }
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
        while i <= #f.queue and not urgent(f.queue[i][1]) do i = i + 1 end
        if i > #f.queue then
            if not f.ready then return end
            i = 1
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
    if kind:sub(1, 13) == "g.radio.file." and not M.peerSupports(pc, "music-files") then return false end
    if kind == "g.heap.fx" and not M.peerSupports(pc, "heap") then return false end
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
    if kind:sub(1, 9) == "g.motion." then
        if os.getenv("PT_MUTATE") ~= "nodgramlane" and M.peerSupports(pc, "datagrams") and PTNative_TunnelMotionSend
            and PTNative_TunnelMotionSend(kind, worldEpoch .. "|" .. data) then return true end
        return M.peerSupports(pc, "motion") and PTNative_MsgMotionToGuest ~= nil
            and PTNative_MsgMotionToGuest(pc:GetAddress(), kind, data) or false
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
        if not common.resolve(f.lease) then flow[key], peers[key] = nil, nil
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
        if f.baselineApplied or (require("session").guestInfo(pc) or {}).caps ~= "mv" then
            f.baseline = true
            if M.ready then pcall(M.ready, pc) end
        end
    end
end)
M.on("g.net.cap", function(pc, data)
    local epoch, list, ticket = data:match("^([^|]+)|([^|]+)|([^|]+)$")
    if not epoch or #epoch > 64 or #ticket > 128 then return end
    if common.netMode() == "client" then
        if hostEpoch ~= epoch then motionSeen = {} end
        if hostEpoch ~= epoch or hostTicket ~= ticket then serial, baselineComplete = 0, false end
        hostEpoch, hostTicket, hostFeatures = epoch, ticket, features(list)
        M.toHost("g.net.cap", epoch .. "|" .. offered .. "|" .. ticket)
        M.baselineComplete()
    elseif common.netMode() == "listen" and epoch == worldEpoch then
        local info = require("session").guestInfo(pc)
        if info and info.caps == "mv" and flowFor(pc).ticket == ticket then
            local previous = peers[pc:GetAddress()]
            peers[pc:GetAddress()] = { name = pc:GetFullName(), lease = common.lease(pc), features = features(list), ticket = ticket, pawnLease = flowFor(pc).pawnLease,
                serial = previous and previous.ticket == ticket and previous.name == pc:GetFullName() and previous.serial or 0 }
        end
    end
end)
M.on("g.net.intent", function(pc, data)
    if common.netMode() ~= "listen" or not M.peerSupports(pc, "intents") then return end
    local epoch, n, ticket, kind, payload = data:match("^([^|]+)|(%d+)|([^|]+)|([^|]+)|(.*)$")
    n = tonumber(n)
    local peer = peers[pc:GetAddress()]
    if epoch ~= worldEpoch or not n or n % 1 ~= 0 or n <= peer.serial or n > 9007199254740991
        or not protected(kind) or not handlers[kind] or not pc.Pawn:IsValid()
        or ticket ~= peer.ticket or not common.resolve(peer.pawnLease)
        or common.identity(pc.Pawn) ~= peer.pawnLease.key
        or (not flowFor(pc).baseline and not (kind == "g.loot.b" and payload == "H"))
        or not require("session").guestInfo(pc) then return end
    peer.serial = n -- Consume before calling: an exception must not replay a partly applied action.
    handlers[kind](pc, payload)
    M.heardAt[kind] = os.clock()
    if M.tap then M.tap(kind) end
end)
function M.baselineComplete(part)
    if part then baselineParts[part] = true end
    local complete = baselineParts.loot and baselineParts.car and (baselineParts.visual or not M.hostSupports("intents"))
    if complete and not baselineComplete and M.hostSupports("intents") then M.toHost("g.net.baseline", hostEpoch) end
    baselineComplete = complete and true or false
end
function M.lifecycle(pc)
    if common.netMode() == "client" then return baselineComplete and "active" or "loading" end
    local f = pc and flow[pc:GetAddress()]
    if not f or not common.resolve(f.lease) then return "disconnected" end
    return f.baseline and "active" or (f.ready and "baseline" or "loading")
end
M.on("g.net.baseline", function(pc, data)
    if common.netMode() ~= "listen" or data ~= worldEpoch or not M.peerSupports(pc, "intents") then return end
    local f = flowFor(pc)
    f.baselineApplied = true
    if f.ready and not f.baseline then
        f.baseline = true
        log("PT|net baseline applied after %.1f s", os.clock() - f.at)
        if M.ready then M.ready(pc) end
    end
end)
M.on("g.net.ack", function(pc, data)
    local n = tonumber(data)
    if not n or n ~= n or n < 0 or n % 1 ~= 0 or n > 9007199254740991 then return end
    local info = common.netMode() == "listen" and require("session").guestInfo(pc)
    local f = flowFor(pc)
    if info and info.caps == "mv" and common.identity(pc.Pawn) then
        if not common.resolve(f.pawnLease) or common.identity(pc.Pawn) ~= f.pawnLease.key then
            f.pawnLease = common.lease(pc.Pawn)
            f.ticket = worldEpoch .. ":" .. f.pawnLease.key
        end
        local peer = peers[pc:GetAddress()]
        if not M.peerSupports(pc, "intents") or peer.ticket ~= f.ticket then
            M.toGuest(pc, "g.net.cap", worldEpoch .. "|" .. offered .. "|" .. f.ticket)
        end
    end
    if f.acked == nil or n < f.acked then -- first ack on this connection (or the guest's count restarted): nothing of ours in flight
        f.acked, f.inflight = n, {}
    end
    for _ = 1, math.min(n - f.acked, #f.inflight) do if #f.inflight > 0 then table.remove(f.inflight, 1) end end
    f.acked = n
    f.ackAt = os.clock()
    drain(f)
end)

-- Test bot calls the actual shipping sender across UE4SS's separate Lua states.
if os.getenv("PT_SCENARIO") then
    local function testIntent(data, tries)
        if common.netMode() ~= "client" then return end
        if not baselineComplete then
            if tries < 1500 then common.defer(100, function() testIntent(data, tries + 1) end) end
            return
        end
        local kind, payload = data:match("^([^|]+)|(.*)$")
        if kind and kind:sub(1, 2) == "g." then M.toHost(kind, payload) end
    end
    M.on("g.net.testintent", function(_, data) testIntent(data, 0) end)
    M.on("g.net.testready", function(pc) PTNative_MsgToGuest(pc:GetAddress(), "t.baseline", "") end)
end

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
        if common.netMode() == "client" and kind:sub(1, 9) ~= "g.motion." and kind ~= "g.net.testintent" then received = received + 1 end -- motion has its own native window, outside the reliable gameplay queue
        local fn, pc = handlers[kind], sender(from)
        if not fn then
            log("PT|error net no handler for %s", kind)
        elseif pc and permitted(pc, kind, data) then
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
    if PTNative_TunnelMotionPoll then
        while true do
            local kind, data, sequence = PTNative_TunnelMotionPoll("g.motion.")
            if not kind then break end
            local epoch, payload = data:match("^([^|]+)|(.*)$")
            if common.netMode() == "client" and M.hostSupports("datagrams") and epoch == hostEpoch
                and sequence > (motionSeen[kind] or -1) and handlers[kind] then
                motionSeen[kind] = sequence
                local applied, why = pcall(handlers[kind], localPC(), payload)
                if not applied then log("PT|error motion %s %s", kind, tostring(why)) end
                M.heardAt[kind] = os.clock()
            end
        end
    end
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
