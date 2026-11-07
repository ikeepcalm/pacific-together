-- Rendered integration: native newest-wins lane, actual wheel axle, passenger radio and host-only Lucky Junk Heap.
return function(T)
    local L=require("scenarios.sessionlib")(T)
    local K=StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local got,sent={},{}
    local function alive(a)return a and a:IsValid() and not a:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function poll()while true do local k,d=PTNative_MsgPoll("t.v2.");if not k then return end;got[k:sub(6)]=d end end
    local function send(k,d)
        if sent[k] then return end;sent[k]=true
        if T.ROLE=="host" then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.v2."..k,d or "1")
        else PTNative_MsgToHost(T.localPC():GetAddress(),"t.v2."..k,d or "1") end
    end
    local function report(k)return function()poll();return got[k]~=nil end end
    local function car()return T.first("BP_CarManager_C").NewCarActor end
    local function radio()for _,a in ipairs(FindAllOf("BP_CarPart_Internal_Radio_C") or {}) do if alive(a) and alive(a:GetAttachParentActor()) and a:GetAttachParentActor():GetAddress()==car():GetAddress() then return a end end end
    local function heap()return T.first("BP_Garage_LuckyJunkHeap_C") end
    local function track()local m=T.first("BP_MusicManager_C"):CurrentRadioTrack();return alive(m) and m:GetFName():ToString() end
    local function wheel(slot)
        for _,a in ipairs(FindAllOf("BP_CarPart_Wheel_Base_C") or {}) do if alive(a:GetAttachParentActor()) and a.AttachedSlotComponent:GetFName():ToString()==slot then return a.MainMesh end end
    end
    local function countItems()
        local center=heap():K2_GetActorLocation();local n=0
        for _,a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do if T.inWorld(a) and alive(a.Instance) then local p=a:K2_GetActorLocation()
            if (p.X-center.X)^2+(p.Y-center.Y)^2+(p.Z-center.Z)^2<2000^2 then n=n+1 end
        end end;return n
    end
    local function openFixtureGate()
        local name=heap():GetClass():GetFullName():gsub("^%S+ ","")..":K2_ShouldHighlight"
        RegisterHook(name,function()return true end) -- raw map has no tutorial completion; prize/economy code stays stock
    end
    if T.ROLE=="host" then
        local drive,beforeTrack,completed,spawnCount= nil,nil,0,nil
        local function setupHeap()
            openFixtureGate()
            local name=heap():GetClass():GetFullName():gsub("^%S+ ","")..":BndEvt__Highlight_K2Node_ComponentBoundEvent_2_OnHighlightInteract__DelegateSignature"
            RegisterHook(name,function()completed=completed+1;T.log("PT|info heap complete count %d",completed)end)
            local arch
            for _,a in ipairs(FindAllOf("BP_CarPart_Wheel_Base_C") or {}) do if alive(a.Instance) then arch=a.Instance.Archetype;break end end
            heap():ResetConsolationPrize() -- stock reset reopens the native one-shot consolation gate
            local c=heap().Highlight:GetCollisionCenter()
            local at={X=c.X+170,Y=c.Y,Z=c.Z+90}
            L.guestChar():K2_HandleSetCharacterLocation({Rotation={X=0,Y=0,Z=0,W=1},Translation=at,Scale3D={X=1,Y=1,Z=1}},false,false)
            send("heap",string.format("%s|%f|%f|%f",heap():GetFName():ToString(),at.X,at.Y,at.Z))
        end
        return {
            T.onMap("RB_MainMenu",90),{run=function()T.console("open /Game/Maps/RunProto/RB_Garage?listen")end},T.onMap("RB_Garage",90),
            {check="guest_joined",timeout=120,cond=function()return L.guestChar()~=nil end},{wait=12},
            {run=function()for i=1,100 do PTNative_MsgMotionToGuest(L.remotePCs()[1]:GetAddress(),"t.latest.drivev2",tostring(i)) end end},
            {check="native_discards_99_obsolete_poses",timeout=10,cond=report("latest")},
            {run=function()
                local c=car();c:ManualSetIgnition_NoAnim(2);c:ManualActivate_Gearbox(0,true);c.VehicleController:SetParkingBrakeActive(false)
                drive=LoopInGameThreadWithDelay(16,function()c:AccelerateBrake(.2);c:SteerLeftRight(.8)end);send("wheel")
            end},
            {check="rolling_wheel_axle_stays_on_native_axis_and_front_steers",timeout=20,cond=report("wheel")},
            {run=function()
                CancelDelayedAction(drive);local c=car();c:AccelerateBrake(0);c:SteerLeftRight(0);c:ManualActivate_Gearbox(1,true)
                T.first("BP_CarManager_C"):SetCarRadioOnOffState(false,true);T.first("BP_MusicManager_C"):SetRadioVolume(.4);send("seat")
            end},
            {check="passenger_native_radio_highlight",timeout=30,cond=report("radio_highlight")},
            {run=function()send("power")end},{check="passenger_toggles_radio",timeout=10,cond=function()return T.first("BP_CarManager_C").CarState_RadioOnOff end},
            {run=function()send("louder")end},{check="passenger_volume_up",timeout=10,cond=function()return T.first("BP_MusicManager_C").MusicVolume>.41 end},
            {run=function()send("quieter")end},{check="passenger_volume_down",timeout=10,cond=function()return T.first("BP_MusicManager_C").MusicVolume<.41 end},
            {check="audio_track_available",timeout=15,cond=function()beforeTrack=track();return beforeTrack~=nil end},
            {run=function()send("next")end},{check="passenger_changes_station",timeout=15,cond=function()return track()~=nil and track()~=beforeTrack end},
            {run=function()send("track",track());send("exit")end},
            {check="guest_hears_host_station",timeout=15,cond=report("track")},
            {check="guest_out_of_car",timeout=20,cond=report("out")},
            {run=setupHeap,tag="heap_setup"},
            {check="guest_native_heap_gameplay_delegate_blocked",timeout=10,cond=report("heap_blocked")},
            {check="guest_heap_interaction_completes_on_host_once",timeout=20,cond=function()return completed==1 end},
            {check="guest_sees_heap_animation",timeout=10,cond=report("heap_anim")},
            {wait=5},
            {check="duplicate_heap_request_does_not_repeat_reward",timeout=1,cond=function()return completed==1 end},
            {run=function()spawnCount=countItems();send("heap_count",tostring(spawnCount))end},
            {check="heap_dispensed_items",timeout=1,cond=function()return spawnCount>0 end},
            {check="heap_prizes_match_without_guest_dispenser",timeout=20,cond=report("heap_count")},
            {run=function()send("cancel")end},{wait=2},
            {check="cancelled_hold_does_not_dispense",timeout=1,cond=function()return completed==1 end},
            {run=function()send("stale")end},{wait=1},
            {check="previous_world_heap_token_rejected",timeout=1,cond=function()return completed==1 end},
            {run=function()send("done")end},{wait=2},
        }
    end
    local observer,latestCount= nil,0
    local samples,phase0,maxRoll,maxAxleZ,steerFrames=0,nil,0,0,0
    local seatSent,exitSent,heapKey,pressAt,released,cancelSent,staleSent=nil,nil,nil,nil,nil,nil,nil
    local function intent(action)T.intent("g.car.ctl",action)end
    local function tick()
        poll()
        while true do local k,d=PTNative_MsgPoll("t.latest.");if not k then break end;if k=="t.latest.drivev2" then latestCount=latestCount+1;if d=="100" and latestCount==1 then send("latest")end end end
        if got.wheel then
            local m=wheel("SLOT_Interior_FL_Wheel");local rear=wheel("SLOT_Interior_RL_Wheel")
            if alive(m) and alive(rear) then
                local r=K:InverseTransformRotation(car():GetTransform(),m:K2_GetComponentRotation());local axis=K:GetRightVector(r)
                local rr=K:InverseTransformRotation(car():GetTransform(),rear:K2_GetComponentRotation());local rearAxis=K:GetRightVector(rr)
                maxAxleZ=math.max(maxAxleZ,math.abs(axis.Z),math.abs(rearAxis.Z))
                local steer=math.deg(math.atan(-axis.X,axis.Y))
                if math.abs(steer-24)<1 and math.abs(rearAxis.X)<.01 then
                    steerFrames=steerFrames+1
                    local f=K:GetForwardVector(r);local phase=math.atan(-f.Z,f.X*math.cos(math.rad(steer))+f.Y*math.sin(math.rad(steer)))
                    phase0=phase0 or phase;maxRoll=math.max(maxRoll,math.abs((phase-phase0+math.pi)%(2*math.pi)-math.pi))
                end
                samples=samples+1
                if steerFrames>=20 and maxRoll>.3 and maxAxleZ<.01 then send("wheel")end
            end
        end
        if got.seat and not seatSent then seatSent=true;T.intent("g.car.enter","")end
        if seatSent and alive(T.myPawn():GetAttachParentActor()) then
            local r=radio();local pc=T.localPC()
            if r then
                pc:SetControlRotation(K:FindLookAtRotation(pc.PlayerCameraManager:GetCameraLocation(),r.Collision:K2_GetComponentLocation()))
                local hm=T.first("BP_HighlightManager_C")
                if alive(hm.CurrentHighlight) and hm.CurrentHighlight:GetAddress()==r.Highlight1:GetAddress() then
                    if r.Highlight1:IsHighlighted() then send("radio_highlight")end
                end
            end
        end
        for key,action in pairs({power="radio",louder="radio_louder",quieter="radio_quieter",next="radio_next"}) do if got[key] and not sent["acted_"..key] then sent["acted_"..key]=true;intent(action)end end
        if got.track and track()==got.track then send("track")end
        if got.exit and not exitSent then exitSent=true;T.intent("g.car.exit","")end
        if exitSent and not alive(T.myPawn():GetAttachParentActor()) then send("out")end
        if got.heap and not heapKey then
            local key,x,y,z=got.heap:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$");heapKey=key
            openFixtureGate()
            local h=heap();local before=PTNative_MuteCount()
            h["BndEvt__Highlight_K2Node_ComponentBoundEvent_2_OnHighlightInteract__DelegateSignature"](h,h.Highlight,nil)
            if PTNative_MuteCount()>before then send("heap_blocked")end
            T.myPawn():K2_HandleSetCharacterLocation({Rotation={X=0,Y=0,Z=0,W=1},Translation={X=tonumber(x),Y=tonumber(y),Z=tonumber(z)},Scale3D={X=1,Y=1,Z=1}},false,false)
            pressAt=os.clock()+1
        end
        if heapKey then
            local h=heap();local pc=T.localPC();pc:SetControlRotation(K:FindLookAtRotation(pc.PlayerCameraManager:GetCameraLocation(),h.Highlight:GetCollisionCenter()))
            if pressAt and os.clock()>=pressAt and not sent.heap_press then
                sent.heap_press=true;T.intent("g.heap.intent",heapKey.."|1|p");T.intent("g.heap.intent",heapKey.."|1|p")
            end
            if sent.heap_press and not released and os.clock()>pressAt+1.2 then released=true;T.intent("g.heap.intent",heapKey.."|2|r")end
            if h.GooChargeup:GetPlaybackPosition()>.05 or h.PopFx:GetPlaybackPosition()>.05 or h.DeniedTimeline:GetPlaybackPosition()>.05 then send("heap_anim")end
            if got.heap_count and countItems()==tonumber(got.heap_count) and not h.ItemDispenser:IsComponentTickEnabled() and not h.ItemDispenser:IsDispensingItems() then send("heap_count")end
            if got.cancel and not cancelSent then cancelSent=true;T.intent("g.heap.intent",heapKey.."|3|p");T.intent("g.heap.intent",heapKey.."|4|r")end
            if got.stale and not staleSent then staleSent=true;T.intent("g.heap.intent","previous_world|100|p")end
        end
    end
    return {T.onMap("RB_MainMenu",90),{check="client_in_garage",timeout=240,cond=function()return T.netMode()=="client" and T.map()=="RB_Garage"end},
        {run=function()observer=LoopInGameThreadWithDelay(16,tick)end},
        {check="integration_finished",timeout=240,cond=function()return got.done~=nil end},
        {run=function()CancelDelayedAction(observer)end}}
end
