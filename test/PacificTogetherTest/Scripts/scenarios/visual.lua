-- PT2 visual, zone: the zone's procedural dressing exists on the host only (buildings, prefab meshes, doors, destructibles; the run's spawn pass
-- never runs on a guest). Fixture zone, the guest joins by itself. The host picks a sample of what is not placed in the map file and sends it
-- (t.sample); the guest looks for each in its own world, then the host changes things and the guest's copies follow within 3 s:
--   guest_mirrors_*            static meshes (90 %), every sampled building frame, door and destructible exists on the guest
--   guest_buildings_same_meshes every sampled building shows the host's visible meshes (its foundation variant: the stairs)
--   guest_door_follows_host    the host swings a door open (the game's own "Set Door from State"): the guest's copy has the same state
--   host_door_used_by_guest    the guest presses its copy of a closed door (Highlight, as E does): the host's door opens
--   guest_destructible_breaks  the host breaks a destructible: the guest's copy breaks or is gone
--   guest_removed_mesh_gone    the host removes a prefab mesh: the guest's copy is removed
-- Run: tools/run-test.ps1 -Scenario visual -Fixture zone -Headless [-Root .. -Port ..]   Mutation novisual: visual.lua inert on both sides.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local RF = 0x00080000 -- RF_WasLoaded: placed in the map file
    local slow = (T.MUTATE == "novisual") and 0.15 or 1 -- a mutation must fail, not wait out every timeout
    local function to(s) return math.max(12, math.floor(s * slow)) end
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function cn(o) return o:GetClass():GetFName():ToString() end
    local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

    -- run-time spawned actors of a class (not in the map file); names of the host are not the guest's, so everything goes by class and place
    local function runtime(class, pred)
        local r = {}
        for _, o in ipairs(FindAllOf(class) or {}) do
            if alive(o) and not o:HasAnyFlags(RF) and not o:GetFullName():find("/Engine/Transient", 1, true) and (not pred or pred(o)) then r[#r + 1] = o end
        end
        return r
    end
    local function meshOf(o) local m = o.StaticMeshComponent.StaticMesh; return (m and m:IsValid()) and m:GetFName():ToString() or "-" end
    local function plainSMA(o)
        local par = o:GetAttachParentActor()
        return o.StaticMeshComponent.Mobility ~= 2 and not (par and par:IsValid() and cn(par):find("^BP_Template_")) and meshOf(o) ~= "-"
    end
    -- a building's visible meshes (its foundation is rolled per side: stairs, dirt piles), sorted
    local function frameMeshes(o)
        local t = {}
        for _, w in ipairs(o:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"))) do
            local c = w:get()
            local m = c.StaticMesh
            -- dirt piles a guest copy's roll removed cannot come back (visual.lua shortcut): not compared
            if c:IsVisible() and m and m:IsValid() and m:GetFName():ToString() ~= "SM_StormChest_DirtPile" then t[#t + 1] = m:GetFName():ToString() end
        end
        table.sort(t)
        return table.concat(t, ",")
    end
    local function isFrame(o) return cn(o):find("^BP_BuildingFrame_") ~= nil end
    local function isDoor(o) return cn(o):find("^BP_Door_") ~= nil end
    local function isDestruct(o) return cn(o):find("^BP_Destruct_") ~= nil and not cn(o):find("Part_", 1, true) end
    local function all(pred)
        local r = {}
        for _, o in ipairs(FindAllOf("Actor") or {}) do
            if alive(o) and not o:HasAnyFlags(RF) and pred(o) and not o:GetFullName():find("/Engine/Transient", 1, true) then r[#r + 1] = o end
        end
        return r
    end
    -- the guest's copy of something the host described: same class (or mesh) within 30 uu
    local function copyOf(kind, name, p)
        local list = kind == "S" and runtime("StaticMeshActor") or runtime(name)
        for _, o in ipairs(list) do
            if (kind ~= "S" or meshOf(o) == name) and d3(o:K2_GetActorLocation(), p) < 30 then return o end
        end
    end

    local function ser(kind, o, extra)
        local p = o:K2_GetActorLocation()
        return string.format("%s\t%s\t%.2f\t%.2f\t%.2f\t%s", kind, kind == "S" and meshOf(o) or cn(o), p.X, p.Y, p.Z, extra or "")
    end
    local function parse(s)
        local r = {}
        for line in (s or ""):gmatch("[^\n]+") do
            local k, n, x, y, z, e = line:match("^(%a)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
            if k then r[#r + 1] = { k = k, n = n, p = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, e = e } end
        end
        return r
    end

    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        local sample, door, door2, cone, mesh = nil, nil, nil, nil, nil
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_zone", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ run = function()
            local S = {}
            local sma = all(function(o) return cn(o) == "StaticMeshActor" and plainSMA(o) end)
            table.sort(sma, function(a, b) return a:GetFName():ToString() < b:GetFName():ToString() end)
            for i = 1, #sma, math.max(1, math.floor(#sma / 60)) do S[#S + 1] = ser("S", sma[i]) end
            mesh = sma[1]
            for _, o in ipairs(all(isFrame)) do S[#S + 1] = ser("F", o, frameMeshes(o)) end
            local doors = all(function(o) return isDoor(o) and o.CurrentState == 0 end)
            table.sort(doors, function(a, b) return a:GetFName():ToString() < b:GetFName():ToString() end)
            for i = 1, math.min(4, #doors) do S[#S + 1] = ser("D", doors[i], tostring(doors[i].CurrentState)) end
            door, door2 = doors[1], doors[2]
            local ds = all(isDestruct)
            table.sort(ds, function(a, b) return a:GetFName():ToString() < b:GetFName():ToString() end)
            for i = 1, math.min(5, #ds) do S[#S + 1] = ser("X", ds[i]) end
            cone = ds[#ds]
            sample = table.concat(S, "\n")
            T.log("PT|info host sample meshes=%d frames=%d doors=%d destructibles=%d (of %d meshes)", math.min(60, #sma), #all(isFrame), math.min(4, #doors), math.min(5, #ds), #sma)
        end })
        -- the sample is repeated until the guest says its mirror is complete
        local lastSample = -100
        add({ check = "guest_mirror_complete", timeout = 400 * slow, cond = function()
            if sample and os.clock() - lastSample > 20 then lastSample = os.clock(); toGuest("t.sample", sample) end
            poll()
            return got["t.mirrored"] ~= nil
        end })
        add({ run = function()
            local p = door:K2_GetActorLocation()
            door["Set Door from State"](door, 1)
            toGuest("t.door", string.format("%s\t%.2f\t%.2f\t%.2f\t1", cn(door), p.X, p.Y, p.Z))
            T.log("PT|info host opened door %s state=%s", cn(door), tostring(door.CurrentState))
        end })
        add({ wait = 6 })
        add({ run = function()
            local p = cone:K2_GetActorLocation()
            local z = { X = 0, Y = 0, Z = 0 }
            if not pcall(function() cone:ComplexBreak(z, cone.BaseMesh) end) then cone:SimpleBreak(z) end
            toGuest("t.break", string.format("%s\t%.2f\t%.2f\t%.2f", cn(cone), p.X, p.Y, p.Z))
            T.log("PT|info host broke %s", cn(cone))
        end })
        add({ wait = 6 })
        add({ run = function()
            local p = mesh:K2_GetActorLocation()
            toGuest("t.remove", string.format("%s\t%.2f\t%.2f\t%.2f", meshOf(mesh), p.X, p.Y, p.Z))
            mesh:K2_DestroyActor()
        end })
        add({ wait = 4 })
        add({ run = function()
            local p = door2:K2_GetActorLocation()
            toGuest("t.use", string.format("%s\t%.2f\t%.2f\t%.2f", cn(door2), p.X, p.Y, p.Z))
            T.log("PT|info host asks the guest to use door %s state=%s", door2:GetFName():ToString(), tostring(door2.CurrentState))
        end })
        add({ check = "host_door_used_by_guest", timeout = to(40), cond = function()
            T.log("PT|info host door %s state=%s", door2:GetFName():ToString(), tostring(door2.CurrentState))
            return door2.CurrentState ~= 0
        end })
        add({ check = "host_guest_finished", timeout = 400 * slow, cond = function() poll(); return got["t.done"] ~= nil end })
        add({ wait = 2 })
        return steps
    end

    -- guest
    local seen
    local function found(kind, name, p) return copyOf(kind, name, p) ~= nil end
    local function mirrored(frac, kinds)
        return function()
            poll()
            local s = got["t.sample"]
            if not s then return false end
            local have, total = 0, 0
            for _, e in ipairs(parse(s)) do
                if kinds[e.k] then
                    total = total + 1
                    local name = e.n
                    if e.k == "S" then name = e.n elseif e.k == "F" or e.k == "D" or e.k == "X" then name = e.n end
                    if found(e.k == "S" and "S" or "B", name, e.p) then have = have + 1 end
                end
            end
            T.log("PT|info guest mirror kinds=%s %d/%d", next(kinds), have, total)
            return total > 0 and have >= total * frac
        end
    end
    -- measured from the host's message: it must show within 3 s of the guest first looking
    local function within(sec, key, test)
        local t0
        return function()
            poll()
            if not got[key] then return false end
            t0 = t0 or os.clock()
            local ok, why = test(got[key])
            T.log("PT|info %s %s after %.1fs", key, tostring(why), os.clock() - t0)
            return ok and os.clock() - t0 <= sec
        end
    end

    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "Rural_Forest_Radio_Scylla_02" and T.cls(T.myPawn()) == T.CHAR end },
        { check = "guest_got_sample", timeout = to(240), cond = function() poll(); return got["t.sample"] ~= nil end },
        { check = "guest_mirrors_static_meshes", timeout = to(400), cond = mirrored(0.9, { S = true }) },
        { check = "guest_mirrors_buildings", timeout = to(120), cond = mirrored(1.0, { F = true }) },
        { check = "guest_buildings_same_meshes", timeout = to(60), cond = function()
            local same, total = 0, 0
            for _, e in ipairs(parse(got["t.sample"])) do
                if e.k == "F" then
                    total = total + 1
                    local o = copyOf("B", e.n, e.p)
                    local mine = o and frameMeshes(o) or "none"
                    if mine == e.e then same = same + 1 else T.log("PT|info guest building %s host=%s guest=%s", e.n, e.e, mine) end
                end
            end
            T.log("PT|info guest buildings with the host's meshes %d/%d", same, total)
            return total > 0 and same == total
        end },
        { check = "guest_mirrors_doors", timeout = to(120), cond = mirrored(1.0, { D = true }) },
        { check = "guest_mirrors_destructibles", timeout = to(120), cond = mirrored(1.0, { X = true }) },
        { run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.mirrored", "1") end },
        { check = "guest_door_follows_host", timeout = to(40), cond = within(3, "t.door", function(d)
            local n, x, y, z, st = d:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)$")
            local o = copyOf("B", n, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) })
            return o ~= nil and o.CurrentState == tonumber(st), o and ("state=" .. tostring(o.CurrentState)) or "no copy"
        end) },
        { check = "guest_destructible_breaks_with_host", timeout = to(40), cond = within(4, "t.break", function(d)
            local n, x, y, z = d:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
            local o = copyOf("B", n, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) })
            return o == nil or o.IsBroken == true, o and ("broken=" .. tostring(o.IsBroken)) or "gone"
        end) },
        { check = "guest_removed_mesh_gone", timeout = to(40), cond = within(3, "t.remove", function(d)
            local n, x, y, z = d:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
            return copyOf("S", n, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }) == nil, "copy gone"
        end) },
        { check = "guest_door_copy_pressed", timeout = to(40), cond = function()
            poll()
            local d = got["t.use"]
            if not d then return false end
            local n, x, y, z = d:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
            local o = copyOf("B", n, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) })
            if not o then return false end
            o.Highlight:InteractPressed(nil) -- what the guest's E does on the door it looks at
            o.Highlight:InteractReleased(nil)
            return true
        end },
        { check = "guest_alive_after", timeout = to(60), cond = L.holds(8, function() return T.netMode() == "client" and T.map() == "Rural_Forest_Radio_Scylla_02" and T.myPawn() ~= nil end) },
        { run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.done", "1") end },
        { wait = 3 },
    }
end
