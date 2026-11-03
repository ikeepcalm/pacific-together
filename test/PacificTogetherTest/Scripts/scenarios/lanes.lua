-- A real native bulk backlog must not hold control, while create/final stay FIFO.
return function(T)
    local L=require("scenarios.sessionlib")(T)
    local bulk,control,latest,created,final,report=0,nil,nil,false,false,nil
    local function poll()
        while true do
            local k,d=PTNative_MsgPoll("t.");if not k then break end
            if k=="t.bulk.lanes" then bulk=bulk+1
            elseif k=="t.control.lanes" then control=bulk
            elseif k=="t.latest.lanes" then latest=d
            elseif k=="t.object.create" then created=true
            elseif k=="t.object.final" then final=created
            elseif k=="t.lanes.report" then report=d end
        end
    end
    if T.ROLE=="host" then return {
        T.onMap("RB_MainMenu",90),{run=function()T.console("open /Game/Maps/RunProto/RB_Garage?listen")end},T.onMap("RB_Garage",90),
        {check="guest_joined",timeout=120,cond=function()return L.guestChar()~=nil end},{wait=12},
        {run=function()
            local pc=L.remotePCs()[1];local blob=string.rep("x",20000)
            for i=1,30 do assert(PTNative_MsgToGuest(pc:GetAddress(),"t.bulk.lanes",blob)) end
            assert(PTNative_MsgToGuest(pc:GetAddress(),"t.object.create","W1"))
            assert(PTNative_MsgToGuest(pc:GetAddress(),"t.object.final","W1"))
            assert(PTNative_MsgToGuest(pc:GetAddress(),"t.control.lanes","control"))
            for i=1,100 do assert(PTNative_MsgMotionToGuest(pc:GetAddress(),"t.latest.lanes",tostring(i))) end
        end},
        {check="control_bypasses_bulk_and_object_dependency_stays_ordered",timeout=90,cond=function()poll();return report=="ok"end},
    }end
    return {
        T.onMap("RB_MainMenu",90),{check="joined",timeout=120,cond=function()return T.map()=="RB_Garage"end},
        {check="control_received_before_bulk_finishes",timeout=90,cond=function()poll();return control~=nil and control<30 end},
        {check="motion_is_newest_snapshot",timeout=20,cond=function()poll();return latest=="100"end},
        {check="all_bulk_and_create_final_order_preserved",timeout=90,cond=function()poll();return bulk==30 and final end},
        {run=function()PTNative_MsgToHost(T.localPC():GetAddress(),"t.lanes.report",control and control<30 and latest=="100" and final and "ok" or "bad")end},
    }
end
