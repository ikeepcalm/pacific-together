-- PT1 car feel: what the host's car and the radios do is heard and seen by the guest too (messages g.feel.*).
--   radios: moved to radio.lua (PT6, host authoritative).
--   car (host -> guest): the guest's replicated car has its vehicle controller off, so its audio and speedometer read zeros.
--     The host sends throttle, normalised speed (the engine's veh_speed RTPC input), signed speed, the speedometer needle,
--     horn and wipers; the guest writes them after each tick of its AC_CarAudio and speedometer (post-hooks), starts and
--     stops the horn through the car's own audio component, and toggles the wipers through the car's own event.
--     Ignition, gear, headlights and doors already arrive through car.lua.
-- Inert in single player: nothing runs without a listening host that has a guest, or a client.
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local log = common.log

local M = {}
if os.getenv("PT_MUTATE") == "nofeel" then
    log("PT|carfeel disabled (mutation nofeel)")
    return M
end

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local first = common.first
local function now()
    local s, p = {}, {}
    UEHelpers.GetGameplayStatics():GetAccurateRealTime(s, p)
    return s.Seconds + p.PartialSeconds
end
local function mode() return common.netMode() end
local function active() return mode() == "client" or (mode() == "listen" and #net.guests() > 0) end
local function send(kind, data)
    if mode() == "client" then net.toHost(kind, data) else net.toGuests(kind, data) end
end
local function carCar()
    local ok, car = pcall(require, "car")
    return ok and type(car) == "table" and car.theCar and car.theCar(mode() == "listen") or nil
end
local ownedCache = {} -- class -> { car address, object }: the lookup walked every AC_CarAudio_C twice a tick
RegisterLoadMapPreHook(function() ownedCache = {} end)
local function ownedBy(class, car)
    local c = ownedCache[class]
    if c and c[1] == car:GetAddress() and valid(c[2]) then return c[2] end
    for _, o in ipairs(FindAllOf(class) or {}) do
        if valid(o) then
            local own = class == "AC_CarAudio_C" and o:GetOwner() or o:GetAttachParentActor()
            if valid(own) and own:GetFullName() == car:GetFullName() then ownedCache[class] = { car:GetAddress(), o }; return o end
        end
    end
end

-- car ------------------------------------------------------------------------------------------------------------------

local feel -- on the guest: the host's latest values
local role, cap, gcar, gaudio, gsp = "none", { veh_engineLoad = 0, veh_speed = 0, veh_speed_direction = 0 }, nil, nil, nil
local function fresh() return feel ~= nil and now() - feel.at < 2.5 end

-- The engine, wheel and speed sounds are fed by the car audio Blueprint through the native SetRTPCValue, from the vehicle
-- controller, which is off on the guest's car. Post hooks never fire for these Blueprint ticks, so the host takes the exact
-- values the game hands to Wwise and the guest swaps them in at the same call (and in the speedometer arm's rotation call).
local hookedAudio = false
local RTPC, ARM = "/Script/AkAudio.AkGameplayStatics:SetRTPCValue", "/Script/Engine.SceneComponent:K2_SetRelativeLocationAndRotation"
local hookIds = {}
local function unhookAudio()
    if not hookedAudio then return end
    for fn, ids in pairs(hookIds) do pcall(UnregisterHook, fn, ids[1], ids[2]) end
    hookIds, hookedAudio = {}, false
end
local function hookAudio()
    if hookedAudio then return end
    local ok, id1, id2 = pcall(RegisterHook, RTPC, function(_, rtpc, val)
        if role ~= "client" and role ~= "listen" then return end
        local okc, e = pcall(function()
            local n = rtpc:get():GetFName():ToString()
            if cap[n] == nil and n ~= "veh_speed_slowRelease" then return end
            if role == "listen" then cap[n] = val:get(); return end
            if not fresh() then return end
            if n == "veh_speed" or n == "veh_speed_slowRelease" then
                val:set(feel.cs)
                if valid(gaudio) then gaudio.CurrentSpeed = feel.cs end
            elseif n == "veh_speed_direction" then val:set(feel.dir)
            elseif n == "veh_engineLoad" then val:set(feel.load) end
        end)
        if not okc then log("PT|error feel rtpc hook %s", tostring(e)) end
    end)
    if not ok then log("PT|error feel hook SetRTPCValue %s", tostring(id1)); return end
    hookIds[RTPC] = { id1, id2 }
    -- every component move of the game passes this native call: only the guest needs it (its speedometer needle)
    if role ~= "client" then hookedAudio = true; return end
    ok, id1, id2 = pcall(RegisterHook, ARM, function(self, _, rot)
        if role ~= "client" or not valid(gsp) or not fresh() then return end
        local okc, e = pcall(function()
            if self:get():GetAddress() == gsp.SpeedArm:GetAddress() then rot:set(feel.arm) end
        end)
        if not okc then log("PT|error feel arm hook %s", tostring(e)) end
    end)
    if not ok then log("PT|error feel hook speedometer %s", tostring(id1)); return end
    hookIds[ARM] = { id1, id2 }
    hookedAudio = true
end

local function sample(car)
    local cm = first("BP_CarManager_C")
    local ca, sp = ownedBy("AC_CarAudio_C", car), ownedBy("BP_CarPart_Internal_Speedometer_C", car)
    if not cm or not ca then return end
    local arm = { Pitch = 0, Yaw = 0, Roll = 0 }
    if sp and valid(sp.SpeedArm) then arm = sp.SpeedArm.RelativeRotation end
    return string.format("%.2f	%.3f	%d	%.3f	%.1f	%.1f	%.1f	%d	%d", cap.veh_engineLoad, cap.veh_speed, cap.veh_speed_direction,
        ca.ThrottleAccumCurrent, arm.Pitch, arm.Yaw, arm.Roll, cm.HornOn and 1 or 0, cm.WiperBladesOnOff and 1 or 0)
end

local lastCar, lastCarAt = nil, 0
local function hostCarTick()
    if not active() then lastCar = nil; return end
    local car = carCar()
    if not car then return end
    local s = sample(car)
    if not s then return end
    local t = now()
    if s ~= lastCar or t - lastCarAt > 1 then
        send("g.feel.c", s)
        lastCar, lastCarAt = s, t
    end
end

-- Cabin sound: the game's own entry runs AC_CarAudio.OnPlayerStartEnterCar (veh_int, PlayerInsideCar, state veh_int); the
-- guest is seated by car.lua, so its car audio stayed "outside, doors shut" and muffled the radio and engine (playtests
-- 2026-11-01 and 2026-11-03). Only the audio events run here, not the game's enter or exit.
local cabinRetryAt = 0 -- after an error (a pawn or controller gone during a load), try again 10 s later
local function seatedIn(pawn) local seat = pawn:GetAttachParentActor(); return valid(gcar) and valid(seat) and seat:GetAddress() == gcar:GetAddress() end
-- the game's in-car share (set only by its own entry timeline): BP_CarManager.WillCarProtectPlayer needs it > 0.33, so a
-- sealed car did not shield the seated guest from radiation (playtest 2026-11-08); storm, black hole and stealer read it too.
-- Every 100 ms on its own, not behind the cabin audio's checks and 10 s error pause: a shield must not outlast the seat.
local function guestInCar()
    if os.getenv("PT_MUTATE") == "noincar" then return end
    local pawn = UEHelpers.GetPlayerController().Pawn
    if not valid(pawn) then return end
    local pct = seatedIn(pawn) and 1 or 0
    if pawn.PercentInCar ~= pct then
        pawn.PercentInCar = pct
        log("PT|feel in-car percent %d", pct)
    end
end
local function guestCabin()
    if not valid(gaudio) then return end
    local pawn = UEHelpers.GetPlayerController().Pawn
    if not valid(pawn) then return end
    local inside = seatedIn(pawn)
    if gaudio.PlayerInsideCar == inside then return end
    if inside then gaudio:OnPlayerStartEnterCar(false) else gaudio:OnPlayerStartExitCar(false) end
    log("PT|feel cabin audio inside=%s", tostring(inside))
end

local function refreshGuest()
    gcar = carCar()
    gaudio = gcar and ownedBy("AC_CarAudio_C", gcar) or nil
    gsp = gcar and ownedBy("BP_CarPart_Internal_Speedometer_C", gcar) or nil
    pcall(guestInCar)
    if os.clock() < cabinRetryAt then return end
    local ok, err = pcall(guestCabin)
    if not ok then cabinRetryAt = os.clock() + 10 log("PT|error feel cabin %s (again in 10 s)", tostring(err)) end
end

local hornApplied, wiperAt = nil, -10
net.on("g.feel.c", function(_, data)
    if mode() ~= "client" then return end
    local f = {}
    for x in (data .. "	"):gmatch("([^	]*)	") do f[#f + 1] = tonumber(x) end
    if #f < 9 then log("PT|error feel car message incomplete"); return end
    feel = { load = f[1], cs = f[2], dir = f[3], acc = f[4], arm = { Pitch = f[5], Yaw = f[6], Roll = f[7] }, horn = f[8], wip = f[9], at = now() }
    local car = carCar()
    if not car then return end
    local ca, cm = ownedBy("AC_CarAudio_C", car), first("BP_CarManager_C")
    if ca and hornApplied ~= feel.horn then
        if pcall(function() ca:Call_CarHorn_Active(feel.horn == 1) end) then hornApplied = feel.horn end
        log("PT|feel horn %d", feel.horn)
    end
    if cm and (cm.WiperBladesOnOff and 1 or 0) ~= feel.wip and feel.at - wiperAt >= 1 then
        wiperAt = feel.at
        pcall(function() car:ToggleWiperBlades() end)
        log("PT|feel wipers %d", feel.wip)
    end
end)

LoopInGameThreadWithDelay(100, function()
    role = mode()
    local ok, err = pcall(function()
        if active() then hookAudio() else unhookAudio() end
        if role == "client" then
            refreshGuest()
            -- the posed car copy hits the ground and the game spawns its metal scrape sound actor; the host hears the real hits
            if os.getenv("PT_MUTATE") ~= "noscrapedrop" then
                -- polled on the game thread: a NotifyOnNewObject callback ran Lua off it and corrupted the Lua state (guest crash in
                -- luaH_next on getting out of the car, garage play 2026-10-24)
                for _, a in ipairs(FindAllOf("BP_CarScrapeFX_C") or {}) do if valid(a) then a:K2_DestroyActor() end end
            end
        elseif role == "listen" then hostCarTick() end
    end)
    if not ok then log("PT|error feel car tick %s", tostring(err)) end
end)
-- the guest's controller is off, so its throttle input (the engine load and wheel spin sounds) is the host's
LoopInGameThreadWithDelay(16, function()
    if feel and valid(gcar) and fresh() then
        pcall(function()
            local car = package.loaded.car
            if not (car and car.physicalProxyActive and car.physicalProxyActive()) then gcar.VehicleController.ThrottleInput = feel.load end
            if valid(gaudio) and math.abs(gaudio.ThrottleAccumCurrent - feel.acc) > 0.3 then gaudio.ThrottleAccumCurrent = feel.acc end
        end)
    end
end)
LoopInGameThreadWithDelay(200, function()
    if mode() == "standalone" or mode() == "none" then feel, hornApplied = nil, nil end
end)

-- Car electrical feedback (BP_FeedbackManager CarElectrical, the game's electrical-fault flicker of headlights and dash): the
-- guest's own copy held ~0.37 while the host's car read 0, so the guest's lights and dash flickered all the time, parked too
-- (owner 2026-11-09, "like the ignition could not finish"; capping the guest's to 0 stopped it). What feeds the guest's value
-- was not found (no ambient source in its map, no burst calls). The guest now shows the host's: its feedback max is set to the
-- host's value and the host's value is added as a source, so the highest source clamped to the max is exactly the host's.
--   g.feel.elec  host -> guests  "<current ambient>"
local ELEC = 0 -- the feedback type index of CarElectrical
local function elecAmbient(fm)
    local v
    pcall(function()
        local s = fm.CarElectrical
        s:ForEachProperty(function(p) local n = p:GetFName():ToString(); if n:find("^CurrentAmbient") then v = s[n] end end)
    end)
    return v
end
local elecSent, elecSentAt, elecSet = -1, 0, false
LoopInGameThreadWithDelay(100, function()
    if mode() ~= "listen" or #net.guests() == 0 then return end
    local fm = first("BP_FeedbackManager_C")
    local v = fm and elecAmbient(fm)
    if not v then return end
    v = math.floor(v * 50 + 0.5) / 50
    if v ~= elecSent or os.clock() - elecSentAt > 2 then
        elecSent, elecSentAt = v, os.clock()
        net.toGuests("g.feel.elec", string.format("%.2f", v))
    end
end)
net.on("g.feel.elec", function(_, data)
    if mode() ~= "client" or os.getenv("PT_MUTATE") == "noelecmirror" then return end
    local v, fm = tonumber(data), first("BP_FeedbackManager_C")
    if not (v and v >= 0 and v <= 1 and fm) then return end
    pcall(function()
        fm:SetCarFeedbackMax(ELEC, v)
        fm["Add Car Feedback Ambient Source"](fm, ELEC, v, FName("PTHost"))
    end)
    if not elecSet then elecSet = true; log("PT|carfeel electrical feedback follows the host (%.2f)", v) end
end)
-- the managers live in the game instance: every map change gives back the game's own maximum (1); in a session the host's next
-- message (within 2 s) sets it again, back in single player it stays the game's
RegisterLoadMapPreHook(function()
    if not elecSet then return end
    elecSet = false
    local fm = first("BP_FeedbackManager_C")
    if fm then pcall(function() fm:SetCarFeedbackMax(ELEC, 1.0); fm:RemoveCarFeedbackAmbientSource(ELEC, FName("PTHost")) end) end
end)
return M
