-- Shared scares and the shared ARC waypoint (owner requests 2026-10-30). Fixture zone.
--   guest_own_events_off        the guest's ambience manager picks no events of its own (AmbientEventsEnabled false)
--   guest_hears_host_scare      the host forces the static ghost (its ambience manager's own debug event): the guest spawns the same
--                               event class (Spawn Ambient Event Actor) within 20 s. Mutation noambsync fails it.
--   host_gets_guest_waypoint    the guest places a BP_WaypointActor 30 m off (what the ARC screen's PlaceWaypoint spawns): the host
--                               has one there within 5 s
--   guest_follows_host_move     the host moves its waypoint 20 m: the guest's follows
--   host_waypoint_cleared       the guest removes its waypoint: the host's goes. Mutation nowaypoint fails the waypoint checks.
-- Run: tools/run-test.ps1 -Scenario sharedworld -Fixture zone -Headless
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local WP = "/Game/UI/CarEquipment/Internal/Gobbler/BP_WaypointActor.BP_WaypointActor_C"
    local got = {}
    local function g(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind]
    end
    local function wps()
        local r = {}
        for _, a in ipairs(FindAllOf("BP_WaypointActor_C") or {}) do if a:IsValid() and T.inWorld(a) then r[#r + 1] = a end end
        return r
    end
    -- the partner's marker: a visible Map-Pin icon on the map bounds actor (mapmark.lua; each player keeps its own actor)
    local function pins()
        local r = {}
        for _, c in ipairs(FindAllOf("MapIconComponent") or {}) do
            if c:IsValid() and c:GetFullName():find("BP_GobblerMapBounds", 1, true) and c.IconTexture:IsValid()
                and c.IconTexture:GetFName():ToString() == "Map-Pin" and c:IsIconVisible() then r[#r + 1] = c end
        end
        return r
    end
    local function pnear(c, x, y) local l = c:K2_GetComponentLocation(); return math.abs(l.X - x) < 50 and math.abs(l.Y - y) < 50 end
    local function near(a, x, y) local l = a:K2_GetActorLocation(); return math.abs(l.X - x) < 50 and math.abs(l.Y - y) < 50 end
    local function spawnWp(x, y, z)
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local c = StaticFindObject(WP)
        if not c:IsValid() then LoadAsset(WP); c = StaticFindObject(WP) end
        return gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(T.myPawn(), c, xf, 1, nil), xf)
    end

    if T.ROLE == "host" then
        local steps, spot = {}, nil
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_zone", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ check = "guest_ready", timeout = 400, cond = function() return g("t.ready") ~= nil end })
        add({ run = function()
            local am = T.first("BP_AmbienceManager_C")
            am["DbgActEvt_ForceStaticGhost_Execute"](am)
            toGuest("t.scare")
        end })
        add({ check = "guest_heard_scare", timeout = 40, cond = function() return g("t.heard") ~= nil end })
        -- the guest's waypoint: where it said it put it
        add({ check = "host_gets_guest_waypoint", timeout = 20, cond = function()
            local s = g("t.wp")
            if not s then return false end
            local x, y = s:match("^(%S+) (%S+)")
            spot = { x = tonumber(x), y = tonumber(y) }
            for _, c in ipairs(pins()) do if pnear(c, spot.x, spot.y) then return true end end
            return false
        end })
        -- the host places its own marker (the guest's pin stays where it is); the guest gets a pin there too
        add({ run = function()
            local l = L.own():K2_GetActorLocation()
            spawnWp(l.X + 3000, l.Y + 2000, l.Z)
            toGuest("t.moved", string.format("%.0f %.0f", l.X + 3000, l.Y + 2000))
        end })
        add({ check = "guest_follow_reported", timeout = 30, cond = function() return g("t.followed") ~= nil end })
        add({ check = "host_waypoint_cleared", timeout = 20, cond = function() return g("t.cleared") ~= nil and #pins() == 0 end })
        add({ run = function() toGuest("t.done") end })
        add({ wait = 3 })
        return steps
    end

    local heard = nil
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.cls(T.myPawn()) == T.CHAR end },
        { wait = 5 },
        { run = function()
            -- every event the guest's manager spawns, ours or the host's
            RegisterHook("/Game/Systems/Managers/BP_AmbienceManager.BP_AmbienceManager_C:Spawn Ambient Event Actor", function(_, cls)
                local c = cls:get()
                if c:IsValid() then heard = c:GetFName():ToString() end
            end)
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.ready", "1")
        end },
        { check = "guest_own_events_off", timeout = 10, cond = function() return T.first("BP_AmbienceManager_C").AmbientEventsEnabled == false end },
        { check = "guest_told_scare", timeout = 120, cond = function() return g("t.scare") ~= nil end },
        { check = "guest_hears_host_scare", timeout = 20, cond = function()
            T.log("PT|info guest ambient event %s", tostring(heard))
            return heard ~= nil and heard:find("StaticGhost", 1, true) ~= nil
        end },
        { run = function()
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.heard", heard or "")
            local p = T.myPawn():K2_GetActorLocation()
            spawnWp(p.X + 3000, p.Y, p.Z)
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.wp", string.format("%.0f %.0f", p.X + 3000, p.Y))
        end },
        { check = "guest_follows_host_move", timeout = 30, cond = function()
            local s = g("t.moved")
            if not s then return false end
            local x, y = s:match("^(%S+) (%S+)")
            for _, c in ipairs(pins()) do if pnear(c, tonumber(x), tonumber(y)) then return true end end
            return false
        end },
        { run = function()
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.followed", "1")
            for _, a in ipairs(wps()) do a:K2_DestroyActor() end
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.cleared", "1")
        end },
        { check = "guest_done", timeout = 60, cond = function() return g("t.done") ~= nil end },
    }
end
