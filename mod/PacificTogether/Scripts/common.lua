local UEHelpers = require("UEHelpers")

local M = {
    MOD_VERSION = "0.8.9",
    PROTOCOL_VERSION = 7, -- 7: map icons (g.map.icons), currencies (g.st.cur), map north; 6: loot drop adoption ("K"), keypad and anchor-take messages; 5: msg.cpp chunks are confirmed ("PT1A|"); a 4 peer never confirms and a 5 sender would stall
}

-- Each run also keeps its own copy of our lines (run-01.log .. run-10.log in the mod folder, runs.txt = the last one used): UE4SS.log
-- starts empty at every launch, and a guest who restarted during the friend session 2026-11-01 sent only its last life. The launcher's
-- "Copy logs" takes them all.
local runLog
do
    local dir = debug.getinfo(1, "S").source:match("^@(.*[\\/])Scripts[\\/]") or ""
    local f = io.open(dir .. "runs.txt", "r")
    local n = f and tonumber(f:read("*l")) or 0
    if f then f:close() end
    n = n % 10 + 1
    f = io.open(dir .. "runs.txt", "w")
    if f then f:write(n); f:close() end
    runLog = io.open(string.format("%srun-%02d.log", dir, n), "w")
    -- flushed per line: Windows' C runtime has no line buffering, and a crash or a killed game lost the whole buffer (empty files)
    if runLog then runLog:write(os.date("PT run started %Y-%m-%d %H:%M:%S\n")); runLog:flush() end
end
function M.log(fmt, ...)
    local s = string.format(fmt, ...)
    print("[PacificTogether] " .. s .. "\n")
    if runLog then runLog:write(os.date("[%H:%M:%S] "), s, "\n"); runLog:flush() end
end

function M.replicateActor(o)
    if not o:HasAuthority() then return false end
    if o.bReplicates and o.RemoteRole ~= 0 and o.bReplicateMovement and o.bAlwaysRelevant and o.NetUpdateFrequency == 10 then return false end
    o:SetReplicates(true)
    o:SetReplicateMovement(true)
    o.bAlwaysRelevant = true -- default distance culling hides anomalies from a guest across the map
    o.NetUpdateFrequency = 10
    o:ForceNetUpdate()
    return true
end

-- UEHelpers.GetPlayerController/GetWorld run FindAllOf("PlayerController") per call (0.26 ms in a zone, measured 2026-10-22),
-- and every module calls them per item and per tick: keep the local controller and its world while they stay valid.
-- A new map makes new ones, so the old ones fail IsValid and are looked up again.
local cachedPC, cachedWorld = nil, nil
local function live(pc) return pc and pc:IsValid() and not pc:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
-- the stock helper returns the first player controller, on a host possibly a guest's: the local one is looked for here
function UEHelpers.GetPlayerController()
    if live(cachedPC) then return cachedPC end
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if live(pc) and pc:IsLocalController() then cachedPC, cachedWorld = pc, nil; return pc end
    end
    return CreateInvalidObject() -- no local controller yet (travel): not a guest's
end
local rawWorld = UEHelpers.GetWorld
function UEHelpers.GetWorld()
    if live(cachedPC) and live(cachedWorld) then return cachedWorld end
    local w = rawWorld()
    if live(cachedPC) and live(w) then cachedWorld = w end
    return w
end

-- A StaticFindObject or RegisterHook path that is not loaded makes UE4SS scan every object (25-45 ms in a zone, 2026-10-22),
-- and modules retry hooks and asset lookups in loops until a class loads: look paths up in the engine's hash tables
-- (PTNative_Find, main.dll; registered after this script starts, so checked per call) and fail fast on a miss.
local rawFind, rawHook = StaticFindObject, RegisterHook
function StaticFindObject(path, ...)
    if PTNative_Find and type(path) == "string" and select("#", ...) == 0 then return PTNative_Find(path) or CreateInvalidObject() end
    return rawFind(path, ...)
end
function RegisterHook(path, ...)
    if PTNative_Find and type(path) == "string" and not PTNative_Find(path) then error("RegisterHook: " .. path .. " is not loaded") end
    return rawHook(path, ...)
end

-- object lookups per class, for main.lua's PT|perf report (which loops cost what)
M.lookups = {}
local function counted(name, raw)
    return function(class, ...)
        local t = os.clock()
        local r = raw(class, ...)
        local byClass = M.lookups[name] or {}
        M.lookups[name] = byClass
        local c = byClass[class] or { total = 0, n = 0 }
        byClass[class] = c
        c.total, c.n = c.total + os.clock() - t, c.n + 1
        return r
    end
