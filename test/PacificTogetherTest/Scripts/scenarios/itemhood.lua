-- Guest opens and shuts the hood; a damaged flare survives host drop, pickup and guest drop.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local ids = assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/ids.lua"))()
    local path = "/Game/Gameplay/Inventory/Items/Tools/Flare/IA_Tool_Throw_Flare"
    local got, sent = {}, {}
    local function alive(a) return a and a:IsValid() and not a:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function poll() while true do local k,d=PTNative_MsgPoll("t.itemhood.");if not k then return end;got[k]=d end end
    local function send(k,d)
        if sent[k] then return end;sent[k]=true
        if T.ROLE=="host" then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.itemhood."..k,d or "1")
        else PTNative_MsgToHost(T.localPC():GetAddress(),"t.itemhood."..k,d or "1") end
    end
    local function has(k) poll();return got["t.itemhood."..k]~=nil end
    local function hood()
        local car=T.first("BP_CarManager_C").NewCarActor;local list={};car:GetAttachedActors(list,true)
        for _,w in ipairs(list) do local a=w:get()
            if alive(a) and a:GetClass():GetFName():ToString()=="BP_Panel_Base_C" and a.RootComponent.AttachParent:GetFName():ToString()=="SLOT_Hood" then return a end
        end
    end
    local function opened() local o={};T.first("BP_CarManager_C"):GetDoorState(4,o);return o.Open end
    local function findNear(p)
        for _,a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
            if alive(a) and alive(a.Instance) and ids.path(a.Instance.Archetype)==path then local q=a:K2_GetActorLocation()
                if (q.X-p.X)^2+(q.Y-p.Y)^2+(q.Z-p.Z)^2<450^2 then return a end
            end
        end
    end
    local function damaged(a) return alive(a) and alive(a.Instance) and ids.spec(a.Instance):find(":d123",1,true)~=nil end
    local steps={};local function add(s) steps[#steps+1]=s end
    if T.ROLE=="host" then
        local item, pos
        for _,s in ipairs(T.loadFixture("garage")) do add(s) end
        add({check="guest_joined",timeout=240,cond=function() return L.guestChar()~=nil end})
        add({check="guest_baseline_applied",timeout=180,cond=function()
            local f=io.open("ue4ss/UE4SS.log","rb");if not f then return false end
            local s=f:read("a");f:close();return s:find("PT|net baseline applied",1,true)~=nil
        end})
        add({run=function() send("open") end})
        add({check="guest_opens_host_hood",timeout=30,cond=opened})
        add({run=function() send("close") end})
        add({check="guest_closes_host_hood",timeout=30,cond=function() return not opened() end})
        add({run=function()
            local p=L.guestChar():K2_GetActorLocation();pos={X=p.X+120,Y=p.Y,Z=p.Z+100}
            item=ids.system():SpawnItemActor(T.world(),{Rotation={X=0,Y=0,Z=0,W=1},Translation=pos,Scale3D={X=1,Y=1,Z=1}},ids.archetype(path),0,0)
            assert(alive(item) and alive(item.Instance));ids.setProps(item.Instance,path..":d123");assert(damaged(item))
            send("item",string.format("%f,%f,%f",pos.X,pos.Y,pos.Z))
        end})
        add({check="guest_sees_damaged_item",timeout=45,cond=function() return has("seen") end})
        add({check="guest_pickup_removes_host_item",timeout=45,cond=function() return not alive(item) end})
        add({check="guest_drop_preserves_host_durability",timeout=60,cond=function() poll();return got["t.itemhood.drop"] and damaged(findNear(pos)) end})
        add({run=function() send("done") end});add({wait=2});return steps
    end
    local item,pos
    add(T.onMap("RB_MainMenu",90))
    add({check="guest_in_garage",timeout=240,cond=function() return T.netMode()=="client" and T.map()=="RB_Garage" end})
    add({check="open_requested",timeout=180,cond=function() return has("open") and alive(hood()) end})
    add({run=function() hood():AttemptOpen() end})
    add({check="close_requested",timeout=60,cond=function() return has("close") end})
    add({run=function() hood():AttemptShut() end})
    add({check="damaged_item_arrived",timeout=90,cond=function()
        if not has("item") then return false end
        if not pos then local x,y,z=got["t.itemhood.item"]:match("([^,]+),([^,]+),([^,]+)");pos={X=tonumber(x),Y=tonumber(y),Z=tonumber(z)} end
        item=findNear(pos);return damaged(item)
    end})
    add({run=function() send("seen");T.myPawn()["Pickup Actor"](T.myPawn(),item,true) end})
    add({check="damaged_item_in_backpack",timeout=30,cond=function()
        local c=T.first("BP_InventoryManager_C").Inventory_Player;local a={};c:GetAllItems(a)
        for _,w in ipairs(a) do local i=w:get();if alive(i) and ids.spec(i)==path..":d123" then return true end end
    end})
    add({run=function()
        local m=T.first("BP_InventoryManager_C");local c=m.Inventory_Player;local slot
        for i=0,c:GetNumSlots()-1 do local s=c:GetSlot(i);if alive(s) and s:GetNumItems()>0 then local a={};s:GetItems(a)
            for _,w in ipairs(a) do local it=w:get();if alive(it) and ids.spec(it)==path..":d123" then slot=s;break end end
        end;if slot then break end end
        assert(slot);slot:TransferSingleIntoContainer(m.Inventory_PlayerHand)
        local a,b={},{};m:PlayerDropHandItem(a,b);assert(a["Drop Success"] and damaged(b["World Actor"]));send("drop")
    end})
    add({check="host_confirmed",timeout=100,cond=function() return has("done") end})
    return steps
end
