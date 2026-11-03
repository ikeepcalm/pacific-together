-- Optional current-song transfer on the existing reliable connection; remote names never become disk paths.
local common, net, ov = require("common"), require("net"), require("overlay")
local M = { enabled = type(PTNative_MusicFinish) == "function" }
if not M.enabled then return M end
local MAX, BLOCK, WINDOW = 64 * 1024 * 1024, 8192, 2
local current, peers, incoming, serial = nil, {}, nil, 0
local function now() return os.clock() end
local function number(s, max)
    local n = tonumber(s)
    return n and n == n and n % 1 == 0 and n >= 0 and n <= max and n or nil
end
local function fields(s)
    if #s > BLOCK * 2 + 1100 then return {} end
    local t = {}; for p in (s .. "|"):gmatch("([^|]*)|") do t[#t + 1] = p end; return t
end
local function valid(f)
    return #f == 5 and f[1] == net.worldToken() and #f[2] == 64 and not f[2]:find("[^0-9a-f]")
        and number(f[3], MAX) and tonumber(f[3]) > 0 and (f[4] == "mp3" or f[4] == "wav" or f[4] == "ogg")
        and #f[5] <= 1024 and f[5]:match("^L:[^|%c]+$")
end
local function send(kind, data) return net.toHost("g.radio.file." .. kind, data) end
local function request(r)
    r.at = now()
    send("request", table.concat({ r.epoch, r.ticket, r.id }, "|"))
end
local function fail()
    local key = incoming and incoming.key
    PTNative_MusicCancel(); incoming = nil
    ov.post("Custom song unavailable", "info", "music")
    if key and M.failed then M.failed(key) end
end
local function ready(r, path)
    r.url, r.at = path, now()
    send("ready", table.concat({ r.epoch, r.ticket, r.id }, "|"))
    ov.post("Shared music ready", "good", "music")
end
function M.discard(key)
    if incoming and incoming.key ~= key then PTNative_MusicCancel(); incoming = nil end
end
function M.url(key, localUrl)
    local r = incoming
    if not r or r.key ~= key then return end
    if r.url then return r.url end
    if not r.started then
        if not r.cacheChecked then
            local path = PTNative_MusicCached(r.id, r.ext, r.size)
            if path == "pending" then return end
            r.cacheChecked = true
            if path ~= "" then ready(r, path); return path end
        end
        -- Identical local filenames are not proof of identical music.
        local info = PTNative_MusicInfo(localUrl or "")
        if info == "pending" then return end
        if info == r.id .. "|" .. r.size .. "|" .. r.ext then ready(r, localUrl); return localUrl end
        r.started = true
        if not PTNative_MusicBegin(r.id, r.ext, r.size) then fail(); return end
        ov.post("Downloading shared music", "info", "music")
        request(r)
    end
end
function M.host(key, uri)
    if not key then current, peers = nil, {}; return end
    local guests, supported = net.guests(), false
    for _, pc in ipairs(guests) do supported = supported or net.peerSupports(pc, "music-files") end
    if not supported then current, peers = nil, {}; return end
    local metadata = PTNative_MusicInfo(uri or "")
    if metadata == "pending" then current, peers = nil, {}; return end
    local id, size, ext = metadata:match("^([0-9a-f]+)|(%d+)|(%w+)$")
    local signature = key .. "|" .. metadata
    if not current or current.signature ~= signature then
        current, peers = { signature = signature, key = key, id = id, size = tonumber(size), ext = ext }, {}
    end
    for _, pc in ipairs(guests) do
        if net.peerSupports(pc, "music-files") and net.lifecycle(pc) == "active" then
            local p = peers[pc:GetAddress()]
            if not p or not common.resolve(p.lease) then p = { lease = common.lease(pc), at = -10 }; peers[pc:GetAddress()] = p end
            if not p.complete and now() - p.at > 2 then
                p.at = now()
                if id then net.toGuest(pc, "g.radio.file.offer", table.concat({ net.worldToken(), id, size, ext, key }, "|"))
                else net.toGuest(pc, "g.radio.file.unavailable", net.worldToken() .. "|" .. key) end
            end
        end
    end
end
net.on("g.radio.file.offer", function(_, data)
    if common.netMode() ~= "client" or not net.hostSupports("music-files") then return end
    local f = fields(data); if not valid(f) then return end
    if incoming and incoming.id == f[2] and incoming.key == f[5] and incoming.epoch == f[1]
        and incoming.size == tonumber(f[3]) and incoming.ext == f[4] then return end
    PTNative_MusicCancel(); serial = serial + 1
    incoming = { epoch = f[1], id = f[2], size = tonumber(f[3]), ext = f[4], key = f[5], ticket = serial, offset = 0, at = now() }
    if M.offered then M.offered(f[5]) end
end)
net.on("g.radio.file.unavailable", function(_, data)
    if common.netMode() ~= "client" or not net.hostSupports("music-files") then return end
    local f = fields(data)
    if #f == 2 and f[1] == net.worldToken() and #f[2] <= 1024 and f[2]:match("^L:[^|%c]+$") then
        if M.failed then M.failed(f[2]) end
    end
end)
local function peer(pc, f)
    if common.netMode() ~= "listen" or not net.peerSupports(pc, "music-files") or net.lifecycle(pc) ~= "active"
        or not current or f[1] ~= net.worldToken() or f[3] ~= current.id then return end
    local p = peers[pc:GetAddress()]
    return p and common.resolve(p.lease) and p or nil
end
net.on("g.radio.file.request", function(pc, data)
    local f = fields(data); if #f ~= 3 then return end
    local p, ticket = peer(pc, f), number(f[2], 9007199254740991)
    if not p or not ticket or ticket < 1 then return end
    if p.ticket and ticket < p.ticket then return end
    if p.ticket == ticket then return end
    p.ticket, p.sent, p.ack, p.touched, p.complete = ticket, 0, 0, now(), false
end)
net.on("g.radio.file.ack", function(pc, data)
    local f = fields(data); if #f ~= 4 then return end
    local p, at = peer(pc, f), number(f[4], MAX)
    if not p or not p.ticket or tonumber(f[2]) ~= p.ticket or not at or at < p.ack or at > p.sent then return end
    p.ack, p.touched = at, now()
end)
net.on("g.radio.file.ready", function(pc, data)
    local f = fields(data); if #f ~= 3 then return end
    local p, ticket = peer(pc, f), number(f[2], 9007199254740991)
    if not p or not ticket or ticket < 1 or (p.ticket and ticket ~= p.ticket) or p.complete then return end
    p.complete, p.ticket = true, ticket
    if M.ready then M.ready(current.key) end
end)
net.on("g.radio.file.data", function(_, data)
    if common.netMode() ~= "client" or not net.hostSupports("music-files") then return end
    local r, f = incoming, fields(data)
    if not r or not r.started or r.url or #f ~= 5 or f[1] ~= r.epoch or tonumber(f[2]) ~= r.ticket or f[3] ~= r.id then return end
    local at, hex = number(f[4], MAX), f[5]
    if not at or #hex == 0 or #hex > BLOCK * 2 or #hex % 2 ~= 0 or hex:find("[^0-9a-f]") or at + #hex / 2 > r.size then return end
    if at == r.offset then
        if not PTNative_MusicAppend(r.id, at, hex) then fail(); return end
        r.offset, r.at = at + #hex / 2, now()
    elseif at > r.offset then return end
    send("ack", table.concat({ r.epoch, r.ticket, r.id, r.offset }, "|"))
    if r.offset == r.size then
        local path = PTNative_MusicFinish(r.id)
        if path == "" then fail() else ready(r, path) end
    end
end)
LoopInGameThreadWithDelay(50, function()
    local mode = common.netMode()
    if mode ~= "client" and mode ~= "listen" then
        if incoming or current then PTNative_MusicCancel(); current, peers, incoming = nil, {}, nil end
        return
    end
    if mode == "client" then
        if incoming and incoming.started and not incoming.url and now() - incoming.at > 15 then fail() end
        return
    end
    if not current or not current.id then return end
    for _, p in pairs(peers) do
        local pc = common.resolve(p.lease)
        if pc and p.ticket and not p.complete and now() - p.touched < 15 and net.lifecycle(pc) == "active" then
            while p.sent < current.size and p.sent - p.ack < WINDOW * BLOCK do
                local hex = PTNative_MusicRead(current.id, p.sent)
                if hex == "" then break end
                local body = table.concat({ net.worldToken(), p.ticket, current.id, p.sent, hex }, "|")
                if not net.toGuest(pc, "g.radio.file.data", body) then break end
                p.sent = p.sent + #hex / 2
            end
        end
    end
end)
RegisterLoadMapPreHook(function()
    PTNative_MusicCancel(); current, peers, incoming, serial = nil, {}, nil, 0
end)
return M