end
FindAllOf, FindFirstOf = counted("FindAllOf", FindAllOf), counted("FindFirstOf", FindFirstOf)

-- Singletons (managers, the game instance) were looked up hundreds of times a minute each (PT|perf lookup, 2026-10-22): the
-- one found is kept while it is live, and every map load drops them all (the old world's go with it).
local SINGLE = { DrivingGameInstance = true, BP_ResourceManager_C = true, BP_InventoryManager_C = true, BP_MainCharacterManager_C = true,
    BP_CarManager_C = true, BP_StatusEffectManager_C = true, BP_ProgressionManager_C = true, BP_QuestManager_C = true,
    BP_DialogueManager_C = true, MessageSystem = true, InventorySystem = true, BP_SaveGameManager_C = true, BP_MusicManager_C = true,
    BP_ToDManager_C = true, BP_StormManager_C = true }
local singles = {}
local rawFirst = FindFirstOf
function FindFirstOf(class)
    if not SINGLE[class] then return rawFirst(class) end
    local o = singles[class]
    if live(o) then return o end
    o = rawFirst(class)
    if live(o) then singles[class] = o end
    return o
end
-- the cached singleton or nil: module-local first() helpers looped FindAllOf (26 CarManager lookups a second on the host)
-- Keys are polled on the game thread (PlayerController:IsInputKeyDown, edge-detected every 30 ms). A RegisterKeyBind callback runs Lua on
-- UE4SS's own thread while the game thread runs Lua in the same state: even a one-line flag setter corrupted it (guest crashes in
-- luaL_traceback / luaH_next, hand play 2026-10-24). M.onKey("X", fn): fn on the game thread when X goes down (UE key names).
local keys, keyDown = {}, {}
function M.onKey(name, fn) keys[#keys + 1] = { name, fn } end
LoopInGameThreadWithDelay(30, function()
    if #keys == 0 then return end
    local pc = UEHelpers.GetPlayerController()
    if not (pc and pc:IsValid()) then return end
    -- read each key once, edge per key: a second handler of the same key never saw the edge (car.lua's E after cutscene.lua's,
    -- hand test 2026-11-01: the seated guest's E did nothing)
    local now = {}
    for _, k in ipairs(keys) do
        if now[k[1]] == nil then
            local ok, down = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(k[1]) }) end)
            now[k[1]] = ok and down == true
        end
    end
    for _, k in ipairs(keys) do
        if now[k[1]] and not keyDown[k[1]] then
            local okf, e = pcall(k[2])
            if not okf then M.log("PT|error key %s %s", k[1], tostring(e)) end
        end
    end
    for name, down in pairs(now) do keyDown[name] = down end
end)

function M.first(class)
    local o = FindFirstOf(class)
    if live(o) then return o end
    -- the first one can be a dead or old-world object while a live one exists (after a map change or a stream)
    for _, x in ipairs(FindAllOf(class) or {}) do if live(x) then return x end end
end
-- the cached controller and world too: a freed object's address can come back as another object, which IsValid cannot tell
local function forget() singles, cachedPC, cachedWorld = {}, nil, nil end
RegisterLoadMapPreHook(forget)
RegisterLoadMapPostHook(forget)

local worldGeneration = 0
RegisterLoadMapPreHook(function() worldGeneration = worldGeneration + 1 end)
-- A still-valid handle may belong to the world we just left; do not even enter its callback.
function M.defer(ms, fn)
    local generation = worldGeneration
    return ExecuteInGameThreadWithDelay(ms, function()
        if generation == worldGeneration or os.getenv("PT_MUTATE") == "nostaleactions" then fn() end
    end)
end

-- Exit portals are spawned at runtime (BFL_RuntimeSpawnHelpers.DynamicSpawnActor), so their object names differ between the
-- host's and the guest's game (playtest 2026-11-03: gateway never shown on the guest). They are named by where they stand.
function M.portalKey(p)
    local l = p:K2_GetActorLocation()
    return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
end
function M.findPortal(key)
    local x, y, z = key:match("^(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    if not x then return nil end
    local best, bestD = nil, 500 * 500 -- within 5 m
    for _, p in ipairs(FindAllOf("BP_LevelTransition_ExitPortal_C") or {}) do
        if live(p) then
            local l = p:K2_GetActorLocation()
            local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2 + (l.Z - z) ^ 2
            if d < bestD then best, bestD = p, d end
        end
    end
    return best
end

function M.netMode()
    local ksl, wco = UEHelpers.GetKismetSystemLibrary(), UEHelpers.GetWorldContextObject()
    if not wco:IsValid() then return "none" end
    if ksl:IsStandalone(wco) then return "standalone" end
    return ksl:IsServer(wco) and "listen" or "client"
end

return M
