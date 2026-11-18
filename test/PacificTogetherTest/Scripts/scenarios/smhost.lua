-- W6: hazards whose Logic Driver state machine is frozen on a listen host (docs/spikes/smhost.md). Fixture `zone`, the guest joins by itself.
--   The host spawns one hazard of each class around its pawn (the saw on a spot where its track builds). Per class the host's own state machine
--   must leave its first state with a player in range (check sm_<class>_runs): in a listen session without smhost.lua the instances read
--   bCanEvaluateTransitionsLocally = false and stay where they start.
--   guest_saw_copy_follows   the guest's copy of the saw shows the blade moving (anommove.lua syncs the Mount, the host's machine drives it)
--   blacksmith info line     what the guest's copy of the Blacksmith does (logged only)
-- Run: tools/run-test.ps1 -Scenario smhost -Fixture zone -Headless ; mutation nosmhost switches smhost.lua off.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local G = "/Game/Gameplay/"
    local function p(dir, c) return G .. dir .. "/" .. c .. "." .. c .. "_C" end
    local SAW = G .. "Hazards/SawBladeAnomaly/BP_Hazard_SawBlade.BP_Hazard_SawBlade_C"
    local SAW_AT = { 65464, -31031, 8221 }
    local ROWS = { -- { check name, class path, ring index or nil for the saw spot }
        { "blacksmith", p("Hazards/RockPounder", "BP_Hazard_RockPounder"), 1 },
        { "titansbone", p("Hazards/HazardProperties/ImpactSpears", "BP_Hazard_ImpactSpear"), 2 },
        { "bubblegum", p("Hazards/Spore", "BP_Hazard_Spore"), 3 },
        { "tumbler", p("Hazards/BombRock", "BP_Hazard_BombRock"), 4 },
        { "bollard", p("Hazards/Bollards", "BP_Hazard_Bollard"), 5 },
        { "pufferfish", p("Boons/ChubbyBunny", "BP_Boon_LootCreature"), 6 },
        { "saw", SAW, nil },
    }
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local function xf(x, y, z) return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } } end
    local function spawn(path, x, y, z)
        local cls = StaticFindObject(path)
        if not cls:IsValid() then LoadAsset(path); cls = StaticFindObject(path) end
        local gs = UEHelpers.GetGameplayStatics()
        return gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(T.world(), cls, xf(x, y, z), 0, nil), xf(x, y, z))
    end
    local function dead(o) return not o:IsValid() or o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local SMC = StaticFindObject("/Script/SMSystem.SMStateMachineComponent")
    local function smState(o) -- active state name of the actor's machine ("" before it started), and whether it may take transitions
        local c = o:GetComponentByClass(SMC)
        if not c:IsValid() then return "", false end
        local i = c.R_Instance
        if not (i and i:IsValid()) then return "", false end
        return i:GetActiveStateName():ToString(), i.bCanEvaluateTransitionsLocally and true or false
    end
    local function nearest(class, x, y) -- the copy of a hazard class whose root is nearest to x, y (both sides place the root at the same spot)
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
        local seen, actors, roots = {}, {}, {} -- row -> set of non-empty state names; row -> actor; row -> root xy
        local g = { mount = nil, pound = nil, poundState = nil }
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.saw" then
                    local x, y, z = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                    if x then g.mount = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end
                elseif kind == "t.pound" then
                    local z, s = data:match("^(%-?[%d%.]+)\t(.*)$")
                    if z then g.pound, g.poundState = tonumber(z), s end
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
            for _, r in ipairs(ROWS) do
                local x, y, z
                if r[3] then
                    local a = r[3] * 2 * math.pi / #ROWS
                    x, y, z = pl.X + math.cos(a) * 1500, pl.Y + math.sin(a) * 1500, pl.Z
                else x, y, z = SAW_AT[1], SAW_AT[2], SAW_AT[3] end
                local o = spawn(r[2], x, y, z)
                actors[r[1]], seen[r[1]] = o, {}
                local l = o:K2_GetActorLocation()
                roots[r[1]] = { l.X, l.Y }
                T.log("PT|info smhost spawned %s at %.0f %.0f %.0f valid=%s", r[1], l.X, l.Y, l.Z, tostring(not dead(o)))
            end
            local s, b = roots.saw, roots.blacksmith
            PTNative_MsgToGuest(gpc:GetAddress(), "t.watch", string.format("%.0f\t%.0f\t%.0f\t%.0f", s[1], s[2], b[1], b[2]))
            LoopInGameThreadWithDelay(500, function() -- sampled for the checks below
                for name, o in pairs(actors) do
                    if not dead(o) then
                        local ok, st = pcall(smState, o)
                        if ok and st ~= "" then seen[name][st] = true end
                    end
                end
                return false
            end)
        end })
        for _, r in ipairs(ROWS) do
            add({ check = "sm_" .. r[1] .. "_runs", timeout = 60, cond = function()
                local n, names = 0, {}
                for s in pairs(seen[r[1]]) do n = n + 1; names[#names + 1] = s end
                local _, ev = smState(actors[r[1]])
                T.log("PT|info smhost %s states seen: %s (may transition: %s)", r[1], table.concat(names, ","), tostring(ev))
                return n >= 2
            end })
        end
        add({ check = "guest_saw_copy_follows", timeout = 60, cond = function()
            poll()
            if not g.mount then return false end
            local gd = math.sqrt(g.mount.X ^ 2 + g.mount.Y ^ 2 + g.mount.Z ^ 2)
            local h = actors.saw.Mount.RelativeLocation
            T.log("PT|info smhost saw mount host=(%.0f,%.0f,%.0f) guest=(%.0f,%.0f,%.0f)", h.X, h.Y, h.Z, g.mount.X, g.mount.Y, g.mount.Z)
            return gd > 500
        end })
        add({ wait = 8 })
        add({ run = function() -- information: the Blacksmith's copy on the guest
            poll()
            local o = actors.blacksmith
            local st = smState(o)
            T.log("PT|info smhost blacksmith host state=%s cylinder z=%.0f; guest copy cylinder z=%s state=%s", st, o.Cylinder.RelativeLocation.Z, tostring(g.pound), tostring(g.poundState))
        end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    -- guest: report what its copies look like, once a second
    local finished, watch = false, nil
    LoopInGameThreadWithDelay(1000, function()
        pcall(function()
            if T.netMode() ~= "client" then return end
            if watch then
                local o = nearest("BP_Hazard_SawBlade_C", watch[1], watch[2])
                if o then
                    local m = o.Mount.RelativeLocation
                    PTNative_MsgToHost(T.localPC():GetAddress(), "t.saw", string.format("%.0f\t%.0f\t%.0f", m.X, m.Y, m.Z))
                end
                local b = nearest("BP_Hazard_RockPounder_C", watch[3], watch[4])
                if b then
                    PTNative_MsgToHost(T.localPC():GetAddress(), "t.pound", string.format("%.0f\t%s", b.Cylinder.RelativeLocation.Z, (smState(b))))
                end
            end
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then break end
                if kind == "t.end" then finished = true end
                if kind == "t.watch" then
                    local a, b, c, d = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                    watch = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
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
