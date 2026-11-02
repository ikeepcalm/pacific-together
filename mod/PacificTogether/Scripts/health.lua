-- P4/D6 player health. Each process runs the single-player game: the player's health is BP_ResourceManager_C.PlayerHealth,
-- one per process (docs/spikes/M4-player.md), so the guest's damage, radiation and healing already run in its own sim and
-- on its own HUD. This file shares the numbers (the name tag shows the other player's health) and handles the guest's death:
-- the game's KillPlayer would return the guest's process to the garage, so the guest never reaches 0 (Minimum 1); at 1 it
-- "dies" here instead: black screen, the host moves its character next to the car, health restored (D6). Host death keeps the
-- game's own behaviour. Inert outside a session (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local log = common.log

-- test mutation (docs/TESTING.md): the feature off, like PT_STATUS this is read only by test runs
local OFF = os.getenv("PT_MUTATE") == "nohealth"

local M = { DEAD_MS = 3000, FALLBACK_MS = 8000, STALE = 8 }

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end

local manager
local function health()
    if not valid(manager) then manager = FindFirstOf("BP_ResourceManager_C") end
    local h = valid(manager) and manager.PlayerHealth
    return valid(h) and h or nil
end

-- the other player's last report
local other, lastSent, lastAt, clamped = nil, "", 0, false

function M.pct(cur, max) return cur <= 1.01 and 0 or math.floor(cur / max * 100 + 0.5) end

-- "70%" for the name tag, nil when we have no fresh report
function M.label()
    return other and os.time() - other.t <= M.STALE and (other.pct .. "%") or nil
end

local function localPC()
    local pc = UEHelpers.GetPlayerController()
    return valid(pc) and pc or nil
end

if OFF then return M end

-- guest: dead until the host has moved us (or the fallback timer ran out) -------------------------------------------

local dying = false
local loadedAt = 0 -- os.clock() of the last map load
local seenAlive = false -- health above 1 seen in this level: a fresh level starts at the minimum until the game fills it, that is no death

local function revive()
    if not dying then return end
    dying = false
    local h, pc = health(), localPC()
    if h then h:Adjust(manager, h.Maximum - h.Current) end
    if pc then
        pc:SetIgnoreMoveInput(false)
        pc:SetIgnoreLookInput(false)
        local cam = pc.PlayerCameraManager
        if valid(cam) then cam:StartCameraFade(1, 0, 1, { R = 0, G = 0, B = 0, A = 1 }, false, false) end
    end
    log("PT|health guest revived")
end

local function die(h, pre, why)
    dying = true
    log("PT|health guest died (%s)", why)
    local okb, bp = pcall(require, "backpack") -- D6: the backpack drops as a bag at this spot
    if okb then pcall(bp.died, pre) end
    local pc = localPC()
    if pc then
        pc:SetIgnoreMoveInput(true)
        pc:SetIgnoreLookInput(true)
        local cam = pc.PlayerCameraManager
        if valid(cam) then cam:StartCameraFade(0, 1, 1, { R = 0, G = 0, B = 0, A = 1 }, false, true) end
    end
    ExecuteInGameThreadWithDelay(M.DEAD_MS, function()
        if not dying then return end
        net.toHost("g.health.respawn", "")
        ExecuteInGameThreadWithDelay(M.FALLBACK_MS, function() pcall(revive) end)
    end)
end

net.on("g.health.revive", function() revive() end)

-- the game's own death on the guest (BP_MainCharacterManager:KillPlayer: a door that crushes, CheckForGameOver, ...) would
-- run the guest's local item penalty, leave PlayerAlive false and wait for a return to the garage. It is our death instead:
-- the backpack of the last tick (before the penalty) goes to the host's crate, the game's death state is undone.
local function undoGameDeath(cm, duringOurs)
    pcall(function() StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):K2_ClearTimer(cm, "OnPlayerDeathReturnTimer") end)
    pcall(function() cm:SetPlayerAlive(true) end)
    if duringOurs then return end -- HUD, car state, collision and movement belong to our own fade and respawn
    local ch = cm.CharacterActor
    if valid(ch) then
        pcall(function() ch.ALS_MovementMode = 1; ch.CharacterMovement:SetMovementMode(1, 0); ch.CapsuleComponent:SetCollisionEnabled(3) end)
    end
    local car = FindFirstOf("BP_CarManager_C")
    if valid(car) then pcall(function() car["Set PlayerCarState"](car, 0); car:SetIsInvunerable(false) end) end
    pcall(function()
        local w = FindObject("BFL_Widget_Utils_C", "Default__BFL_Widget_Utils_C")
        w["Set Player HUD Hidden"](w, false, cm)
    end)
