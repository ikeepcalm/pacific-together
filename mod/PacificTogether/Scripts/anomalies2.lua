-- Anomalies, second pass (W6, W7). The host runs every hazard; what the guest still lacks:
--   leech, bomb rock    item actors: they mostly replicate by themselves, the host makes sure (guest copy = Role 1, anomalies2 scenario).
--                       A Leech's leap hurts only the host's character (CheckForHitPlayer compares with BP_MainCharacterManager):
--                       a leap that hits a guest's pawn on the host gives the guest the game's own 15 damage.
--   physics grabber     it targets the host's character (BP_MainCharacterManager) only. When a guest's pawn (on the host) is inside its
--                       cone the host sends "g.anom.pull x y z" and the guest pulls itself toward the grabber's core with the
--                       game's own pull force (MapRangeClamped(distance, 0..500, 6000..8500) + 150 up on CharacterMovement) and
--                       takes its hit as the game does (MSG_Damage_Physical_Impact, forwarded by anomalies.lua).
-- Inert outside a session (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local safety = require("safety")
local ov = require("overlay")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "noanom2", debug = os.getenv("PT_ANOM_DEBUG") ~= nil } -- the test mutation switches the module off
local function live(o) return o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and not o:GetFullName():find("/Engine/Transient", 1, true) end
local function each(class, fn) for _, o in ipairs(FindAllOf(class) or {}) do if live(o) then fn(o) end end end
local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then log("PT|error anomalies2 %s %s", what, tostring(err)) end
end

local IMPACT = "/Game/Systems/Messages/MSG_Damage_Physical_Impact.MSG_Damage_Physical_Impact_C"
-- a hazard's hit on a guest's pawn (on the host): anomalies.lua forwards the message to the guest and gives the host its health back
local function hurt(pawn, dmg)
    local ms, c = FindFirstOf("MessageSystem"), StaticFindObject(IMPACT)
    if not c:IsValid() then pcall(LoadAsset, IMPACT); c = StaticFindObject(IMPACT) end
    if not (ms and c:IsValid()) then return end
    local m = StaticConstructObject(c, ms)
    m.Damage = dmg
    ms:DispatchMessage(m, pawn)
end

local function guestPawnOf(o)
    if not (o and o:IsValid()) then return end
    for _, pc in ipairs(net.guests()) do if pc:IsValid() and pc.Pawn:IsValid() and pc.Pawn:GetAddress() == o:GetAddress() then return pc.Pawn end end
end

-- ---------------------------------------------------------------- leech and bomb rock exist for the guest

-- They usually replicate by themselves, not always (run 20261021-173243: a spawned Leech never reached the guest): the host makes sure.
LoopInGameThreadWithDelay(1000, function()
    if not (M.enabled and safety.active() and not safety.guest()) then return end
    try("worlditem", function()
        each("BP_Base_Hazard_WorldItem_C", function(o)
            if common.replicateActor(o) then log("PT|anom2 replicating %s", o:GetFName():ToString()) end
        end)
    end)
end)

-- ---------------------------------------------------------------- leech

