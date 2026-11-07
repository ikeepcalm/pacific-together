-- Replace the guest pawn during the previous pawn's delayed exit. Its timer must not repossess the old pawn.
return function(T)
    local S=require("scenarios.sessionlib")(T)
    local function car() return T.first("BP_CarManager_C").NewCarActor end
    local function attached(p)
        return p and p:IsValid() and p:GetAttachParentActor():IsValid()
    end
    if T.ROLE=="host" then
        local replacement, retained, monitor
        return {
            T.onMap("RB_MainMenu",90),
            {run=function() T.console("open /Game/Maps/RunProto/RB_Garage?listen") end},
            T.onMap("RB_Garage",90),
            {check="guest_joined",timeout=120,cond=function() return S.guestChar()~=nil end},
            {check="guest_seated",timeout=60,cond=function() return attached(S.guestChar()) end},
            {run=function()
                local g=S.guestChar()
                monitor=LoopInGameThreadWithDelay(1,function()
                    if not attached(g) and not replacement then
                        local pc=S.remotePCs()[1]
                        local p=g:K2_GetActorLocation()
                        replacement=require("UEHelpers").GetWorld():SpawnActor(g:GetClass(),
                            {X=p.X+100,Y=p.Y,Z=p.Z+50},{Pitch=0,Yaw=0,Roll=0})
                        assert(replacement and replacement:IsValid(),"replacement pawn missing")
                        pc:Possess(replacement)
                        ExecuteInGameThreadWithDelay(1000,function()
                            retained=pc.Pawn:IsValid() and pc.Pawn:GetAddress()==replacement:GetAddress()
                        end)
                        CancelDelayedAction(monitor)
                    end
                end)
                PTNative_MsgToGuest(S.remotePCs()[1]:GetAddress(),"t.seatepoch.go","")
            end},
            {check="old_exit_cannot_repossess_replacement_pawn",timeout=5,cond=function() return retained==true end},
            {wait=2},
            {run=function() PTNative_MsgToGuest(S.remotePCs()[1]:GetAddress(),"t.seatepoch.normal","") end},
            {check="ordinary_exit_restores_host_movement",timeout=30,cond=function()
                local g=S.guestChar()
                return PTNative_MsgPoll("t.seatepoch.normaldone")~=nil and g and not attached(g)
                    and g:GetActorEnableCollision() and g.CharacterMovement.MovementMode~=0
            end},
            {run=function()
                if monitor then CancelDelayedAction(monitor) end
                PTNative_MsgToGuest(S.remotePCs()[1]:GetAddress(),"t.seatepoch.done","")
            end},
        }
    end
    local function send(k) T.intent(k,"") end
    return {
        T.onMap("RB_MainMenu",90),
        {check="client_joined",timeout=180,cond=function() return T.netMode()=="client" and T.myPawn()~=nil and T.map()=="RB_Garage" end},
        {run=function()
            local p=car():K2_GetActorLocation()
            T.myPawn():K2_SetActorLocation({X=p.X+100,Y=p.Y-180,Z=p.Z+30},false,{},true)
            send("g.car.enter")
        end},
        {check="client_seated",timeout=60,cond=function() return attached(T.myPawn()) end},
        {check="reentry_requested",timeout=60,cond=function() return PTNative_MsgPoll("t.seatepoch.go")~=nil end},
        {run=function() send("g.car.exit") end},
        {check="normal_cycle_requested",timeout=30,cond=function() return PTNative_MsgPoll("t.seatepoch.normal")~=nil end},
        {run=function() send("g.car.enter") end},
        {check="replacement_can_enter",timeout=20,cond=function() return attached(T.myPawn()) end},
        {run=function() send("g.car.exit") end},
        {wait=2},
        {check="ordinary_exit_restores_client_movement",timeout=15,cond=function()
            local p=T.myPawn()
            return p and not attached(p) and p:GetActorEnableCollision() and p.CharacterMovement.MovementMode~=0
        end},
        {run=function() send("t.seatepoch.normaldone") end},
        {check="host_finished",timeout=60,cond=function() return PTNative_MsgPoll("t.seatepoch.done")~=nil end},
        {check="client_has_replacement_pawn",timeout=10,cond=function() return T.myPawn()~=nil and not attached(T.myPawn()) end},
    }
end
