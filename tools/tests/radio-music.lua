local root = assert(arg[1]):gsub("\\", "/")
local path = root .. "/mod/PacificTogether/Scripts/"
for _, name in ipairs({ "radio", "radiomusic", "net", "common" }) do assert(loadfile(path .. name .. ".lua")) end
local passed = 0
local function check(name, fn) fn(); passed = passed + 1; print("PASS " .. name) end
local A, B = string.rep("a", 64), string.rep("b", 64)
local function pair(options)
    options = options or {}
    local time, messages, host, guest, done, chunks = 0, {}, nil, nil, 0, 0
    local source = { id = A, size = 25001, ext = "mp3", bytes = string.rep("ab", 25001) }
    local pc = { uid = 1, GetAddress = function() return 1 end }
    local function context(mode)
        local s = { mode = mode, epoch = "world", handlers = {}, loops = {}, resets = {}, begins = 0, infoCalls = 0, cache = {}, bytes = nil }
        local net = {
            worldToken = function() return s.epoch end,
            hostSupports = function() return options.supported ~= false end,
            peerSupports = function() return options.supported ~= false end,
            lifecycle = function() return s.active == false and "loading" or "active" end,
            guests = function() return { pc } end,
            on = function(k, fn) s.handlers[k] = fn end,
            toHost = function(k, d) messages[#messages + 1] = { to = "host", kind = k, data = d }; return true end,
            toGuest = function(_, k, d) if k == "g.radio.file.data" then chunks = chunks + 1 end; messages[#messages + 1] = { to = "guest", kind = k, data = d }; return true end,
        }
        local common = {
            netMode = function() return s.mode end,
            lease = function(o) return { object = o, uid = o.uid } end,
            resolve = function(l) return l and l.uid == l.object.uid and l.object or nil end,
        }
        local function info()
            s.infoCalls = s.infoCalls + 1
            if options.hashTicks and s.infoCalls <= options.hashTicks then return "pending" end
            if mode == "listen" or options.localMatch then return source.id .. "|" .. source.size .. "|" .. source.ext end
            return options.sameNameWrongBytes and (B .. "|" .. source.size .. "|" .. source.ext) or ""
        end
        local env = setmetatable({
            os = { clock = function() return time end },
            require = function(n) if n == "net" then return net elseif n == "common" then return common else assert(n == "overlay"); return { post = function() end } end end,
            PTNative_MusicInfo = info,
            PTNative_MusicCached = function(id)
                s.cacheCalls = (s.cacheCalls or 0) + 1
                if options.cacheTicks and s.cacheCalls <= options.cacheTicks then return "pending" end
                return s.cache[id] or ""
            end,
            PTNative_MusicBegin = function() s.begins = s.begins + 1; s.bytes = ""; return not options.diskFailure end,
            PTNative_MusicAppend = function(_, at, hex) assert(#s.bytes / 2 == at); s.bytes = s.bytes .. hex; return true end,
            PTNative_MusicFinish = function(id)
                if options.corrupt or s.bytes ~= source.bytes then return "" end
                local url = "file://cache/" .. id .. ".mp3"; s.cache[id] = url; return url
            end,
            PTNative_MusicRead = function(id, at) assert(id == source.id); return source.bytes:sub(at * 2 + 1, (at + 8192) * 2) end,
            PTNative_MusicCancel = function() s.bytes = nil end,
            LoopInGameThreadWithDelay = function(_, fn) s.loops[#s.loops + 1] = fn end,
            RegisterLoadMapPreHook = function(fn) s.resets[#s.resets + 1] = fn end,
        }, { __index = _G })
        s.api = assert(loadfile(path .. "radiomusic.lua", "t", env))()
        return s
    end
    host, guest = context("listen"), context("client")
    host.api.ready = function() done = done + 1 end
    guest.api.failed = function() guest.failed = true end
    local function deliver()
        while #messages > 0 do
            local m = table.remove(messages, 1); local s = m.to == "host" and host or guest
            assert(s.handlers[m.kind], m.kind)(pc, m.data)
            if options.duplicate and m.kind == "g.radio.file.data" then s.handlers[m.kind](pc, m.data) end
        end
    end
    local key, uri = "L:same-name.mp3", "file://C:/host/same-name.mp3"
    local function tick()
        time = time + .05
        host.api.host(key, uri); deliver()
        guest.api.url(key, "file://C:/guest/same-name.mp3"); deliver()
        for _, s in ipairs({ host, guest }) do for _, fn in ipairs(s.loops) do fn() end end
        deliver()
    end
    return {
        host = host, guest = guest, source = source, pc = pc, tick = tick, deliver = deliver,
        done = function() return done end, chunks = function() return chunks end,
        run = function() for _ = 1, 20 do tick() end; return guest.api.url(key) end,
        inject = function(to, kind, data) (to == "host" and host or guest).handlers["g.radio.file." .. kind](pc, data) end,
        advance = function(n) time = time + n end,
        change = function(id) source.id = id; source.bytes = string.rep(id:sub(1, 2), source.size) end,
    }
end
check("missing file arrives intact and schedules a shared restart", function()
    local p = pair(); assert(p.run() == "file://cache/" .. A .. ".mp3"); assert(p.guest.begins == 1 and p.done() == 1); assert(p.chunks() == 4)
end)
check("same filename with different contents is replaced only in the cache", function()
    local p = pair({ sameNameWrongBytes = true }); assert(p.run()); assert(p.guest.begins == 1)
end)
check("matching local file avoids download", function()
    local p = pair({ localMatch = true }); assert(p.run() == "file://C:/guest/same-name.mp3"); assert(p.chunks() == 0 and p.guest.begins == 0 and p.done() == 1)
end)
check("incremental local hashing never becomes a playback URL", function()
    local p = pair({ hashTicks = 3, localMatch = true }); assert(p.run() == "file://C:/guest/same-name.mp3"); assert(p.guest.begins == 0 and p.done() == 1)
end)
check("incremental cache verification completes before playback", function()
    local p = pair({ cacheTicks = 3 }); p.guest.cache[A] = "file://verified.mp3"
    assert(p.run() == "file://verified.mp3"); assert(p.chunks() == 0 and p.guest.begins == 0)
end)
check("verified cache avoids another download", function()
    local p = pair(); assert(p.run()); local chunks = p.chunks()
    for _, fn in ipairs(p.guest.resets) do fn() end
    for _, fn in ipairs(p.host.resets) do fn() end
    assert(p.run()); assert(p.chunks() == chunks and p.guest.begins == 1)
end)
check("duplicate data is idempotent", function() local p = pair({ duplicate = true }); assert(p.run() and p.guest.begins == 1 and p.done() == 1) end)
check("legacy peer receives no extension or file reads", function()
    local p = pair({ supported = false }); p.run()
    p.inject("guest", "offer", "world|" .. A .. "|25001|mp3|L:same-name.mp3"); p.guest.api.url("L:same-name.mp3", "")
    assert(p.chunks() == 0 and p.guest.begins == 0 and p.host.infoCalls == 0)
end)
check("bulk waits for applied baseline", function()
    local p = pair(); p.host.active = false; p.run(); assert(p.guest.begins == 0); p.host.active = true; assert(p.run())
end)
check("invalid metadata never opens a destination", function()
    local p = pair()
    for _, data in ipairs({ "old|" .. A .. "|1|mp3|L:a", "world|../bad|1|mp3|L:a", "world|" .. A .. "|67108865|wav|L:a", "world|" .. A .. "|1|exe|L:a", "world|" .. A .. "|nan|mp3|L:a" }) do p.inject("guest", "offer", data) end
    p.guest.api.url("L:a", "file://C:/guest/a"); assert(p.guest.begins == 0)
end)
check("unexpected acknowledgements and request replays are harmless", function()
    local p = pair(); p.host.api.host("L:same-name.mp3", "file://C:/host/a.mp3"); p.deliver()
    p.inject("host", "ack", "world|1|" .. A .. "|100")
    p.tick(); assert(p.run())
    p.inject("host", "request", "world|0|" .. A); assert(p.done() == 1)
end)
check("world, ticket, hash, offset and hex are checked before writes", function()
    local p = pair(); p.host.api.host("L:same-name.mp3", "file://C:/host/a.mp3"); p.deliver(); p.guest.api.url("L:same-name.mp3", "")
    local before = p.guest.bytes
    for _, data in ipairs({ "old|1|" .. A .. "|0|ab", "world|9|" .. A .. "|0|ab", "world|1|" .. B .. "|0|ab", "world|1|" .. A .. "|1|ab", "world|1|" .. A .. "|0|zz" }) do p.inject("guest", "data", data) end
    assert(p.guest.bytes == before); assert(p.run())
end)
check("failed integrity never reaches playback", function() local p = pair({ corrupt = true }); assert(not p.run()); assert(p.guest.failed and p.done() == 0) end)
check("disk failure falls back without publishing a partial file", function() local p = pair({ diskFailure = true }); assert(not p.run()); assert(p.guest.failed and p.done() == 0) end)
check("travel cancels partial data and rejects previous-world messages", function()
    local p = pair(); p.host.api.host("L:same-name.mp3", "file://C:/host/a.mp3"); p.deliver(); p.guest.api.url("L:same-name.mp3", "")
    for _, fn in ipairs(p.guest.resets) do fn() end; p.guest.epoch = "next"
    p.inject("guest", "data", "world|1|" .. A .. "|0|ab"); assert(not p.guest.bytes and not p.guest.api.url("L:same-name.mp3"))
end)
check("a different song with the same name requires its own content", function()
    local p = pair(); assert(p.run()); p.change(B); assert(p.run() == "file://cache/" .. B .. ".mp3"); assert(p.guest.begins == 2 and p.done() == 2)
end)
check("disconnect with no progress drops the partial file", function()
    local p = pair(); p.host.api.host("L:same-name.mp3", "file://C:/host/a.mp3"); p.deliver(); p.guest.api.url("L:same-name.mp3", "")
    p.advance(16); for _, fn in ipairs(p.guest.loops) do fn() end; assert(p.guest.failed and not p.guest.bytes)
end)
check("leaving multiplayer aborts without waiting for a map hook", function()
    local p = pair(); p.host.api.host("L:same-name.mp3", "file://C:/host/a.mp3"); p.deliver(); p.guest.api.url("L:same-name.mp3", "")
    p.guest.mode = "standalone"; for _, fn in ipairs(p.guest.loops) do fn() end
    assert(not p.guest.bytes and not p.guest.api.url("L:same-name.mp3"))
end)
print("PASS " .. passed .. " radio music checks; no games started")