local leeched = {} -- leech name -> os.clock() of its last hit (the game waits 10 s)
local pending = true
LoopInGameThreadWithDelay(2000, function()
    if not pending then return end
    -- the Blueprint class loads with its map: retried until it exists
    pending = not pcall(RegisterHook, "/Game/Gameplay/Hazards/Leech/BP_Hazard_Leech.BP_Hazard_Leech_C:CheckForHitPlayer", function(self, hit)
        if not (M.enabled and safety.active() and not safety.guest()) then return end
        try("leech", function()
            local l, pawn = self:get(), guestPawnOf(hit:get())
            local key = l:GetFName():ToString()
            -- LeechState 3 = leaping (the game's own condition); one hit per 10 s
            if not pawn or l.LeechState ~= 3 or os.clock() - (leeched[key] or -99) < 10 then return end
            leeched[key] = os.clock()
            hurt(pawn, 15)
            M.leeched = (M.leeched or 0) + 1
            log("PT|anom2 leech hit the guest")
        end)
    end)
end)

-- ---------------------------------------------------------------- physics grabbers pull the guest

local GRAB = "BP_Hazard_PhysicsGrabber_C"
local HIT, RANGE, PULL_MAX, COOL = 10, 700, 3, 6 -- shortcut: the game's tuning tag value is not read; range stands in for the cone when its overlap is off
local grabList, grabAt = {}, -99
RegisterLoadMapPreHook(function() grabAt = -99 end)
local grabbing = {} -- grabber name -> { since, last, cool }
M.pulls = 0

local function guestPawns()
    local r = {}
    for _, pc in ipairs(net.guests()) do
        if pc:IsValid() and pc.Pawn:IsValid() then r[#r + 1] = { pc = pc, pawn = pc.Pawn } end
    end
    return r
end

local function inCone(g, pawn, core)
    local ok, o = pcall(function() return g.Cone:IsOverlappingActor(pawn) end)
    if ok and o then return true end
    local l = pawn:K2_GetActorLocation()
    return (l.X - core.X) ^ 2 + (l.Y - core.Y) ^ 2 + (l.Z - core.Z) ^ 2 < RANGE ^ 2
end

LoopInGameThreadWithDelay(100, function()
    if not (M.enabled and safety.active() and not safety.guest()) then return end
    try("grab", function()
        local now = os.clock()
        local gp = guestPawns()
        if #gp == 0 then return end
        -- the grabber list is refetched every 1 s (one just spawned shows up late), not 10 times a second
        if now - grabAt > 1 then
            grabList, grabAt = {}, now
            each(GRAB, function(g) grabList[#grabList + 1] = g end)
        end
        for _, g in ipairs(grabList) do if g:IsValid() then
            local core = g.CoreFloatingMesh:K2_GetComponentLocation()
            for _, t in ipairs(gp) do
                local key = g:GetFName():ToString()
                local st = grabbing[key] or {}
                if (st.cool or 0) > now then
                elseif inCone(g, t.pawn, core) then
                    st.since = st.since or now
                    if now - st.since > PULL_MAX then st.cool, st.since = now + COOL, nil
                    else
                        if st.since == now then -- first contact: the game's hit on the one it grabs
                            hurt(t.pawn, HIT)
                            ov.post(ov.other() .. " was grabbed", "warn", "anom")
                        end
                        net.toGuest(t.pc, "g.anom.pull", string.format("%.0f	%.0f	%.0f", core.X, core.Y, core.Z))
                        M.pulls = M.pulls + 1
                    end
                else st.since = nil end
                grabbing[key] = st
            end
        end end
    end)
end)

local pullTo, pullUntil -- guest
net.on("g.anom.pull", function(_, data)
    if not (M.enabled and safety.guest()) then return end
    local x, y, z = data:match("^(%-?[%d%.]+)	(%-?[%d%.]+)	(%-?[%d%.]+)$")
    if not x then return end
    pullTo, pullUntil = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) - 250 }, os.clock() + 0.35
    M.applied = (M.applied or 0) + 1
end)
LoopInGameThreadWithDelay(16, function()
    if not (pullTo and os.clock() < pullUntil and safety.guest()) then return end
    try("pull", function()
        local pc = UEHelpers.GetPlayerController()
        local me = pc and pc:IsValid() and pc.Pawn or nil
        if not (me and me:IsValid()) then return end
        local l = me:K2_GetActorLocation()
        local d = { X = pullTo.X - l.X, Y = pullTo.Y - l.Y, Z = pullTo.Z - l.Z }
        local len = math.max(math.sqrt(d.X ^ 2 + d.Y ^ 2 + d.Z ^ 2), 1)
        local f = 6000 + 2500 * math.min(len, 500) / 500 -- MapRangeClamped(len, 0, 500, 6000, 8500)
        me.CharacterMovement:AddForce({ X = d.X / len * f, Y = d.Y / len * f, Z = d.Z / len * f + 150 })
        M.pulled = (M.pulled or 0) + 1
    end)
end)

return M
