-- World stations and hazards the guest could not share (friend playtest 2026-11-15, NOTES item 8/13). Fixture zone.
--   junk heap   BP_WorldStation_FriendlyDumpster: the guest's use is an intent, the HOST's heap runs (prizes = world items both see);
--               the guest's own copy never rolls prizes (muted) and shows the host's uses
--   shelter     BP_Boon_Frame_Shelter_Health: the host's copy reaches the guest passive with its resource, the guest's own copy is gone
--   acid glob   BP_Hazard_AcidGlob: replicated the moment it begins play (not at the next 1 s sweep) and seen by the guest
--   feed        "%d item{s} put into dumpster 03" is logged formatted
-- Mutations: nodumpster (heap intent + mute off), noboons (shelter not replicated), noglobhook (glob only by sweep), nofeedfmt is a code revert.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local P = {
        dump = "/Game/Gameplay/Boons/WorldStations/FriendlyDumpster/BP_WorldStation_FriendlyDumpster.BP_WorldStation_FriendlyDumpster_C",
        shelter = "/Game/Gameplay/Boons/Shelters/BP_Boon_Frame_Shelter_Health.BP_Boon_Frame_Shelter_Health_C",
        glob = "/Game/Gameplay/Hazards/AcidGlob/BP_Hazard_AcidGlob.BP_Hazard_AcidGlob_C",
    }
    local EVT = "BndEvt__Highlight_K2Node_ComponentBoundEvent_0_OnHighlightInteract__DelegateSignature"
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end
    local function spawn(path, l, pre)
        local c = StaticFindObject(path)
        if not c:IsValid() then LoadAsset(path); c = StaticFindObject(path) end
        assert(c:IsValid(), path)
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = l, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local gs = UEHelpers.GetGameplayStatics()
        local o = gs:BeginDeferredActorSpawnFromClass(T.world(), c, xf, 2, nil)
        return gs:FinishSpawningActor(o, xf), o
    end
    local function near(o, p, r)
        local l = o:K2_GetActorLocation()
        return (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2 + (l.Z - p.Z) ^ 2 < (r or 100) ^ 2
    end
    local function all(class, p, r)
        local r2 = {}
        for _, o in ipairs(FindAllOf(class) or {}) do
            if T.inWorld(o) and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and near(o, p, r) then r2[#r2 + 1] = o end
        end
        return r2
    end
    local function testLevel() T.world():K2_GetWorldSettings().bIsTestLevel = true end -- the heap destroys itself before Q01 is done
    local function count(pattern)
        local f = io.open("ue4ss/UE4SS.log", "rb")
        if not f then return -1 end
        local text = f:read("a")
        f:close()
        return text:find(pattern, 1, true) and 1 or 0
    end
    local function spot(base, i) return { X = base.X + i * 600, Y = base.Y, Z = base.Z + 60 } end

    if T.ROLE == "host" then
        local steps, base = {}, nil
        local function add(s) steps[#steps + 1] = s end
        local dump, shelter, glob, globAtOnce
        local function send(k, d) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, d or "1") end
        local function reported(n, expected)
            return function()
                poll()
                T.log("PT|info worldstations %s=%s expected=%s", n, tostring(got["t." .. n]), expected)
                return got["t." .. n] == expected
            end
        end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen_zone", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == "Rural_Forest_Radio_Scylla_02" end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function()
            testLevel()
            local l = L.guestChar():K2_GetActorLocation()
            base = { X = l.X, Y = l.Y + 800, Z = l.Z }
            send("t.seed", string.format("%.1f|%.1f|%.1f", base.X, base.Y, base.Z))
        end })
        add({ check = "guest_seeded_local_copies", timeout = 60, cond = reported("seeded", "1") })
        add({ check = "guest_local_heap_muted", timeout = 30, cond = reported("muted", "0") })
        add({ run = function()
            dump = spawn(P.dump, spot(base, 0))
            local o = spawn(P.shelter, spot(base, 1))
            shelter = o
            shelter.HealingPowerRemaining = 77
            T.log("PT|info host heap %s uses=%d allow=%s", dump:GetFName():ToString(), dump.Uses, tostring(dump.AllowHighlightInteraction))
        end })
        -- shelter
        add({ check = "guest_sees_host_shelter_passive", timeout = 60, cond = reported("shelter", "1|0|1|77") })
        -- glob: replicated at once, seen by the guest
        add({ run = function()
            glob = spawn(P.glob, spot(base, 2))
            globAtOnce = glob.bReplicates and glob.bAlwaysRelevant -- read in the same tick: the 1 s sweep has not run
            T.log("PT|info host glob rep=%s relevant=%s", tostring(glob.bReplicates), tostring(glob.bAlwaysRelevant))
        end })
        add({ check = "glob_replicated_on_begin_play", timeout = 1, cond = function() return globAtOnce end })
        add({ check = "guest_sees_glob", timeout = 60, cond = reported("glob", "1") })
        -- heap: the guest uses it
        add({ run = function() send("t.use") end })
        add({ check = "host_heap_ran_for_guest", timeout = 30, cond = function()
            T.log("PT|info host heap uses=%d allow=%s", dump.Uses, tostring(dump.AllowHighlightInteraction))
            return dump.Uses == 1
        end })
        add({ check = "host_heap_made_prizes", timeout = 30, cond = function() return #all("BP_WorldItem_C", spot(base, 0), 800) > 0 end })
        add({ check = "guest_sees_prizes", timeout = 60, cond = function()
            poll()
            local n = tonumber(got["t.prizes"]) or 0
            T.log("PT|info worldstations guest prizes=%d host prizes=%d", n, #all("BP_WorldItem_C", spot(base, 0), 800))
            return n > 0
        end })
        add({ check = "guest_heap_shows_host_use", timeout = 30, cond = reported("heapstate", "1|false") })
        add({ run = function() send("t.feed") end })
        add({ check = "guest_feed_logged_formatted", timeout = 30, cond = reported("feed", "1") })
        add({ run = function() send("t.done") end })
        add({ wait = 3 })
        return steps
    end

    local base, localDump, localShelter, finished = nil, nil, nil, false
    local function report()
        poll()
        if got["t.seed"] and not base then
            local x, y, z = got["t.seed"]:match("([^|]+)|([^|]+)|([^|]+)")
            base = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
            testLevel()
            localDump = spawn(P.dump, spot(base, 0))
            localShelter = spawn(P.shelter, spot(base, 1))
            localShelter.HealingPowerRemaining = 5
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.seeded", "1")
            -- a use of the guest's own heap must not roll anything (muted); give the 1 s mute loop time
            ExecuteWithDelay(4000, function()
                pcall(function()
                    localDump[EVT](localDump, localDump.Highlight, nil)
                    PTNative_MsgToHost(T.localPC():GetAddress(), "t.muted", tostring(localDump.Uses))
                end)
            end)
        end
        if not base then return end
        local me = T.myPawn()
        local sh = 0
        local list = all("BP_Boon_Frame_Shelter_Health_C", spot(base, 1), 100)
        local rep, passive, power = 0, 0, "none"
        for _, o in ipairs(list) do
            if o.Role == 1 then
                rep = rep + 1
                if not o:IsActorTickEnabled() and not o.ActivateShelterOverlap:GetGenerateOverlapEvents() then passive = 1 end
                power = string.format("%.0f", o.HealingPowerRemaining)
            end
        end
        PTNative_MsgToHost(T.localPC():GetAddress(), "t.shelter", string.format("%d|%d|%d|%s", rep, #list - rep, passive == 1 and 1 or 0, power))
        local g = 0
        for _, o in ipairs(all("BP_Hazard_AcidGlob_C", spot(base, 2), 100)) do if o.Role == 1 then g = 1 end end
        PTNative_MsgToHost(T.localPC():GetAddress(), "t.glob", tostring(g))
        PTNative_MsgToHost(T.localPC():GetAddress(), "t.prizes", tostring(#all("BP_WorldItem_C", spot(base, 0), 800)))
        if localDump and localDump:IsValid() then
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.heapstate", localDump.Uses .. "|" .. tostring(localDump.AllowHighlightInteraction))
        end
        if got["t.use"] then
            got["t.use"] = nil
            require("stations").dumpUse(localDump)
        end
        if got["t.feed"] then
            got["t.feed"] = nil
            require("overlay").post("%d item{s} put into dumpster 03", "info", "loot.in.test", 2)
            ExecuteWithDelay(1500, function()
                PTNative_MsgToHost(T.localPC():GetAddress(), "t.feed", tostring(count("PT|feed (quiet) 2 items put into dumpster 03")))
            end)
        end
        if got["t.done"] then finished = true end
    end
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "Rural_Forest_Radio_Scylla_02" and T.cls(T.myPawn()) == T.CHAR end },
        { wait = 12 },
        { check = "guest_finished", timeout = 600, tick = report, cond = function() return finished end },
    }
end
