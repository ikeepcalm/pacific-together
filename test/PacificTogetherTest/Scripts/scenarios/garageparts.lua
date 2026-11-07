-- Actual damaged car parts, the garage wreck, saved vegetation and passenger hood filtering.
return function(T)
    local L=require('scenarios.sessionlib')(T)
    local ids=assert(loadfile('ue4ss/Mods/PacificTogether/Scripts/ids.lua'))()
    local got={};local function poll()while true do local k,d=PTNative_MsgPoll('t.gparts.');if not k then return end;got[k:sub(10)]=d end end
    local function has(k)poll();return got[k]~=nil end
    local function send(k,d)
        if T.ROLE=='host'then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),'t.gparts.'..k,d or '1')
        else PTNative_MsgToHost(T.localPC():GetAddress(),'t.gparts.'..k,d or '1')end
    end
    local function live(a)return a and a:IsValid()and not a:HasAnyInternalFlags(EInternalObjectFlags.PendingKill)end
    local function real(a)return live(a)and a:GetFullName():find('/Game/Maps',1,true)end
    local function body()
        for _,a in ipairs(FindAllOf('LootableTemplate')or{})do if real(a)and a:GetClass():GetFName():ToString()=='BP_Template_GovCar_01_C'then return a end end
    end
    local function trunk(b)
        for _,a in ipairs(FindAllOf('LootableTemplatePart')or{})do
            if real(a)and live(a:GetAttachParentActor())and a:GetAttachParentActor():GetAddress()==b:GetAddress()
                and a:GetClass():GetFName():ToString()=='BP_TemplatePart_Trunk_Locked_C'then return a end
        end
    end
    local function box(a)
        if live(a.MyContentsActor)then a=a.MyContentsActor end
        assert(live(a.ItemInstance)and a.ItemInstance:IsA(StaticFindObject('/Script/PenDriverInventory.ItemInstance')))
        local o={};ids.bfl():GetInstanceContainer(a.ItemInstance,a,o);return live(o.Container)and o.Container
    end
    local function state(a)local o={};a:GetTrunkState(o);return o['Current State']end
    local function health(it)
        local o={{},{},{},{},{},{},{},{},{},{}}
        ids.bfl():GetHealth(it,T.world(),o[1],o[2],o[3],o[4],o[5],o[6],o[7],o[8],o[9],o[10]);return o[3].Health
    end
    local function wheel(c)
        local items={};c:GetAllItems(items)
        for _,w in ipairs(items)do local it=w:get();if live(it)and ids.path(it.Archetype):find('IA_Attach_Wheel_Basic',1,true)then return it end end
    end
    local function savedTree()
        local p={X=559.7,Y=-1482.9,Z=31.0}
        local function near(q)return(q.X-p.X)^2+(q.Y-p.Y)^2+(q.Z-p.Z)^2<25 end
        local mesh='/Game/Env/Forest/Trees/Pine/SM_Pine_Young_01.SM_Pine_Young_01'
        for _,c in ipairs(FindAllOf('FoliageInstancedStaticMeshComponent')or{})do if real(c)and live(c.StaticMesh)and ids.path2(c.StaticMesh)==mesh then
            for _,i in ipairs(c:GetInstancesOverlappingSphere(p,100,true))do local xf={};if c:GetInstanceTransform(i:get(),xf,true)and near(xf.Translation)then return true end end
        end end
        for _,a in ipairs(FindAllOf('BP_Crash_Complex_Foliage_Base_C')or{})do if real(a)and not a.IsBroken and live(a.BaseMesh)and live(a.BaseMesh.StaticMesh)then
            local s=a.InstanceSwappableData;local q,m
            if s.Initialized_13_A81C055B4B2DB6E0D27C5292D399C857 then q=s.InstanceTransform_11_06A4F5C7447701E17A7210BD5DE540B7.Translation;m=s.StaticMesh_8_8CBDF16941839081660D19B1C70D18EF
            else q=a:K2_GetActorLocation();m=a.BaseMesh.StaticMesh end
            if live(m)and ids.path2(m)==mesh and near(q)then return true end
        end end
        return false
    end
    local function hood()
        local car=T.first('BP_CarManager_C').NewCarActor;local list={};car:GetAttachedActors(list,true)
        for _,w in ipairs(list)do local a=w:get()
            if live(a)and a:GetClass():GetFName():ToString()=='BP_Panel_Base_C'and a.RootComponent.AttachParent:GetFName():ToString()=='SLOT_Hood'then return a end
        end
    end
    local function hc()
        local cls=StaticFindObject('/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_HealthComponent.BP_HealthComponent_C');assert(live(cls),'health class missing')
        for _,w in ipairs(hood():K2_GetComponentsByClass(cls))do return w:get()end
    end
    local function installedHealth()local o={{},{},{},{},{},{},{},{}};hc():GetHealth(table.unpack(o));return o[1].Health end
    local function panelMaterialsMatch(b)
        local paint=b.SelectedPaintPalette:GetCDO()['Paint Color Tint']
        local decal=b.SelectedDecalPalette:GetCDO()['Decal Diffuse Texture']
        local layers='/Game/BaseArt/LayerLibrary/Gameplay/ML_Palette_'
        local checked=0
        for _,w in ipairs(b:GetAllTemplateParts())do local part=w:get()
            if part:GetClass():GetFName():ToString()=='BP_TemplatePart_Panel_C'then
                for _,v in ipairs(part:K2_GetComponentsByClass(StaticFindObject('/Script/Engine.StaticMeshComponent')))do local mesh=v:get()
                    for i=0,mesh:GetNumMaterials()-1 do local m=mesh:GetMaterial(i)
                        local info=m:GetParameterInfo(0,FName('Palette_Paint_Color'),StaticFindObject(layers..'Paint.ML_Palette_Paint'))
                        if info.Index>=0 then
                            local c=m:K2_GetVectorParameterValueByInfo(info)
                            if math.abs(c.R-paint.R)>0.001 or math.abs(c.G-paint.G)>0.001 or math.abs(c.B-paint.B)>0.001 then return false end
                            checked=checked+1
                        end
                        local di=m:GetParameterInfo(0,FName('Palette_Decal_Diffuse_Texture'),StaticFindObject(layers..'Decal.ML_Palette_Decal'))
                        if di.Index>=0 and m:K2_GetTextureParameterValueByInfo(di):GetFullName()~=decal:GetFullName()then return false end
                    end
                end
            end
        end
        return checked>0
    end
    local blue='/Game/BaseArt/Palettes/Paints/BP_Palette_Paint_Generic_Blue.BP_Palette_Paint_Generic_Blue_C'
    local steps={};local function add(s)steps[#steps+1]=s end
    local b,t,c,storedAddress
    if T.ROLE=='host'then
        for _,s in ipairs(T.loadFixture('garage'))do add(s)end
        add({check='guest_joined',timeout=240,cond=function()return L.guestChar()~=nil end})
        add({check='saved_host_tree_already_absent',timeout=1,cond=function()return not savedTree()end})
        add({check='guest_ready',timeout=180,cond=function()return has('ready')end})
        if os.getenv('PT_VARIANT')=='foliage'then add({wait=3});return steps end
        add({run=function()
            b=assert(body());t=assert(trunk(b));c=assert(box(t),'wreck trunk container missing');c:RemoveAllItems()
            ids.setProps(t.ItemInstance,ids.path(t.ItemInstance.Archetype)..':h37.5')
            b.SelectedPaintPalette=assert(ids.asset(blue));b:SetupTintOnVehicleAndParts();send('paint')
        end})
        add({check='guest_palette_matches',timeout=20,cond=function()return has('painted')end})
        if os.getenv('PT_VARIANT')=='wreck'then add({wait=3});return steps end
        add({run=function()t.BP_LockedComponent:SetLockStrength(0);assert(state(t)~=0);send('unlocked')end})
        add({check='guest_lock_matches',timeout=20,cond=function()return has('unlocked')end})
        add({run=function()t.AnimStateOpened=true;t.OpenTrunkTimeline:PlayFromStart();send('opened')end})
        add({check='guest_pried_trunk_opens',timeout=20,cond=function()return has('opened')end})
        add({run=function()
            local h=t.MyContentsActor.Highlight;h:InteractPressed(T.myPawn());h:InteractReleased(T.myPawn())
            local path='/Game/Gameplay/Inventory/Items/Car/Wheels/Wheel_Basic_01/IA_Attach_Wheel_Basic'
            ids.applyLayout(c,'@0.0.0='..path..':h37.5*1')
            assert(wheel(c)and math.abs(health(wheel(c))-37.5)<0.01)
            send('layout',ids.layout(c))
        end})
        add({check='guest_trunk_grid_matches',timeout=20,cond=function()return has('layout')end})
        add({run=function()ids.setProps(wheel(c),ids.path(wheel(c).Archetype)..':h21.25');send('wear')end})
        add({check='guest_stored_part_wear_matches',timeout=15,cond=function()return has('wear')end})
        add({check='guest_grid_edit_preserved_on_host',timeout=30,cond=function()return has('edit')and ids.layout(c)==got.edit end})
                add({run=function()hc():SetHealth(37.5);assert(math.abs(installedHealth()-37.5)<0.01);send('installed')end})
        add({check='guest_installed_wear_matches',timeout=20,cond=function()return has('installed')end})
        add({run=function()send('done')end})
        add({check='passenger_checked',timeout=60,cond=function()return has('seat')end})
        add({wait=2});return steps
    end
    add(T.onMap('RB_MainMenu',90))
    add({check='guest_in_garage',timeout=240,cond=function()return T.map()=='RB_Garage'and T.netMode()=='client'and T.myPawn()~=nil end})
    add({check='saved_tree_removed_on_guest',timeout=120,cond=function()return not savedTree()end})
    add({run=function()send('ready')end})
    if os.getenv('PT_VARIANT')=='foliage'then add({wait=3});return steps end
    add({check='palette_changed_on_host',timeout=90,cond=function()return has('paint')end})
    add({check='wreck_uses_host_palette',timeout=20,cond=function()b=body();return b and #b.DynamicMaterialInstances > 0 and ids.path2(b.SelectedPaintPalette)==blue end})
    add({check='visible_panel_paint_and_decal_match',timeout=5,cond=function()return panelMaterialsMatch(b)end})
    add({run=function()t=assert(trunk(b));c=assert(box(t))end})
    add({check='wreck_part_health_matches',timeout=5,cond=function()return math.abs(health(t.ItemInstance)-37.5)<0.01 end})
    add({run=function()send('painted')end})
    if os.getenv('PT_VARIANT')=='wreck'then add({wait=3});return steps end
    add({check='host_unlock_received',timeout=30,cond=function()return has('unlocked')end})
    add({check='wreck_unlocked_on_guest',timeout=20,cond=function()return state(t)~=0 end})
    add({run=function()send('unlocked')end})
    add({check='host_open_received',timeout=30,cond=function()return has('opened')end})
    add({check='wreck_open_on_guest',timeout=20,cond=function()return t.AnimStateOpened==true end})
    add({run=function()local h=t.MyContentsActor.Highlight;h:InteractPressed(T.myPawn());h:InteractReleased(T.myPawn());send('opened')end})
    add({check='host_grid_received',timeout=30,cond=function()return has('layout')end})
    add({check='wreck_grid_and_health_match',timeout=20,cond=function()
        return ids.layout(c)==got.layout and wheel(c)and math.abs(health(wheel(c))-37.5)<0.01
    end})
    
    add({check='trunk_inventory_open',timeout=10,cond=function()local o={};T.first('BP_InventoryManager_C'):IsPlayerMenuOpen(o,{});return o.IsOpen==true end})
    add({wait=1})
    add({run=function()storedAddress=wheel(c):GetAddress();send('layout')end})
    add({check='host_wear_received',timeout=30,cond=function()return has('wear')end})
    add({check='stored_wheel_health_updated',timeout=15,cond=function()return wheel(c)and math.abs(health(wheel(c))-21.25)<0.01 end})
    add({run=function()if not os.getenv('PT_HEADLESS')then T.shot('wreck-health-open-inventory')end end})
    add({check='stored_item_identity_preserved',timeout=1,cond=function()return wheel(c):GetAddress()==storedAddress end})
    add({run=function()
        T.first('BP_InventoryManager_C'):RequestPlayerMenuClose();send('wear');local p=ids.path(wheel(c).Archetype)
        ids.applyLayout(c,'@1.0.0='..p..':h21.25*1');send('edit',ids.layout(c))
    end})
        add({check='host_installed_wear_received',timeout=30,cond=function()return has('installed')end})
    add({check='installed_part_health_matches',timeout=2,cond=function()local hp=installedHealth();T.log('PT|info installed health %.5f',hp);return math.abs(hp-37.5)<0.01 end})
    add({run=function()send('installed')end})
    add({check='host_confirmed',timeout=40,cond=function()return has('done')end})
    add({run=function()T.first('BP_CarManager_C').NewCarActor.SLOT_FrontLeftDoor:GetItemActor({}):StartEntry(false)end})
    add({check='guest_seated',timeout=30,cond=function()local p=T.myPawn():GetAttachParentActor();return live(p)and p:GetClass():GetFName():ToString()=='BP_PlayerCarNew_C'end})
    add({check='passenger_hood_not_highlighted',timeout=5,cond=function()return T.first('BP_HighlightManager_C'):PassesFilter(hood().Highlight)==false end})
    add({run=function()send('seat')end})
    return steps
end
