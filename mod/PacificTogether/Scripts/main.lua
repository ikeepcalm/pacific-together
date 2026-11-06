local UEHelpers = require("UEHelpers")
local common = require("common")
local log = common.log

-- One file per feature, so parallel work does not collide; each module sets itself up when required.
local FEATURES = { "foliage", "overlay", "steam", "session", "safety", "nametag", "health", "world", "anomalies", "anomalies2", "car", "loot", "backpack", "guestact", "story", "progression", "garage", "junkheap", "desync", "guestparts", "carfeel", "radio", "guestswap", "anomalies3", "mapmark", "ping", "upgrades", "stations", "hands", "survivor", "visual", "guestui", "radiation", "wheelflat", "pause", "transition", "cutscene", "ambient", "rescue", "heal", "perf" }

-- Status lines are for the test runner only; players never set PT_STATUS, so the mod stays silent in single player.
local STATUS_MS = tonumber(os.getenv("PT_STATUS") or "")

local function status()
    local world = UEHelpers.GetWorld()
    local map = world:IsValid() and UEHelpers.GetGameplayStatics():GetCurrentLevelName(world, true):ToString() or "none"
    local pcs = 0
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if pc:IsValid() then pcs = pcs + 1 end
    end
    log("PT|status net=%s map=%s pcs=%d", common.netMode(), map, pcs)
end

log("PT|boot version=%s protocol=%d", common.MOD_VERSION, common.PROTOCOL_VERSION)
-- Lua's default incremental collector let the heap swing 7-45 MB and paid for it in 20-50 ms pauses inside whichever loop
-- allocated next (host car loop in carsync, 2026-10-24); generational (stable in UE4SS's Lua 5.4.7) keeps it near 8 MB:
-- host frames over 30 ms 26 -> 6, worst 47-60 -> 25-29 ms
collectgarbage("generational")

-- hitch finder (playtest 2026-10-22: both games froze every 2-3 s): a loop or hook body over 30 ms is logged with where it was registered
-- An error escaping a hook went back into UE4SS and the guest's game closed without a crash report (host dropped items next to
-- the guest, local playtest 2026-10-22): caught here and logged with where the hook was registered.
-- Paper-style timings: per loop site the total and worst time of the last minute, logged as PT|perf (heaviest first)
local perf, perfAt = {}, os.clock()
local function account(where, d)
    local p = perf[where] or { total = 0, max = 0, n = 0 }
    perf[where] = p
    p.total, p.n = p.total + d, p.n + 1
    if d > p.max then p.max = d end
    if os.clock() - perfAt < 60 then return end
    local rows = {}
    for w, q in pairs(perf) do rows[#rows + 1] = { w, q } end
    table.sort(rows, function(a, b) return a[2].total > b[2].total end)
    for i = 1, math.min(8, #rows) do
        local w, q = rows[i][1], rows[i][2]
        log("PT|perf %s total=%.0f ms max=%.0f ms n=%d", w, q.total * 1000, q.max * 1000, q.n)
    end
    rows = {}
    for fn, byClass in pairs(common.lookups) do
        for class, q in pairs(byClass) do rows[#rows + 1] = { fn .. " " .. tostring(class), q } end
    end
    table.sort(rows, function(a, b) return a[2].n > b[2].n end)
    for i = 1, math.min(8, #rows) do
        log("PT|perf lookup %s total=%.0f ms n=%d", rows[i][1], rows[i][2].total * 1000, rows[i][2].n)
    end
    perf, perfAt, common.lookups = {}, os.clock(), {}
end
local function timed(fn, where)
    return function(...)
        local t = os.clock()
        local r = table.pack(pcall(fn, ...))
        local d = os.clock() - t
        account(where, d)
        if d > 0.03 then log("PT|slow %s %.0f ms", where, d * 1000) end
        if not r[1] then log("PT|error in %s: %s", where, tostring(r[2])); return end
        return table.unpack(r, 2, r.n)
    end
end
local function caller() -- the module line, past pcall
    for lv = 3, 8 do
        local i = debug.getinfo(lv, "Sl")
        if not i then break end
        if i.what ~= "C" then return i.short_src:match("[^/\\]+$") .. ":" .. i.currentline end
    end
    return "?"
end
-- loops only: wrapping RegisterHook callbacks was followed by a never-seen hook error and a guest crash (2026-10-22)
local rawLoop = LoopInGameThreadWithDelay
LoopInGameThreadWithDelay = function(ms, fn) return rawLoop(ms, timed(fn, caller())) end

for _, name in ipairs(FEATURES) do
    local ok, err = pcall(require, name)
    -- a feature that is not written yet is fine; one that fails to load is an error the tests catch
    if not ok and not tostring(err):find("module '" .. name .. "' not found", 1, true) then
        log("PT|error feature %s %s", name, tostring(err))
    end
end

-- the native layer registers its functions only after this script has started
ExecuteInGameThreadWithDelay(1000, function()
    log("PT|native version=%s", PTNative_Version and PTNative_Version() or "missing")
end)

if STATUS_MS then
    LoopInGameThreadWithDelay(STATUS_MS, function()
        local ok, err = pcall(status)
        if not ok then log("PT|error status %s", tostring(err)) end
    end)
end
