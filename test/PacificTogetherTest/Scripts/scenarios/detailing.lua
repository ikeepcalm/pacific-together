-- G2 detailing + tinker hints: the guest changes the car's cosmetics and buys a hint with its own game's functions, the HOST applies them once.
--   detailing  the guest swaps a hood ornament from its pack into the car's HoodOrnament slot (ItemSlot:SwapSlotContents, what the Detailing
--              station's EquipSlot calls): the host's car slot holds the ornament, it stays, the guest's car shows it too (slot and part actor),
--              the guest's pack lost it (one copy)
--   hints      the guest does what the diagnose screen's RevealHint does (SetTypeKnown on the quirk's behavior, CurrencyAdjust(AnchorJuice, -cost),
--              IncrementHintsBought): the HOST's anchor energy fell by exactly one hint's cost, the host's quirk shows the hint as known, the guest
--              shows the same currency, known flag and hint count
-- Run: tools/run-test.ps1 -Scenario detailing -Fixture garage -Headless
-- Mutations: nodetailing (guestswap.lua's SwapSlotContents hook off), nohints (stations.lua's hint sync off).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function im() return T.first("BP_InventoryManager_C") end
    local function sm() return FindFirstOf("BP_StatusEffectManager_C") end
    local TAG = "Car.Equip.Cosmetics.HoodOrnament"
    local ORN = "IA_Cosmetic_Ornament_Basic_01"
    local ORNPATH = "/Game/Gameplay/Inventory/Items/Car/Cosmetic/Ornament/Basic_01/IA_Cosmetic_Ornament_Basic_01.IA_Cosmetic_Ornament_Basic_01"
    local CAPATH = "/Game/Gameplay/StatusEffects/Quirks/CA_AnchorJuice_Stable.CA_AnchorJuice_Stable"
    local function carSlot()
        local box = {}
        im():GetCarEquippedContainer(box)
        return box.Inventory_CarEquipped:GetSlot(FName(TAG))
    end
    local function carArch()
        local s = carSlot()
        if not alive(s) then return "noslot" end
        if s:GetNumItems() == 0 then return "empty" end
        return s:GetItem(0).Archetype:GetFName():ToString()
    end
    local function ornamentActors()
        local n = 0
        for _, a in ipairs(FindAllOf("BP_CarPart_Cosmetic_Base_C") or {}) do
            if alive(a) and not a:GetFullName():find("/Engine/Transient", 1, true) then n = n + 1 end
        end
        return n
    end
    local function packOrnaments()
        local n = 0
        local items = {}
        im().Inventory_Player:GetAllItems(items)
        for _, e in ipairs(items) do if e:get().Archetype:GetFName():ToString() == ORN then n = n + 1 end end
        return n
    end
    local function anchor() -- the stable anchor energy in the currency table
        local v
        im().CurrencyTable:ForEach(function(k, x) if k:get():GetFullName():find("CA_AnchorJuice_Stable", 1, true) then v = x:get() end end)
        return v or 0
    end
    local function cost() local o = {}; sm():GetHintCost(o); return o.Anchors or 0 end
    local function quirk() local q = sm().CarQuirks[1]; return alive(q) and q or nil end
    local function known(q)
        local o = {}
        q.QuirkBehavior:IsTypeKnown(1, o)
        return o.Known == true
    end

    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind] ~= nil
    end
    local function g(kind) has(kind); return got[kind] end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        local st = {}
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 20 })

        -- detailing
        add({ run = function()
            carSlot():RemoveAllItems({}) -- a clean slot on both sides
            st.base = ornamentActors()
            T.log("PT|info host baseline slot=%s ornament actors=%d", carArch(), st.base)
        end })
        add({ wait = 8 })
        add({ run = function() toGuest("t.go.detail") end })
        add({ check = "host_car_has_the_ornament", timeout = 90, cond = function() return carArch() == ORN end })
        add({ check = "host_ornament_stays", timeout = 40, cond = L.holds(10, function() return carArch() == ORN end) })
        add({ check = "guest_slot_and_pack_report", timeout = 90, cond = function() return g("t.d.slot") == ORN and g("t.d.pack") == "0" end })
        add({ check = "guest_car_shows_ornament_actor", timeout = 60, cond = function() local n = tonumber(g("t.d.actors")) or 0; return n > st.base and n == ornamentActors() end })

        -- hints
        add({ run = function()
            sm():DbgActEvt_RollRandomQuirk_Execute()
            sm().ConsecutiveHintsBought = 4 -- cost = count + 0.5: a hint that costs whole table units to measure (the first costs less than one)
            local ca = StaticFindObject(CAPATH)
            st.cost = cost()
            local a0 = anchor()
            im():CurrencyAdjust(ca, -st.cost) -- what one hint costs in table units (also proves there is enough to measure)
            st.unit = a0 - anchor()
            im():CurrencyAdjust(ca, st.cost * 4)
            T.log("PT|info host hint cost %s = %s table units (anchor %s)", tostring(st.cost), tostring(st.unit), tostring(anchor()))
        end })
        add({ check = "host_hint_cost_positive", timeout = 5, cond = function() return st.unit ~= nil and st.unit > 0 end })
        add({ check = "host_has_a_quirk", timeout = 20, cond = function() return quirk() ~= nil end })
        add({ wait = 15 }) -- the quirk list and currencies reach the guest
        add({ run = function()
            st.before, st.count0, st.known0 = anchor(), sm().ConsecutiveHintsBought, known(quirk())
            T.log("PT|info host before hint: anchor %s hints %s known %s", tostring(st.before), tostring(st.count0), tostring(st.known0))
            toGuest("t.go.hint")
        end })
        add({ check = "host_hint_not_known_before", timeout = 1, cond = function() return st.known0 == false end })
        add({ check = "host_quirk_shows_hint_known", timeout = 60, cond = function() return known(quirk()) end })
        add({ check = "host_anchor_fell_by_exactly_one_hint", timeout = 60, cond = L.holds(15, function()
            local now = anchor()
            if now ~= st.before - st.unit then T.log("PT|info host anchor %s (want %s)", tostring(now), tostring(st.before - st.unit)) return false end
            return true
        end) })
        add({ check = "host_counts_one_hint", timeout = 20, cond = function() return sm().ConsecutiveHintsBought == st.count0 + 1 end })
        add({ run = function() toGuest("t.hintdone") end })
        add({ check = "guest_anchor_equals_host", timeout = 60, cond = function() return tonumber(g("t.h.anchor")) == anchor() end })
        add({ check = "guest_keeps_hint_known", timeout = 40, cond = L.holds(10, function() return g("t.h.known") == "1" end) })
        add({ check = "guest_hint_count_equals_host", timeout = 40, cond = function() return tonumber(g("t.h.count")) == sm().ConsecutiveHintsBought end })
        add({ run = function() toGuest("t.done") end })
        add({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local function say(k, v) PTNative_MsgToHost(T.localPC():GetAddress(), k, v or "") end
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_go_detail", timeout = 400, cond = function() return has("t.go.detail") end })
    add({ run = function()
        local lib = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
        local inst = lib:CreateItemInstance(T.myPawn():GetWorld(), StaticFindObject(ORNPATH), 0)
        im().Inventory_Player:AddItem(inst, true)
        local pack = im().Inventory_Player
        local from
        for i = 0, pack:GetNumSlots() - 1 do
            local s = pack:GetSlot(i)
            if s:GetNumItems() > 0 and s:GetItem(0).Archetype:GetFName():ToString() == ORN then from = s break end
        end
        T.log("PT|info guest ornament in pack slot: %s, car slot %s", tostring(from ~= nil), carArch())
        if from then carSlot():SwapSlotContents(from) end
        T.log("PT|info guest after swap: car %s pack ornaments %d", carArch(), packOrnaments())
    end })
    add({ check = "guest_reports_detailing", timeout = 400, cond = function()
        say("t.d.slot", carArch())
        say("t.d.pack", tostring(packOrnaments()))
        say("t.d.actors", tostring(ornamentActors()))
        return has("t.go.hint")
    end })
    add({ run = function()
        local q = quirk()
        local ca = StaticFindObject(CAPATH)
        T.log("PT|info guest quirk %s cost %s anchor %s", tostring(q ~= nil), tostring(cost()), tostring(anchor()))
        -- the diagnose screen's RevealHint: mark the hint known, pay, count
        q.QuirkBehavior:SetTypeKnown(true, 1)
        im():CurrencyAdjust(ca, -cost())
        sm():IncrementHintsBought()
    end })
    add({ check = "guest_reports_hint", timeout = 400, cond = function()
        local q = quirk()
        say("t.h.anchor", tostring(anchor()))
        say("t.h.known", q and known(q) and "1" or "0")
        say("t.h.count", tostring(sm().ConsecutiveHintsBought))
        return has("t.done")
    end })
    return steps
end
