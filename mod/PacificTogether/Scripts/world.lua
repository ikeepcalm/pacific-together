-- The guest sees the host's run (W3, W4, W6, G3). The host owns the world; the guest's process only mirrors it.
--   anomalies  the host replicates its hazards (every BP_Base_Hazard: Tourists, Bunnies, grabbers, Tesla ...), the zone storm
--              and the exit portals (SetReplicates + movement, always relevant); the guest destroys what it simulated itself.
--   run state  once a second the host sends time of day, weather overrides, instability, storm manager state and the picked
--              gateway ("g.world.state"); the guest applies them through the game's own setters.
--   story      the guest's mission manager cannot start missions and its narrative-beat actors are removed: it is a bystander.
-- Everything is inert outside a session (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local safety = require("safety")
local log = common.log
local ov = require("overlay")
local clock = require("worldclock")

local M = { enabled = os.getenv("PT_MUTATE") ~= "noworldsync", mutate = os.getenv("PT_MUTATE") } -- the test mutation switches the module off

local function first(c) for _, o in ipairs(FindAllOf(c) or {}) do if o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then return o end end end
local function live(o) return o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and not o:GetFullName():find("/Engine/Transient", 1, true) end
local function firstLive(c) for _, o in ipairs(FindAllOf(c) or {}) do if live(o) then return o end end end
local function each(class, fn) for _, o in ipairs(FindAllOf(class) or {}) do if live(o) then fn(o) end end end
local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error world %s %s", what, tostring(err)) end
end
local function short(o) return (o and o:IsValid()) and o:GetFName():ToString() or "none" end

local WI = StaticFindObject("/Game/Gameplay/Hazards/BaseHazard/BP_Base_Hazard_WorldItem.BP_Base_Hazard_WorldItem_C")
local REPLICATED = { "BP_Base_Hazard_C", "BP_ZoneStorm_Base_C", "BP_LevelTransition_ExitPortal_C" }
-- These inherit Actor through BP_Base_Boon, outside BP_Base_Hazard.
local BOONS = {
    BP_Boon_Healer_C = { power = "HealingPowerRemaining", stop = "EndHeal", depleted = "OnRunOutOfJuice" },
    BP_Boon_Charging_C = { power = "ChargePowerRemaining", stop = "EndCharge", depleted = "PowerDrainedCompletely" },
}
if M.mutate == "noboons" then BOONS = {} end
for class in pairs(BOONS) do REPLICATED[#REPLICATED + 1] = class end

-- weather override struct (build 21896301): field names carry the Blueprint GUIDs
local OV = { "Priority_2_E0B18C1F4F7065861D754CBC1717C0F4", "RainAmount_6_1DF01C624F8A4DABBCF2D9B45FEE5251", "FogAmount_7_DF39641648DD1C067F04379E79B4AC5F",
    "WindAmount_11_AA5396694831838AD8399192FA714B4C", "DarknessAmount_12_C1E6970E406443EC371A029B6E403FA3", "ZoneStormAmount_29_0E19DE884D969BB97E764EBE017A5607",
    "AcidAmount_31_1713ABA54AE616BBBC74EEB59EFF6CF2", "Identifier_26_37794E45404F7D45933471B6A50F260C", "OverrideSpeedMult_34_B5D9F9C34E787BDD5826CA97FDFF7EFA" }
local PROP = "BP_Resource_Narrative_Q01_RadioBitsGrabbable_C" -- story.lua replicates it
-- names of the host's portals and story props: the guest's level-placed copy of one is what the host's channel binds to
-- (destroyed, the bunch fails: "SerializeNewActor failed to find/spawn actor")
local keep = {}
RegisterLoadMapPostHook(function() keep = {} end) -- placed names repeat across maps (BP_LevelTransition_ExitPortal_C_1)
local ID = 8
local INSTAB = { TagName = FName("WB.WorldState.Instability.Current") }

local function whiteboard()
    local pm = StaticFindObject("/Script/PenDriverPro.Default__BaseProgressionManager")
    local w = pm:IsValid() and UEHelpers.GetWorld():IsValid() and pm:GetRouteWhiteboard(UEHelpers.GetWorld()) or nil
    return (w and w:IsValid()) and w or nil
end

-- ---------------------------------------------------------------- host

local function replicate()
    for _, class in ipairs(REPLICATED) do
        each(class, function(o)
            if WI:IsValid() and class == "BP_Base_Hazard_C" and o:IsA(WI) then return end -- item actors need their item instance: not today
            common.replicateActor(o)
        end)
    end
end

local OBJMARK = "BP_ScriptKit_GobblerMap_GenericObjective_C"
local function f(v) return string.format("%.4f", v) end

local function snapshot()
    local L = {}
    local function add(k, v) L[#L + 1] = k .. "\t" .. tostring(v) end
    local tod = first("BP_ToDManager_C")
    if tod then
        local r = {}
        tod["Get Current Time Of Day"](tod, r)
        add("tod", f(r["Returned Time Of Day"] or 0))
        local p = tod["Target TOD Preset"]
        add("preset", (p and p:IsValid()) and p:GetFullName():gsub("^%S+ ", "") or "")
        add("north", f(tod["Current North As Rotator"].Yaw))
        add("cur", table.concat({ f(tod.TOD_Override_Rain_Current), f(tod.TOD_Override_Fog_Current), f(tod.TOD_Override_Wind_Current),
            f(tod.TOD_Override_Darkness_Current), f(tod["TOD Override Zone Storm Current"]), f(tod["TOD Override Acid Current"]), f(tod.TOD_Override_SpeedMult) }, "|"))
        local a = tod.TargetWeatherOverrideArray
        for i = 1, a:GetArrayNum() do
            local e, v = a[i], {}
            for j, k in ipairs(OV) do
                local x = e[k]
                v[j] = j == ID and x:ToString() or f(x)
            end
            add("ov", table.concat(v, "|"))
        end
    end
    local wb = whiteboard()
    if wb then add("instab", f(wb:GetTagFloat(INSTAB, true, 0))) end
    local sm = first("BP_StormManager_C")
    if sm then
        add("storm", table.concat({ sm.CurrentStormState, tostring(sm.RedWallActive), f(sm.TimeBeforeInstabilityStarts), f(sm.FinalInstabilityTollerance), f(sm.StormAudioVisualIntensity) }, "|"))
        local g = sm.EvolvedGatewayExit
        add("gate", (g and g:IsValid()) and common.portalKey(g) or "none")
    end
    local names = {}
    for _, c in ipairs({ "BP_LevelTransition_ExitPortal_C", PROP }) do each(c, function(o) names[#names + 1] = short(o) end) end
    add("keep", table.concat(names, ","))
    local st = firstLive("BP_ZoneStorm_Base_C")
    if st then add("wall", table.concat({ f(st.Vol_Rad_Main), f(st.Vol_Rad_Weak), tostring(st.Collapsed) }, "|")) end
    for class, b in pairs(BOONS) do
        each(class, function(o)
            local l = o:K2_GetActorLocation()
            add("boon", table.concat({ class, f(l.X), f(l.Y), f(l.Z), f(o[b.power]), tostring(o.OutOfJuice) }, "|"))
        end)
    end
    return table.concat(L, "\n")
end

-- Co-op weather (owner request 2026-10-30): a run with a friend is darker than single player. The host leans the game's own
-- systems, the guest follows through the state above:
--   gloom   an override on top of the game's (priority 9) that keeps each of its values but never below a floor: storms still
--           come through, clear spells are overcast and drizzly
--   nights  time runs at 0.6x at night and 1.8x by day (0 = midnight, 0.3 dawn, 0.68 sunset), and a map that loads in daylight
--           starts late in the afternoon
--   storms  one of the game's weather events every 5-9 min (they replace each other)
-- Mutation nospooky: off.
local SPOOKY = M.mutate ~= "nospooky"
local GLOOM_ID, FLOOR = "PTCoopGloom", { [2] = 0.3, [3] = 0.45, [4] = 0.45, [5] = 0.3 } -- OV index: rain, fog, wind, darkness
local EVENTS = { "Storm", "Storm", "Rain Heavy", "Rain Heavy", "Dark Heavy", "Fog Medium" }
local spooky = { on = false }
RegisterLoadMapPostHook(function() spooky.dusk = os.clock() + 5 end) -- after the game's own time set on load
local function spookyTick()
    local tod = first("BP_ToDManager_C")
    if not tod then return end
    spooky.on = true
    local a, mx, speed = tod.TargetWeatherOverrideArray, {}, 1
    for j = 2, 7 do mx[j] = FLOOR[j] or 0 end
    for i = 1, a:GetArrayNum() do
        local e = a[i]
        if e[OV[ID]]:ToString() ~= GLOOM_ID then
            for j = 2, 7 do mx[j] = math.max(mx[j], e[OV[j]]) end
            speed = math.max(speed, e[OV[9]])
        end
    end
    local st, key = {}, {}
    for j, k in ipairs(OV) do
        st[k] = j == 1 and 9 or j == ID and FName(GLOOM_ID) or j == 9 and speed or mx[j]
        if j ~= ID then key[#key + 1] = f(st[k]) end
    end
    key = table.concat(key, "|")
    if key ~= spooky.key then tod:AddTODWeatherOverride(st); spooky.key = key end -- the same identifier replaces ours
    local r = {}
    tod["Get Current Time Of Day"](tod, r)
    local t = r["Returned Time Of Day"] or 0.5
    if spooky.dusk and os.clock() > spooky.dusk then
        spooky.dusk = nil
        if t > 0.3 and t < 0.65 then tod["Set Current Time Of Day"](tod, 0.65); t = 0.65; log("PT|world co-op weather: daylight load, late afternoon") end
    end
    local want = (t >= 0.75 or t <= 0.25) and 0.6 or 1.8
    if spooky.speed ~= want then tod["Set Time Of Day Speed Multiplier"](tod, want); spooky.speed = want end
    spooky.next = spooky.next or os.clock() + 120
    if os.clock() > spooky.next then
        local e = EVENTS[math.random(#EVENTS)]
        pcall(tod["DbgActEvt_Force Event: " .. e .. "_Execute"], tod)
        spooky.next = os.clock() + math.random(300, 540)
        log("PT|world co-op weather event %s", e)
    end
end
local function spookyOff()
    if not spooky.on then return end
    local tod = first("BP_ToDManager_C")
    if tod then
        pcall(tod.RemoveTODWeatherOverride, tod, FName(GLOOM_ID))
        pcall(tod["Set Time Of Day Speed Multiplier"], tod, 1)
    end
    spooky = { on = false }
end

local function hostTick()
    replicate()
    if SPOOKY then try("coopweather", spookyTick) end
    local data = snapshot()
    net.toGuests("g.world.state", data)
end

-- ---------------------------------------------------------------- guest

local lastState = 0 -- os.clock() of the last state from the host

local function parse(data)
    local s = { ov = {}, boons = {} }
    for line in (data .. "\n"):gmatch("(.-)\n") do
        local k, v = line:match("^([^\t]+)\t(.*)$")
        if k == "ov" then s.ov[#s.ov + 1] = v
        elseif k == "boon" then s.boons[#s.boons + 1] = v
        elseif k then s[k] = v end
    end
    return s
end

local function split(s) local t = {} for x in (s .. "|"):gmatch("(.-)|") do t[#t + 1] = x end return t end

local function passiveBoon(o, b)
    if o.Sphere1:GetGenerateOverlapEvents() then
        o.Sphere1:SetGenerateOverlapEvents(false)
        o[b.stop](o, false) -- also stops a timer started before the first host snapshot
    end
    o:SetActorTickEnabled(false)
end

local function applyBoons(lines)
    if #lines == 0 then return end
    local copies = {}
    for class in pairs(BOONS) do
        copies[class] = {}
        each(class, function(o) if o.Role == 1 then copies[class][#copies[class] + 1] = o end end)
    end
    for _, line in ipairs(lines) do
        local v = split(line)
        local b, x, y, z, power = BOONS[v[1]], tonumber(v[2]), tonumber(v[3]), tonumber(v[4]), tonumber(v[5])
        if b and x and y and z and power and power >= 0 and power < math.huge and (v[6] == "true" or v[6] == "false") then
            -- shortcut: stationary boons match by class/location; use a replicated ID if they can move or overlap.
            local best, distance = nil, 100 ^ 2
            for _, o in ipairs(copies[v[1]]) do
                local l = o:K2_GetActorLocation()
                local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2 + (l.Z - z) ^ 2
                if d < distance then best, distance = o, d end
            end
            if best then
                passiveBoon(best, b)
                best[b.power] = power
                local depleted = v[6] == "true"
                if depleted and not best.OutOfJuice then best[b.depleted](best) end
                best.OutOfJuice = depleted
            end
        end
    end
end

local function applyTime(s)
    local tod = first("BP_ToDManager_C")
    if not tod then return end
    -- each side rolls its own random north per map (RandomizeNorth): the guest's ARC map was turned 90 degrees (live 2026-11-04)
    local n = tonumber(s.north)
    if n and math.abs((tod["Current North As Rotator"].Yaw - n + 180) % 360 - 180) > 0.5 then
        local y = math.rad(n)
        tod:SetTrueNorth({ X = math.cos(y), Y = math.sin(y), Z = 0 }, { Pitch = 0, Yaw = n, Roll = 0 })
        local b = firstLive("BP_GobblerMapBounds_C")
        if b then b["Capture Configure"](b, true) end -- turns the bounds and renders the map picture again
        log("PT|world guest north %.1f (map %s)", n, b and "turned" or "not loaded")
    end
    if s.tod and not clock.active() then
        local r = {}
        tod["Get Current Time Of Day"](tod, r)
        local d = math.abs((r["Returned Time Of Day"] or 0) - tonumber(s.tod))
        if math.min(d, 1 - d) > 0.002 then tod["Set Current Time Of Day"](tod, tonumber(s.tod)) end
    end
    if s.preset and s.preset ~= "" then
        local cur = tod["Target TOD Preset"]
        if not (cur and cur:IsValid() and cur:GetFullName():gsub("^%S+ ", "") == s.preset) then
            local c = StaticFindObject(s.preset)
            if c and c:IsValid() then tod["Set New TOD Target"](tod, c) end
        end
    end
    -- the guest's manager lost its sim actor and the sim never heard of preset changes (hand play 2026-10-24: host in rain, guest dry):
    -- relink, and feed the sim the manager's target preset when it still runs another one
    if M.mutate ~= "nosimlink" then
        local sim = first("ToD_Simulation_C")
        if sim and not (tod.ToDSimulationActor and tod.ToDSimulationActor:IsValid()) then tod:SetupToDSimulationActor() end
        local want = tod["Target TOD Preset"]
        if sim and want and want:IsValid() and sim.CurrentPresetObject:IsValid() and sim.CurrentPresetObject:GetClass():GetFullName() ~= want:GetFullName() then
            sim:WeatherChangeEvent(want)
        end
    end
    -- overrides by identifier: add or replace the host's, remove the rest
    local want = {}
    for _, line in ipairs(s.ov) do
        local v = split(line)
        want[v[ID]] = true
        local st = {}
        for j, k in ipairs(OV) do st[k] = j == ID and FName(v[j]) or tonumber(v[j]) end
        tod:AddTODWeatherOverride(st)
    end
    local a = tod.TargetWeatherOverrideArray
    local drop = {}
    for i = 1, a:GetArrayNum() do
        local id = a[i][OV[ID]]:ToString()
        if not want[id] then drop[#drop + 1] = id end
    end
    for _, id in ipairs(drop) do tod:RemoveTODWeatherOverride(FName(id)) end
    if s.cur then
        local c = split(s.cur)
        tod:SetCurrentWeatherOverrideValues(tonumber(c[1]), tonumber(c[2]), tonumber(c[3]), tonumber(c[4]), tonumber(c[5]), tonumber(c[6]), tonumber(c[7]))
    end
end

local gateMissing, gateShown -- the last gateway position logged as not found / shown, so each happens once
RegisterLoadMapPostHook(function() gateMissing, gateShown = nil, nil end)
local function applyStorm(s)
    local wb = whiteboard()
    if wb and s.instab then wb:SetTagFloat(INSTAB, tonumber(s.instab)) end
    local sm = first("BP_StormManager_C")
    if sm and s.storm then
        local v = split(s.storm)
        sm.CurrentStormState = tonumber(v[1])
        sm.RedWallActive = v[2] == "true"
        sm.TimeBeforeInstabilityStarts = tonumber(v[3])
        sm.FinalInstabilityTollerance = tonumber(v[4])
        sm.StormAudioVisualIntensity = tonumber(v[5])
    end
    local st = firstLive("BP_ZoneStorm_Base_C")
    if st and s.wall then
        local v = split(s.wall)
        st.Vol_Rad_Main, st.Vol_Rad_Weak, st.Collapsed = tonumber(v[1]), tonumber(v[2]), v[3] == "true"
    end
    -- the gateway the host summoned: its portal is the picked exit here too
    if sm and s.gate and s.gate ~= "none" then
        local p = common.findPortal(s.gate)
        local cur = sm.EvolvedGatewayExit
        if not p then
            if gateMissing ~= s.gate then gateMissing = s.gate log("PT|world guest gateway at %s: no portal there", s.gate) end
        elseif gateShown ~= s.gate and not (cur and cur:IsValid() and short(cur) == short(p)) then
            gateShown = s.gate -- once: if the pick does not stick here, the state would replay the beam and sound every second
            p.IsPickedExit = true
            sm["Select Exit Portal Actor"](sm, p)
            -- the beam, lights, sound and map icon: the visual part of the portal's Activate, which runs on the host only
            -- (playtest 2026-11-01: summoned gateway invisible to the guest). Not Activate itself: it also turns on the
            -- portal's collision, and a transition must not start in the guest's own game.
            pcall(function() p:Portal_AnimStart() end)
            pcall(function() p:SetExitPortalActive(true) end)
            pcall(function() p.BP_AkComponent_Ambient:RequestPlay() end)
            log("PT|world guest gateway %s shown (%s)", s.gate, short(p))
            ov.post("Gateway summoned", "good")
        end
    end
end

-- anything this process simulated on its own: after the host's state has been flowing for a few seconds, only replicated copies (Role 1) stay
local function cleanGuest()
    -- the test mutation: the old behaviour, own story pickups destroyed at once
    if os.getenv("PT_MUTATE") == "noportals" then each(PROP, function(o) if o.Role ~= 1 then o:K2_DestroyActor() end end) end
    if os.clock() - lastState > 5 or os.clock() - (M.since or os.clock()) < 5 then return end
    local classes = { PROP }
    for _, class in ipairs(REPLICATED) do classes[#classes + 1] = class end
    for _, class in ipairs(classes) do
        each(class, function(o)
            if (class == PROP or class == "BP_LevelTransition_ExitPortal_C") and keep[short(o)] then return end
            if o.Role == 1 then
                -- the host's copy decides where it is: the guest's own motion code stays off (position updates: g.world.pos)
                if class == "BP_Base_Hazard_C" and not (WI:IsValid() and o:IsA(WI)) then o:SetActorTickEnabled(false) end
                if BOONS[class] then passiveBoon(o, BOONS[class]) end
                return
            end
            if WI:IsValid() and class == "BP_Base_Hazard_C" and o:IsA(WI) then return end
            o:K2_DestroyActor()
        end)
    end
    -- the guest's own map objective markers: its copy of an old mission's marker stayed on its map (live 2026-11-04) and a live
    -- one turns its icon back on every tick; the guest's map draws the host's icons instead (mapmark.lua)
    each(OBJMARK, function(o) o:K2_DestroyActor(); log("PT|world guest objective marker %s removed (the map shows the host's)", short(o)) end)
    -- G3: story drivers of the guest's own game
    each("NarrativeBeatActor", function(o) if o.Role ~= 1 then o:K2_DestroyActor() end end)
end

net.on("g.world.state", function(_, data)
    if not M.enabled then return end
    M.since = M.since or os.clock()
    lastState = os.clock()
    local s = parse(data)
    if s.keep and os.getenv("PT_MUTATE") ~= "noportals" then keep = {} for n in s.keep:gmatch("[^,]+") do keep[n] = true end end
    try("time", applyTime, s)
    try("storm", applyStorm, s)
    try("boons", applyBoons, s.boons)
end)

-- falling rain, splashes and radiation haze follow the local character (BP_AmbienceManager). The guest's manager initialised before
-- its character existed (rendered guest 2026-10-30): VFXInitialized stayed false, so its tick never ran (the rain stood at the map
-- origin, inside/outside never changed), AmbsReadyToPlay stayed false, and the rain occlusion camera and the global height capture
-- (spawned on the host's side only) were missing. The game's own initialisers, run here once the character is there, fix all of it.
local HEIGHT = "/Game/Systems/GlobalHeightCapture/BP_GlobalHeightCapture.BP_GlobalHeightCapture_C"
local ambienceFor, tries -- the character the setup runs for, attempts left (a headless game makes no effects and would retry forever)
local function ambience()
    local am, cm = first("BP_AmbienceManager_C"), first("BP_MainCharacterManager_C")
    local char = cm and cm:GetCharacterActor()
    if not (am and char and char:IsValid()) then return end
    if ambienceFor ~= char:GetFullName() then ambienceFor, tries = char:GetFullName(), 3 end
    if tries <= 0 or (am.VFXInitialized and am.AmbsReadyToPlay) then return end
    tries = tries - 1
    if not am.AmbsReadyToPlay then am:RetryInitialize() end
    if not am.VFXInitialized then
        -- each call makes a new falling-rain component: the old one would stay where it stood
        local old = am.RainSystem
        if old:IsValid() then pcall(function() old:DestroyComponent(old) end) end
        am:InitializeAmbientVFX()
    end
    if not first("rainOcclusionCamera_Blueprint_C") then am:SpawnRainOcclusionCamera() end
    if not first("BP_GlobalHeightCapture_C") then
        if not StaticFindObject(HEIGHT):IsValid() then pcall(LoadAsset, HEIGHT) end
        local cls, gs = StaticFindObject(HEIGHT), UEHelpers.GetGameplayStatics()
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        if cls:IsValid() then gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(char, cls, xf, 1, nil), xf) end
    end
    log("PT|world guest ambience vfx=%s ready=%s", tostring(am.VFXInitialized), tostring(am.AmbsReadyToPlay))
end

-- G3: the mission-manager pre-hooks that keep the guest from starting a story live in story.lua.

LoopInGameThreadWithDelay(1000, function()
    if not M.enabled or not safety.active() then M.since = nil; if not safety.guest() then try("coopweather", spookyOff) end return end
    if safety.guest() then
        try("clean", cleanGuest)
        if M.mutate ~= "noambience" then try("ambience", ambience) end
    else try("host", hostTick) end
end)

-- Level-placed hazards (grabbers) keep simulating on the guest and ignore replicated movement: the host sends the positions
-- of those that moved and the guest puts its copies there (same name on both sides). Between updates the guest's own motion shows.
-- A grabber's floating core moves on its own inside the actor: its world position goes along, else the guest's core stayed
-- ~650 uu under an awake grabber (hand playtest 2026-10-23: "a wiggling wreck" instead of the grabber).
local function core(o)
    local ok, c = pcall(function() return o.CoreFloatingMesh end)
    return ok and c and c:IsValid() and c or nil
end
local function moved(a, b) return math.abs(a.X - b.X) + math.abs(a.Y - b.Y) + math.abs(a.Z - b.Z) > 20 end
local sent, beat = {}, 0
-- host: the hazard list is refetched every 5 s (and on a map load), the 4 Hz position pass only checks the kept objects
local hazards, hazardsAt = {}, -99
RegisterLoadMapPreHook(function() hazardsAt = -99 end)
local function eachHazard(fn)
    if os.clock() - hazardsAt > 5 then
        hazards, hazardsAt = {}, os.clock()
        each("BP_Base_Hazard_C", function(o) hazards[#hazards + 1] = o end)
    end
    for _, o in ipairs(hazards) do if o:IsValid() then fn(o) end end
end
LoopInGameThreadWithDelay(250, function()
    if not M.enabled or not safety.active() or safety.guest() then return end
    beat = beat + 1
    if beat % 8 == 0 then sent = {} end -- everything again every 2 s (a late guest, a copy that drifted)
    try("pos", function()
        local L = {}
        eachHazard(function(o)
            if WI:IsValid() and o:IsA(WI) then return end
            local n, l = o:GetFName():ToString(), o:K2_GetActorLocation()
            local c = core(o)
            c = c and c:K2_GetComponentLocation()
            local p = sent[n]
            if not p or moved(p, l) or (c and (not p.c or moved(p.c, c))) then
                sent[n] = { X = l.X, Y = l.Y, Z = l.Z, c = c and { X = c.X, Y = c.Y, Z = c.Z } }
                L[#L + 1] = string.format("%s\t%.1f\t%.1f\t%.1f", n, l.X, l.Y, l.Z)
                    .. (c and string.format("\t%.1f\t%.1f\t%.1f", c.X, c.Y, c.Z) or "")
            end
        end)
        if #L > 0 then net.toGuests("g.world.pos", table.concat(L, "\n")) end
    end)
end)

net.on("g.world.pos", function(_, data)
    if not M.enabled then return end
    try("pos", function()
        local at = {}
        for line in data:gmatch("[^\n]+") do
            local n, x, y, z, rest = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)(.*)$")
            if n then
                at[n] = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
                local cx, cy, cz = rest:match("^\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
                if cx then at[n].c = { X = tonumber(cx), Y = tonumber(cy), Z = tonumber(cz) } end
            end
        end
        each("BP_Base_Hazard_C", function(o)
            local l = at[o:GetFName():ToString()]
            if not l then return end
            o:K2_SetActorLocation(l, false, {}, true)
            local c = l.c and core(o)
            if c then c:K2_SetWorldLocation(l.c, false, {}, true) end
        end)
    end)
end)

-- Smooth hazards on the guest (pt3-anom, "the grabber moves very per frame"): a replicated hazard's position arrives 4 to 10 times a second and the
-- engine snaps the copy to it. Every frame the guest notices that the engine (or g.world.pos above) moved a copy, takes that spot as the target and
-- shows the copy gliding there from where it was shown, over the time the last two updates were apart. A jump over 1500 uu (teleport) is not glided.
-- Mutation nosmooth switches it off.
local smooth, hz, scanned = {}, {}, 0
RegisterLoadMapPostHook(function() smooth, hz, scanned = {}, {}, 0 end) -- keyed by address: freed ones come back as other objects
local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
local NEAR = 8000 -- uu: farther hazards jump to their updates unsmoothed (nobody sees it)
LoopInGameThreadWithDelay(16, function()
    if not M.enabled or os.getenv("PT_MUTATE") == "nosmooth" or not safety.guest() then return end
    local now = os.clock()
    if now - scanned > 1 then
        scanned, hz = now, {}
        -- only hazards near the guest: every hazard of a big zone each frame cost ~6 ms a frame after 2 h (playtest 2026-10-31)
        local pc = UEHelpers.GetPlayerController()
        local me = pc and pc:IsValid() and pc.Pawn
        local here = me and me:IsValid() and me:K2_GetActorLocation()
        each("BP_Base_Hazard_C", function(o)
            if o.Role == 1 and not (WI:IsValid() and o:IsA(WI)) and (not here or dist(o:K2_GetActorLocation(), here) < NEAR) then hz[#hz + 1] = o end
        end)
    end
    for _, o in ipairs(hz) do
        pcall(function()
            if not live(o) then return end
            local key, cur = o:GetAddress(), o:K2_GetActorLocation()
            local s = smooth[key]
            if not s then smooth[key] = { shown = cur, from = cur, to = cur, t0 = now, len = 0.25 } return end
            if dist(cur, s.shown) > 1 then -- someone moved it: a new update
                if dist(cur, s.shown) > 1500 then s.shown, s.from, s.to, s.t0 = cur, cur, cur, now
                else s.from, s.to, s.len, s.t0 = s.shown, cur, math.max(0.08, math.min(0.5, now - s.t0)), now end
            end
            local k = math.min(1, (now - s.t0) / s.len)
            s.shown = { X = s.from.X + (s.to.X - s.from.X) * k, Y = s.from.Y + (s.to.Y - s.from.Y) * k, Z = s.from.Z + (s.to.Z - s.from.Z) * k }
            if dist(s.shown, cur) > 0.5 then o:K2_SetActorLocation(s.shown, false, {}, true) end
        end)
    end
end)

M.snapshot = snapshot
return M
