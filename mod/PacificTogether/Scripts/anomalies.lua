-- Anomalies act on both players (W6, W7, D19). The host runs every hazard (world.lua replicates them, the guest's copies are
-- inert), and the hazards' logic targets "the player" through single-reference managers, so the host's own process decides.
--   damage   hazards hurt by dispatching MSG_Damage_* messages to pawns in a sphere. The guest's pawn exists on the host too and
--            its AC_PlayerHealthReceiverHelper adjusts the HOST's PlayerHealth: the host was hurt for the guest's hit. The host
--            intercepts the remote receiver before its health/feedback logic and sends "g.anom.msg"; the guest dispatches the same message
--            class to its own pawn, so its own health, magic HP, feedback and death run as for any hit (health.lua handles death).
--            The same the other way: the guest hitting the host's body (a melee swing) hurt the GUEST (hand playtest 2026-10-23);
--            the guest intercepts that receiver and the host takes the hit on its own character.
--   tourists a Tourist creeps only when camera 0 (the host's) does not see it; a post-hook on CreepCheck also asks the guest's
--            camera as the host sees it (ServerUpdateCamera), docs/research/tourists.md.
-- Everything is inert outside a session (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local safety = require("safety")
local log = common.log
local ov = require("overlay")

local M = { enabled = os.getenv("PT_MUTATE") ~= "noanom", debug = os.getenv("PT_ANOM_DEBUG") ~= nil } -- the test mutation switches the module off
local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error anomalies %s %s", what, tostring(err)) end
end
-- Blueprint classes load with their map: a hook is retried until its class exists, then kept
local pending = {}
local function hook(path, pre, post)
    pending[#pending + 1] = { path = path, pre = pre or function() end, post = post }
end
LoopInGameThreadWithDelay(2000, function()
    for i = #pending, 1, -1 do
        local h = pending[i]
        if pcall(RegisterHook, h.path, h.pre, h.post) then table.remove(pending, i) end
    end
end)

-- ---------------------------------------------------------------- damage

local RECEIVER = "/Game/Characters/Player/Components/AC_PlayerHealthReceiverHelper.AC_PlayerHealthReceiverHelper_C:"
local BINDS = { "MessageBind_MSG_Damage_Physical_C", "MessageBind_MSG_Base_Heal_C", "MessageBind_MSG_Damage_Acid_C", "MessageBind_MSG_Damage_Radiation_C",
    "MessageBind_MSG_Damage_Electrical_C", "MessageBind_MSG_Damage_FallDamage_C", "MessageBind_MSG_Heal_Generic_C", "MessageBind_MSG_Base_Damage_C" }
M.forwarded, M.applied = 0, 0 -- counters for the scenario

-- host: is this receiver on the pawn of a remote player?
local function isGuestPawn(receiver)
    local owner = receiver:GetOwner()
    if not valid(owner) then return false end
    local c = owner.Controller
    return valid(c) and not c:IsLocalController()
end

-- Legacy fallback for native builds without receiver interception; the native guard also prevents HUD feedback and refunds.
local lastHp, lastPayload, lastAt = nil, nil, 0

local function hostHealth()
    local rm = FindFirstOf("BP_ResourceManager_C")
    return valid(rm) and valid(rm.PlayerHealth) and rm or nil
end

LoopInGameThreadWithDelay(16, function()
    if PTNative_DamagePoll and os.getenv("PT_MUTATE") ~= "nodamageguard" then lastHp = nil return end
    if not (M.enabled and safety.active()) then lastHp = nil return end
    local rm = hostHealth()
    lastHp = rm and rm.PlayerHealth.Current or nil
end)

-- guest: is this receiver on a character that is not ours (the host's body)?
local function isHostBody(receiver)
    local owner, pc = receiver:GetOwner(), UEHelpers.GetPlayerController()
    return valid(owner) and valid(pc) and valid(pc.Pawn) and owner:GetAddress() ~= pc.Pawn:GetAddress()
        and owner:IsA(StaticFindObject("/Script/PenDriverPro.BaseCharacter"))
end

-- guest: the game seating the rejoined guest jolts the car on the guest's side and hurts the host's body there (hand play
-- 2026-10-24: 60 and 19.8 forwarded to the host after every junction, 2-8 s after the load). shortcut: a real hit on the host's
-- body in the guest's world in the first 20 s of a map is dropped too; anchor to the seating instead if that matters
local loadedAt, GUARD = 0, os.getenv("PT_MUTATE") == "noseatguard" and 0 or 20 -- mutation noseatguard: zoneexit
RegisterLoadMapPostHook(function() loadedAt = os.clock() end)

local function pre(rec, p, intercepted)
    if not (M.enabled and safety.active()) then return end
    local guest = safety.guest()
    if not (valid(rec) and valid(p)) then return end
    if guest then if not isHostBody(rec) or os.clock() - loadedAt < GUARD then return end elseif not isGuestPawn(rec) then return end
    local dmg = p.Damage
    local key, now = p:GetAddress(), os.clock()
    if not intercepted then
        if key == lastPayload and now - lastAt < 0.5 then return end
        lastPayload, lastAt = key, now
    end
    if dmg == 0 then return end
    -- a bump of the host's body in the guest's world (seating jolts, its copy of the car): the host's game already deals its own
    -- physical hits, and a forwarded 60 came out of nowhere for the host (playtest 2026-10-31)
    if guest and p:GetClass():GetFName():ToString():find("Physical_Impact", 1, true) then return end
    local sample, cap = lastHp, math.abs(dmg) * 1.5 + 1
    if sample and not intercepted then
        common.defer(40, function() try("put back", function()
            local rm = hostHealth()
            if not rm then return end
            local d = math.max(-cap, math.min(cap, sample - rm.PlayerHealth.Current))
            if math.abs(d) > 0.05 then rm.PlayerHealth:Adjust(rm, d); M.undone = (M.undone or 0) + d; log("PT|anom host health put back %.1f", d) end
        end) end)
    end
    local cls = p:GetClass():GetFullName():gsub("^%S+ ", "")
    local msg = string.format("%s\t%.3f\t%d\t%d\t%.3f\t%d", cls, dmg, p.Spillover and 1 or 0, p.IsDamageOverTime and 1 or 0, p.FeedbackStrength, p.DistributeMode)
    M.forwarded = M.forwarded + 1
    if guest then
        net.toHost("g.anom.msg", msg)
        log("PT|anom damage for host %s", msg)
        return
    end
    net.toGuest(rec:GetOwner().Controller, "g.anom.msg", msg)
    log("PT|anom damage for guest %s", msg)
    ov.post(ov.other() .. " was hit by an anomaly", "warn", "anom")
end

for _, fn in ipairs(BINDS) do
    hook(RECEIVER .. fn, function(self, payload)
        if PTNative_DamagePoll and os.getenv("PT_MUTATE") ~= "nodamageguard" then return end
        try("forward", pre, self:get(), payload:get(), false)
    end)
end

local receiversAt = -1
RegisterLoadMapPreHook(function() receiversAt = -1; if PTNative_DamageClear then PTNative_DamageClear() end end)
LoopInGameThreadWithDelay(16, function()
    if not PTNative_DamagePoll then return end
    if not (M.enabled and safety.active()) or os.getenv("PT_MUTATE") == "nodamageguard" then PTNative_DamageClear(); receiversAt = -1; return end
    try("receiver guard", function()
        -- the native side keeps receivers (weak pointers) until cleared, so the FindAllOf runs 4x a second, not every frame
        -- (0.4-0.8 ms a frame on both sides, 0.8.8 sessions); only the queue is polled every frame
        if os.clock() - receiversAt >= 0.25 then
            receiversAt = os.clock()
            for _, rec in ipairs(FindAllOf("AC_PlayerHealthReceiverHelper_C") or {}) do
                if valid(rec) and (safety.guest() and isHostBody(rec) or not safety.guest() and isGuestPawn(rec)) then
                    PTNative_DamageReceiver(rec:GetAddress())
                end
            end
        end
        while true do
            local rec, payload = PTNative_DamagePoll()
            if not rec then break end
            pre(rec, payload, true)
        end
    end)
end)

-- Car crashes (from PDCoopNet's hazards.lua, MIT, BroZYTnikkkk): the car's damage controller works out the player's share of
-- every hit on the car (LimitDamageToPlayerOverTime, limited over time; ~20 MSG_Damage_Physical_Impact of 0.04-0.5 per crash) and
-- hands it to "the player", always the host, so a guest riding along took nothing. While a guest sits in that car, the host sends
-- it the same share as g.anom.msg (its own resistances apply). Not in the garage, where the game deals no player damage. The
-- guest's copy of the car cannot work it out itself (its controller stops at once on a replicated car, PDCoopNet exp215).
local DISPATCH = "/Game/Systems/Messages/BP_CarDispatchController.BP_CarDispatchController_C:LimitDamageToPlayerOverTime"
local function inGarage()
    local ok, g = pcall(function() return FindFirstOf("DrivingGameInstance"):IsInGarage() end)
    return ok and g == true
end
local function crash(self, msgp, _, updatedp)
    if not M.enabled or os.getenv("PT_MUTATE") == "nocrash" or safety.guest() or not safety.active() then return end
    if os.getenv("PT_CRASH_GARAGE") ~= "1" and inGarage() then return end -- the carcrash test runs in the garage
    local dmg, p = updatedp:get(), msgp:get()
    if type(dmg) ~= "number" or dmg <= 0 or not valid(p) then return end
    local ctl = self:get() -- a plain object, not a component: its car is the one whose DamageDispatchController it is
    for _, pc in ipairs(net.guests()) do
        local pawn = pc.Pawn
        local ok, mine = pcall(function()
            local car = pawn:GetAttachParentActor()
            return valid(car) and car.DamageDispatchController:GetAddress() == ctl:GetAddress()
        end)
        if valid(pawn) and ok and mine then
            local cls = p:GetClass():GetFullName():gsub("^%S+ ", "")
            net.toGuest(pc, "g.anom.msg", string.format("%s\t%.3f\t%d\t%d\t%.3f\t%d\tcrash", cls, dmg, p.Spillover and 1 or 0,
                p.IsDamageOverTime and 1 or 0, p.FeedbackStrength, p.DistributeMode))
            M.crashes = (M.crashes or 0) + 1
        end
    end
end
hook(DISPATCH, function(...) try("crash", crash, ...) end)

net.on("g.anom.msg", function(_, data)
    if not (M.enabled and safety.active()) then return end
    local guest = safety.guest()
    try("apply", function()
        local cls, dmg, sp, dot, fb, dm, why = data:match("^([^\t]+)\t([^\t]+)\t(%d)\t(%d)\t([^\t]+)\t(%d)\t?(%a*)$")
        if not cls then return end
        local c = StaticFindObject(cls)
        if not valid(c) then pcall(LoadAsset, cls); c = StaticFindObject(cls) end
        local pc, ms = UEHelpers.GetPlayerController(), FindFirstOf("MessageSystem")
        local cm = FindFirstOf("BP_MainCharacterManager_C")
        local target = guest and (valid(pc) and pc.Pawn) or (valid(cm) and cm.CharacterActor)
        if not (valid(c) and valid(target) and valid(ms)) then return end
        local m = StaticConstructObject(c, ms)
        m.Damage, m.Spillover, m.IsDamageOverTime, m.FeedbackStrength, m.DistributeMode = tonumber(dmg), sp == "1", dot == "1", tonumber(fb), tonumber(dm)
        ms:DispatchMessage(m, target)
        M.applied = M.applied + 1
        log("PT|anom damage applied %s", data)
        if why == "crash" then ov.post("Hurt in the crash", "warn", "crash")
        else ov.post(guest and "Hit by an anomaly" or (ov.other() .. " hit you"), "warn", "anom") end
    end)
end)

-- ---------------------------------------------------------------- tourists (D19, W7)

-- the game's own test in CreepCheck: within 2000 uu of the camera and dot(camera -> mine, camera forward) > 0.3 = seen
local function sees(loc, rot, t)
    local d = { X = t.X - loc.X, Y = t.Y - loc.Y, Z = t.Z - loc.Z }
    local len = math.sqrt(d.X ^ 2 + d.Y ^ 2 + d.Z ^ 2)
    if len > 2000 or len < 1 then return false end
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    local f = { X = math.cos(p) * math.cos(y), Y = math.cos(p) * math.sin(y), Z = math.sin(p) }
    return (d.X * f.X + d.Y * f.Y + d.Z * f.Z) / len > 0.3
end

-- CreepCheck (the game's own test, camera 0 only) is what lets a Tourist step. A hook given as a single callback runs after the
-- Blueprint body (see Observations) and may change the out value: when it says "could creep" and a guest's camera sees the Tourist,
-- it says no. (The earlier ShouldCreep flag trick ran too late for the first step after the host's own view reset the Tourist.)
hook("/Game/Gameplay/Hazards/Landmine/BP_Hazard_Landmine.BP_Hazard_Landmine_C:CreepCheck", function(self, could)
    if not (M.enabled and safety.active() and not safety.guest()) or not could:get() then return end
    try("creep", function()
        local at = self:get().Body:K2_GetComponentLocation()
        for _, pc in ipairs(net.guests()) do
            -- the guest's camera as the host knows it (the stock ServerUpdateCamera feeds its PlayerCameraManager here)
            local cam = pc.PlayerCameraManager
            if valid(cam) and sees(cam:GetCameraLocation(), cam:GetCameraRotation(), at) then could:set(false); M.frozen = (M.frozen or 0) + 1; return end
        end
    end)
end)

return M
