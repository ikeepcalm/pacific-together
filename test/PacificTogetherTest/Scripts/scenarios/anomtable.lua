-- anomtable: the W6 long tail (docs/spikes/W6-anomalies.md), one row per anomaly class not covered by its own scenario.
--   Every row spawns the class on the HOST next to a guest far from the host (the zone's Tesla leaves first, as in anomwake2).
--   <row>_copy  the guest has exactly one copy within 2000 uu, a replicated one (Role 1, not its own simulation, W2), at the
--               host's position (within 400 uu at the same moment). Mutation noworldsync (no hazard replication) fails these.
--   <row>_hurt  rows of kind "hurt" are spawned at the guest's feet: the guest's own health drops (host far away, its health
--               unchanged). Mutation noanom (no damage forwarding to the guest) fails these.
--   A row with a 5th field true is short-lived (the lightning strike): the guest remembers its first sighting, compared with the spawn spot.
--   A row with a 6th field (a reason) is not checked: a known gap written up in docs/spikes/anomtail.md.
-- Run: tools/run-test.ps1 -Scenario anomtable -Fixture zone -Headless [-Mutate noworldsync|noanom|noanomtail]
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local G, F = "/Game/Gameplay/Hazards/", "/PDFeature_Fig/Gameplay/Anomalies/"
    local function p(dir, c) return dir .. "/" .. c .. "." .. c .. "_C" end
    -- { check name, wiki name, object path, kind }
    local ROWS = {
        { "bollard", "Bollard", p(G .. "Bollards", "BP_Hazard_Bollard"), "copy" },
        { "touristtrap", "Tourist Trap", p(G .. "Bollards", "BP_Hazard_Bollard_Explosive"), "copy" },
        { "tourbus", "Tour Bus", p(G .. "BigBoyLandmine", "BP_Hazard_BigBoyLandmine"), "copy" },
        { "shockedtourist", "Shocked Tourist", p(G .. "Landmine/Electric", "BP_Hazard_Landmine_Electric"), "copy" },
        { "boltbunny", "Bolt Bunny", p(G .. "Leech/Acid", "BP_Hazard_Leech_Electric"), "hurt" },
        { "burpbunny", "Burp Bunny", p(G .. "Leech/Acid", "BP_Hazard_Leech_Acid"), "hurt" },
        { "boombunny", "Boom Bunny", p(G .. "Leech/Explosive", "BP_Hazard_Leech_Explosive"), "hurt" },
        { "brokenbunny", "Broken Bunny", p(G .. "Leech", "BP_Hazard_Leech_Malfunction"), "hurt" },
        { "dustbunny", "Dust Bunny", p(G .. "Leech", "BP_Hazard_Leech_Rad"), "hurt" },
        { "hoppeduphare", "Hopped-up Hare", p(G .. "Leech", "BP_Hazard_Leech_Charging"), "copy" },
        { "happyhare", "Happy Hare", p(G .. "Leech", "BP_Hazard_Leech_Healer"), "copy" },
        { "coughbox", "Cough Box", p(G .. "Cloud", "BP_Hazard_Cloud_Acid"), "hurt" },
        { "sizzlingmist", "Sizzling Mist", p(G .. "Cloud", "BP_Hazard_Cloud_Electric"), "hurt" },
        { "devilgrinder", "Devil Grinder", p(G .. "Cloud", "BP_Hazard_Cloud_Impact"), "hurt" },
        { "sickmickey", "Sick Mickey", p(G .. "Geyser_Large", "BP_Hazard_LargeGeyser"), "copy" },
        { "belchingbarnacle", "Belching Barnacle", p(G .. "Geyser_Small", "BP_Hazard_SmallGeyser"), "copy" },
        { "cracklingcrawler", "Crackling Crawler", p(G .. "GopherMine/Electric", "BP_Hazard_GopherMine_Electric"), "copy" },
        { "radiantdredge", "Radiant Dredge", p(G .. "GopherMine", "BP_Hazard_GopherMine_Impact"), "copy" },
        { "titansbone", "Titan's Bone", p(G .. "HazardProperties/ImpactSpears", "BP_Hazard_ImpactSpear"), "copy" },
        { "fallenfirmament", "Fallen Firmament", p(G .. "FallingPillar", "BP_Hazard_FallingPillar"), "copy" },
        { "blacksmith", "Blacksmith", p(G .. "RockPounder", "BP_Hazard_RockPounder"), "copy" },
        { "wrigglingwreck", "Wriggling Wreck", p(G .. "MovementHazard", "BP_Hazard_MovementHazard"), "copy" },
        { "minuteman", "Minuteman", p(G .. "MovementHazard", "BP_Hazard_Movement_Prong"), "copy", false, "its replicated copy destroys itself ~3 s after it appears on the guest (own retract cycle), docs/spikes/anomtail.md" },
        { "bubblegumbuddy", "Bubblegum Buddy", p(G .. "Spore", "BP_Hazard_Spore"), "copy" },
        { "moldyballoon", "Moldy Balloon", p(G .. "Bouncing/Acid", "BP_Hazard_Bouncing_Acid"), "copy" },
        { "glitteringboulder", "Glittering Boulder", p(G .. "MalfunctionMine", "BP_Hazard_MalfunctionMine_SuperCharger"), "copy" },
        { "shaggyscrambler", "Shaggy Scrambler", p(G .. "MalfunctionMine", "BP_Hazard_MalfunctionImpact_RandomToggle"), "copy" },
        { "leftright", "Left-Right", p(G .. "MalfunctionVolume", "BP_Hazard_MalfunctionVolume_ReverseSteering"), "copy" },
        { "airstrip", "Airstrip", p(G .. "LowGravityZone", "BP_Hazard_LowGravityZone"), "copy" },
        { "lightning", "Lightning Squall strike", p(G .. "HazardProperties/LightningStrike", "BP_Hazard_LightningStrike"), "copy", true },
        -- Whispers in the Woods (PDFeature_Fig plugin)
        { "ferryman", "Ferryman", p(F .. "DistantCultist", "BP_Hazard_DistantCultist"), "copy" },
        { "gloomypocket", "Gloomy Pocket", p(F .. "Evolved/ShroudCloud", "BP_Hazard_Evolved_Cloud_Shroud"), "copy" },
        { "glowgrabber", "Glowgrabber", p(F .. "Parasites/BatteryParasite", "BP_Hazard_Parasite_Battery_World"), "copy" },
        { "harvestman", "Harvestman", p(F .. "Parasites/FuelParasite", "BP_Hazard_Parasite_World_Fuel"), "copy" },
        { "highwayman", "Highwayman", p(F .. "Evolved/PhysicsGrabber", "BP_Hazard_Evolved_PhysicsGrabber"), "copy" },
        { "interloper", "Interloper", p(F .. "ProximityMine/EvolvedCultist", "BP_Hazard_ProximityMine_EvolvedCultist"), "copy", false, "the host actor leaves its spawn spot (~36000 uu) and destroys itself within seconds when spawned by hand, docs/spikes/anomtail.md" },
        { "maw", "Maw", p(F .. "Giants/DoomSphere", "BP_Hazard_Giant_DoomSphere"), "copy" },
        { "pilgrim", "Pilgrim", p(F .. "Evolved/Landmine/Holder", "BP_Hazard_Evolved_Landmine_Holder"), "copy" },
        { "sightseer", "Sightseer", p(F .. "Evolved/Landmine/Floater", "BP_Hazard_Evolved_Landmine_Floater"), "copy" },
    }
    local only = os.getenv("PT_ANOMROWS") -- optional comma list of row names (debugging a few rows)
    local mapName = "Rural_Forest_Radio_Scylla_02"
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
    local function short(path) return path:match("%.([^%.]+)$") end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local gpc, guestHp, hostHp0 = nil, -1, -1
        local copy = { n = -1 } -- the guest's last answer to t.q
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.hp" then guestHp = tonumber(data) or guestHp end
                if kind == "t.c" then
                    local q, n, x, y, z, role = data:match("^(%S+)\t(%d+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%S+)$")
                    if q then copy = { q = q, n = tonumber(n), x = tonumber(x), y = tonumber(y), z = tonumber(z), role = role } end
                end
            end
        end
        local function toGuest(kind, data) PTNative_MsgToGuest(gpc:GetAddress(), kind, data) end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function()
            gpc = L.remotePCs()[1]
            local tesla
            for _, o in ipairs(FindAllOf("BP_Hazard_Tesla_C") or {}) do
                if T.inWorld(o) and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then tesla = tesla or o end
            end
            assert(tesla, "no map Tesla")
            local l = tesla:K2_GetActorLocation()
            local gl = { X = l.X + 400, Y = l.Y, Z = l.Z + 150 }
            toGuest("t.tp", string.format("%.0f\t%.0f\t%.0f", gl.X, gl.Y, gl.Z))
            pcall(function() L.guestChar():K2_TeleportTo(gl, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
            tesla:K2_DestroyActor()
            hostHp0 = health()
        end })
        add({ check = "host_far_from_guest", timeout = 30, cond = function() return T.dist(L.guestChar(), T.myPawn()) > 6000 end })
        add({ wait = 6 })
        for _, r in ipairs(ROWS) do
            local name, wiki, path, kind, sticky, open = r[1], r[2], r[3], r[4], r[5], r[6]
            if open then add({ run = function() T.log("PT|info row %s (%s) not checked: %s", name, wiki, open) end })
            elseif not only or (("," .. only .. ","):find("," .. name .. ",", 1, true)) then
                local o, hp0, sp
                add({ run = function()
                    toGuest("t.heal", "1")
                    local at = L.guestChar():K2_GetActorLocation()
                    if kind == "hurt" then o = spawn(path, at.X, at.Y, at.Z - 80) else o = spawn(path, at.X + 900, at.Y, at.Z - 80) end
                    T.log("PT|info row %s (%s) %s kind=%s", name, wiki, o and T.name(o) or "SPAWN FAILED", kind)
                    copy = { n = -1 }
                end })
                -- sticky rows (a short-lived actor, the lightning strike): the guest remembers the first copy it sees; compared with the spawn spot
                if sticky then
                    steps[#steps].run = (function(inner) return function()
                        local at = L.guestChar():K2_GetActorLocation()
                        sp = { X = at.X + 900, Y = at.Y, Z = at.Z - 80 }
                        toGuest("t.s", string.format("%s	%.0f	%.0f	%.0f", short(path), sp.X, sp.Y, sp.Z))
                        inner()
                    end end)(steps[#steps].run)
                end
                add({ wait = sticky and 0.5 or 3 })
                add({ run = function()
                    poll(); hp0 = guestHp
                    if o and o:IsValid() then -- replication state of the host's actor (docs/spikes/anomtail.md)
                        local function g(k) local ok, v = pcall(function() return o[k] end); return ok and tostring(v) or "?" end
                        T.log("PT|info %s host actor at %.0f %.0f %.0f repl=%s remote=%s always=%s dormancy=%s netload=%s onlyowner=%s tickon=%s", name, o:K2_GetActorLocation().X, o:K2_GetActorLocation().Y, o:K2_GetActorLocation().Z, g("bReplicates"), g("RemoteRole"), g("bAlwaysRelevant"), g("NetDormancy"), g("bNetLoadOnClient"), g("bOnlyRelevantToOwner"), tostring(o:IsActorTickEnabled()))
                    end
                end })
                add({ check = name .. "_copy", timeout = 30, cond = function()
                    if not sticky and not (o and o:IsValid()) then T.log("PT|info %s host actor gone or not spawned", name); return false end
                    local h = sticky and sp or o:K2_GetActorLocation()
                    toGuest("t.q", string.format("%s\t%.0f\t%.0f\t%.0f", short(path), h.X, h.Y, h.Z))
                    poll()
                    if copy.q ~= short(path) then return false end
                    local d = math.sqrt((copy.x - h.X) ^ 2 + (copy.y - h.Y) ^ 2 + (copy.z - h.Z) ^ 2)
                    T.log("PT|info %s guest copies=%d role=%s offset=%.0f", name, copy.n, copy.role, copy.n > 0 and d or -1)
                    return copy.n == 1 and copy.role == "1" and d < 400
                end })
                if kind == "hurt" then
                    add({ check = name .. "_hurt", timeout = 45, cond = function()
                        poll()
                        T.log("PT|info %s guest hp=%.0f (was %.0f) host hp=%.0f", name, guestHp, hp0, health())
                        return guestHp >= 0 and guestHp < hp0 - 1
                    end })
                end
                add({ run = function() if o and o:IsValid() then o:K2_DestroyActor() end end })
                add({ wait = 3 })
            end
        end
        add({ check = "host_not_hurt_for_guest", timeout = 8, cond = function() T.log("PT|info host hp %.0f (start %.0f)", health(), hostHp0); return health() >= hostHp0 - 20 end })
        add({ run = function() toGuest("t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    local finished, query = false, nil
    LoopInGameThreadWithDelay(100, function() pcall(function()
        if T.netMode() ~= "client" then return end
        local me = T.myPawn()
        local pc = T.localPC():GetAddress()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then break end
            if kind == "t.end" then finished = true end
            if kind == "t.s" then
                local c, x, y, z = data:match("^(%S+)	(%-?[%d%.]+)	(%-?[%d%.]+)	(%-?[%d%.]+)$")
                query = { c = c, x = tonumber(x), y = tonumber(y), z = tonumber(z), sticky = true }
            end
            if kind == "t.q" then
                local c, x, y, z = data:match("^(%S+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                if not (query and query.c == c) then query = { c = c } end
                query.x, query.y, query.z = tonumber(x), tonumber(y), tonumber(z)
            end
            if kind == "t.heal" then pcall(function() local rm = T.first("BP_ResourceManager_C"); rm.PlayerHealth:Fill(me) end) end
            if kind == "t.tp" and me and me:IsValid() then
                local x, y, z = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                me:K2_SetActorLocation({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, false, {}, true)
            end
        end
        PTNative_MsgToHost(pc, "t.hp", string.format("%.0f", health()))
        if query then
            local all = 0 -- every live copy of the class anywhere, logged when it changes (a copy that vanishes shows up here)
            for _, o in ipairs(FindAllOf(query.c) or {}) do
                if o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then
                    all = all + 1
                    if not query.logged then
                        local l = o:K2_GetActorLocation()
                        local okw, w = pcall(function() return o:GetWorld():GetFullName() end)
                        T.log("PT|info guest %s copy at %.0f %.0f %.0f inWorld=%s world=%s mine=%s", query.c, l.X, l.Y, l.Z, tostring(T.inWorld(o)), tostring(w), T.world():GetFullName())
                        query.logged = true
                    end
                end
            end
            if all ~= query.all then T.log("PT|info guest %s live copies %d (was %s)", query.c, all, tostring(query.all)); query.all = all end
            local n, best, bd, role = 0, nil, 1e18, "none"
            for _, o in ipairs(FindAllOf(query.c) or {}) do
                if T.inWorld(o) and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then
                    local l = o:K2_GetActorLocation()
                    local d = (l.X - query.x) ^ 2 + (l.Y - query.y) ^ 2 + (l.Z - query.z) ^ 2
                    if d < 2000 * 2000 then
                        n = n + 1
                        if d < bd then bd, best, role = d, l, tostring(o.Role) end
                    end
                end
            end
            best = best or { X = 0, Y = 0, Z = 0 }
            if query.sticky then -- the first sighting stays the answer
                if n > 0 and not query.keep then query.keep = { n = n, best = best, role = role } end
                if query.keep then n, best, role = query.keep.n, query.keep.best, query.keep.role end
            end
            PTNative_MsgToHost(pc, "t.c", string.format("%s\t%d\t%.0f\t%.0f\t%.0f\t%s", query.c, n, best.X, best.Y, best.Z, role))
        end
    end) end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { check = "client_stays_until_host_done", timeout = 2400, cond = function() return finished end },
    }
end
