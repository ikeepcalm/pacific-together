return function(T)
    local L=require('scenarios.sessionlib')(T)
    local got={}
    local function poll()while true do local k,d=PTNative_MsgPoll('t.lid.');if not k then return end;got[k]=d end end
    local function has(k)poll();return got['t.lid.'..k]~=nil end
    local function send(k,d)
        if T.ROLE=='host'then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),'t.lid.'..k,d or '1')
        else PTNative_MsgToHost(T.localPC():GetAddress(),'t.lid.'..k,d or '1')end
    end
    local function heap()return T.first('BP_Garage_LuckyJunkHeap_C')end
    local function pitch()return heap().SM_LuckyJunkHeap_Small_Lid.RelativeRotation.Pitch end
    local steps={};local function add(s)steps[#steps+1]=s end
    if T.ROLE=='host'then
        for _,s in ipairs(T.loadFixture('garage'))do add(s)end
        add({check='guest_joined',timeout=240,cond=function()return L.guestChar()~=nil end})
        add({wait=5})
        for _,n in ipairs({'idle','open','closed'})do
            add({run=function()
                if n~='idle'then heap().SM_LuckyJunkHeap_Small_Lid:K2_SetRelativeRotation({Pitch=n=='open'and -30 or -90,Yaw=0,Roll=0},false,{},false)end
                send(n,tostring(pitch()))
            end})
            add({check='guest_'..n..'_matches_host',timeout=15,cond=function()return has(n)end})
        end
        add({wait=2});return steps
    end
    add(T.onMap('RB_MainMenu',90))
    add({check='guest_in_garage',timeout=240,cond=function()return T.map()=='RB_Garage'and T.netMode()=='client'end})
    for _,n in ipairs({'idle','open','closed'})do
        add({check=n..'_pose_received',timeout=90,cond=function()return has(n)end})
        add({check=n..'_lid_angle_matches',timeout=10,cond=function()return math.abs(pitch()-tonumber(got['t.lid.'..n]))<0.1 end})
        add({run=function()send(n)end})
    end
    add({wait=2});return steps
end