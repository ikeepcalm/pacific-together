-- PT lane craftcrash: guest crafts through the backpack crafting UI path ~30 s after a death respawn (friend session crash, AV 0x100).
-- Run: tools/run-test.ps1 -Scenario craftcrash -Fixture zone -Headless
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind]
    end
    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ check = "host_guest_done", timeout = 600, cond = function() return has("t.done") ~= nil end })
        return steps
    end
    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end })
    add({ wait = 12 })
    local RECIPE = "/Game/Gameplay/Inventory/Items/Tools/FixStatusEffect/FixElectronic/CR_Tool_Target_FixElectronics.CR_Tool_Target_FixElectronics"
    local function im() return T.first("BP_InventoryManager_C") end
    local function lib() return StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary") end
    local function bag() -- the recipe's materials into the backpack
        local r = StaticFindObject(RECIPE)
        local comps = r:GetRecipeRaw().Components
        for i = 1, #comps do
            local it = comps[i]:get().Item
            if it.Archetype:IsValid() then for _ = 1, it.Quantity do im().Inventory_Player:AddItem(lib():CreateItemInstance(T.world(), it.Archetype, 0), true) end end
        end
    end
    local function dump(tag)
        local m = im()
        for _, k in ipairs({ "Inventory_Player", "Inventory_PlayerHand", "Inventory_OverflowContainer", "Inventory_ActiveStations" }) do
            local ok, v = pcall(function() return m[k] end)
            local good = ok and v ~= nil and v:IsValid()
            T.log("PT|info %s %s valid=%s %s", tag, k, tostring(good), good and v:GetFullName() or "?")
        end
    end
    local function ui() -- the backpack menu's recipe list
        for _, l in ipairs(FindAllOf("UMG_CraftingUI_RecipeList_C") or {}) do
            if l:GetFullName():find("UMG_PlayerMenu_Main", 1, true) then return l end
        end
    end
    local function craftViaUI(tag, g)
        local m, l = im(), ui()
        m:SetActiveTier(3, g or false, g or false) -- the backpack menu: no garage, no car
        bag()
        local info = l.CurRecipeIngredients
        info:SetRecipe(StaticFindObject(RECIPE))
        T.log("PT|info %s craft button click", tag)
        info.UMG_CraftingUI_CraftButton:Craft()
        T.log("PT|info %s craft returned", tag)
    end
    local function owned()
        local o, n = {}, 0
        im():GetOwnedItems(true, true, true, o)
        for _, e in ipairs(o) do
            local a = e:get().Archetype
            if a:IsValid() and a:GetFName():ToString():find("IA_Tool_Target_FixElectronics", 1, true) then n = n + 1 end
        end
        return n
    end
    add({ run = function() dump("before"); craftViaUI("before") end })
    add({ check = "crafted_before_death", timeout = 5, cond = function() return owned() >= 1 end })
    add({ wait = 23 })
    add({ run = function()
        local h = T.first("BP_ResourceManager_C").PlayerHealth
        h:Adjust(T.first("BP_ResourceManager_C"), -h.Maximum)
    end })
    add({ check = "guest_backpack_emptied", timeout = 40, cond = function() return owned() == 0 end })
    add({ check = "guest_alive_again", timeout = 40, cond = function() return T.first("BP_MainCharacterManager_C"):IsPlayerAlive() end })
    add({ run = function() T.log("PT|info pawn after respawn %s", T.name(T.myPawn())) end })
    add({ wait = 30 })
    add({ run = function() dump("after"); craftViaUI("after") end })
    add({ check = "crafted_after_death", timeout = 5, cond = function() return owned() >= 1 end })
    add({ wait = 3 })
    add({ run = function() craftViaUI("after_car_garage", true); craftViaUI("after_again") end })
    add({ check = "crafted_twice_more", timeout = 5, cond = function() return owned() >= 3 end })
    add({ wait = 10 })
    add({ run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.done", "") end })
    return steps
end
