-- Shared pneumatic mail: discard guest defaults, mirror deposits and withdrawals without local physical launches.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local keys = { "Inventory_Tubes_In", "Inventory_Tubes_Out", "Inventory_GarageTransfer" }
    local function inv(k) return T.first("BP_InventoryManager_C")[k] end
    local function count(k) local a = {}; inv(k):GetAllItems(a); return #a end
    local function sum() local a = {}; for _, k in ipairs(keys) do a[#a + 1] = tostring(count(k)) end; return table.concat(a, ",") end
    local got = {}
    local function has(k)
        while true do local a,b=PTNative_MsgPoll("t."); if not a then break end; got[a]=b end
        return got[k] ~= nil
    end
    local function send(k, v)
        if T.ROLE == "host" then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "")
        else PTNative_MsgToHost(T.localPC():GetAddress(), k, v or "") end
    end
    local steps = T.ROLE == "host" and T.loadFixture("garage") or { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps+1]=s end
    add({check="mail_connected",timeout=400,cond=function()
        return T.map()=="RB_Garage" and (T.ROLE=="host" and L.guestChar()~=nil or T.ROLE=="client" and T.netMode()=="client")
    end})
    if T.ROLE == "host" then
        add({wait=15})
        add({run=function() send("t.baseline",sum()) end})
        add({check="guest_mail_matches_save",timeout=45,cond=function() return has("t.equal") end})
        add({run=function()
            local lib=StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary")
            local a=StaticFindObject("/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel")
            inv(keys[1]):AddItem(lib:CreateItemInstance(T.world(),a,0),true)
            send("t.deposit",sum())
        end})
        add({check="guest_receives_host_mail",timeout=45,cond=function() return has("t.received") end})
        add({check="host_receives_guest_withdrawal",timeout=45,cond=function() return has("t.withdrawn") and count(keys[1])==tonumber(got["t.withdrawn"]) end})
        add({run=function() send("t.done") end})
    else
        add({check="guest_has_host_baseline",timeout=90,cond=function() return has("t.baseline") end})
        add({check="guest_purges_extra_mail",timeout=45,cond=function() return sum()==got["t.baseline"] end})
        add({run=function() send("t.equal") end})
        add({check="guest_sees_deposit",timeout=45,cond=function() return has("t.deposit") and sum()==got["t.deposit"] end})
        add({run=function()
            send("t.received")
            local a={}; inv(keys[1]):GetAllItems(a); inv(keys[1]):RemoveItem(a[#a]:get()); send("t.withdrawn",tostring(count(keys[1])))
        end})
        add({check="guest_tube_does_not_launch_duplicates",timeout=10,cond=function()
            local found=false
            for _, a in ipairs(FindAllOf("BP_GarageTransferTube_C") or {}) do
                if a:IsValid() then found=true; if a:IsActorTickEnabled() then return false end end
            end
            return found
        end})
        add({check="mail_roundtrip_done",timeout=45,cond=function() return has("t.done") end})
    end
    add({wait=5})
    return steps
end
