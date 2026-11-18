-- Guest kicks on hazards (W6). The Tourist (BP_Hazard_Landmine, also Shocked Tourist) explodes when its antenna tilts 25 degrees,
-- which the host's kick (BP_MainCharacterManager:PlayerKick: AddImpulseAtLocation on the hit component, then the Kickable interface's
-- ObjectKicked) does through physics. The guest's kick lands on its own puppet copy (tick off, host decides), so nothing happened.
-- The guest's ObjectKicked on a replicated copy becomes "g.anomhit" (class, copy position, kick point, kick vector); the host finds
-- its own hazard there, checks the guest pawn is within kick reach, and applies the same impulse and ObjectKicked.
-- Replicated actors have different names on each side (level-placed ones are GUID-named on the host), so the key is class + position.
-- Not covered: Tour Bus / Tourist Trap (no ObjectKicked; they explode on physics hits), thrown items. Inert outside a session (Q7).
local common = require("common")
local net = require("net")
local safety = require("safety")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "noanomhit", sent = 0, applied = 0 }
local MINE = "/Game/Gameplay/Hazards/Landmine/BP_Hazard_Landmine.BP_Hazard_Landmine_C"
local REACH = 450 -- uu from the guest pawn to the kick point (the kick traces 200 from the camera, 75 above the pawn)
local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error anomhit %s %s", what, tostring(err)) end
end
local function v3(v) return string.format("%.1f\t%.1f\t%.1f", v.X, v.Y, v.Z) end

-- guest: the class loads with the map, so the hook is retried until it exists
local hooked = false
LoopInGameThreadWithDelay(2000, function()
    if hooked or not M.enabled then return end
    hooked = pcall(RegisterHook, MINE .. ":ObjectKicked", function(self, comp, loc, vec)
        try("kick", function()
            if not (safety.active() and safety.guest()) then return end
            local o = self:get()
            if not (valid(o) and o.Role == 1) then return end -- only the replicated copy; the guest's own simulation does not count
            local l = o:K2_GetActorLocation()
            net.toHost("g.anomhit", o:GetClass():GetFName():ToString() .. "\t" .. v3(l) .. "\t" .. v3(loc:get()) .. "\t" .. v3(vec:get()))
            M.sent = M.sent + 1
            log("PT|anomhit kick sent")
        end)
    end)
end)

local curve
local function kickMultiplier(mass)
    if not (curve and curve:IsValid()) then
        curve = StaticFindObject("/Game/Systems/Controller/C_PlayerKickMassMultiplier.C_PlayerKickMassMultiplier")
        if not curve:IsValid() then return nil end
    end
    return curve:GetFloatValue(mass)
end

-- host
net.on("g.anomhit", function(pc, data)
    if not (M.enabled and safety.active() and not safety.guest()) then return end
    try("apply", function()
        local cls, ax, ay, az, kx, ky, kz, vx, vy, vz = data:match("^([^\t]+)" .. ("\t([^\t]+)"):rep(9) .. "$")
        if not cls then return end
        ax, ay, az, kx, ky, kz, vx, vy, vz = tonumber(ax), tonumber(ay), tonumber(az), tonumber(kx), tonumber(ky), tonumber(kz), tonumber(vx), tonumber(vy), tonumber(vz)
        if not (ax and az and kx and kz and vx and vz) then return end
        local pawn = pc.Pawn
        if not valid(pawn) then return end
        local p = pawn:K2_GetActorLocation()
        if (p.X - kx) ^ 2 + (p.Y - ky) ^ 2 + (p.Z - kz) ^ 2 > REACH ^ 2 then return end
        local best, bd = nil, 250 ^ 2
        for _, o in ipairs(FindAllOf("BP_Hazard_Landmine_C") or {}) do
            if valid(o) and o:GetClass():GetFName():ToString() == cls and valid(o.Body) then
                local l = o:K2_GetActorLocation()
                local d = (l.X - ax) ^ 2 + (l.Y - ay) ^ 2 + (l.Z - az) ^ 2
                if d < bd then best, bd = o, d end
            end
        end
        if not best then return end
        local body = best.Body
        local mass = body:GetMass()
        local mult = kickMultiplier(mass)
        if not mult then return end
        local f = mass * mult
        body:AddImpulseAtLocation({ X = vx * f, Y = vy * f, Z = vz * f }, { X = kx, Y = ky, Z = kz }, FName("None"))
        best:ObjectKicked(body, { X = kx, Y = ky, Z = kz }, { X = vx, Y = vy, Z = vz })
        M.applied = M.applied + 1
        log("PT|anomhit kick applied to %s", best:GetFName():ToString())
    end)
end)

return M
