-- Hazards whose Logic Driver state machine is frozen on a LISTEN host (W6 "anomalies run on the host"; docs/spikes/smhost.md).
-- The game ships every hazard's SMStateMachineComponent for a standalone game (config Client = 0). In a listen session the component
-- counts as "configured for networking": its instance gets a NetworkInterface and bCanEvaluateTransitionsLocally = false, so the machine
-- ticks but never takes a transition (the saw never leaves IDLE, the Blacksmith never swings ...). Switching the component's replication
-- off makes IsConfiguredForNetworking() false again; a fresh instance (Shutdown, Initialize, Start) then behaves as in a standalone
-- game. Host process only (a guest's copies keep their own configuration, W2). The state is not replicated any more: the guest gets
-- the hazards' effects from world.lua / anommove.lua as before.
-- A host listening alone is the same: vanilla single player ran these machines (Q7 is about what the mod adds; this restores it).
-- Mutation nosmhost switches the module off.
local common = require("common")
local safety = require("safety")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "nosmhost", fixed = 0, names = {} }
-- owner classes whose machines are left alone (none: the Abductor's machine is fixed too, it then hunts the car AND loose items / the player as in single
-- player, docs/spikes/anomfin.md; anommove.lua's own car-hunt driver stands aside for a machine that runs)
local SKIP = {}
local seen = {} -- component address -> true

local function fix(c)
    local i = c.R_Instance
    local started = i:IsValid() and i.R_bHasStarted
    local cet, ti = i:IsValid() and i.bCanEverTick, i:IsValid() and i.TickInterval
    c.bReplicates = false
    c.bReuseInstanceAfterShutdown = false
    c:Shutdown()
    c:Initialize(c:GetOwner())
    if started then -- the BP's own Start / SetCanEverTick / SetTickInterval ran once when a player came in range
        c:Start()
        local n = c.R_Instance
        n:SetCanEverTick(cet)
        n:SetTickInterval(ti)
    end
end

LoopInGameThreadWithDelay(500, function()
    if not (M.enabled and common.netMode() == "listen") then return end
    for _, c in ipairs(FindAllOf("SMStateMachineComponent") or {}) do
        if c:IsValid() and not c:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then
            local key = c:GetAddress()
            if not seen[key] then
                seen[key] = true
                local name = c:GetFullName()
                local owner = c:GetOwner()
                local class = owner:IsValid() and owner:GetClass():GetFName():ToString() or ""
                if not name:find("Default__", 1, true) and not name:find("_GEN_VARIABLE", 1, true) and (class:find("^BP_Hazard_") or class:find("^BP_Boon_")) and not SKIP[class]
                    and c:IsConfiguredForNetworking() then
                    local ok, err = pcall(fix, c)
                    if ok then
                        M.fixed = M.fixed + 1
                        M.names[class] = (M.names[class] or 0) + 1
                        log("PT|smhost fixed %s", class)
                    else log("PT|error smhost %s %s", class, tostring(err)) end
                end
            end
        end
    end
end)

RegisterLoadMapPostHook(function() seen = {} end)

return M
