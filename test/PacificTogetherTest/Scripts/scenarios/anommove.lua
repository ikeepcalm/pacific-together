-- W6: the Abductor (BP_Hazard_PhysicsGrabber) and the Can Opener (BP_Hazard_SawBlade) move for the guest and hurt it. Fixture `zone`, the guest joins by itself.
--   grabber   spawned next to the guest; the host lifts its Core and Magnet by 900 uu (the grabber's own lift is driven by its state machine,
--             which needs a car to hunt; the lift here is the same component motion): the guest's copy must be where the host's is
--             (at rest, and lifted), not on the ground where its own gravity put it
--   saw       spawned on a spot the game accepts (landscape + clear ground, 7000 uu from the start); the host's blade must run its cycle
--             (the state machine is off in a listen session), the guest's copy must show the blade moving along the host's path
--   damage    the saw's own overlap handler with the guest's pawn: the guest loses health, the host does not
-- Run: tools/run-test.ps1 -Scenario anommove -Fixture zone -Headless ; mutation noanommove switches anommove.lua off in both processes.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local P = "/Game/Gameplay/Hazards/"
    local GRAB = P .. "PhysicsGrabber/BP_Hazard_PhysicsGrabber.BP_Hazard_PhysicsGrabber_C"
    local SAW = P .. "SawBladeAnomaly/BP_Hazard_SawBlade.BP_Hazard_SawBlade_C"
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local SAW_AT = { 65464, -31031 } -- a spot where the saw's spline builds (the game destroys a saw that cannot lay its track; near the start is a safety zone)
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
        return gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(T.world(), cls, xf(x, y, z), 0, nil), xf(x, y, z))
    end
    local function dead(o) return not o:IsValid() or o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    -- the copy of a hazard class whose root is nearest to x, y (both sides place the root at the same spot)
    local function nearest(class, x, y)
        local best, bd = nil, 80 ^ 2
        for _, o in ipairs(FindAllOf(class) or {}) do
            if T.inWorld(o) and not dead(o) and not o:GetFullName():find("Default__", 1, true) then
                local l = o:K2_GetActorLocation()
                local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
                if d < bd then best, bd = o, d end
            end
        end
        return best
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local gpc, gr, saw = nil, nil, nil
        local g = { coreZ = nil, magZ = nil, mount = nil, hp = -1, vis = nil }
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.hp" then g.hp = tonumber(data) or g.hp end
                if kind == "t.grab" then local a, b = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)$"); g.coreZ, g.magZ = tonumber(a), tonumber(b) end
                if kind == "t.saw" then
                    local x, y, z, v = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%d)$")
                    if x then g.mount = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }; g.vis = v == "1" end
                end
            end
        end
        local function nearGuest(dx, dy) local l = L.guestChar():K2_GetActorLocation(); return l.X + dx, l.Y + dy, l.Z + 300 end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function() gpc = L.remotePCs()[1] end })

        -- ---------------------------------------------------------------- Abductor
        local z0
        add({ run = function()
            local x, y, z = nearGuest(500, 0)
            gr = spawn(GRAB, x, y, z)
            local l = gr:K2_GetActorLocation()
            PTNative_MsgToGuest(gpc:GetAddress(), "t.watchgrab", string.format("%.0f\t%.0f", l.X, l.Y))
            T.log("PT|info spawned grabber %s at %.0f %.0f %.0f", T.name(gr), l.X, l.Y, l.Z)
        end })
        add({ wait = 6 })
        add({ check = "guest_abductor_at_host_height", timeout = 40, cond = function()
            poll()
            local hz = gr.CoreFloatingMesh:K2_GetComponentLocation().Z
            z0 = z0 or hz
            T.log("PT|info grabber core host z=%.0f guest z=%s", hz, tostring(g.coreZ))
            return g.coreZ ~= nil and math.abs(g.coreZ - hz) < 250
        end })
        add({ run = function() -- the lift: core and magnet 900 uu up over 8 s (every 100 ms, a teleport of the bodies, physics off)
            local n = 0
            local core, mag = gr.CoreFloatingMesh, gr.SM_PG_Magnet
            local c0, m0 = core:K2_GetComponentLocation(), mag:K2_GetComponentLocation()
            z0 = c0.Z
            core:SetSimulatePhysics(false); mag:SetSimulatePhysics(false) -- the grabber's own height stabiliser would pull the bodies back down
            LoopInGameThreadWithDelay(100, function()
                n = n + 1
                if n > 80 or dead(gr) then return true end
                pcall(function()
                    core:K2_SetWorldLocation({ X = c0.X, Y = c0.Y, Z = c0.Z + n * 11 }, false, {}, true)
                    mag:K2_SetWorldLocation({ X = m0.X, Y = m0.Y, Z = m0.Z + n * 11 }, false, {}, true)
                end)
                return false
            end)
        end })
        add({ wait = 9 })
        add({ check = "guest_abductor_lifts", timeout = 30, cond = function()
            poll()
            local hz = gr.CoreFloatingMesh:K2_GetComponentLocation().Z
            local hm = gr.SM_PG_Magnet:K2_GetComponentLocation().Z
            T.log("PT|info lifted: host core z=%.0f (start %.0f) magnet z=%.0f; guest core z=%s magnet z=%s", hz, z0, hm, tostring(g.coreZ), tostring(g.magZ))
            return hz > z0 + 600 and g.coreZ ~= nil and g.coreZ > z0 + 400 and math.abs(g.coreZ - hz) < 250
                and g.magZ ~= nil and math.abs(g.magZ - hm) < 300
        end })

        -- ---------------------------------------------------------------- Can Opener
        add({ run = function()
            saw = spawn(SAW, SAW_AT[1], SAW_AT[2], 8221)
            assert(not dead(saw), "the saw could not lay its track here (spawn destroyed it)")
            local l = saw:K2_GetActorLocation()
            PTNative_MsgToGuest(gpc:GetAddress(), "t.watchsaw", string.format("%.0f\t%.0f", l.X, l.Y))
            T.log("PT|info spawned saw %s at %.0f %.0f", T.name(saw), l.X, l.Y)
        end })
        local hostMoved, guestMoved, guestNear, maxHost = false, false, false, 0
        add({ check = "host_saw_runs_its_cycle", timeout = 60, cond = function()
            local m = saw.Mount.RelativeLocation
            maxHost = math.max(maxHost, math.sqrt(m.X ^ 2 + m.Y ^ 2 + m.Z ^ 2))
            T.log("PT|info saw host state=%s mount=(%.0f,%.0f,%.0f)", tostring(saw.SawbladeState), m.X, m.Y, m.Z)
            return maxHost > 500
        end })
        add({ check = "guest_saw_follows_host", timeout = 60, cond = function()
            poll()
            if not g.mount then return false end
            local h = saw.Mount.RelativeLocation
            local d = math.sqrt((h.X - g.mount.X) ^ 2 + (h.Y - g.mount.Y) ^ 2 + (h.Z - g.mount.Z) ^ 2)
            local gd = math.sqrt(g.mount.X ^ 2 + g.mount.Y ^ 2 + g.mount.Z ^ 2)
            if gd > 500 then guestMoved = true end
            if guestMoved and d < 700 then guestNear = true end
            T.log("PT|info saw mount host=(%.0f,%.0f,%.0f) guest=(%.0f,%.0f,%.0f) apart=%.0f visible on guest=%s", h.X, h.Y, h.Z, g.mount.X, g.mount.Y, g.mount.Z, d, tostring(g.vis))
            return guestNear
        end })

        -- ---------------------------------------------------------------- the saw hurts the guest
        local hp0, hostHp0
        add({ run = function()
            poll(); hp0, hostHp0 = g.hp, health()
            saw.OverlapLimiterActors:Empty()
            -- the saw's overlap event with the guest's pawn: the game's own handler dispatches the piercing damage message to it
            saw:BndEvt__StaticMesh_K2Node_ComponentBoundEvent_0_ComponentBeginOverlapSignature__DelegateSignature(saw.StaticMesh, L.guestChar(), L.guestChar().Mesh, 0, false, {})
            T.log("PT|info saw hit sent: guest hp=%.0f host hp=%.0f", hp0, hostHp0)
        end })
        add({ check = "guest_hurt_by_saw", timeout = 30, cond = function()
            poll()
            T.log("PT|info guest hp=%.0f (was %.0f) host hp=%.0f", g.hp, hp0, health())
            return g.hp >= 0 and g.hp < hp0 - 5
        end })
        add({ check = "host_not_hurt_by_saw_on_guest", timeout = 4, cond = L.holds(3, function() return health() >= hostHp0 - 0.5 end) })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    -- guest: report what its copies look like, once a second
    local finished, wgrab, wsaw = false, nil, nil
    LoopInGameThreadWithDelay(1000, function()
        pcall(function()
            if T.netMode() ~= "client" then return end
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.hp", string.format("%.0f", health()))
            if wgrab then
                local o = nearest("BP_Hazard_PhysicsGrabber_C", wgrab[1], wgrab[2])
                if o then
                    PTNative_MsgToHost(T.localPC():GetAddress(), "t.grab", string.format("%.0f\t%.0f", o.CoreFloatingMesh:K2_GetComponentLocation().Z, o.SM_PG_Magnet:K2_GetComponentLocation().Z))
                end
            end
            if wsaw then
                local o = nearest("BP_Hazard_SawBlade_C", wsaw[1], wsaw[2])
                if o then
                    local m = o.Mount.RelativeLocation
                    PTNative_MsgToHost(T.localPC():GetAddress(), "t.saw", string.format("%.0f\t%.0f\t%.0f\t%d", m.X, m.Y, m.Z, o.StaticMesh:IsVisible() and 1 or 0))
                end
            end
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then break end
                if kind == "t.end" then finished = true end
                if kind == "t.watchgrab" or kind == "t.watchsaw" then
                    local x, y = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                    if kind == "t.watchgrab" then wgrab = { tonumber(x), tonumber(y) } else wsaw = { tonumber(x), tonumber(y) } end
                end
            end
        end)
    end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { check = "client_stays_until_host_done", timeout = 900, cond = function() return finished end },
    }
end
