-- W6: the newly un-frozen hazards move on the guest's copy (docs/spikes/anomvis.md). Fixture `zone`, the guest joins by itself.
--   The host spawns one hazard of each class (Blacksmith, Titan's Bone, Bubblegum Buddy, Ticking Tumbler, Bollard, Pufferfish) around its pawn.
--   For 40 s the host samples every SceneComponent's world transform (and each root's world position) of each; a "mover" is a part that
--   deviated > 20 from its first sample. The guest reports the same parts of its copies twice a second; guest_<class>_follows needs a mover
--   whose guest values match a host sample of the last 5 s (within 50 uu / deg, >= 60 %) and move too (>= 20 uu).
--   guest_hurt_by_spear   a fresh Titan's Bone under the guest, the host elsewhere; the spear's own Damage reaches the guest, not the host
-- Run: tools/run-test.ps1 -Scenario anomvis -Fixture zone -Headless ; mutation noanomvis switches anomvis.lua off.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local G = "/Game/Gameplay/"
    local function p(dir, c) return G .. dir .. "/" .. c .. "." .. c .. "_C" end
    local ROWS = { -- { check name, class path, class name (live objects), ring index }
        { "blacksmith", p("Hazards/RockPounder", "BP_Hazard_RockPounder"), "BP_Hazard_RockPounder_C", 1 },
        { "titansbone", p("Hazards/HazardProperties/ImpactSpears", "BP_Hazard_ImpactSpear"), "BP_Hazard_ImpactSpear_C", 2 },
        { "bubblegum", p("Hazards/Spore", "BP_Hazard_Spore"), "BP_Hazard_Spore_C", 3 },
        { "tumbler", p("Hazards/BombRock", "BP_Hazard_BombRock"), "BP_Hazard_BombRock_C", 4 },
        { "bollard", p("Hazards/Bollards", "BP_Hazard_Bollard"), "BP_Hazard_Bollard_C", 5 },
        { "pufferfish", p("Boons/ChubbyBunny", "BP_Boon_LootCreature"), "BP_Boon_LootCreature_C", 6 },
    }
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local SCENE = StaticFindObject("/Script/Engine.SceneComponent")
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
    -- the actor's parts: name -> { loc xyz, rot pyr } in world space; "<root>" = world position
    local function sample(o)
        local r, root = {}, o:K2_GetRootComponent()
        local l = o:K2_GetActorLocation()
        local ar = o:K2_GetActorRotation()
        r["<root>"] = { l.X, l.Y, l.Z, ar.Pitch, ar.Yaw, ar.Roll }
        for _, w in ipairs(o:K2_GetComponentsByClass(SCENE)) do
            local c = w:get()
            if c:IsValid() and c:GetAddress() ~= root:GetAddress() then
                local a, b = c:K2_GetComponentLocation(), c:K2_GetComponentRotation()
                r[c:GetFName():ToString()] = { a.X, a.Y, a.Z, b.Pitch, b.Yaw, b.Roll }
            end
        end
        return r
    end
    local function adiff(a, b, i) -- angle difference for the rotation slots
        local d = math.abs(a - b)
        if i > 3 then d = d % 360; if d > 180 then d = 360 - d end end
        return d
    end
    local function dist(a, b)
        local m = 0
        for i = 1, 6 do m = math.max(m, adiff(a[i], b[i], i)) end
        return m
    end
    local function nearest(class, x, y) -- the copy of a class whose root is nearest to x, y
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
        local gpc
        local actors, roots = {}, {}
        local hist, first, range = {}, {}, {} -- row -> part -> samples (last 50) / first sample / host's largest deviation
        local gseen = {} -- row -> part -> { n, ok, first, far } from the guest's reports
        local gHp, gSpears
        local SMC = StaticFindObject("/Script/SMSystem.SMStateMachineComponent")
        local function smState(o)
            local c = o:GetComponentByClass(SMC)
            local i = c:IsValid() and c.R_Instance
            return (i and i:IsValid()) and i:GetActiveStateName():ToString() or ""
        end
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.part" then
                    local row, name, v = data:match("^([^\t]+)\t([^\t]+)\t(.*)$")
                    local h = row and hist[row] and hist[row][name]
                    if h and #h > 0 then
                        local g = {}
                        for x in v:gmatch("[^,]+") do g[#g + 1] = tonumber(x) end
                        local s = gseen[row][name]
                        if not s then s = { n = 0, ok = 0, far = 0, first = g }; gseen[row][name] = s end
                        local best = 1e9
                        for _, hs in ipairs(h) do best = math.min(best, dist(hs, g)) end
                        s.n = s.n + 1
                        if best < 50 then s.ok = s.ok + 1 end
                        s.far = math.max(s.far, dist(s.first, g)); s.last, s.hlast, s.best = g, h[#h], best
                    end
                elseif kind == "t.hp" then gHp = tonumber(data)
                elseif kind == "t.sp" then gSpears = tonumber(data)
                end
            end
        end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function()
            gpc = L.remotePCs()[1]
            local pl = UEHelpers.GetPlayerController().Pawn:K2_GetActorLocation()
            local w = {}
            for _, r in ipairs(ROWS) do
                local a = r[4] * 2 * math.pi / #ROWS
                local o = spawn(r[2], pl.X + math.cos(a) * 1500, pl.Y + math.sin(a) * 1500, pl.Z)
                if r[1] == "bollard" then o:K2_SetActorRotation({ Pitch = 0, Yaw = 130, Roll = 0 }, false) end -- a spawned one picks a random yaw; make it a large one
                actors[r[1]], hist[r[1]], first[r[1]], range[r[1]], gseen[r[1]] = o, {}, {}, {}, {}
                local l = o:K2_GetActorLocation()
                roots[r[1]] = { l.X, l.Y }
                w[#w + 1] = string.format("%s:%.0f:%.0f:%s", r[1], l.X, l.Y, r[3])
                T.log("PT|info anomvis spawned %s at %.0f %.0f %.0f valid=%s", r[1], l.X, l.Y, l.Z, tostring(not dead(o)))
            end
            PTNative_MsgToGuest(gpc:GetAddress(), "t.watch", table.concat(w, ";"))
            local tick, probeDrop = 0, 0
            LoopInGameThreadWithDelay(100, function() -- the host's samples (the guest's reports are read here too, not only in the checks: the queue is bounded)
                tick = tick + 1
                poll()
                if tick % 50 == 1 and actors.blacksmith and not dead(actors.blacksmith) then
                    pcall(function()
                        local b = actors.blacksmith
                        if smState(b) == "Pre-Drop" then
                            probeDrop = probeDrop + 1
                            if probeDrop == 3 then b:OnDrop(); T.log("PT|info anomvis blacksmith OnDrop called") end
                        end
                        T.log("PT|info anomvis blacksmith probe state=%s cylinder z=%.0f pounderState=%s inRange=%s", smState(b), b.Cylinder.RelativeLocation.Z, tostring(b.RockPounderState), tostring(b.PlayerInRange))
                    end)
                end
                for name, o in pairs(actors) do
                    if not dead(o) then
                        local ok, err = pcall(function()
                            for part, v in pairs(sample(o)) do
                                local h = hist[name][part] or {}
                                hist[name][part] = h
                                h[#h + 1] = v
                                if #h > 50 then table.remove(h, 1) end
                                first[name][part] = first[name][part] or v
                                range[name][part] = math.max(range[name][part] or 0, dist(first[name][part], v))
                            end
                        end)
                        if not ok and not first[name].err then first[name].err = true; T.log("PT|info anomvis sample error %s: %s", name, tostring(err)) end
                    end
                end
                return false
            end)
        end })
        add({ wait = 40 })
        for _, r in ipairs(ROWS) do
            if r[1] == "blacksmith" then -- its machine stands in Pre-Drop on the listen host (spikes/anomvis.md): nothing moves, logged only
                add({ run = function() poll(); T.log("PT|info anomvis blacksmith: host Cylinder rel z=%.0f, state=%s", actors.blacksmith.Cylinder.RelativeLocation.Z, smState(actors.blacksmith)) end })
            else
            add({ check = "guest_" .. r[1] .. "_follows", timeout = 30, cond = function()
                poll()
                local movers, good, top, topn = {}, false, 0, ""
                for part, rg in pairs(range[r[1]]) do
                    if rg > top then top, topn = rg, part end
                    if rg > 20 then
                        local s = gseen[r[1]][part]
                        local line = string.format("%s host range %.0f guest %s", part, rg, s and string.format("n=%d ok=%d far=%.0f best=%.0f last g=%.0f,%.0f,%.0f/%.0f,%.0f,%.0f h=%.0f,%.0f,%.0f/%.0f,%.0f,%.0f", s.n, s.ok, s.far, s.best, s.last[1], s.last[2], s.last[3], s.last[4], s.last[5], s.last[6], s.hlast[1], s.hlast[2], s.hlast[3], s.hlast[4], s.hlast[5], s.hlast[6]) or "none")
                        movers[#movers + 1] = line
                        if s and s.n >= 5 and s.far >= 20 and (s.ok / s.n >= 0.6 or (s.n <= 15 and s.ok >= 3)) then good = true end -- a spear lives ~5 s: 3 matching reports
                    end
                end
                T.log("PT|info anomvis %s alive=%s movers: %s", r[1], tostring(not dead(actors[r[1]])), #movers > 0 and table.concat(movers, " | ") or string.format("none (largest %s %.0f)", topn, top))
                return good
            end })
            end
        end

        add({ check = "guest_bollard_yaw_matches", timeout = 15, cond = function() -- the spawned Bollard's yaw (130) reaches the guest's copy (anomvis.lua root rotation)
            poll()
            local s = gseen.bollard and gseen.bollard["<root>"]
            local a = actors.bollard
            if not (s and s.last and a and not dead(a)) then return false end
            local d = math.abs(a:K2_GetActorRotation().Yaw - s.last[5]) % 360
            if d > 180 then d = 360 - d end
            T.log("PT|info anomfin bollard yaw host %.0f guest %.0f", a:K2_GetActorRotation().Yaw, s.last[5])
            return d < 3
        end })

        -- ---------------------------------------------------------------- a spear hurts the guest while the host is far away
        local hp0, hostHp0
        local spear
        add({ run = function()
            poll()
            local gl = L.guestChar():K2_GetActorLocation()
            spear = spawn(ROWS[2][2], gl.X, gl.Y, gl.Z - 80) -- the first one has retracted and gone by now
            T.log("PT|info anomvis fresh spear at the guest %.0f %.0f %.0f", gl.X, gl.Y, gl.Z)
        end })
        add({ wait = 1 })
        add({ run = function()
            poll()
            hp0, hostHp0 = gHp, health()
            T.log("PT|info anomvis spear alive=%s: guest %.0f uu from the host, guest hp=%s host hp=%.0f", tostring(not dead(spear)), T.dist(L.guestChar(), T.myPawn()), tostring(hp0), hostHp0)
            spear:Damage()
        end })
        add({ check = "guest_hurt_by_spear", timeout = 30, cond = function()
            poll()
            T.log("PT|info anomvis guest hp=%s (was %s) host hp=%.0f", tostring(gHp), tostring(hp0), health())
            return gHp ~= nil and hp0 ~= nil and gHp >= 0 and gHp < hp0 - 5
        end })
        add({ check = "host_not_hurt_by_spear_on_guest", timeout = 4, cond = L.holds(3, function() return health() >= hostHp0 - 0.5 end) })

        -- ---------------------------------------------------------------- the Blacksmith completes its slam cycle (W6, docs/spikes/anomfin.md)
        -- Inside a safety zone (the whole start area of the zone fixture) a hazard's ground generator never finds a spot, so the machine stays in
        -- Pre-Drop (as in single player). Outside it the listen host's machine must go Pre-Drop > Drop > Hit, and its spear chain shows on the guest.
        local SMC2 = StaticFindObject("/Script/SMSystem.SMStateMachineComponent")
        local bs, spot, seen, spearsHost = nil, nil, {}, 0
        local function clearSpot()
            local hm = T.first("BP_HazardManager_C")
            local pl = T.myPawn():K2_GetActorLocation()
            local ksl = UEHelpers.GetKismetSystemLibrary()
            local pawn = T.myPawn()
            local function inZone(x, y)
                local t = {}
                hm:IsPointInSafetyZone({ X = x, Y = y, Z = pl.Z }, 500.0, t, {})
                return t.InZone ~= false
            end
            local function ground(x, y)
                local hit = {}
                local ok = ksl:LineTraceSingle(pawn, { X = x, Y = y, Z = pl.Z + 4000 }, { X = x, Y = y, Z = pl.Z - 8000 }, 0, false, {}, 0, hit, true, { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
                return ok and hit.ImpactPoint.Z or nil
            end
            for _, d in ipairs({ 10000, 13000, 16000, 20000 }) do
                for a = 0, 330, 30 do
                    local x, y = pl.X + d * math.cos(math.rad(a)), pl.Y + d * math.sin(math.rad(a))
                    local clear = true
                    for r = 0, 5000, 1250 do
                        for b = 0, 315, 45 do if inZone(x + r * math.cos(math.rad(b)), y + r * math.sin(math.rad(b))) then clear = false end end
                    end
                    local gz = clear and ground(x, y)
                    if gz then return { x, y, gz } end
                end
            end
        end
        add({ run = function()
            spot = clearSpot()
            T.log("PT|info anomfin clear spot %s", spot and string.format("%.0f %.0f %.0f", spot[1], spot[2], spot[3]) or "none")
            if not spot then return end
            T.myPawn():K2_TeleportTo({ X = spot[1], Y = spot[2], Z = spot[3] + 300 }, { Pitch = 0, Yaw = 0, Roll = 0 })
            PTNative_MsgToGuest(gpc:GetAddress(), "t.tp", string.format("%.0f\t%.0f\t%.0f", spot[1] + 400, spot[2], spot[3] + 300))
        end })
        add({ wait = 4 })
        add({ run = function()
            if not spot then return end
            bs = spawn(ROWS[1][2], spot[1] - 1500, spot[2], spot[3] + 20)
            LoopInGameThreadWithDelay(200, function()
                if not bs or dead(bs) then return true end
                pcall(function()
                    local c = bs:GetComponentByClass(SMC2)
                    seen[c.R_Instance:GetActiveStateName():ToString()] = true
                    local n = 0
                    for _, o in ipairs(FindAllOf("BP_Hazard_ImpactSpear_C") or {}) do if not dead(o) and not o:GetFullName():find("Default__", 1, true) then n = n + 1 end end
                    spearsHost = math.max(spearsHost, n)
                end)
                return false
            end)
        end })
        add({ check = "host_blacksmith_slams", timeout = 60, cond = function()
            T.log("PT|info anomfin blacksmith states seen: Pre-Drop=%s Drop=%s Hit=%s spears(host max)=%d guest spears=%s", tostring(seen["Pre-Drop"]), tostring(seen.Drop), tostring(seen.Hit), spearsHost, tostring(gSpears))
            return seen.Drop and seen.Hit
        end })
        add({ check = "guest_sees_slam_spears", timeout = 30, cond = function() poll(); return (gSpears or 0) > 0 end })
        add({ run = function() if bs and not dead(bs) then bs:K2_DestroyActor() end end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    -- guest: report the parts of its copies, twice a second
    local finished, watch = false, {}
    LoopInGameThreadWithDelay(500, function()
        pcall(function()
            if T.netMode() ~= "client" then return end
            local pc = T.localPC():GetAddress()
            PTNative_MsgToHost(pc, "t.hp", string.format("%.0f", health()))
            local ns = 0
            for _, c in ipairs(FindAllOf("BP_Hazard_ImpactSpear_C") or {}) do if T.inWorld(c) and not dead(c) and not c:GetFullName():find("Default__", 1, true) then ns = ns + 1 end end
            PTNative_MsgToHost(pc, "t.sp", tostring(ns))
            for _, w in ipairs(watch) do
                local o = w.obj
                if not (o and o:IsValid()) then o = nearest(w[4], w[2], w[3]); w.obj = o end
                if not o and w[1] ~= "bollard" then -- the only copy of its class (spawned ones have moved from the spot by the time they are seen; the zone has level-placed bollards)
                    for _, c in ipairs(FindAllOf(w[4]) or {}) do if T.inWorld(c) and not dead(c) and not c:GetFullName():find("Default__", 1, true) then o = c; w.obj = c end end
                end
                w.n = (w.n or 0) + 1
                if w.n % 20 == 1 then
                    local all, l = FindAllOf(w[4]) or {}, o and o:K2_GetActorLocation()
                    T.log("PT|info anomvis guest %s: %d objects, copy %s at %s, expected %.0f %.0f, applied=%s", w[1], #all, tostring(o ~= nil), l and string.format("%.0f %.0f %.0f", l.X, l.Y, l.Z) or "-", w[2], w[3], tostring(package.loaded.anomvis and package.loaded.anomvis.applied))
                end
                if o then
                    for part, v in pairs(sample(o)) do
                        PTNative_MsgToHost(pc, "t.part", string.format("%s\t%s\t%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", w[1], part, v[1], v[2], v[3], v[4], v[5], v[6]))
                    end
                end
            end
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then break end
                if kind == "t.end" then finished = true end
                if kind == "t.tp" then
                    local x, y, z = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                    pcall(function() T.myPawn():K2_TeleportTo({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
                end
                if kind == "t.watch" then
                    watch = {}
                    for n, x, y, c in data:gmatch("([^:;]+):(%-?[%d%.]+):(%-?[%d%.]+):([^;]+)") do watch[#watch + 1] = { n, tonumber(x), tonumber(y), c } end
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
