-- Guest-side visuals (owner 2026-11-16): the guest's copy of what the host does by hand must look and sound like it.
--   1. a car door and the hood, opened and shut on the HOST by the door's own AttemptOpen/AttemptShut (a player's E): the guest's
--      mesh turns over several frames (not one jump) and a door sound plays on the guest
--   2. scrapping a wreck's panel: the guest's tool damage message reaches the copy, its health falls step by step before the host
--      breaks it (the copy used to stay at full health until it vanished)
-- Run: tools/run-test.ps1 -Scenario guestvisual -Fixture gateway -Headless
-- Mutations: nodoorvisual (door state applied without the guest's animation/sound), noguestscrapvis (old behaviour: copy lifted to full health).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local COMP = "/Game/Gameplay/Inventory/GenericItemProperties/Components/"
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind]
    end
    local function theCar()
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
            local l = alive(c) and c:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and (T.ROLE == "host" or c.Role ~= 3) then return c end
        end
    end
    local PARTS = { { "door", "BP_CarPart_Door_Base_C", "SLOT_RearRightDoor" }, { "hood", "BP_Panel_Base_C", "SLOT_Hood" } }
    local function part(name)
        local want
        for _, p in ipairs(PARTS) do if p[1] == name then want = p end end
        local c = theCar()
        for _, a in ipairs(FindAllOf(want[2]) or {}) do
            local par = alive(a) and a:GetAttachParentActor()
            if par and par:IsValid() and par:GetFullName() == c:GetFullName() and a.RootComponent.AttachParent:GetFName():ToString() == want[3] then return a end
        end
    end
    local function panels()
        local r = {}
        for _, a in ipairs(FindAllOf("BP_TemplatePart_Panel_C") or {}) do
            if alive(a) and not a:GetFullName():find("/Engine/Transient", 1, true) then
                local l = a:K2_GetActorLocation()
                r[#r + 1] = { a = a, x = l.X, y = l.Y, z = l.Z }
            end
        end
        table.sort(r, function(p, q) return p.x * 3 + p.y * 7 + p.z < q.x * 3 + q.y * 7 + q.z end)
        return r
    end
    local function hpOf(a)
        local hc = a:K2_GetComponentsByClass(StaticFindObject(COMP .. "BP_HealthComponent.BP_HealthComponent_C"))[1]:get()
        local t = { {}, {}, {}, {}, {}, {}, {}, {} }
        hc:GetHealth(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8])
        return t[1].Health, t[2].MaxHealth
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        for _, s in ipairs(T.loadFixture("gateway")) do add(s) end
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_zone", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 20 })
        -- 1. door and hood by hand on the host: record on the guest, then act (open, then shut)
        for _, p in ipairs(PARTS) do
            for _, verb in ipairs({ "open", "shut" }) do
                local key = p[1] .. "_" .. verb
                add({ run = function() toGuest("t.rec", key) end })
                add({ wait = 1.5 })
                add({ run = function()
                    local a = part(p[1])
                    log("PT|info host %s %s %s", p[1], verb, tostring(a ~= nil))
                    if verb == "open" then a:AttemptOpen() else a:AttemptShut() end
                end })
                add({ check = "guest_reported_" .. key, timeout = 40, cond = function() return has("t.res_" .. key) ~= nil end })
                add({ run = function()
                    local frames, travel, step, snd = got["t.res_" .. key]:match("^(%d+)|([%d.]+)|([%d.]+)|(%d+)$")
                    log("PT|info %s: guest pose changed on %s frames, travel %s deg, biggest frame step %s deg, door sounds %s", key, frames, travel, step, snd)
                end })
                add({ check = "guest_" .. key .. "_moves_over_frames", timeout = 2, cond = function()
                    local frames, travel, step = got["t.res_" .. key]:match("^(%d+)|([%d.]+)|([%d.]+)|(%d+)$")
                    frames, travel, step = tonumber(frames), tonumber(travel), tonumber(step)
                    return travel > 5 and frames >= 5 and step < 0.6 * travel
                end })
                add({ check = "guest_" .. key .. "_plays_sound", timeout = 2, cond = function()
                    local _, _, _, snd = got["t.res_" .. key]:match("^(%d+)|([%d.]+)|([%d.]+)|(%d+)$")
                    return tonumber(snd) >= 1
                end })
            end
        end
        -- 2. scrap a wreck's panel from the guest
        local P
        add({ run = function()
            for _, e in ipairs(panels()) do if not P and (pcall(hpOf, e.a)) and hpOf(e.a) >= 20 then P = e end end -- sturdy enough for several hits
            P = P or panels()[3]
            log("PT|info host wreck panel %.0f %.0f %.0f hp %.1f", P.x, P.y, P.z, (hpOf(P.a)))
            toGuest("t.wreck", string.format("%.0f|%.0f|%.0f", P.x, P.y, P.z))
        end })
        add({ check = "guest_reported_scrap", timeout = 120, cond = function() return has("t.res_scrap") ~= nil end })
        add({ run = function() log("PT|info scrap guest copy health trace %s", got["t.res_scrap"]) end })
        add({ check = "guest_copy_health_fell_before_break", timeout = 2, cond = function()
            local start, low, n = got["t.res_scrap"]:match("^([%d.]+)|([%d.]+)|(%d+)$")
            return tonumber(n) >= 3 -- the copy's health falls in at least three steps while the part is still there
        end })
        add({ check = "host_wreck_part_broken_by_guest", timeout = 60, cond = function() return not alive(P.a) end })
        add({ wait = 3 })
        return steps
    end

    -- guest ---------------------------------------------------------------------------------------------------------------
    local snd = 0
    local hookedSnd = false
    local function hookSound()
        if hookedSnd then return end
        -- the one-shot spawner the door sounds go through; no parameter is read (reading them crashed the client), the count is only
        -- of calls inside a recording window, where nothing else makes a sound near the car
        pcall(function()
            RegisterHook("/Game/Sound/Blueprints/BPFL_AudioFunctions.BPFL_AudioFunctions_C:SpawnAndAttachOneShotAkComponent", function() snd = snd + 1 end)
            hookedSnd = true
        end)
    end
    local function pose(a)
        local c = theCar()
        local m = a.MainMesh or a.RootComponent
        local r = KML:InverseTransformRotation(c:GetTransform(), m:K2_GetComponentRotation())
        local l = KML:InverseTransformLocation(c:GetTransform(), m:K2_GetComponentLocation())
        return { r.Pitch, r.Yaw, r.Roll, l.X / 5, l.Y / 5, l.Z / 5 } -- location in 1/5 uu per degree
    end
    local function wrap(d) return math.abs((d + 180) % 360 - 180) end
    local function dist(a, b) local s = 0; for i = 1, 6 do s = s + (i <= 3 and wrap(a[i] - b[i]) or math.abs(a[i] - b[i])) end return s end
    local steps = {}
    local function add(s) steps[#steps + 1] = s end
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() ~= "RB_MainMenu" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_has_car_parts", timeout = 120, cond = function() return theCar() ~= nil and part("door") ~= nil and part("hood") ~= nil end })
    add({ run = hookSound })
    -- 1. recorders: a message starts 7 s of per-frame sampling
    local function record(key)
        local a = part(key:match("^(%a+)_"))
        local base, last, frames, travel, step = pose(a), pose(a), 0, 0, 0
        snd = 0
        local t0, loop = os.clock(), nil
        loop = LoopInGameThreadWithDelay(1, function()
            pcall(function()
                local p = pose(a)
                local d = dist(p, last)
                if d > 0.3 then frames = frames + 1 end
                step = math.max(step, d)
                travel = math.max(travel, dist(p, base))
                last = p
            end)
            if os.clock() - t0 > 7 then
                CancelDelayedAction(loop)
                PTNative_MsgToHost(T.localPC():GetAddress(), "t.res_" .. key, string.format("%d|%.1f|%.1f|%d", frames, travel, step, snd))
            end
        end)
    end
    for _, p in ipairs(PARTS) do
        for _, verb in ipairs({ "open", "shut" }) do
            local key = p[1] .. "_" .. verb
            add({ check = "guest_told_" .. key, timeout = 300, cond = function()
                if has("t.rec") == key then got["t.rec"] = nil; return true end
            end })
            add({ run = function() record(key) end })
            add({ wait = 8 })
        end
    end
    -- 2. scrap a wreck panel through the scrapper's damage message, a few hits a second, sampling the copy's health
    add({ check = "guest_told_wreck", timeout = 300, cond = function() return has("t.wreck") ~= nil end })
    local E
    add({ check = "guest_has_wreck_copy", timeout = 60, cond = function()
        local x, y, z = got["t.wreck"]:match("^([^|]*)|([^|]*)|([^|]*)")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        for _, e in ipairs(panels()) do
            if math.abs(e.x - x) < 40 and math.abs(e.y - y) < 40 and math.abs(e.z - z) < 40 then E = e end
        end
        return E ~= nil
    end })
    local function im() return T.first("BP_InventoryManager_C") end
    local SCRAPPER = "/Game/Gameplay/Inventory/Items/Tools/Scrapper/IA_Tool_Target_ItemHarvest_Scrapper.IA_Tool_Target_ItemHarvest_Scrapper"
    add({ run = function()
        local m = im()
        if not StaticFindObject(SCRAPPER):IsValid() then pcall(LoadAsset, SCRAPPER) end
        m.Inventory_PlayerHand:GetSlot(0):RemoveAllItems({})
        m:GiveItemToPlayer(StaticFindObject(SCRAPPER))
        for i = 0, m.Inventory_Player:GetNumSlots() - 1 do
            local s = m.Inventory_Player:GetSlot(i)
            if s:GetNumItems() > 0 and s:GetCurrentArchetype():GetFName():ToString() == "IA_Tool_Target_ItemHarvest_Scrapper" then s:TransferStackIntoContainer(m.Inventory_PlayerHand, {}); return end
        end
    end })
    add({ check = "guest_holds_scrapper", timeout = 20, cond = function()
        for _, x in ipairs(FindAllOf("BP_Tool_Target_ItemHarvest_Scrapper_C") or {}) do if alive(x) then return true end end
    end })
    add({ wait = 3 })
    local start, low, nsteps, lastHp
    add({ run = function()
        local t
        for _, x in ipairs(FindAllOf("BP_Tool_Target_ItemHarvest_Scrapper_C") or {}) do if alive(x) then t = x end end
        local ms = StaticFindObject("/Script/PenDriverPro.Default__BlueprintGameUtilities"):GetMessageSystem(t)
        local cls = StaticFindObject("/Game/Systems/Messages/MSG_Damage_Physical_Piercing_Scrapper.MSG_Damage_Physical_Piercing_Scrapper_C")
        start = hpOf(E.a)
        low, nsteps, lastHp = start, 0, start
        local n, loop = 0, nil
        loop = LoopInGameThreadWithDelay(50, function()
            n = n + 1
            if not alive(E.a) or not alive(t) or n > 600 then CancelDelayedAction(loop); return end
            pcall(function()
                local msg = StaticConstructObject(cls, t)
                msg.Damage, msg.IsDamageOverTime, msg.ToolDispatched = 3.0, true, true
                ms:DispatchMessage(msg, E.a)
            end)
        end)
        local sample
        sample = LoopInGameThreadWithDelay(100, function()
            if not alive(E.a) then
                CancelDelayedAction(sample)
                PTNative_MsgToHost(T.localPC():GetAddress(), "t.res_scrap", string.format("%.1f|%.1f|%d", start, low, nsteps))
                return
            end
            pcall(function()
                local h = hpOf(E.a)
                if h < lastHp - 0.5 and h > 0.5 then nsteps = nsteps + 1 end -- falls that end above 0: the copy itself, not the host's break
                lastHp, low = h, math.min(low, h)
            end)
        end)
    end })
    add({ wait = 80 })
    return steps
end
