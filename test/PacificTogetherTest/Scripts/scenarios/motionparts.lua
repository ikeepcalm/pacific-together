-- Four hand-play regressions, without a save fixture: lockers, wheel visuals, passenger filter and real thrown-item motion.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local K = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local got, sent = {}, {}
    local function poll() while true do local k,d=PTNative_MsgPoll("t.motion."); if not k then return end; got[k]=d end end
    local function send(k,d)
        if sent[k] then return end
        sent[k] = true
        if T.ROLE=="host" then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.motion."..k,d or "1")
        else PTNative_MsgToHost(T.localPC():GetAddress(),"t.motion."..k,d or "1") end
    end
    local function alive(a) return a and a:IsValid() and not a:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function car() return T.first("BP_CarManager_C").NewCarActor end
    local function spawner(suffix)
        for _,s in ipairs(FindAllOf("BP_GarageInstallation_Spawner_C") or {}) do
            if alive(s) and not s:GetFullName():find("/Engine/Transient",1,true) and s:GetFName():ToString()=="BP_GarageStation_PartStorage_"..suffix then return s end
        end
    end
    local function cabinet(suffix) local s=spawner(suffix);if not s then return end; local o={};s:GetUpgradeActor(o);return o["Upgrade Actor"] end
    local function lockerBox(suffix)
        local c=cabinet(suffix).NamedPartsContainer
        return {
            GetNumItems=function()local items={};c:GetAllItems(items);return #items end,
            AddItem=function(_,inst)return c:AddItem(FName('Stations.Slots.01'),inst,false)end,
            RemoveAllItems=function()return c:RemoveAllItems()end,
        }
    end
    local function bodies(a,fn)
        for _,v in ipairs(a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))) do fn(v:get()) end
    end
    local function wheelMesh()
        for _,v in ipairs(car():K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent"))) do
            local m=v:get();if m:GetFName():ToString()=="FrontLeftWheel_Mesh" then return m end
        end
    end
    local function windshield()
        for _,a in ipairs(FindAllOf("BP_CarPart_Interactive_C") or {}) do
            if T.inWorld(a) then local s={};a:GetSlotComponent(s)
                if alive(s.SlotSceneComponent) and s.SlotSceneComponent:GetFName():ToString()=="SLOT_Windshield" then return a.Highlight end
            end
        end
    end
    local function spawn(arch,p,v)
        local a=T.first("InventorySystem"):SpawnItemActor(T.world(),{Rotation={X=0,Y=0,Z=0,W=1},Translation=p,Scale3D={X=1,Y=1,Z=1}},arch,0,0)
        assert(alive(a),"item did not spawn")
        bodies(a,function(c)
            T.log("PT|info thrown body %s physics=%s",c:GetFName():ToString(),tostring(c:IsSimulatingPhysics(FName("None"))))
            if c:IsSimulatingPhysics(FName("None")) then c:SetPhysicsLinearVelocity(v,false,FName("None")) end
        end)
        return a
    end
    local function report(k) return function() poll();return got["t.motion."..k]~=nil end end
    if T.ROLE=="host" then
        local item,origin,arch,drive,guestDrop,dropWatch,maxDropV,itemDrive,smoothItem,smoothOrigin
        maxDropV = 0
        local function findGuestDrop()
            for _,a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
                if T.inWorld(a) and alive(a.Instance) and a~=item and a:GetAddress()~=item:GetAddress() and a.Instance.Archetype:GetAddress()==arch:GetAddress() then
                    local p=a:K2_GetActorLocation();if (p.X-origin.X)^2+(p.Y-origin.Y)^2<2000^2 then guestDrop=a;return true end
                end
            end
        end
        return {
            T.onMap("RB_MainMenu",90),
            {run=function() T.console("open /Game/Maps/RunProto/RB_Garage?listen") end}, T.onMap("RB_Garage",90),
            {check="guest_joined",timeout=120,cond=function() return L.guestChar()~=nil end}, {wait=12},
            {run=function()
                local up=LoadAsset("/Game/Gameplay/CarGarage/Stations/StorageLocker/UP_Garage_InventoryParts_Install.UP_Garage_InventoryParts_Install_C")
                for _,n in ipairs({"BackYard","Fence"}) do spawner(n):InstallSpecificUpgrade(up,true) end
            end},
            {check="both_host_lockers_spawned",timeout=20,cond=function() return alive(cabinet("BackYard")) and alive(cabinet("Fence")) end},
            {check="both_guest_lockers_spawned",timeout=60,cond=report("lockers")},
            {check="guest_baseline_applied_before_locker_transfer",timeout=180,cond=function()
                local f=io.open("ue4ss/UE4SS.log","rb");if not f then return false end
                local text=f:read("a");f:close();return text:find("PT|net baseline applied",1,true)~=nil
            end},
            {run=function()
                local ids=assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/ids.lua"))()
                local arch=ids.archetype("/Game/Gameplay/Inventory/Items/Car/Wheels/Wheel_Spare_01/IA_Attach_Wheel_Spare")
                local inst=StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary"):CreateItemInstance(T.world(),arch,0)
                assert(lockerBox("BackYard"):AddItem(inst,true),"locker rejected wheel")
                send("locker_item")
            end},
            {check="guest_locker_contents_received",timeout=30,cond=report("locker_item_ok")},
            {check="guest_locker_removal_reaches_host",timeout=30,cond=function() return lockerBox("BackYard"):GetNumItems()==0 end},
            {run=function()
                local c=car();c:ManualSetIgnition_NoAnim(2);c:ManualActivate_Gearbox(0,true);c.VehicleController:SetParkingBrakeActive(false)
                drive=LoopInGameThreadWithDelay(16,function() c:AccelerateBrake(0.2);c:SteerLeftRight(0.7) end)
                send("wheels")
            end},
            {check="guest_wheel_roll_and_steering",timeout=15,cond=report("wheels_ok")},
            {run=function()
                CancelDelayedAction(drive);local c=car();c:AccelerateBrake(0);c:SteerLeftRight(0);c.Chassis:SetSimulatePhysics(false);c.VehicleController:SetComponentTickEnabled(false)
                for _,a in ipairs(FindAllOf("BP_CarPart_Wheel_Base_C") or {}) do if alive(a.Instance) and alive(a:GetAttachParentActor()) then arch=a.Instance.Archetype;break end end
                assert(arch,"no wheel archetype")
                local p=c:K2_GetActorLocation();origin={X=p.X,Y=p.Y+500,Z=p.Z+600}
                send("arch",arch:GetFullName():gsub("^%S+ ",""));send("origin",string.format("%f,%f,%f",origin.X,origin.Y,origin.Z))
                item=spawn(arch,origin,{X=100,Y=0,Z=100})
            end},
            {check="guest_saw_airborne_motion",timeout=10,cond=report("airborne")},
            {wait=8},
            {run=function()
                local p=item:K2_GetActorLocation();assert(p.Z<origin.Z-200,"item never fell")
                bodies(item,function(c) c:SetSimulatePhysics(false) end)
                local r=item:K2_GetActorRotation();send("landed",string.format("%f,%f,%f,%f,%f,%f",p.X,p.Y,p.Z,r.Pitch,r.Yaw,r.Roll))
            end},
            {check="guest_same_landing_pose",timeout=10,cond=report("landed_ok")},
            {run=function()
                local p=item:K2_GetActorLocation()
                smoothOrigin={X=p.X,Y=p.Y+800,Z=p.Z+300}
                smoothItem=spawn(arch,smoothOrigin,{X=0,Y=0,Z=0})
                bodies(smoothItem,function(c) c:SetSimulatePhysics(false) end)
                send("smooth",string.format("%f,%f,%f",smoothOrigin.X,smoothOrigin.Y,smoothOrigin.Z))
            end},
            {wait=1},
            {run=function()
                local start=os.clock()
                itemDrive=LoopInGameThreadWithDelay(16,function()
                    local x=math.min(os.clock()-start,5)*180
                    smoothItem:K2_SetActorLocation({X=smoothOrigin.X+x,Y=smoothOrigin.Y,Z=smoothOrigin.Z},false,{},true)
                end)
            end},
            {wait=5.5},
            {run=function() CancelDelayedAction(itemDrive);send("smooth_end") end},
            {check="guest_item_smooth_during_motion",timeout=15,cond=report("smooth_ok")},
            {run=function()
                local p=L.guestChar():K2_GetActorLocation();origin={X=p.X+30,Y=p.Y,Z=p.Z+300}
                dropWatch=LoopInGameThreadWithDelay(16,function()
                    if not guestDrop then findGuestDrop() end
                    if alive(guestDrop) then bodies(guestDrop,function(c) maxDropV=math.max(maxDropV,c:GetPhysicsLinearVelocity(FName("None")).X) end) end
                end)
                send("throw",string.format("%f,%f,%f",origin.X,origin.Y,origin.Z))
            end},
            {check="guest_throw_reaches_host",timeout=10,cond=findGuestDrop},
            {check="guest_throw_keeps_velocity",timeout=2,cond=function() return maxDropV>200 end},
            {check="guest_throw_seen_airborne",timeout=10,cond=report("throw_airborne")},
            {wait=5},
            {run=function()
                bodies(guestDrop,function(c) c:SetSimulatePhysics(false) end)
                local p,r=guestDrop:K2_GetActorLocation(),guestDrop:K2_GetActorRotation()
                assert(p.Z<origin.Z-100,"guest throw did not fall")
                send("throw_landed",string.format("%f,%f,%f,%f,%f,%f",p.X,p.Y,p.Z,r.Pitch,r.Yaw,r.Roll))
            end},
            {check="guest_throw_same_landing_pose",timeout=10,cond=report("throw_landed_ok")},
            {run=function() send("pickup") end},
            {check="guest_pickup_removes_host_item",timeout=10,cond=function() return not alive(guestDrop) end},
            {run=function() CancelDelayedAction(dropWatch);send("seat");end},
            {check="passenger_key_highlight_preserved",timeout=30,cond=report("key_selected")},
            {check="passenger_shifter_preserved_windshield_blocked",timeout=30,cond=report("filter")},
            {check="windshield_available_after_exit",timeout=30,cond=report("restored")},
            {run=function() send("done") end}, {wait=2},
        }
    end
    local arch,origin,seen,lastZ,airSamples,wheelStart,rolled,steered,thrown,filterSent,exitSent= nil,nil,nil,nil,0,nil,false,false,false,false,false
    local observer, seatRequested, keySelected, localDropAddr, picked
    local lastMoveAt, maxMoveGap, moveSamples = nil, 0, 0
    local smoothLast, smoothFrames, smoothMoved, smoothFirst, smoothEnd, smoothReported, smoothOrigin = nil, 0, 0, nil, nil, false, nil
    local function xyz(s) local x,y,z=s:match("([^,]+),([^,]+),([^,]+)");return {X=tonumber(x),Y=tonumber(y),Z=tonumber(z)} end
    local function tick()
        poll()
        if alive(cabinet("BackYard")) and alive(cabinet("Fence")) then send("lockers") end
        if got["t.motion.locker_item"] and not sent.locker_item_ok and alive(cabinet("BackYard")) then
            local c=lockerBox("BackYard")
            if c:GetNumItems()>0 then send("locker_item_ok");c:RemoveAllItems() end
        end
        if got["t.motion.wheels"] then
            local r=K:InverseTransformRotation(car():GetTransform(),wheelMesh():K2_GetComponentRotation())
            if wheelStart then
                if math.abs((r.Pitch-wheelStart.Pitch+180)%360-180)>10 then rolled=true end
                if math.abs((r.Yaw-wheelStart.Yaw+180)%360-180)>3 then steered=true end
                if rolled and steered then send("wheels_ok") end
            else wheelStart={Pitch=r.Pitch,Yaw=r.Yaw} end
        end
        if got["t.motion.arch"] then arch=StaticFindObject(got["t.motion.arch"]) end
        if got["t.motion.origin"] and not origin then origin=xyz(got["t.motion.origin"]) end
        if got["t.motion.smooth"] and not smoothOrigin then smoothOrigin=xyz(got["t.motion.smooth"]);origin=smoothOrigin;seen=nil;lastZ=nil end
        if origin and not alive(seen) then
            for _,a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
                if T.inWorld(a) and alive(a.Instance) and a.Instance.Archetype:GetAddress()==arch:GetAddress() then local p=a:K2_GetActorLocation()
                    local radius=(smoothOrigin and not thrown) and 300 or 1500
                    if (p.X-origin.X)^2+(p.Y-origin.Y)^2<radius^2 then seen=a;break end
                end
            end
        end
        if alive(seen) then
            local p=seen:K2_GetActorLocation()
            if got["t.motion.smooth"] and not got["t.motion.smooth_end"] then
                if smoothLast then
                    smoothFrames=smoothFrames+1
                    if math.abs(p.X-smoothLast)>.05 then
                        smoothMoved=smoothMoved+1
                        smoothFirst=smoothFirst or smoothFrames; smoothEnd=smoothFrames
                    end
                end
                smoothLast=p.X
            elseif got["t.motion.smooth_end"] and not smoothReported then
                smoothReported=true
                local span=smoothFirst and smoothEnd-smoothFirst+1 or 0
                T.log("PT|info item smooth frames=%d moving=%d span=%d",smoothFrames,smoothMoved,span)
                if span>=20 and smoothMoved/span>=.65 then send("smooth_ok") end
            end
            if p.Z>origin.Z-300 and lastZ and math.abs(lastZ-p.Z)>1 then
                airSamples=airSamples+1
                local now=os.clock()
                if lastMoveAt then maxMoveGap=math.max(maxMoveGap,now-lastMoveAt) end
                lastMoveAt,moveSamples=now,moveSamples+1
            end
            lastZ=p.Z
            if airSamples>=3 then send(thrown and "throw_airborne" or "airborne") end
            local landed=got[thrown and "t.motion.throw_landed" or "t.motion.landed"]
            if landed then
                local f={};for v in landed:gmatch("[^,]+") do f[#f+1]=tonumber(v) end
                local r=seen:K2_GetActorRotation();local physical=false;bodies(seen,function(c) physical=physical or c:IsSimulatingPhysics(FName("None")) end)
                if thrown then assert(seen:GetAddress()==localDropAddr,"guest throw was replaced instead of adopted") end
                if not physical and (p.X-f[1])^2+(p.Y-f[2])^2+(p.Z-f[3])^2<9 and math.abs((r.Pitch-f[4]+180)%360-180)<2 and math.abs((r.Roll-f[6]+180)%360-180)<2 then
                    if not sent[thrown and "throw_landed_ok" or "landed_ok"] then T.log("PT|info item flight %s samples=%d max_move_gap=%.3fs",thrown and "guest" or "host",moveSamples,maxMoveGap) end
                    send(thrown and "throw_landed_ok" or "landed_ok")
                end
            end
        end
        if got["t.motion.throw"] and not thrown then
            thrown=true;origin=xyz(got["t.motion.throw"]);seen=nil;lastZ=nil;airSamples=0;got["t.motion.landed"]=nil
            lastMoveAt,maxMoveGap,moveSamples=nil,0,0
            localDropAddr=spawn(arch,origin,{X=650,Y=0,Z=180}):GetAddress()
        end
        if got["t.motion.pickup"] and alive(seen) and not picked then
            picked=true;T.myPawn()["Pickup Actor"](T.myPawn(),seen,true)
        end
        if got["t.motion.seat"] and not filterSent then
            local p=T.myPawn()
            if not alive(p:GetAttachParentActor()) then
                if not seatRequested then T.intent("g.car.enter","");seatRequested=true end
            else
                local hm,h=T.first("BP_HighlightManager_C"),car().Highlight_Key
                if keySelected then
                    for _,a in ipairs(FindAllOf("BP_Carpart_Shifter_Base_C") or {}) do if alive(a:GetAttachParentActor()) then h=a.Highlight;break end end
                end
                if alive(h) and h.HighlightCollision[1]:IsValid() then
                    local pc=T.localPC();pc:SetControlRotation(K:FindLookAtRotation(pc.PlayerCameraManager:GetCameraLocation(),h.HighlightCollision[1]:K2_GetComponentLocation()))
                    if alive(hm.CurrentHighlight) and hm.CurrentHighlight:GetAddress()==h:GetAddress() then
                        if not keySelected then keySelected=true;send("key_selected")
                        elseif not hm:PassesFilter(windshield()) then filterSent=true;send("filter");T.intent("g.car.exit","") end
                    end
                end
            end
        end
        if filterSent and not alive(T.myPawn():GetAttachParentActor()) then
            local hm=T.first("BP_HighlightManager_C")
            if hm:PassesFilter(windshield()) then send("restored") end
        end
    end
    return {T.onMap("RB_MainMenu",90), {check="client_in_garage",timeout=240,cond=function() return T.netMode()=="client" and T.map()=="RB_Garage" end},
        {run=function() observer=LoopInGameThreadWithDelay(16,tick) end},
        {check="motion_regressions_finished",timeout=240,cond=function() return got["t.motion.done"]~=nil end},
        {run=function() CancelDelayedAction(observer) end}}
end
