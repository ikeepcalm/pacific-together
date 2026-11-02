-- Healer/Charging visibility, host resources, duplicates and removal. Fixture garage; mutation noboons.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local TYPES = {
        { path = "/Game/Gameplay/Boons/Healer/BP_Boon_Healer.BP_Boon_Healer_C", class = "BP_Boon_Healer_C", power = "HealingPowerRemaining", mesh = "SM_boonHealingA", amount = 37 },
        { path = "/Game/Gameplay/Boons/Healer/BP_Boon_Healer.BP_Boon_Healer_C", class = "BP_Boon_Healer_C", power = "HealingPowerRemaining", mesh = "SM_boonHealingA", amount = 19 },
        { path = "/Game/Gameplay/Boons/Charging/BP_Boon_Charging.BP_Boon_Charging_C", class = "BP_Boon_Charging_C", power = "ChargePowerRemaining", mesh = "SM_BoonCharger", amount = 23 },
    }
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end
    local function spawn(t, l, preReplicated)
        local c = StaticFindObject(t.path)
        if not c:IsValid() then LoadAsset(t.path); c = StaticFindObject(t.path) end
        assert(c:IsValid(), t.path)
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = l, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local gs = UEHelpers.GetGameplayStatics()
        local o = gs:BeginDeferredActorSpawnFromClass(T.world(), c, xf, 2, nil)
        if preReplicated then
            o:SetReplicates(true)
            o:SetReplicateMovement(false)
            o.bAlwaysRelevant, o.NetUpdateFrequency = false, 2
        end
        o = gs:FinishSpawningActor(o, xf)
        o[t.power] = t.amount
        return o
    end
    local slow = T.MUTATE == "noboons" and 15 or 60
    if T.ROLE == "host" then
        local steps, actors = {}, {}
        local function add(s) steps[#steps + 1] = s end
        local function send(k, d) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, d or "1") end
        local function reported(n, expected)
            return function()
                poll()
                T.log("PT|info boons %s=%s expected=%s", n, tostring(got["t." .. n]), expected)
                return got["t." .. n] == expected
            end
        end
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 60, cond = function() return T.netMode() == "listen" and T.map() == "RB_Garage" and T.listening() end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ run = function()
            local l = L.own():K2_GetActorLocation()
            send("t.seed", string.format("%.1f|%.1f|%.1f", l.X + 22000, l.Y, l.Z))
        end })
        add({ check = "guest_local_boons_seeded", timeout = 60, cond = reported("seeded", "3") })
        add({ run = function()
            local x, y, z = got["t.origin"]:match("([^|]+)|([^|]+)|([^|]+)")
            for i, t in ipairs(TYPES) do actors[i] = spawn(t, { X = tonumber(x) + i * 2000, Y = tonumber(y), Z = tonumber(z) }, i == 3) end
        end })
        add({ check = "host_boons_fully_configured", timeout = slow, cond = function()
            for _, o in ipairs(actors) do
                if not (o.bReplicates and o.RemoteRole ~= 0 and o.bReplicateMovement and o.bAlwaysRelevant and o.NetUpdateFrequency == 10) then return false end
            end
            return true
        end })
        add({ check = "guest_sees_all_boons", timeout = slow, cond = reported("seen", "3") })
        add({ check = "guest_has_no_local_boons", timeout = slow, cond = reported("own", "0") })
        add({ check = "guest_boons_passive", timeout = slow, cond = reported("passive", "3") })
        add({ check = "guest_boon_resources_match", timeout = slow, cond = reported("power", "37|19|23") })
        add({ run = function()
            actors[1].HealingPowerRemaining = 0
            actors[1]:OnRunOutOfJuice()
            actors[3].ChargePowerRemaining = 0
            actors[3]:PowerDrainedCompletely()
            send("t.deplete")
        end })
        add({ check = "guest_boon_depletion_matches", timeout = slow, cond = reported("depleted", "true|false|true") })
        add({ check = "guest_depleted_power_matches", timeout = slow, cond = reported("power", "0|19|0") })
        add({ run = function() actors[1]:K2_DestroyActor() end })
        add({ check = "guest_boon_removed_once", timeout = slow, cond = reported("seen", "2") })
        add({ check = "host_other_boon_unchanged", timeout = 5, cond = function() return actors[2]:IsValid() and actors[2].HealingPowerRemaining == 19 and not actors[2].OutOfJuice end })
        add({ run = function() send("t.done") end })
        add({ wait = 3 })
        return steps
    end

    local origin, seeded = nil, false
    local function report()
        poll()
        if got["t.seed"] and not seeded then
            local x, y, z = got["t.seed"]:match("([^|]+)|([^|]+)|([^|]+)")
            origin = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
            for i, t in ipairs(TYPES) do spawn(t, { X = origin.X + i * 2000, Y = origin.Y, Z = origin.Z }) end
            seeded = true
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.origin", got["t.seed"])
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.seeded", "3")
        end
        if not origin then return end
        local seen, own, passive, power, depleted = 0, 0, 0, {}, {}
        local lists = {}
        for _, t in ipairs(TYPES) do
            if not lists[t.class] then
                lists[t.class] = {}
                for _, o in ipairs(FindAllOf(t.class) or {}) do
                    if T.inWorld(o) and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then
                        if o.Role == 1 then lists[t.class][#lists[t.class] + 1] = o else own = own + 1 end
                    end
                end
            end
        end
        for i, t in ipairs(TYPES) do
            power[i], depleted[i] = "missing", "missing"
            for _, o in ipairs(lists[t.class]) do
                local l = o:K2_GetActorLocation()
                if (l.X - origin.X - i * 2000) ^ 2 + (l.Y - origin.Y) ^ 2 + (l.Z - origin.Z) ^ 2 < 100 ^ 2 then
                    if o[t.mesh]:IsValid() and not o.bHidden then seen = seen + 1 end
                    if not o:IsActorTickEnabled() and not o.Sphere1:GetGenerateOverlapEvents() then passive = passive + 1 end
                    power[i], depleted[i] = string.format("%.0f", o[t.power]), tostring(o.OutOfJuice)
                end
            end
        end
        for k, v in pairs({ seen = seen, own = own, passive = passive, power = table.concat(power, "|"), depleted = table.concat(depleted, "|") }) do
            PTNative_MsgToHost(T.localPC():GetAddress(), "t." .. k, tostring(v))
        end
    end
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end },
        { check = "guest_finished", timeout = 600, tick = report, cond = function() return got["t.done"] ~= nil end },
    }
end
