-- C5, W11, D13, D22: the guest works on the car and uses the ARC. Fixture `gateway` (a real run, the car parked, ARC charged).
--   The guest holds the game's own tools and runs their effect points (PatchKit:PatchPart, ChargeBattery:ChargeBattery,
--   FuelableComponent:TransferFuel from a fuel can into the gas cap, ARC screen OnExitUseComplete, Gobbler AddingAnchorCompleteLogic);
--   the HOST's car then has the repaired part, the charged battery, the fuel, the ARC charge and the picked gateway, and the
--   guest sees the same (state message, ARC mirror, world.lua). A tool in the guest's hand is real; its aim is set directly
--   (headless: no highlight to point at).
-- Run: tools/run-test.ps1 -Scenario guestact -Fixture gateway -Headless
-- Mutation noguestact: the shipping mod's guestact module does nothing (host checks and the ARC mirror FAIL).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local COMP = "/Game/Gameplay/Inventory/GenericItemProperties/Components/"
    local TOOLS = "/Game/Gameplay/Inventory/Items/Tools/"
    local HP_SLOT, BAT_SLOT = "Body.DoorsFR", "Attachments.BackSeatRight"
    local slow = (T.MUTATE == "noguestact") and 0.15 or 1
    local function to(s) return math.max(15, math.floor(s * slow)) end

    local function cm() return T.first("BP_CarManager_C") end
    local function manif(name)
        local r, r2 = {}, {}
        cm():GetItemManifestationEquippedInSlot({ TagName = FName("Car.Equip." .. name) }, r, r2)
        local m = r.Manifestation
        return (m and m:IsValid()) and m or nil
    end
    local function comp(m, cls) for _, x in ipairs(m:K2_GetComponentsByClass(StaticFindObject(COMP .. cls))) do return x:get() end end
    local function hpOf(name)
        local c = comp(manif(name), "BP_HealthComponent.BP_HealthComponent_C")
        local t = { {}, {}, {}, {}, {}, {}, {}, {} }
        c:GetHealth(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8])
        return t[1].Health
    end
    local function batOf(name)
        local c = comp(manif(name), "BP_BatteryComponent.BP_BatteryComponent_C")
        local t = { {}, {}, {}, {}, {} }
        c:GetBatteryStatus(t[1], t[2], t[3], t[4], t[5])
        return t[1].BATTERY
    end
    local function arc()
        local c, m = {}, {}
        T.first("BP_Carpart_Internal_GobblerScreen_C"):GetAnchorCharge(c, m)
        return c.CurrentCharge
    end
    local function portals() local r = {} for _, p in ipairs(FindAllOf("BP_LevelTransition_ExitPortal_C") or {}) do if p:IsValid() and p.Role ~= 0 then r[#r + 1] = p end end return r end

    local got = {}
    local function drain()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then return end
            got[kind] = data
        end
    end
    local function has(kind) drain(); return got[kind] end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local base = {}
        for _, s in ipairs(T.loadFixture("gateway")) do add(s) end
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_zone", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 15 })
        -- a hurt part, a flat battery; remember fuel and ARC charge
        add({ run = function()
            comp(manif(HP_SLOT), "BP_HealthComponent.BP_HealthComponent_C"):SetHealth(5.0)
            local b = comp(manif(BAT_SLOT), "BP_BatteryComponent.BP_BatteryComponent_C")
            b["Set Battery"](b, 2.0)
            base.fuel, base.arc = cm().AggregateFuelCurrent, arc()
            log("PT|info host baseline fuel=%.2f arc=%.2f hp=%.1f bat=%.1f", base.fuel, base.arc, hpOf(HP_SLOT), batOf(BAT_SLOT))
            PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.go", "")
        end })
        add({ check = "host_part_repaired_by_guest", timeout = to(240), cond = function() local h = hpOf(HP_SLOT); log("PT|info host hp=%.1f", h); return h >= 39 end })
        add({ check = "host_battery_charged_by_guest", timeout = to(120), cond = function() local b = batOf(BAT_SLOT); log("PT|info host battery=%.1f", b); return b >= 25 end })
        -- the jumper on the charge port (playtest 2026-11-15): the host's flat battery rises through ChargeAllBatteries
        add({ run = function()
            local b = comp(manif(BAT_SLOT), "BP_BatteryComponent.BP_BatteryComponent_C")
            b["Set Battery"](b, 2.0)
            PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.go2", "")
        end })
        add({ check = "host_battery_charged_via_port", timeout = to(120), cond = function() local b = batOf(BAT_SLOT); log("PT|info host battery via port=%.1f", b); return b >= 25 end })
        add({ check = "host_car_fuelled_by_guest", timeout = to(120), cond = function()
            local f = cm().AggregateFuelCurrent
            log("PT|info host fuel %.2f -> %.2f", base.fuel, f)
            return f - base.fuel >= 1.0
        end })
        add({ check = "host_arc_charged_by_guest", timeout = to(120), cond = function() local a = arc(); log("PT|info host arc %.2f -> %.2f", base.arc, a); return a - base.arc >= 1.0 end })
        add({ check = "host_gateway_summoned_by_guest", timeout = to(120), cond = function()
            local sm, s = T.first("BP_StormManager_C"), T.first("BP_Carpart_Internal_GobblerScreen_C")
            local g = T.name(sm.EvolvedGatewayExit):match("[^%.]+$") or "none"
            log("PT|info host gateway=%s exitSelected=%s", g, tostring(s.ExitSelected))
            return g ~= "none" and s.ExitSelected == true
        end })
        add({ check = "host_guest_finished", timeout = to(300), cond = function() return has("t.done") ~= nil end })
        return steps
    end

    -- guest -------------------------------------------------------------------------------------------------------------
    local function arch(path)
        local a = StaticFindObject(path)
        if not (a and a:IsValid()) then pcall(LoadAsset, path); a = StaticFindObject(path) end
        return a
    end
    local function im() return T.first("BP_InventoryManager_C") end
    -- the game's own give, then the stack into the hand (the hand manifestation is the tool actor)
    local function hold(path)
        local m = im()
        m.Inventory_PlayerHand:GetSlot(0):RemoveAllItems({})
        m:GiveItemToPlayer(arch(path))
        local want = path:match("([^/%.]+)$")
        for i = 0, m.Inventory_Player:GetNumSlots() - 1 do
            local s = m.Inventory_Player:GetSlot(i)
            if s:GetNumItems() > 0 and s:GetCurrentArchetype():GetFName():ToString() == want then s:TransferStackIntoContainer(m.Inventory_PlayerHand, {}); return end
        end
        error("tool not in the backpack: " .. want)
    end
    -- the held tool: the earlier ones (replaced by hold()) linger in FindAllOf until the GC runs, and a call on such a stale one never
    -- reached the hook the mod sets (guestact port check, flaky since 2026-11-17); the live one is the last that is not pending kill
    local function tool(cls)
        local r
        for _, x in ipairs(FindAllOf(cls) or {}) do
            if x:IsValid() and not x:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then r = x end
        end
        return r
    end
    local function sendDone() PTNative_MsgToHost(T.localPC():GetAddress(), "t.done", "1") end
    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local PATCH, CHARGER, CAN = TOOLS .. "PatchKit/IA_Tool_Target_Consumable_PatchKit.IA_Tool_Target_Consumable_PatchKit",
        TOOLS .. "BatteryCharger/Consumable/IA_Tool_Target_BatteryCharger_Consumable.IA_Tool_Target_BatteryCharger_Consumable",
        TOOLS .. "FuelCan/FuelCan5G/IA_Tool_Target_FuelCan_5Gal.IA_Tool_Target_FuelCan_5Gal"
    local hostArc
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "Rural_Forest_Radio_Scylla_02" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_one_car", timeout = 90, cond = function()
        local n = 0
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do if c:IsValid() and c.Role ~= 3 then n = n + 1 end end
        return n == 1 and manif(HP_SLOT) ~= nil
    end })
    -- the host's ARC energy is on the guest's screen (D13)
    add({ check = "guest_arc_shows_host_charge", timeout = to(60), cond = function() local a = arc(); log("PT|info guest arc=%.2f", a); return a >= 6.9 end })
    add({ check = "guest_told_to_go", timeout = 240, cond = function() return has("t.go") ~= nil end })
    add({ wait = 5 })
    -- C5 repair: repair putty on the hurt door
    add({ run = function() hold(PATCH) end })
    add({ check = "guest_holds_patch_kit", timeout = 20, cond = function() return tool("BP_Tool_Target_Consumable_PatchKit_C") ~= nil end })
    add({ wait = 3 })
    add({ check = "guest_door_is_hurt", timeout = 30, cond = function() return hpOf(HP_SLOT) <= 6 end })
    add({ run = function()
        local t = tool("BP_Tool_Target_Consumable_PatchKit_C")
        t.TargetedActor = manif(HP_SLOT)
        t:PatchPart()
    end })
    -- C5 battery: the battery charger on the flat battery
    add({ run = function() hold(CHARGER) end })
    add({ check = "guest_holds_charger", timeout = 20, cond = function() return tool("BP_Tool_Target_Consumable_ChargeBattery_Base_C") ~= nil end })
    add({ wait = 3 })
    add({ check = "guest_battery_is_flat", timeout = 30, cond = function() return batOf(BAT_SLOT) <= 3 end })
    add({ run = function()
        local t = tool("BP_Tool_Target_Consumable_ChargeBattery_Base_C")
        t.TargetedActor = manif(BAT_SLOT)
        t:ChargeBattery()
    end })
    add({ check = "guest_told_port", timeout = 120, cond = function() return has("t.go2") ~= nil end })
    add({ run = function() hold(CHARGER) end })
    add({ check = "guest_holds_charger2", timeout = 20, cond = function() return tool("BP_Tool_Target_Consumable_ChargeBattery_Base_C") ~= nil end })
    add({ wait = 3 })
    add({ check = "guest_battery_flat_again", timeout = 30, cond = function() return batOf(BAT_SLOT) <= 3 end }) -- a full battery takes no charge
    add({ run = function()
        local t = tool("BP_Tool_Target_Consumable_ChargeBattery_Base_C")
        t.TargetedActor = manif("Internal.ChargePort")
        log("PT|info guest port target=%s bat=%.1f", T.name(t.TargetedActor), batOf(BAT_SLOT))
        for _, x in ipairs(t.TargetedActor:K2_GetComponentsByClass(StaticFindObject(COMP .. "BP_BatteryComponent.BP_BatteryComponent_C"))) do log("PT|info guest port comp %s", T.name(x:get())) end
        t:ChargeBattery()
        log("PT|info guest port charged bat=%.1f", batOf(BAT_SLOT))
    end })
    -- C5 refuel: a fuel can into the gas cap
    add({ run = function() hold(CAN) end })
    add({ check = "guest_holds_fuel_can", timeout = 20, cond = function() return tool("BP_Tool_Target_FuelCan5g_C") ~= nil end })
    add({ wait = 3 })
    add({ run = function()
        local can = comp(tool("BP_Tool_Target_FuelCan5g_C"), "BP_FuelableComponent.BP_FuelableComponent_C")
        can["Set Fuel"](can, 5.0)
        local gas = comp(manif("Internal.GasCap"), "BP_FuelableComponent.BP_FuelableComponent_C")
        for _ = 1, 10 do can:TransferFuel(can, gas, 1.0, {}, {}) end
    end })
    -- W11/D13 ARC: an anchor into the ARC, then the gateway at the ARC screen
    add({ run = function()
        local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
        local a = arch("/Game/Gameplay/Inventory/Items/Resources/Anchor/AnchorBlue/IA_Resource_Anchor_Stable_M.IA_Resource_Anchor_Stable_M")
        local g = T.first("BP_Carpart_Internal_Gobbler_C")
        g:AddingAnchorCompleteLogic(lib:CreateItemInstance(g:GetWorld(), a, 0))
    end })
    add({ wait = 4 })
    -- a nil portal made the screen's OnExitUseComplete crash the guest (suite run 20261022-011955); the portal actors replicate late
    add({ check = "guest_has_exit_portal", timeout = to(60), cond = function() return portals()[1] ~= nil end })
    add({ run = function()
        local p = portals()[1]
        log("PT|info guest picks gateway %s", T.name(p))
        if not p then return end -- the check above failed; calling the screen with nil crashes the game
        T.first("BP_Carpart_Internal_GobblerScreen_C"):OnExitUseComplete(p)
    end })
    -- what the guest sees now is the host's car: the repaired door stays repaired, the ARC follows the host, the gateway is picked
    add({ check = "guest_door_stays_repaired", timeout = to(60), cond = L.holds(8, function() return hpOf(HP_SLOT) >= 39 end) })
    add({ check = "guest_sees_gateway", timeout = to(60), cond = function()
        local sm = T.first("BP_StormManager_C")
        local g = T.name(sm.EvolvedGatewayExit):match("[^%.]+$") or "none"
        log("PT|info guest gateway=%s", g)
        return g ~= "none"
    end })
    add({ run = sendDone })
    add({ wait = 3 })
    return steps
end
