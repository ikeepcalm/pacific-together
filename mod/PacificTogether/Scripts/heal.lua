-- Partner heal (owner's choice after playtest 2026-10-31: the host kept losing health to damage not fixed yet). Look at the other
-- player within 3 m and press H: they get 40% of their maximum health back, for free. Each player can do it once per 3 minutes.
-- The giver checks distance, aim and its own cooldown; the receiver heals itself (each process owns its own PlayerHealth,
-- health.lua). Messages (net.target, to one player): g.heal.give; g.heal.full, the receiver's answer when it was already at full
-- health: the giver gets its cooldown back (hand test 2026-11-01 spent it on a full host). Inert in single player (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local ov = require("overlay")
local log = common.log

local M = { REACH = 300, AIM_DEG = 25, SHARE = 0.4, COOLDOWN = 180 }
if os.getenv("PT_MUTATE") == "noheal" then return M end

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end

local readyAt = 0 -- os.clock() when this player may heal again

-- the other player's character in front of our camera, close enough
local function partnerInReach(pc)
    local me = pc.Pawn
    local cam = pc.PlayerCameraManager
    if not valid(me) or not valid(cam) then return nil end
    local from = cam:GetCameraLocation()
    local fwd = UEHelpers.GetKismetMathLibrary():GetForwardVector(cam:GetCameraRotation())
    local minCos = math.cos(math.rad(M.AIM_DEG))
    for _, c in ipairs(FindAllOf("PDP_MainCharacter_C") or {}) do
        if valid(c) and c:GetAddress() ~= me:GetAddress() then
            local p = c:K2_GetActorLocation()
            local d = { X = p.X - from.X, Y = p.Y - from.Y, Z = p.Z - from.Z }
            local len = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
            if len < M.REACH and len > 1 and (d.X * fwd.X + d.Y * fwd.Y + d.Z * fwd.Z) / len > minCos then return c end
        end
    end
end

local function press()
    if not safety.active() then return end
    local pc = UEHelpers.GetPlayerController()
    local target = valid(pc) and partnerInReach(pc)
    if not target then return end
    local left = readyAt - os.clock()
    if left > 0 then ov.post(string.format("You can heal %s again in %d s", ov.nameOf(target), math.ceil(left)), "warn", "heal"); return end
    local id = net.idOf(target)
    if id < 0 then return end -- its PlayerState has not arrived yet
    readyAt = os.clock() + M.COOLDOWN
    net.sendTo(id, "g.heal.give", "")
    ov.post("You patched up " .. ov.nameOf(target), "good", "heal")
    log("PT|heal given")
end
common.onKey("H", press)
if os.getenv("PT_SCENARIO") == "healhint" then net.on("g.heal.testpress", press) end -- the test bot's H

-- the key hint (owner request 2026-11-12): only while the partner is in reach and in front of the camera AND our heal is ready
-- (the hint would otherwise tell a player to press H when it only answers "again in N s"). Mutation healhintalways: always shown.
local ALWAYS = os.getenv("PT_MUTATE") == "healhintalways"
LoopInGameThreadWithDelay(150, function()
    local want = nil
    if safety.active() or ALWAYS then
        local pc = UEHelpers.GetPlayerController()
        local target = valid(pc) and os.clock() >= readyAt and partnerInReach(pc)
        if ALWAYS or target then want = "[H] Patch up " .. (target and ov.nameOf(target) or ov.other()) end
    end
    ov.hint(want)
end)

net.target("g.heal.give", function(_, _, giver)
    local m = FindFirstOf("BP_ResourceManager_C")
    local h = valid(m) and m.PlayerHealth
    if not valid(h) then return end
    local add = math.min(h.Maximum * M.SHARE, h.Maximum - h.Current)
    if add <= 0 then
        net.sendTo(giver, "g.heal.full", "")
        return
    end
    h:Adjust(m, add)
    ov.post(ov.nameOf(giver) .. " patched you up", "good", "heal")
    log("PT|heal got +%.0f now %.0f/%.0f", add, h.Current, h.Maximum)
end)

net.target("g.heal.full", function(_, _, id)
    readyAt = 0
    ov.post(ov.nameOf(id) .. " is already at full health", "info", "heal")
end)

-- ARC Doc (the Doctor ARC's car ability, class AP_Tether_Basic): the game heals only the player who activates it (the host:
-- a seated guest is not natively in the car and gets no ability menu). While it is active, a guest seated in the car heals at
-- the ability's own rate (TUNE_TetherHealthPerSecond, 10 HP/s) and the host's batteries pay the ability's exchange rate
-- (TUNE_BatteryHealthScale, 0.4 battery per HP) for what the guest gained (owner's choice 2026-11-09).
--   g.doc     host -> guests  "<hp per s>" while active (every 0.5 s), "0" when it ends
--   g.doc.hp  guest -> host   HP the guest gained since its last report (about once a second)
local DOC = "/Game/Gameplay/Abilities/AP_Tether_Basic.AP_Tether_Basic_C"
local function seated(pc)
    local me = valid(pc) and pc.Pawn
    local car = valid(me) and me:GetAttachParentActor()
    return valid(car) and car:GetClass():GetFName():ToString() == "BP_PlayerCarNew_C"
end
local function docAbility() -- host: the ARC Doc ability while it is active, else nil
    for _, p in ipairs(FindAllOf("BP_AbilityProviderComponent_C") or {}) do
        if valid(p) and p.AbilityIsActive and valid(p.CachedAbilityClass) and p.CachedAbilityClass:GetFullName():find(DOC, 1, true) then
            local a = FindFirstOf("AP_Tether_Basic_C")
            if valid(a) then return a end
        end
    end
end
local function tuning(t)
    local lib = StaticFindObject("/Script/PenDriverUtils.Default__TuningFloatLibrary")
    local ok, v = pcall(function() return lib:Conv_TuningFloatToFloat(t) end)
    return ok and tonumber(v) or nil
end

local docSent, docScale, docAllowed, docAt = false, 0.4, 0, os.clock()
LoopInGameThreadWithDelay(500, function()
    if common.netMode() ~= "listen" or not safety.active() or os.getenv("PT_MUTATE") == "nodocshare" then return end
    local a = docAbility()
    local hps = a and tuning(a.TUNE_TetherHealthPerSecond)
    local dt = os.clock() - docAt
    docAt = os.clock()
    if hps and hps > 0 then
        docScale = tuning(a.TUNE_BatteryHealthScale) or docScale
        docAllowed = math.min(docAllowed + hps * dt * 1.5, hps * 5) -- the most a guest's reports may claim (lag, batching)
        net.toGuests("g.doc", string.format("%.3f", hps))
        if not docSent then log("PT|heal doc on %.1f HP/s, battery %.2f per HP", hps, docScale) end
        docSent = true
    elseif docSent then
        net.toGuests("g.doc", "0")
        docSent = false
        log("PT|heal doc off")
    end
end)

net.on("g.doc.hp", function(_, data)
    if common.netMode() ~= "listen" then return end
    local hp = math.min(tonumber(data) or 0, docAllowed)
    if hp <= 0 then return end
    docAllowed = docAllowed - hp
    local cm = FindFirstOf("BP_CarManager_C")
    if not valid(cm) then return end
    local e, empty = {}, {}
    cm["Drain All Batteries"](cm, hp * docScale, e, empty)
    log("PT|heal doc guest +%.1f HP, battery -%.2f", hp, hp * docScale)
end)

-- guest
local docRate, docUntil, docGained, docReportAt, docTick = 0, 0, 0, 0, os.clock()
net.on("g.doc", function(_, data)
    if common.netMode() ~= "client" then return end
    docRate = tonumber(data) or 0
    docUntil = docRate > 0 and os.clock() + 1.5 or 0 -- a lost "0" ends it 1.5 s after the last "on"
end)
LoopInGameThreadWithDelay(100, function()
    local dt = math.min(os.clock() - docTick, 0.5)
    docTick = os.clock()
    if common.netMode() ~= "client" or not safety.active() then return end
    -- the report runs after the ability ended too: the last second's HP are paid as well
    if docGained > 0 and os.clock() >= docReportAt then
        net.toHost("g.doc.hp", string.format("%.2f", docGained))
        docGained, docReportAt = 0, os.clock() + 1
    end
    if docRate <= 0 or os.clock() > docUntil then return end
    local pc = UEHelpers.GetPlayerController()
    if not seated(pc) then return end
    local m = FindFirstOf("BP_ResourceManager_C")
    local h = valid(m) and m.PlayerHealth
    if not valid(h) then return end
    local add = math.min(docRate * dt, h.Maximum - h.Current)
    if add > 0 then h:Adjust(m, add); docGained = docGained + add end
end)

return M
