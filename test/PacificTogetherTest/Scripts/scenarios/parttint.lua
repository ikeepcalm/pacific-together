-- Installed -> guest hands -> guest drop -> host pickup/install -> host drop -> guest pickup/install.
return function(T)
    local L=require('scenarios.sessionlib')(T)
    local SLOT='Car.Equip.Body.DoorsFL'
    local TINT='/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_TintableComponent.BP_TintableComponent_C'
    local PAINT='/Game/BaseArt/Palettes/Paints/BP_Palette_Paint_Gov_Gray.BP_Palette_Paint_Gov_Gray_C'
    local DECAL='/Game/BaseArt/Palettes/Decals/BP_Palette_Decal_Arda_01.BP_Palette_Decal_Arda_01_C'
    local got={}
    local function has(k)
        while true do local n,d=PTNative_MsgPoll('t.');if not n then break end;got[n]=d end
        return got['t.tint.'..k]~=nil
    end
    local function send(k)
        if T.ROLE=='host' then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),'t.tint.'..k,'')
        else PTNative_MsgToHost(T.localPC():GetAddress(),'t.tint.'..k,'') end
    end
    local function slot()
        for _,a in ipairs(FindAllOf('BP_CarPart_Interactive_C')or{})do
            if T.inWorld(a)then local s,n={},{};a:GetSlot(s,n)
                if n.TagName:ToString()==SLOT then return a,s.ItemSlot end
            end
        end
    end
    local function installed()local _,s=slot();return s and s:GetNumItems()>0 and s:GetItem(0) or nil end
    local function im()return T.first('BP_InventoryManager_C')end
    local function inHand()
        local o={};local c=T.first('BP_MainCharacterManager_C'):GetCharacterActor();c:GetActiveHandItem(false,o)
        local h=o['Hand Item'];local it=h and h:IsValid()and h.Instance
        return it and it:IsValid()and it.Archetype:GetFName():ToString():find('Door',1,true)and it or nil
    end
    local function toHand()
        if inHand()then return end
        local m=im();local held={};m.Inventory_PlayerHand:GetAllItems(held)
        for _,w in ipairs(held)do local it=w:get();if not it.Archetype:GetFName():ToString():find('Door',1,true)then
            m.Inventory_PlayerHand:RemoveItem(it);assert(m.Inventory_Player:AddItem(it,true),'cannot stow test hand item')
        end end
        local c=m.Inventory_Player
        for i=0,c:GetNumSlots()-1 do local s=c:GetSlot(i)
            if s:GetNumItems()>0 and s:GetCurrentArchetype():GetFName():ToString():find('Door',1,true)then s:TransferStackIntoContainer(im().Inventory_PlayerHand,{});return end
        end
    end
    local reader
    local function tint(it)
        if not it then return nil end
        for _,c in ipairs(FindAllOf('BP_TintableComponent_C')or{})do
            if c:IsValid() and not c:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and c.Instance:IsValid() and c.Instance:GetAddress()==it:GetAddress()then return c end
        end
        if not reader or not reader:IsValid() then
            reader=T.localPC():AddComponentByClass(LoadAsset(TINT),false,{Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}},false)
        end
        reader:SetItemInstance(it,false)
        return reader
    end
    local function matches(it)
        local c=tint(it);if not c then return false end
        local p,t,d,v={},{},{},{};c:GetTintableProperties(p,t,d,v)
        T.log('PT|info tint item=%s paint=%s decal=%s enabled=%s',it.Archetype:GetFName():ToString(),p.Paint:GetFullName(),d.DecalPalette:GetFullName(),tostring(t.TintingEnabled))
        return v.Valid and p.Paint:IsValid() and d.DecalPalette:IsValid() and p.Paint:GetFullName():find(PAINT,1,true) and d.DecalPalette:GetFullName():find(DECAL,1,true) and t.TintingEnabled
    end
    local function loose()
        for _,a in ipairs(FindAllOf('BP_WorldItem_C')or{})do
            if T.inWorld(a)and a.Instance:IsValid()and a.Instance.Archetype:GetFName():ToString():find('Door',1,true)then return a end
        end
    end
    local function material(mesh)
        local mid=mesh:GetMaterial(0)
        if not mid:IsA(StaticFindObject('/Script/Engine.MaterialInstanceDynamic'))then return false end
        local layer=LoadAsset('/Game/BaseArt/LayerLibrary/Gameplay/ML_Palette_Paint.ML_Palette_Paint')
        local info=mid:GetParameterInfo(0,FName('Palette_Paint_Color'),layer)
        if info.Index<0 then return false end
        local actual=mid:K2_GetVectorParameterValueByInfo(info)
        local expected=LoadAsset(PAINT):GetCDO()['Paint Color Tint']
        if math.abs(actual.R-expected.R)+math.abs(actual.G-expected.G)+math.abs(actual.B-expected.B)>0.001 then return false end
        local dl=LoadAsset('/Game/BaseArt/LayerLibrary/Gameplay/ML_Palette_Decal.ML_Palette_Decal')
        local di=mid:GetParameterInfo(0,FName('Palette_Decal_Diffuse_Texture'),dl)
        return di.Index>=0 and mid:K2_GetTextureParameterValueByInfo(di):GetFullName()==LoadAsset(DECAL):GetCDO()['Decal Diffuse Texture']:GetFullName()
    end
    local function rendered(a)
        if not a then return false end
        for _,w in ipairs(a:K2_GetComponentsByClass(StaticFindObject('/Script/Engine.StaticMeshComponent')))do if material(w:get())then return true end end
        return false
    end
    local function mirrored()
        for _,a in ipairs(FindAllOf('StaticMeshActor')or{})do
            local sm=a.StaticMeshComponent.StaticMesh
            if T.inWorld(a)and sm:IsValid()and sm:GetFName():ToString():find('Door',1,true)and a:GetAttachParentActor():IsValid()and material(a.StaticMeshComponent)then return true end
        end
        return false
    end
    local function swap(action)local cm=T.first('BP_CarManager_C');local r={};cm['Swap Equipment'](cm,action,slot(),r);assert(r.Success,'swap failed')end
    local function drop()local a,b={},{};im():PlayerDropHandItem(a,b);assert(a['Drop Success'],'drop failed')end
    local function pickup()T.myPawn()['Pickup Actor'](T.myPawn(),assert(loose()),true)end
    local steps={};local function add(s)steps[#steps+1]=s end
    if T.ROLE=='host'then
        for _,s in ipairs(T.loadFixture('garage'))do add(s)end
        add({check='guest_joined',timeout=180,cond=function()return L.guestChar()~=nil end})
        add({check='baseline_active_before_swap',timeout=120,cond=function()
            local f=io.open('ue4ss/UE4SS.log','rb');if not f then return false end;local s=f:read('*a');f:close();return s:find('PT|net baseline applied',1,true)~=nil
        end})
        add({run=function()local c=assert(tint(installed()));c:SetPaint(LoadAsset(PAINT),{TagName=FName('None')});c:SetDecal(LoadAsset(DECAL),{TagName=FName('None')});c:SetTintingEnabled(true);send('painted')end})
        add({check='guest_carried_paint',timeout=60,cond=function()return has('carried')end})
        add({check='host_slot_removed_by_guest',timeout=15,cond=function()return installed()==nil end})
        add({check='guest_hand_mirror_material',timeout=20,cond=mirrored})
        add({run=function()send('drop')end})
        add({check='guest_drop_instance_paint',timeout=30,cond=function()local a=loose();return a and matches(a.Instance)end})
        add({check='guest_drop_rendered_paint_decal',timeout=10,cond=function()return rendered(loose())end})
        add({run=function()pickup();toHand()end})
        add({check='host_pickup_keeps_paint',timeout=15,cond=function()toHand();return matches(inHand())end})
        add({run=function()swap(0)end})
        add({check='host_install_keeps_paint',timeout=15,cond=function()return matches(installed())end})
        add({run=function()swap(1);toHand();drop();send('hostdrop')end})
        add({check='guest_roundtrip_finished',timeout=90,cond=function()return has('done')end})
        add({check='guest_install_reaches_host_with_paint',timeout=15,cond=function()return matches(installed())end})
    else
        add(T.onMap('RB_MainMenu',90))
        add({check='client_joined',timeout=240,cond=function()return T.netMode()=='client'and T.map()=='RB_Garage'and T.cls(T.myPawn())==T.CHAR end})
        add({check='installed_host_paint',timeout=180,cond=function()return has('painted')and matches(installed())end})
        add({run=function()swap(1);toHand()end})
        add({check='removed_part_keeps_paint',timeout=15,cond=function()toHand();return matches(inHand())end})
        add({run=function()send('carried')end})
        add({check='host_verified_hand',timeout=60,cond=function()return has('drop')end})
        add({run=drop})
        add({check='host_drop_instance_paint',timeout=120,cond=function()local a=loose();return has('hostdrop')and a and matches(a.Instance)end})
        add({check='host_drop_rendered_paint_decal',timeout=15,cond=function()return rendered(loose())end})
        add({run=function()pickup();toHand()end})
        add({check='guest_pickup_keeps_paint',timeout=15,cond=function()toHand();return matches(inHand())end})
        add({run=function()swap(0)end})
        add({check='guest_install_keeps_paint',timeout=15,cond=function()return matches(installed())end})
        add({run=function()send('done')end});add({wait=5})
    end
    return steps
end