end
local killHooked = os.getenv("PT_MUTATE") == "nokillfix" -- the class loads after the main menu: hooked from the tick
local function hookKill()
    killHooked = pcall(RegisterHook, "/Game/Systems/Managers/BP_MainCharacterManager.BP_MainCharacterManager_C:KillPlayer", function(self)
        if not safety.guest() then return end
        if dying then undoGameDeath(self:get(), true); return end -- a game death after our own: undo it, no second flow
        local okb, bp = pcall(require, "backpack")
        local pre = okb and bp.pre and bp.pre() or nil
        undoGameDeath(self:get())
        local h = health()
        if h then h:Adjust(manager, h.Maximum - h.Current) end
        die(h, pre, "game kill")
    end)
    if killHooked then log("PT|health kill hook registered") end
end

-- host: the guest's respawn point is the car, else us ---------------------------------------------------------------

local function anchor()
    local car = FindFirstOf("BP_PlayerCarNew_C")
    if valid(car) then return car end
    local pc = localPC()
    if pc and valid(pc.Pawn) then return pc.Pawn end
    local cm = FindFirstOf("BP_MainCharacterManager_C")
    return valid(cm) and cm.CharacterActor or nil
end

net.on("g.health.respawn", function(pc)
    local g, a = pc.Pawn, anchor()
    if not (valid(g) and valid(a)) then log("PT|error health respawn: no guest pawn or anchor"); return end
    local l, r = a:K2_GetActorLocation(), a:GetActorRightVector()
    local placed = false
    for _, d in ipairs({ 350, -350, 600, -600 }) do
        -- the engine's own teleport refuses a spot with no room; the server's move is what the guest's client accepts
        if g:K2_TeleportTo({ X = l.X + r.X * d, Y = l.Y + r.Y * d, Z = l.Z + 120 }, g:K2_GetActorRotation()) then placed = true; break end
    end
    if not placed then g:K2_SetActorLocation({ X = l.X, Y = l.Y, Z = l.Z + 300 }, false, {}, true) end
    log("PT|health respawn guest next to %s placed=%s", a:GetClass():GetFName():ToString(), tostring(placed))
    net.toGuest(pc, "g.health.revive", "")
end)

net.on("g.health.hp", function(_, data)
    local c, m = data:match("^([%d.]+),([%d.]+)$")
    if c then other = { pct = M.pct(tonumber(c), tonumber(m)), t = os.time() } end
end)

-- every 500 ms ---------------------------------------------------------------------------------------------------------

local function tick()
    if not killHooked and valid(FindFirstOf("BP_MainCharacterManager_C")) then hookKill() end
    local h = health()
    if not safety.active() then
        if other or dying then other, dying, lastSent = nil, false, "" end
        if clamped and h then h.Minimum, clamped = 0, false end -- left the session: single player dies as the game does
        return
    end
    if not h then return end
    local cur, max = h.Current, h.Maximum
    if safety.guest() then
        -- the game's death needs Current <= 0: stay above it (a runtime value on the resource, not a saved setting)
        if h.Minimum ~= 1 then h.Minimum, clamped = 1, true end
        -- the grace runs from the end of the host's transition: the guest waits for the host's go up to a minute after its load,
        -- and the game drops health to the minimum at the release (false death on every zone arrival, playtest 2026-11-01)
        local tr = package.loaded["transition"]
        if tr and tr.state().phase then loadedAt, seenAlive = os.clock(), false end
        if cur > 1.01 then seenAlive = true end
        -- a level loads its health over the first seconds (seen: 100 then the minimum 0.5 s after arrival): no death then
        if not dying and seenAlive and os.clock() - loadedAt > 8 and cur <= 1.01 then die(h, nil, "health at minimum") end
    end
    -- on change, else every 2 s so a late joiner and a missed message catch up
    local msg = string.format("%.1f,%.1f", cur, max)
    if msg ~= lastSent or os.time() - lastAt >= 2 then
        lastSent, lastAt = msg, os.time()
        if safety.guest() then net.toHost("g.health.hp", msg) else net.toGuests("g.health.hp", msg) end
    end
end

-- a map change frees the objects we hold
RegisterLoadMapPreHook(function() manager, seenAlive = nil, false end)
RegisterLoadMapPostHook(function() loadedAt = os.clock() end)

LoopInGameThreadWithDelay(500, function()
    local ok, err = pcall(tick)
    if not ok then log("PT|error health %s", tostring(err)) end
end)

return M
