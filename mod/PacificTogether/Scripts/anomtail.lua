-- Bunnies (the Leeches, W6, docs/spikes/anomtail.md). The host runs them; two gaps remained:
--   guest copy  a replicated Leech (Role 1) kept its own physics sphere and its own tick, whose last act is "actor location = my sphere": the copy
--               sat wherever the guest's physics left it, not where the host's leech is (anomtable: 180 to 1160 uu off). The copy gets no
--               tick; its sphere is put at the replicated actor every 50 ms (SetSimulatePhysics(false) on it crashed the guest, 20261118-094510).
--   guest hurt  the game's leap target is the host's car (and its camera), CheckForHitPlayer compares with the host's character only. A leech
--               within LEAP of a guest's pawn (on the host) that is not cooling down launches at the pawn and bites it for the game's own 15
--               (anomalies.lua forwards the damage to the guest). Healer and Charging Bunnies do not bite.
-- Mutation noanomtail switches the module off. Inert outside a session (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local safety = require("safety")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "noanomtail", bites = 0, followed = 0 }
local CLASS, IMPACT = "BP_Hazard_Leech_C", "/Game/Systems/Messages/MSG_Damage_Physical_Impact.MSG_Damage_Physical_Impact_C"
local LEAP, BITE, COOL = 900, 220, 10 -- uu: start of the leap, bite reach; seconds between bites (the game waits 10 s)
local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error anomtail %s %s", what, tostring(err)) end
end
local function live(o) return o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and not o:GetFullName():find("/Engine/Transient", 1, true) end
local function each(fn) for _, o in ipairs(FindAllOf(CLASS) or {}) do if live(o) then fn(o) end end end
local function hurt(pawn, dmg)
    local ms, c = FindFirstOf("MessageSystem"), StaticFindObject(IMPACT)
    if not c:IsValid() then pcall(LoadAsset, IMPACT); c = StaticFindObject(IMPACT) end
    if not (ms and c:IsValid()) then return end
    local m = StaticConstructObject(c, ms)
    m.Damage = dmg
    ms:DispatchMessage(m, pawn)
end
local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

-- ---------------------------------------------------------------- host: a leech leaps at and bites a guest near it
local bitAt, leaping = {}, {} -- leech name -> os.clock() of its last bite / of its leap
RegisterLoadMapPreHook(function() bitAt, leaping = {}, {} end)
LoopInGameThreadWithDelay(200, function()
    if not (M.enabled and safety.active() and not safety.guest()) then return end
    try("bite", function()
        local pawns = {}
        for _, pc in ipairs(net.guests()) do if pc:IsValid() and pc.Pawn:IsValid() then pawns[#pawns + 1] = pc.Pawn end end
        if #pawns == 0 then return end
        local now = os.clock()
        each(function(l)
            local cls = l:GetClass():GetFName():ToString()
            if cls:find("Healer", 1, true) or cls:find("Charging", 1, true) or l.IsGrabbed or l.Deactivated then return end
            local key = l:GetFName():ToString()
            if now - (bitAt[key] or -99) < COOL or l.LeechState == 3 then return end -- 3 = leaping: the game's own hit path (anomalies2)
            local ball = l.SM_Prototype_BlockySphere
            local at = ball:K2_GetComponentLocation()
            local best, bd
            for _, p in ipairs(pawns) do
                local d = d3(at, p:K2_GetActorLocation())
                if d < LEAP and (not bd or d < bd) then best, bd = p, d end
            end
            if not best then leaping[key] = nil return end
            if bd < BITE then
                bitAt[key], leaping[key] = now, nil
                hurt(best, 15)
                M.bites = M.bites + 1
                log("PT|anomtail %s bit the guest", key)
            elseif not leaping[key] or now - leaping[key] > 3 then
                leaping[key] = now
                if ball:IsSimulatingPhysics("None") then
                    local to = best:K2_GetActorLocation()
                    local dx, dy = to.X - at.X, to.Y - at.Y
                    local n = math.max(math.sqrt(dx * dx + dy * dy), 1)
                    local v = math.min(bd * 2, 1500)
                    ball:AddImpulse({ X = dx / n * v, Y = dy / n * v, Z = 350 }, "None", true)
                end
            end
        end)
    end)
end)

-- ---------------------------------------------------------------- guest: the copy shows where the host's leech is
LoopInGameThreadWithDelay(50, function()
    if not (M.enabled and safety.active() and safety.guest()) then return end
    try("follow", function()
        each(function(l)
            if l.Role ~= 1 then return end
            l:SetActorTickEnabled(false)
            local ball = l.SM_Prototype_BlockySphere
            ball:K2_SetWorldLocation(l:K2_GetActorLocation(), false, {}, true)
            M.followed = M.followed + 1
        end)
    end)
end)

-- ---------------------------------------------------------------- Lightning strike: replicated as it begins play
-- A strike lives about a second; the 1 s sweep of world.lua came too late (the guest never had a copy).
local STRIKE = "/Game/Gameplay/Hazards/HazardProperties/LightningStrike/BP_Hazard_LightningStrike.BP_Hazard_LightningStrike_C"
local hooked = false
LoopInGameThreadWithDelay(2000, function()
    if hooked or not M.enabled then return end
    if not StaticFindObject(STRIKE):IsValid() then pcall(LoadAsset, STRIKE) end
    hooked = pcall(RegisterHook, STRIKE .. ":ReceiveBeginPlay", function(self)
        if safety.active() and not safety.guest() then pcall(common.replicateActor, self:get()) end
    end)
end)

return M
