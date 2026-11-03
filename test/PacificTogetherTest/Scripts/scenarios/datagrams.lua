-- Optional motion uses the existing tunnel outside UE reliable delivery; final edges remain reliable.
return function(T)
    local L=require("scenarios.sessionlib")(T)
    local count,last,sequence,beforeEnd,ended,report=0,nil,nil,false,false,nil
    local function poll()
        while true do
            local kind,data,seq=PTNative_TunnelMotionPoll("t.motion.");if not kind then break end
            count,last,sequence=count+1,data,seq;beforeEnd=not ended
        end
        while true do
            local kind,data=PTNative_MsgPoll("t.datagram.");if not kind then break end
            if kind=="t.datagram.end"then ended=true elseif kind=="t.datagram.report"then report=data end
        end
    end
    if T.ROLE=="host"then return {
        T.onMap("RB_MainMenu",90),{run=function()T.console("open /Game/Maps/RunProto/RB_Garage?listen")end},T.onMap("RB_Garage",90),
        {check="guest_joined",timeout=120,cond=function()return L.guestChar()~=nil end},{wait=12},
        {run=function()
            local pc=L.remotePCs()[1]
            for i=1,40 do assert(PTNative_MsgToGuest(pc:GetAddress(),"t.datagram.bulk",string.rep("x",20000)))end
            for i=1,100 do assert(PTNative_TunnelMotionSend("t.motion.independent","current-world|"..i))end
            assert(PTNative_MsgToGuest(pc:GetAddress(),"t.datagram.end","final"))
        end},
        {check="independent_motion_arrived_before_reliable_backlog",timeout=120,cond=function()poll();return report=="ok"end},
    }end
    return {
        T.onMap("RB_MainMenu",90),{check="joined",timeout=120,cond=function()return T.map()=="RB_Garage"end},
        {check="latest_motion_datagram_arrives_before_reliable_final",timeout=90,cond=function()poll();return last=="current-world|100" and beforeEnd and sequence>0 end},
        {check="reliable_final_eventually_arrives",timeout=90,cond=function()poll();return ended end},
        {run=function()PTNative_MsgToHost(T.localPC():GetAddress(),"t.datagram.report",last=="current-world|100"and beforeEnd and "ok"or"bad")end},
    }
end
