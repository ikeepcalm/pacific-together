-- hosthurt: a guest that died and was revived must not drain the host (lane hosthurt, docs/spikes/hosthurt.md).
--   The guest is killed (health to its minimum), the host respawns it, then it is taken far from the host again and a Cough Box
--   cloud (BP_Hazard_Cloud_Acid) is spawned at its feet.
--   guest_died / guest_revived   health.lua's death and revive ran on the guest
--   guest_hurt_after_revive      the guest's own health fell in the cloud
--   host_not_drained_after_guest_death  the host's health held through the cloud (mutation hostdrain brings back the old drain)
-- PT_HURT_NEAR=1 leaves the revived guest where the host put it (next to the host's car) for the double-hit case.
-- Run: tools/run-test.ps1 -Scenario hosthurt -Fixture zone -Headless [-Mutate hostdrain]
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local CLOUD = "/Game/Gameplay/Hazards/Cloud/BP_Hazard_Cloud_Acid.BP_Hazard_Cloud_Acid_C"
    local function health()
        local rm = T.first("BP_ResourceManager_C")
        local h = rm and rm.PlayerHealth
        return (h and h:IsValid()) and h.Current or -1
    end
    local function xf(x, y, z) return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } } end
    local function spawn(path, x, y, z)
        local cls = StaticFindObject(path)
        if not cls:IsValid() then pcall(LoadAsset, path); cls = StaticFindObject(path) end
        if not cls:IsValid() then return nil end
        local gs = UEHelpers.GetGameplayStatics()
        return gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(T.world(), cls, xf(x, y, z), 2, nil), xf(x, y, z))
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local gpc, guestHp, minSeen, hostHp0, guestHp0, o = nil, -1, 1e9, -1, -1, nil
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.hp" then guestHp = tonumber(data) or guestHp; minSeen = math.min(minSeen, guestHp) end
            end
        end
        local function toGuest(kind, data) PTNative_MsgToGuest(gpc:GetAddress(), kind, data) end
        local spot -- the zone's Tesla spot (as anomtable): far from the host and the car
        local function farTp()
            toGuest("t.tp", string.format("%.0f\t%.0f\t%.0f", spot.X, spot.Y, spot.Z))
            pcall(function() L.guestChar():K2_TeleportTo(spot, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
        end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function()
            gpc = L.remotePCs()[1]
            local tesla
            for _, x in ipairs(FindAllOf("BP_Hazard_Tesla_C") or {}) do
                if T.inWorld(x) and not x:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then tesla = tesla or x end
            end
            assert(tesla, "no map Tesla")
            local l = tesla:K2_GetActorLocation()
            spot = { X = l.X + 400, Y = l.Y, Z = l.Z + 150 }
            tesla:K2_DestroyActor()
            farTp()
            toGuest("t.heal", "1")
        end })
        add({ check = "host_far_from_guest", timeout = 30, cond = function() return T.dist(L.guestChar(), T.myPawn()) > 6000 end })
        add({ wait = 12 }) -- health.lua ignores a minimum within 8 s of the level load
        add({ run = function() toGuest("t.kill", "1") end })
        add({ check = "guest_died", timeout = 30, cond = function() poll(); return minSeen <= 1.5 end })
        add({ check = "guest_revived", timeout = 60, cond = function() poll(); return guestHp >= 90 end })
        if not os.getenv("PT_HURT_NEAR") then
            add({ wait = 3 })
            add({ run = farTp })
            add({ wait = 4 })
        end
        add({ wait = 5 })
        add({ run = function()
            poll(); hostHp0, guestHp0 = health(), guestHp
            local at = L.guestChar():K2_GetActorLocation()
            o = spawn(CLOUD, at.X, at.Y, at.Z - 80)
            T.log("PT|info cloud %s host hp0=%.0f guest hp0=%.0f", o and T.name(o) or "SPAWN FAILED", hostHp0, guestHp0)
        end })
        add({ check = "guest_hurt_after_revive", timeout = 45, cond = function() poll(); return guestHp >= 0 and guestHp < guestHp0 - 1 end })
        add({ wait = 10 })
        add({ run = function() if o and o:IsValid() then o:K2_DestroyActor() end end })
        add({ check = "host_not_drained_after_guest_death", timeout = 5, cond = function()
            T.log("PT|info host hp %.0f (start %.0f) guest hp %.0f", health(), hostHp0, guestHp)
            return health() >= hostHp0 - 5
        end })
        add({ run = function() toGuest("t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    local finished = false
    LoopInGameThreadWithDelay(100, function() pcall(function()
        if T.netMode() ~= "client" then return end
        local me = T.myPawn()
        local pc = T.localPC():GetAddress()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then break end
            if kind == "t.end" then finished = true end
            local rm = T.first("BP_ResourceManager_C")
            local h = rm and rm.PlayerHealth
            if kind == "t.heal" then pcall(function() h:Adjust(rm, h.Maximum - h.Current) end) end
            if kind == "t.kill" then pcall(function() h:Adjust(rm, 1 - h.Current) end) end -- to its minimum: health.lua's death
            if kind == "t.tp" and me and me:IsValid() then
                local x, y, z = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                me:K2_SetActorLocation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, false, {}, true)
            end
        end
        PTNative_MsgToHost(pc, "t.hp", string.format("%.0f", health()))
    end) end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { check = "client_stays_until_host_done", timeout = 600, cond = function() return finished end },
    }
end
