-- PT1 garage: doors for both players (docs/spikes/PT1-garage.md).
--   The garage doors' Logic Driver state machines never leave Closed in a listen/client session (playtest 1: no door ever moved),
--   so in a session the door position is driven here from the door's global switch. The guest's own directors would decide the
--   switches from the guest's fresh game, so they are stopped there and the host's three switches ("g.garage.sw") are applied.
-- Inert in single player (Q7): only runs as a listening host or a guest.
local common = require("common")
local safety = require("safety")
local net = require("net")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "nogarage" }

local function live(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error garage %s %s", what, tostring(err)) end
end

-- switch asset, the state name the game itself uses for it, the guest's director that writes it
local SW = {
    { "GSS_Garage_FrontDoorOpened", "LegSelectedAndEmbark", "BP_Director_GSS_GarageFrontDoor_C" },
    { "GSS_Garage_RearDoorOpened", "ButtonToggle" },
    { "GSS_Garage_ExitGateOpened", "GarageFrontDoor", "BP_Director_GSS_GarageExitGate_C" },
}
local function asset(n) return StaticFindObject("/Game/Systems/GlobalStateSwitches/" .. n .. "." .. n) end
local function gi() local g = FindFirstOf("DrivingGameInstance"); return live(g) and g or nil end

local function netted() local m = common.netMode(); return m == "listen" or m == "client" end

-- MoveDoorPosition is the call the state machine makes every tick; here it runs over MoveDuration seconds.
-- shortcut: no obstruction check (the machine reverses a rear door that hits something); add one if players get crushed.
local lastDrive = os.clock()
local doors, doorsAt = {}, -math.huge
local quietUntil = 0 -- doors are torn down across a map load: reading them then returned garbage property types (suite 2026-10-22)
RegisterLoadMapPreHook(function() quietUntil, doors, doorsAt = math.huge, {}, -math.huge end)
RegisterLoadMapPostHook(function() quietUntil = os.clock() + 3 end)
local function driveDoors()
    local now = os.clock()
    local dt = math.min(now - lastDrive, 0.25)
    lastDrive = now
    if now < quietUntil then return end
    local g = gi()
    if not g then return end
    -- the doors are placed in the map: the list is read again every 2 s, not every 50 ms
    if now - doorsAt > 2 then doors, doorsAt = FindAllOf("BP_GarageDoor_C") or {}, now end
    for _, d in ipairs(doors) do
        if live(d) and not d:GetFullName():find("/Engine/Transient", 1, true) then
            local a = asset(d.IsFrontGarageDoor and SW[1][1] or SW[2][1])
            if a:IsValid() then
                local target = g:GetGlobalSwitch(a) and 1 or 0
                local pos = d.CurrentDoorPosition
                if type(pos) == "number" and math.abs(target - pos) > 0.001 then
                    local step = math.min(dt / math.max(d.MoveDuration, 0.5), math.abs(target - pos))
                    d:MoveDoorPosition(target > pos and step or -step)
                end
            end
        end
    end
end

local function readSwitches()
    local g = gi()
    if not g then return nil end
    local t = {}
    for i, s in ipairs(SW) do
        local a = asset(s[1])
        t[i] = (a:IsValid() and g:GetGlobalSwitch(a)) and "1" or "0"
    end
    return table.concat(t)
end

-- Garage stations (Unmaker, fax, doors' keypads, storage ...): each level-placed BP_GarageInstallation_Spawner has an upgrade item in
-- its slot (a status effect of an ItemUpgrade class). The guest never loaded the host's save, so its slots are empty; the host lists
-- "spawner name -> installed upgrade classes" and the guest installs the missing ones with the spawner's own InstallSpecificUpgrade.
local function spawners()
    local r = {}
    for _, s in ipairs(FindAllOf("BP_GarageInstallation_Spawner_C") or {}) do
        if live(s) and not s:GetFullName():find("/Engine/Transient", 1, true) then r[#r + 1] = s end
    end
    return r
end
local function installed(s, im, sm)
    local a, r = {}, {}
    s:GetUpgradeArchetype(a)
    if not (a.Archetype and a.Archetype:IsValid()) then return r end
    local item = im:FindOrCreateGarageUpgradeSlot(a.Archetype, s.StationInstallTag):GetItem(0)
    if not (item and item:IsValid()) then return r end
    local list = sm:GetStatusEffects(item)
    for i = 1, #list do
        local e = list[i]:get()
        if e and e:IsValid() then r[#r + 1] = (e:GetClass():GetFullName():gsub("^%S+ ", "")) end
    end
    return r
end
local function managers()
    local im, sm = FindFirstOf("BP_InventoryManager_C"), FindFirstOf("BP_StatusEffectManager_C")
    if live(im) and live(sm) then return im, sm end
end
local function upgradeLines()
    local im, sm = managers()
    if not im then return nil end
    local L = {}
    for _, s in ipairs(spawners()) do
        local ok, r = pcall(installed, s, im, sm)
        if ok and #r > 0 then L[#L + 1] = s:GetFName():ToString() .. "\t" .. table.concat(r, ",") end
    end
    table.sort(L)
    return table.concat(L, "\n")
end

local done = {} -- guest: spawner full name .. class -> true once installed here (or given up)
-- An install that does not take is tried again after 2, 4, 8, 16, 32 s, then given up: the 30 picture frames of a long save
-- (FramedMount) never take on a guest, and installing all 30 again every 500 ms held each of its frames 60-70 ms (rendered profile,
-- 2026-10-24). Storage stations take only after a few tries (3 tries in 10 s missed them).
local tries = {}
local function applyUpgrades(data)
    local im, sm = managers()
    if not im then return end
    local byName = {}
    for _, s in ipairs(spawners()) do byName[s:GetFName():ToString()] = s end
    -- two installs a pass (500 ms): all of a long save's ~80 in one pass held a rendered guest's game 22 s on joining
    -- (rendered profile, 2026-10-24); the stations now appear over ~20 s
    local budget = 2
    for line in data:gmatch("[^\n]+") do
        if budget <= 0 then return end
        local n, classes = line:match("^([^\t]+)\t(.*)$")
        local s = n and byName[n]
        if s then
            local have
            for c in classes:gmatch("[^,]+") do
                local key = s:GetFullName() .. c
                local tr = tries[key]
                if budget > 0 and not done[key] and not (tr and os.clock() < tr.at) then
                    have = have or installed(s, im, sm)
                    local present = false
                    for _, h in ipairs(have) do if h == c then present = true end end
                    local cls = StaticFindObject(c)
                    if not (cls and cls:IsValid()) then cls = LoadAsset(c) end
                    if not present and cls and cls:IsValid() then
                        budget = budget - 1
                        M.applying = true -- stations.lua: this install is the host's, not the guest's own
                        pcall(s.InstallSpecificUpgrade, s, cls, true)
                        M.applying = false
                        local okNow, after = pcall(installed, s, im, sm)
                        for _, h in ipairs(okNow and after or {}) do if h == c then present = true end end
                        if present then
                            log("PT|garage installed %s on %s", c:match("[^.]+$"), n)
                            local okP, prog = pcall(require, "progression")
                            if okP and prog.reapplyWb then prog.reapplyWb() end -- the install counted itself into the copied WB.GarageUpgrades tags
                        else
                            local k = (tr and tr.n or 0) + 1
                            tr = { n = k, at = os.clock() + 2 ^ k }
                            tries[key] = tr
                            if k >= 6 then
                                done[key] = true
                                log("PT|garage install of %s on %s did not take in 6 tries: given up", c:match("[^.]+$"), n)
                            end
                        end
                    end
                    if present then done[key] = true end
                end
            end
        end
    end
end

local last, lastSent, lastUp, lastUpSent, lastUpCheck = nil, 0, nil, 0, 0
local function hostTick()
    local s = readSwitches()
    if s and (s ~= last or os.clock() - lastSent > 3) then
        last, lastSent = s, os.clock()
        net.toGuests("g.garage.sw", s)
    end
    if os.clock() - lastUpCheck < 6 then return end -- 71 spawners' installs read: every 2 s it was ~1 s a minute on a host
    lastUpCheck = os.clock()
    local u = upgradeLines()
    if u and (u ~= lastUp or os.clock() - lastUpSent > 4) then
        lastUp, lastUpSent = u, os.clock()
        net.toGuests("g.garage.up", u)
    end
end

local want, wantUp
-- stations.lua: the upgrade classes installed on a spawner on this side / in the host's last list (guest)
function M.installedOn(s) local im, sm = managers(); return im and installed(s, im, sm) or {} end
function M.hostHas(name, cls)
    if not wantUp then return nil end
    for line in wantUp:gmatch("[^\n]+") do
        local n, classes = line:match("^([^\t]+)\t(.*)$")
        if n == name then
            for c in classes:gmatch("[^,]+") do if c == cls then return true end end
        end
    end
    return false
end
net.on("g.garage.sw", function(_, data) want = data end)
net.on("g.garage.up", function(_, data) wantUp = data end)

local screenOn
local function guestTick()
    for _, s in ipairs(SW) do
        if s[3] then
            for _, d in ipairs(FindAllOf(s[3]) or {}) do if live(d) and d:IsTickEnabled() then d:SetTickEnabled(false) end end
        end
    end
    if wantUp then try("upgrades", applyUpgrades, wantUp) end
    -- the status monitor's start-up runs on the host's return-to-garage moment only: the guest's stayed black (hand test 2026-11-01)
    -- shortcut: always on for the guest; mirror the host's state if the host's can be legitimately off
    -- (once per map: its start-up flickers through 0)
    if not screenOn then
        for _, d in ipairs(FindAllOf("BP_Garage_StatusDisplay_C") or {}) do
            if live(d) and d.StartupTimeline_Brightness_57C1FD07453CC1F37491EC8375046A4D == 0 then d:SetDisplayEnabled(true); screenOn = true end
        end
    end
    local g = gi()
    if not (g and want) then return end
    for i, s in ipairs(SW) do
        local a = asset(s[1])
        local on = want:sub(i, i) == "1"
        if a:IsValid() and (g:GetGlobalSwitch(a) and true or false) ~= on then g:SetGlobalSwitch(a, FName(s[2]), on and 1 or 2) end
    end
end

RegisterLoadMapPostHook(function() done, tries, screenOn = {}, {}, nil end)

-- The guest presses the back-door button: its own press toggles its own switch, the host's copy of the button gets the same press
-- (the host's switch is the truth and comes back in g.garage.sw). Registered once the button's class is loaded (garage map).
local hooked = false
local function hookButton()
    if hooked or not live(FindFirstOf("BP_BackDoorButton_01_C")) then return end
    local ok = pcall(RegisterHook, "/Game/Gameplay/CarGarage/BP_BackDoorButton_01.BP_BackDoorButton_01_C:BndEvt__Highlight_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature", function()
        if M.enabled and safety.guest() then net.toHost("g.garage.btn", "") end
    end)
    hooked = ok
end
net.on("g.garage.btn", function()
    local b = FindFirstOf("BP_BackDoorButton_01_C")
    if M.enabled and live(b) then
        b.Highlight:InteractPressed(nil)
        b.Highlight:InteractReleased(nil)
    end
end)

-- The battery charger's lever (either player): the same press runs on the other side too, lever, sparks and charge alike (hand test
-- 2026-11-01: the other player saw nothing, and a guest's pull charged nothing on the host). Its event does not read its arguments.
local CHARGE = "BndEvt__Highlight_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature"
local chargeHooked, replaying = false, false
local function hookCharger()
    if chargeHooked or not live(FindFirstOf("BP_Garage_BatteryCharger_C")) then return end
    chargeHooked = pcall(RegisterHook, "/Game/Gameplay/CarGarage/Stations/BatteryCharger/BP_Garage_BatteryCharger.BP_Garage_BatteryCharger_C:" .. CHARGE, function()
        if replaying or not (M.enabled and safety.active()) then return end
        net.send("g.garage.charge", "")
        log("PT|garage charger pulled, sent")
    end)
end
net.share("g.garage.charge", function() -- the host passes a guest's pull on to the other guests
    local c = FindFirstOf("BP_Garage_BatteryCharger_C")
    if not (M.enabled and safety.active() and live(c)) then return end
    replaying = true
    try("charger", function() c[CHARGE](c, c.Highlight, nil) end)
    replaying = false
    log("PT|garage charger pulled by the other player")
end, true) -- an event: not replayed to a guest who joins later

LoopInGameThreadWithDelay(500, function()
    if not M.enabled or not netted() then last, want = nil, nil return end
    try("hook", hookButton)
    try("hook", hookCharger)
    if safety.guest() then try("guest", guestTick) elseif safety.active() then try("host", hostTick) end
end)

LoopInGameThreadWithDelay(50, function()
    if not M.enabled or not netted() then return end
    try("drive", driveDoors)
end)

M.readSwitches = readSwitches
return M
