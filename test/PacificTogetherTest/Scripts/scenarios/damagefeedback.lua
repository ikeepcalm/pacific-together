-- A remote hit must never touch local health/feedback, including between frames.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local function hp() return T.first("BP_ResourceManager_C").PlayerHealth.Current end
    local got = {}
    local function poll()
        while true do local k,d=PTNative_MsgPoll("t."); if not k then return end; got[k]=d end
    end
    if T.ROLE == "host" then
        local steps, before, guestBefore, immediate, ownHit, receiverValue = {}, nil, nil, nil, nil, nil
        local function add(s) steps[#steps+1]=s end
        local function hit(pawn, amount)
            local path="/Game/Systems/Messages/MSG_Damage_Electrical.MSG_Damage_Electrical_C"
            if not StaticFindObject(path):IsValid() then LoadAsset(path) end
            local ms=T.first("MessageSystem")
            local m=StaticConstructObject(StaticFindObject(path),ms); m.Damage=amount; ms:DispatchMessage(m,pawn)
            return m,ms
        end
        for _,s in ipairs(T.loadFixture("garage")) do add(s) end
        add({check="host_listen",timeout=90,cond=function() return T.netMode()=="listen" and T.map()=="RB_Garage" end})
        add({check="guest_joined",timeout=240,cond=function() return L.guestChar()~=nil end})
        add({check="guest_reports_health",timeout=60,cond=function() poll(); return tonumber(got["t.hp"])~=nil end})
        add({wait=2})
        add({run=function()
            before=hp(); guestBefore=tonumber(got["t.hp"])
            receiverValue=L.guestChar().AC_PlayerHealthReceiverHelper.FinalIncomingDamage
            hit(L.guestChar(),15); immediate=hp()
        end})
        add({check="host_dispatch_keeps_local_health",timeout=1,cond=function() T.log("PT|info host before=%.2f immediate=%.2f",before,immediate); return math.abs(immediate-before)<0.05 end})
        add({check="guest_receives_damage",timeout=30,cond=function() poll(); return tonumber(got["t.hp"])<guestBefore-8 end})
        add({check="remote_receiver_does_not_run_feedback",timeout=5,cond=L.holds(2,function()
            return L.guestChar().AC_PlayerHealthReceiverHelper.FinalIncomingDamage==receiverValue
        end)})
        add({run=function() hit(L.own(),5); ownHit=hp(); hit(L.guestChar(),15); immediate=hp() end})
        -- The receiver applies its own hit on a later frame; the remote hit must neither add to nor refund it.
        add({check="own_damage_not_refunded",timeout=10,cond=L.holds(3,function()
            T.log("PT|info own hit before=%.2f immediate=%.2f current=%.2f",ownHit,immediate,hp())
            return hp()<ownHit-1 and hp()>ownHit-5.5 and math.abs(immediate-ownHit)<0.05
        end)})
        add({run=function()
            poll(); guestBefore=tonumber(got["t.hp"])
            local pawn=L.guestChar()
            local m,ms=hit(pawn,15)
            pawn.AC_PlayerHealthReceiverHelper.IncomingDamageMessage=m -- retain the reusable payload through the delay
            ExecuteInGameThreadWithDelay(200,function() ms:DispatchMessage(m,pawn) end)
        end})
        add({check="reused_payload_delivers_each_hit_once",timeout=20,cond=function()
            poll(); local loss=guestBefore-tonumber(got["t.hp"]); return loss>12 and loss<23
        end})
        add({run=function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.done","1") end})
        add({wait=3})
        return steps
    end
    return {
        T.onMap("RB_MainMenu",90),
        {check="guest_in_garage",timeout=400,cond=function() return T.netMode()=="client" and T.map()=="RB_Garage" and T.cls(T.myPawn())==T.CHAR end},
        {check="guest_finished",timeout=400,tick=function() poll(); PTNative_MsgToHost(T.localPC():GetAddress(),"t.hp",tostring(hp())) end,cond=function() return got["t.done"]~=nil end},
    }
end
