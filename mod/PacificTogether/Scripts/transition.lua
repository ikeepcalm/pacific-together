-- Map transitions as a co-op game does them (immersion lane, 2026-10-25). Hand play: the guest's car drove on past the point where
-- the host faded out, then "Paused by host" over a driving car, then the new map seen from under its textures until the host had
-- placed the guest. Now:
--   host   tells the guest when its level-transition fade starts (junction exit, exit portal, garage gate) and when the junction
--          route menu opens; after its own map load it keeps the game's loading screen up until the guest reports its character
--          (g.net.ready), 60 s at most, then both fade in together ("go").
--   guest  fades to black with the host, shows the game's own LoadingScreen widget from the moment its connection drops until the
--          host says "go" (the engine shows it itself during the guest's own map load; we add it again around that).
-- The loading screen is DrivingGameInstance.LoadingScreenUserWidget: the engine adds and removes its Slate widget directly, so
-- AddToViewport/RemoveFromParent of ours never collide with it as long as ours is gone before the engine's LoadMap (pre-hook).
-- The host's hold: K2_OnLevelReady sets FadeGoal 0 and the widget's own tick fades StatusBox to it, then fires
-- SpawningManager.LoadScreenFinishedFadingOut; FadeGoal 1 / FadeDirection true after that event keeps it up without firing.
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local safety = require("safety")
local overlay = require("overlay")
local log = common.log

local M = {}
local OFF = os.getenv("PT_MUTATE") == "notransition" -- tests only
local MENU, Z, HOLD_MAX = "RB_MainMenu", 20000, 60
local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function screen()
    local gi = common.first("DrivingGameInstance")
    local ls = gi and gi.LoadingScreenUserWidget
    return valid(ls) and ls or nil
end
local function mapName()
    local w = UEHelpers.GetWorld()
    return valid(w) and UEHelpers.GetGameplayStatics():GetCurrentLevelName(w, true):ToString() or "none"
end

-- host ----------------------------------------------------------------------------------------------------------------------

local expectGuest, holdSince = false, nil
local clock=require("worldclock")
local clocks = {} -- guest controller address -> { lease, since, done }: its world-clock handshake (3-4 players: one per guest)
local function startClock(pc)
    if clocks[pc:GetAddress()] then return end
    clock.begin(pc); clocks[pc:GetAddress()] = { lease = common.lease(pc), since = os.clock() }
end
-- the hold ends once every guest has its character and its clock (or its clock timed out); starts a missing guest's clock
local function allReady()
    local list = net.guests()
    if #list == 0 then return false end -- after the load the guests reconnect: none yet is not "all ready" (dayclock 2026-11-14)
    for _, g in ipairs(list) do
        -- its character is there ("baseline": loot and visual copies still coming): since the intent queue (0.9.0) net.ready waits
        -- for the whole baseline, and the host held its loading screen ~30 s at every zone change (transition 2026-11-14)
        local life = net.lifecycle(g)
        if life ~= "baseline" and life ~= "active" then return false end -- a stalled guest holds everyone until HOLD_MAX
        -- its capabilities first: before they arrive clock.ready() answers "no clock, nothing to wait for" (dayclock 2026-11-14);
        -- every guest of this mod version has the world clock
        if not net.peerSupports(g, 'world-clock') then return false end
        local c = clocks[g:GetAddress()]
        if not clock.ready(g) and not (c and c.done) then startClock(g); return false end
    end
    return true
end
local function others() return #net.guests() > 1 and "the others" or overlay.other() end
local function release(why,force)
    if not holdSince then return end
    if not force and not allReady() then return end
    local clocked, synced = false, true
    for _, g in ipairs(net.guests()) do
        if net.peerSupports(g, 'world-clock') then clocked, synced = true, synced and clock.ready(g) end
    end
    if clocked then why = why .. (synced and ' (guest clock ready)' or ' (clock timeout)') end
    local ls = screen()
    if ls then ls.FadeGoal = 0.0; ls.FadeDirection = false end
    log("PT|trans host release after %.1f s: %s", os.clock() - holdSince, why)
    holdSince, expectGuest = nil, false
    net.toGuests("g.trans", "go")
end
local hooked = {}
local function hook(path, fn)
    if hooked[path] then return end
    hooked[path] = pcall(RegisterHook, path, function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log("PT|error trans %s %s", path, tostring(err)) end
    end)
end
-- the first call of a timeline's update function within 5 s is the start of that fade
local function onFirst(fn)
    local last = -10
    return function(...)
        if os.clock() - last > 5 then fn(...) end
        last = os.clock()
    end
end
local function tell(what)
    if OFF or common.netMode() ~= "listen" then return end
    net.toGuests("g.trans", what)
    log("PT|trans host %s", what)
end
local function hookAll()
    hook("/Game/Gameplay/LevelTransitions/BP_LevelTransition_EnterExit.BP_LevelTransition_EnterExit_C:Fadeout__UpdateFunc", onFirst(function() tell("fade") end))
    hook("/Game/Gameplay/LevelTransitions/BP_LevelTransition_ExitPortal.BP_LevelTransition_ExitPortal_C:Final Transition Fade In Timeline__UpdateFunc", onFirst(function() tell("fade") end))
    hook("/Game/Systems/Managers/BP_ProgressionManager.BP_ProgressionManager_C:Open Map UI", function() tell("route") end)
    -- runs after the Blueprint body: FadeGoal is 0 now, the fade has not ticked yet
    hook("/Game/UI/System/LoadingScreen.LoadingScreen_C:K2_OnLevelReady", function(self)
        if OFF or not expectGuest or common.netMode() ~= "listen" then return end
        local ls = self:get()
        ls.FadeGoal = 1.0
        ls.FadeDirection = true
        ls.StatusBox:SetRenderOpacity(1.0)
        ls.CurrentStatusSwitcher:SetActiveWidgetIndex(0)
        ls.CurrentStateText:SetText(FText("WAITING FOR " .. others():upper() .. "..."))
        pcall(function() ls.StatusBorder.Slot:SetAutoSize(true) end) -- a fixed 500 uu box: a long name ran off the right edge
        holdSince = os.clock()
        overlay.post("Waiting for " .. others() .. " to load\226\128\166")
        log("PT|trans host hold")
    end)
end

-- the guest's character is there (net.lua): let go, or tell a guest that joined mid-map to show the world
net.ready = function(pc)
    if OFF then return end
    if not clock.ready(pc) then
        startClock(pc)
    elseif holdSince then release("guest ready") else net.toGuest(pc, "g.trans", "go") end
end

RegisterLoadMapPreHook(function()
    clocks = {}
    pcall(function()
        if common.netMode() == "listen" and #net.guests() > 0 then
            expectGuest = true
            tell("load")
        end
    end)
end)

-- guest ---------------------------------------------------------------------------------------------------------------------

local phase, phaseAt, clientWorld, hostMap, charSince = nil, 0, nil, "", nil -- phase: "fade" (black), "load" (loading screen up), nil
local function fadeCamera(from, to, secs, hold)
    local pc = UEHelpers.GetPlayerController()
    local cm = valid(pc) and pc.PlayerCameraManager
    if valid(cm) then cm:StartCameraFade(from, to, secs, { R = 0, G = 0, B = 0, A = 1 }, false, hold) end
end
local function showScreen()
    local ls = screen()
    if not ls then return end
    if not ls:IsInViewport() then ls:K2_OnBeginLoad(hostMap); ls:AddToViewport(Z) end
    ls.CurrentStatusSwitcher:SetActiveWidgetIndex(0)
    ls.StatusBox:SetRenderOpacity(1.0)
    ls.CurrentStateText:SetText(FText(mapName() == MENU and "TRAVELING..." or "WAITING FOR HOST..."))
    pcall(function() ls.StatusBorder.Slot:SetAutoSize(true) end) -- grows to the left (right-aligned), not off the screen
end
local function hideScreen()
    local ls = screen()
    if ls and ls:IsInViewport() then ls:RemoveFromParent() end
end
local function setPhase(p, why)
    if phase == p then return end
    log("PT|trans guest %s -> %s (%s)", tostring(phase), tostring(p), why)
    phase, phaseAt = p, os.clock()
    overlay.transition(p ~= nil)
    if p == "load" then showScreen()
    elseif p == nil then hideScreen(); fadeCamera(1, 0, 0.8, false) end
end

net.on("g.trans", function(_, data)
    if OFF or common.netMode() ~= "client" then return end
    if data == "route" then overlay.post("Host is choosing a route")
    elseif data == "fade" then
        if phase == nil then fadeCamera(0, 1, 1.2, true); overlay.post("Host is travelling\226\128\166") end
        if phase ~= "load" then setPhase("fade", "host fades") end
    elseif data == "load" then setPhase("load", "host loads")
    elseif data == "go" then setPhase(nil, "host says go")
    end
end)

-- ours must be out before the engine adds its own for the map load; the engine takes it down again when the map is up,
-- while we still wait for the host to place us
RegisterLoadMapPreHook(function() pcall(function() hideScreen(); fadeCamera(0, 0, 0, false) end) end)
RegisterLoadMapPostHook(function()
    pcall(function()
        if mapName() == MENU then setPhase(nil, "menu"); return end
        local s = package.loaded["session"]
        if OFF or common.netMode() ~= "client" or not (s and s.wanted()) then return end
        -- a moment later: the engine takes its own copy down around here, ours must not sit in the viewport beside it
        common.defer(1000, function()
            pcall(function()
                if common.netMode() ~= "client" then return end
                if phase == "load" then showScreen() else setPhase("load", "map loaded, waiting for the host") end
            end)
        end)
    end)
end)

LoopInGameThreadWithDelay(100, function()
    if OFF then return end
    local mode = common.netMode()
    if mode == "listen" then
        for a, c in pairs(clocks) do
            local pc = common.resolve(c.lease)
            if not pc then clocks[a] = nil
            elseif not c.done and (clock.ready(pc) or os.clock() - c.since > 5) then
                c.done = true
                if holdSince then release(clock.ready(pc) and "guest clock ready" or "clock timeout") else net.toGuest(pc,"g.trans","go") end
            end
        end
        hookAll()
        if holdSince then release("guests here") end -- lets go once allReady() holds (or starts their clocks)
        if holdSince and os.clock() - holdSince > HOLD_MAX then
            overlay.post(others() .. " did not load in time", "warn")
            release("timeout", true)
        end
        return
    end
    local s = package.loaded["session"]
    local w = UEHelpers.GetWorld()
    -- the host's close takes the guest world's NetDriver away (probe 2026-10-25: driver invalid 60 ms after the close, GameState
    -- and the world stay); the same world without its driver is a dropped connection, a new world is a load
    local client = valid(w) and valid(w.NetDriver) and valid(w.NetDriver.ServerConnection)
    if client then clientWorld, hostMap = w:GetFullName(), mapName() end
    if clientWorld and not client and valid(w) and w:GetFullName() == clientWorld and s and s.wanted() and mapName() ~= MENU then
        clientWorld = nil
        setPhase("load", "connection dropped")
    end
    if phase and os.clock() - phaseAt > 150 then setPhase(nil, "timeout") end
    -- the host's transition was called off (nobody in the car at the portal): no drop followed the fade
    if phase == "fade" and os.clock() - phaseAt > 15 then setPhase(nil, "no travel followed") end
    -- no "go" within 3 s of having our own character: the host's word is what makes both fade in together, but it must not
    -- keep a guest on the screen when it does not come (an older host, a lost message)
    local p = client and UEHelpers.GetPlayerController().Pawn or nil
    local char = valid(p) and p:IsA(StaticFindObject("/Script/PenDriverPro.BaseCharacter"))
    charSince = char and (charSince or os.clock()) or nil
    if phase == "load" and charSince and os.clock() - charSince > 3
        and (not net.hostSupports("intents") or net.lifecycle() == "active") then setPhase(nil, "own character, no go") end
end)

function M.state() return { phase = phase, holding = holdSince ~= nil } end
return M
