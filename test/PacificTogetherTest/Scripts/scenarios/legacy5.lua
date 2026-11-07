-- Core actions and old N drop payload, with one actual unmodified protocol-5 mod/native peer.
return function(T)
    local L=require("scenarios.sessionlib")(T)
    local got={}
    local function poll()while true do local k,d=PTNative_MsgPoll("t.legacy.");if not k then break end;got[k]=d end end
    local function send(k)PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.legacy."..k,"1")end
    local function car()return T.first("BP_CarManager_C").NewCarActor end
    local function attached(p)return p and p:IsValid() and p:GetAttachParentActor():IsValid()end
    if T.ROLE=="host" then
        local before={}
        return {
            T.onMap("RB_MainMenu",90),{run=function()T.console("open /Game/Maps/RunProto/RB_Garage?listen")end},T.onMap("RB_Garage",90),
            {check="legacy_guest_joined",timeout=120,cond=function()return L.guestChar()~=nil end},
            {check="legacy_guest_applied_full_baseline",timeout=100,cond=function()return PTNative_MsgPoll("t.legacy.baseline")~=nil end},{wait=2},
            {run=function()car():ManualSetIgnition_NoAnim(0);car():ManualActivate_Gearbox(1,true);send("seat")end},
            {check="legacy_passenger_enter",timeout=20,cond=function()return attached(L.guestChar())end},
            {run=function()send("ign")end},{check="legacy_passenger_ignition",timeout=10,cond=function()return T.first("BP_CarManager_C").CarIgnitionState==2 end},
            {run=function()send("gear")end},{check="legacy_passenger_drive_gear",timeout=10,cond=function()return not car().VehicleController:GetParkingBrakeActive() end},
            {run=function()send("exit")end},{check="legacy_passenger_exit",timeout=20,cond=function()return not attached(L.guestChar())end},
            {wait=2},
            {run=function()for _,a in ipairs(FindAllOf("BP_WorldItem_C")or{})do before[a:GetFullName()]=true end;send("drop")end},
            {check="legacy_drop_spawned_on_host",timeout=15,cond=function()
                for _,a in ipairs(FindAllOf("BP_WorldItem_C")or{})do
                    if T.inWorld(a) and a.Instance:IsValid() and not before[a:GetFullName()] and not attached(a) then return true end
                end
            end},
            {run=function()send("done")end},
        }
    end
    local done={}
    LoopInGameThreadWithDelay(16,function()
        poll()
        for _,k in ipairs({"seat","ign","gear","exit","drop"})do
            if got["t.legacy."..k] and not done[k] then
                done[k]=true
                if k=="drop" then
                    local arch
                    for _,a in ipairs(FindAllOf("BP_CarPart_Wheel_Base_C")or{})do if a:IsValid() and a.Instance:IsValid() then arch=a.Instance.Archetype;break end end
                    assert(arch);local p=T.myPawn():K2_GetActorLocation();p.Z=p.Z+150
                    T.first("InventorySystem"):SpawnItemActor(T.world(),{Rotation={X=0,Y=0,Z=0,W=1},Translation=p,Scale3D={X=1,Y=1,Z=1}},arch,0,0)
                else T.intent(k=="seat" and "g.car.enter" or k=="exit" and "g.car.exit" or "g.car.ctl",k=="ign" and "ign" or k=="gear" and "gear" or "") end
            end
        end
    end)
    return {T.onMap("RB_MainMenu",90),{check="legacy_client_joined",timeout=150,cond=function()return T.map()=="RB_Garage"end},
        {check="legacy_full_baseline_applied",timeout=100,cond=function()
            local f=io.open("ue4ss/UE4SS.log","r");if not f then return false end;local text=f:read("a");f:close()
            if not text:find("PT|loot guest purged",1,true)then return false end
            if not done.baseline then PTNative_MsgToHost(T.localPC():GetAddress(),"t.legacy.baseline","1");done.baseline=true end
            return true
        end},
        {check="legacy_interactions_finished",timeout=100,cond=function()poll();return got["t.legacy.done"]~=nil end}}
end
