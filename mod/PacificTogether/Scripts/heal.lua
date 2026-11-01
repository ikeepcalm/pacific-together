-- Partner heal (owner's choice after playtest 2026-10-31: the host kept losing health to damage not fixed yet). Look at the other
-- player within 3 m and press H: they get 40% of their maximum health back, for free. Each player can do it once per 3 minutes.
-- The giver checks distance, aim and its own cooldown; the receiver heals itself (each process owns its own PlayerHealth,
-- health.lua). Messages: g.heal.give (no data); g.heal.full (no data), the receiver's answer when it was already at full health:
-- the giver gets its cooldown back (hand test 2026-11-01 spent it on a full host). Inert in single player (Q7).
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

common.onKey("H", function()
    if not safety.active() then return end
    local pc = UEHelpers.GetPlayerController()
    if not valid(pc) or not partnerInReach(pc) then return end
    local left = readyAt - os.clock()
    if left > 0 then ov.post(string.format("You can heal %s again in %d s", ov.other(), math.ceil(left)), "warn", "heal"); return end
    readyAt = os.clock() + M.COOLDOWN
    if common.netMode() == "client" then net.toHost("g.heal.give", "") else net.toGuests("g.heal.give", "") end
    ov.post("You patched up " .. ov.other(), "good", "heal")
    log("PT|heal given")
end)

net.on("g.heal.give", function()
    local m = FindFirstOf("BP_ResourceManager_C")
    local h = valid(m) and m.PlayerHealth
    if not valid(h) then return end
    local add = math.min(h.Maximum * M.SHARE, h.Maximum - h.Current)
    if add <= 0 then
        if common.netMode() == "client" then net.toHost("g.heal.full", "") else net.toGuests("g.heal.full", "") end
        return
    end
    h:Adjust(m, add)
    ov.post(ov.other() .. " patched you up", "good", "heal")
    log("PT|heal got +%.0f now %.0f/%.0f", add, h.Current, h.Maximum)
end)

net.on("g.heal.full", function()
    readyAt = 0
    ov.post(ov.other() .. " is already at full health", "info", "heal")
end)

return M
