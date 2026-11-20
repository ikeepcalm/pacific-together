-- anomwake2: more hazards act on a GUEST far from the awake host (docs/spikes/anomwake2.md).
--   Spike strip and spike bush spawned at the guest's feet (host 44000 uu away): the guest loses health, the host does not.
--   Bounce pad under the guest: the guest is launched upward (impulse applied on the guest, not only on the host's copy of its pawn).
-- Run: tools/run-test.ps1 -Scenario anomwake2 -Fixture zone -Headless ; mutation noanomwake2 = host-range/host-pawn-only (old behaviour).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local CLS = {
        strip = "/Game/Gameplay/Hazards/SpikeStrips/BP_Hazard_SpikeStrip.BP_Hazard_SpikeStrip_C",
        bush = "/Game/Gameplay/Hazards/SpikeBush/BP_Hazard_SpikeBush.BP_Hazard_SpikeBush_C",
        bounce = "/Game/Gameplay/Hazards/BouncePad/BP_Hazard_BouncePad.BP_Hazard_BouncePad_C",
        nudge = "/Game/Gameplay/Hazards/NudgePad/BP_Hazard_NudgePad.BP_Hazard_NudgePad_C",
        mine = "/Game/Gameplay/Hazards/Landmine/BP_Hazard_Landmine.BP_Hazard_Landmine_C",
    }
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local function health()
        local rm = T.first("BP_ResourceManager_C")
        local h = rm and rm.PlayerHealth
        return (h and h:IsValid()) and h.Current or -1
    end
    local function xf(x, y, z) return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } } end
    local function spawn(path, x, y, z)
        local cls = StaticFindObject(path)
        if not cls:IsValid() then LoadAsset(path); cls = StaticFindObject(path) end
        local gs = UEHelpers.GetGameplayStatics()
        return gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(T.world(), cls, xf(x, y, z), 2, nil), xf(x, y, z))
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local gpc, guestHp, guestZ, guestMaxZ, guestMaxVx = nil, -1, 0, -1e9, 0
        local hostHp0 = -1
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.vx" then guestMaxVx = tonumber(data) or guestMaxVx end
                if kind == "t.hp" then guestHp = tonumber(data) or guestHp end
                if kind == "t.z" then local z, m = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)$"); guestZ, guestMaxZ = tonumber(z) or guestZ, tonumber(m) or guestMaxZ end
            end
        end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        -- the zone's own Tesla would shoot the guest: it leaves first
        local gl
        add({ run = function()
            gpc = L.remotePCs()[1]
            local tesla
            for _, o in ipairs(FindAllOf("BP_Hazard_Tesla_C") or {}) do
                if T.inWorld(o) and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then tesla = tesla or o end
            end
            assert(tesla, "no map Tesla")
            local l = tesla:K2_GetActorLocation()
            gl = { X = l.X + 400, Y = l.Y, Z = l.Z + 150 }
            hostHp0 = health()
            PTNative_MsgToGuest(gpc:GetAddress(), "t.tp", string.format("%.0f\t%.0f\t%.0f", gl.X, gl.Y, gl.Z))
            pcall(function() L.guestChar():K2_TeleportTo(gl, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
            tesla:K2_SetActorLocation({ X = l.X + 30000, Y = l.Y, Z = l.Z + 3000 }, false, {}, true)
            tesla:K2_DestroyActor()
        end })
        add({ check = "host_far_from_guest", timeout = 30, cond = function()
            local d = T.dist(L.guestChar(), T.myPawn())
            T.log("PT|info host-guest distance %.0f", d)
            return d > 6000
        end })
        add({ wait = 6 })
        local function hurtBy(name, cls, dz)
            local o, hp0
            add({ run = function()
                poll(); hp0 = guestHp
                local at = L.guestChar():K2_GetActorLocation()
                o = spawn(CLS[cls], at.X, at.Y, at.Z + dz)
                T.log("PT|info %s %s spawned at the guest, guest hp %.0f tick=%s", name, T.name(o), hp0, tostring(o:IsActorTickEnabled()))
            end })
            add({ check = "guest_hurt_by_" .. name, timeout = 60, cond = function()
                poll()
                T.log("PT|info %s guest hp=%.0f (was %.0f) host hp=%.0f", name, guestHp, hp0, health())
                return guestHp >= 0 and guestHp < hp0 - 1 and guestHp > 0
            end })
            add({ run = function() o:K2_DestroyActor() end }) -- at once: a strip keeps cutting 10 hp a second
            add({ check = "host_not_hurt_by_" .. name, timeout = 8, cond = L.holds(4, function() return health() >= hostHp0 - 0.5 end) })
            add({ wait = 4 })
        end
        hurtBy("spikestrip", "strip", -80)
        hurtBy("spikebush", "bush", -80)
        -- a launching pad under the guest (bounce pad, nudge pad): the guest lifts, the far-away host does not
        local function padTest(name, cls, rise)
            local pad, z0, hz0
            add({ run = function() pcall(LoadAsset, CLS[cls]) end }) -- a map loads the class with its pads; the mod hooks it within 2 s of that
            add({ wait = 6 })
            add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.zreset", "1") end })
            add({ wait = 4 })
            add({ run = function()
                poll(); z0 = guestMaxZ -- the guest's resting height since the reset
                hz0 = T.myPawn():K2_GetActorLocation().Z
                local at = L.guestChar():K2_GetActorLocation()
                pad = spawn(CLS[cls], at.X, at.Y, at.Z - 90)
                T.log("PT|info %s %s spawned under the guest, z=%.0f", name, T.name(pad), z0)
            end })
            add({ check = "guest_launched_by_" .. name, timeout = 60, cond = function()
                poll()
                T.log("PT|info %s guest z=%.0f max=%.0f (start %.0f)", name, guestZ, guestMaxZ, z0)
                return guestMaxZ > z0 + rise -- the pad's 1000 impulse lifts the guest ~100 uu (gravity scale); a standing guest stays within 5
            end })
            add({ check = "host_not_launched_by_" .. name, timeout = 8, cond = L.holds(3, function() return math.abs(T.myPawn():K2_GetActorLocation().Z - hz0) < 60 end) })
            add({ run = function() pad:K2_DestroyActor() end })
        end
        padTest("bouncepad", "bounce", 60)
        padTest("nudgepad", "nudge", 200) -- the pad mesh itself rises and lifts a guest ~100 uu without the hook (mutation run), the hook adds repeated launches (~340)
        -- nudge pad smart launch (docs/spikes/nudgepad-smart.md): a guest moving +X onto a pad with an anomaly (a landmine) 1500 uu ahead is arced toward it
        -- (horizontal speed 700+); the plain up impulse leaves it at 0. Headless input does not walk a character, so the host's copy of the guest's velocity
        -- (what the pad hook reads) is set to 600 uu/s +X for a few seconds instead. Mutation nosmartlaunch.
        local pad2, mine
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.vreset", "1") end })
        add({ wait = 4 })
        add({ run = function()
            local at = L.guestChar():K2_GetActorLocation()
            mine = spawn(CLS.mine, at.X + 1500, at.Y, at.Z)
            pad2 = spawn(CLS.nudge, at.X, at.Y, at.Z - 90)
            T.log("PT|info smart test: pad %s landmine %s, guest at %.0f,%.0f,%.0f", T.name(pad2), T.name(mine), at.X, at.Y, at.Z)
            local n, gc = 0, L.guestChar()
            LoopInGameThreadWithDelay(50, function()
                n = n + 1
                pcall(function() local v = gc.CharacterMovement.Velocity; gc.CharacterMovement.Velocity = { X = 600, Y = 0, Z = v.Z } end)
                return n > 100
            end)
        end })
        add({ check = "guest_nudged_toward_anomaly", timeout = 40, cond = function()
            poll()
            T.log("PT|info smart test guest max horizontal speed %.0f", guestMaxVx)
            return guestMaxVx > 600
        end })
        add({ run = function() pad2:K2_DestroyActor(); mine:K2_DestroyActor() end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    local finished, maxZ, maxVx = false, -1e9, 0
    LoopInGameThreadWithDelay(100, function() pcall(function()
        if T.netMode() ~= "client" then return end
        local me = T.myPawn()
        if me and me:IsValid() then
            maxZ = math.max(maxZ, me:K2_GetActorLocation().Z)
            local v = me.CharacterMovement.Velocity
            maxVx = math.max(maxVx, math.sqrt(v.X * v.X + v.Y * v.Y))
        end
    end) end)
    LoopInGameThreadWithDelay(1000, function() pcall(function()
        if T.netMode() ~= "client" then return end
        local me = T.myPawn()
        PTNative_MsgToHost(T.localPC():GetAddress(), "t.hp", string.format("%.0f", health()))
        PTNative_MsgToHost(T.localPC():GetAddress(), "t.vx", string.format("%.0f", maxVx))
        if me and me:IsValid() then PTNative_MsgToHost(T.localPC():GetAddress(), "t.z", string.format("%.0f\t%.0f", me:K2_GetActorLocation().Z, maxZ)) end
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then break end
            if kind == "t.end" then finished = true end
            if kind == "t.vreset" then maxVx = 0 end
            if kind == "t.zreset" then maxZ = -1e9 end
            if kind == "t.tp" and me and me:IsValid() then
                local x, y, z = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                me:K2_SetActorLocation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, false, {}, true)
            end
        end
    end) end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { check = "client_stays_until_host_done", timeout = 900, cond = function() return finished end },
    }
end
