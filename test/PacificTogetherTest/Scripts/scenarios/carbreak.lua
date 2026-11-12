-- Host breaks one level-placed Simple (sign/barrel/floating rock) and one Complex (fence/barricade) breakable the way a car hit
-- does (SimpleBreak/ComplexBreak -> PostBreakLogic); the guest's copies must end broken.
return function(T)
    local L=require("scenarios.sessionlib")(T);local got={};local map="Rural_Forest_Radio_Scylla_02"
    local function poll()while true do local k,d=PTNative_MsgPoll("t.carbreak.");if not k then return end;got[k]=d end end
    local function has(k)poll();return got["t.carbreak."..k]~=nil end
    local function send(k,d)if T.ROLE=="host"then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.carbreak."..k,d or "1")else PTNative_MsgToHost(T.localPC():GetAddress(),"t.carbreak."..k,d or "1")end end
    local function pick(cls)
        local me=T.myPawn():K2_GetActorLocation();local best,bd
        for _,v in ipairs(FindAllOf(cls)or{})do
            local n=v:GetFullName()
            if T.inWorld(v)and not v.IsBroken and v.BaseMesh and v.BaseMesh:IsValid()and not n:find("BP_IF_",1,true)and not n:find("Foliage",1,true)then
                local p=v:K2_GetActorLocation();local d=(p.X-me.X)^2+(p.Y-me.Y)^2+(p.Z-me.Z)^2
                if not bd or d<bd then best,bd=v,d end
            end
        end
        return best
    end
    local function parse(t)local m,x,y,z=t:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)");return m,{X=tonumber(x),Y=tonumber(y),Z=tonumber(z)}end
    local function mine(cls,t)-- the guest's own copy of a host actor: same mesh, same spot
        local m,p=parse(t)
        for _,v in ipairs(FindAllOf(cls)or{})do
            if T.inWorld(v)and v.BaseMesh:IsValid()and v.BaseMesh.StaticMesh:IsValid()and v.BaseMesh.StaticMesh:GetFullName():find(m,1,true)then
                local q=v:K2_GetActorLocation();if (q.X-p.X)^2+(q.Y-p.Y)^2+(q.Z-p.Z)^2<30^2 then return v end
            end
        end
    end
    local function gone(a)return not a:IsValid()or a:HasAnyInternalFlags(EInternalObjectFlags.PendingKill)or a.IsBroken end
    if T.ROLE=="host"then
        local s,c,sp,cp
        return {T.onMap("RB_MainMenu",90),{run=function()T.console("open /Game/Maps/Rural/"..map.."/"..map.."?listen")end},T.onMap(map,120),
            {check="guest_joined",timeout=240,cond=function()return L.guestChar()~=nil end},{wait=15},
            {run=function()
                s=pick("BP_Crash_Simple_Base_C");c=pick("BP_Crash_Complex_Base_C");assert(s and c,"no simple/complex breakable in zone")
                local function id(v)local p=v:K2_GetActorLocation();return string.format("%s|%f|%f|%f",v.BaseMesh.StaticMesh:GetFullName():match("^%S+ (.+)$"),p.X,p.Y,p.Z)end
                sp=id(s);cp=id(c)
                T.log("PT|info carbreak targets %s %s",sp,cp)
                send("targets",sp.."\n"..cp)
            end},
            {check="guest_ready",timeout=40,cond=function()return has("ready")end},
            {run=function()s:SimpleBreak({X=0,Y=0,Z=0})end},{wait=4},{run=function()T.log("PT|info carbreak complex next");c:ComplexBreak({X=0,Y=0,Z=0},c.BaseMesh)end},
            {check="guest_broke",timeout=40,cond=function()return has("broke")end},{wait=2}}
    end
    local sp,cp,sa,ca
    return {T.onMap("RB_MainMenu",90),{check="guest_in_forest",timeout=240,cond=function()return T.netMode()=="client"and T.map()==map end},
        {check="targets",timeout=240,cond=function()return has("targets")end},
        {check="guest_has_targets",timeout=60,cond=function()
            sp,cp=got["t.carbreak.targets"]:match("([^\n]+)\n([^\n]+)")
            sa,ca=mine("BP_Crash_Simple_Base_C",sp),mine("BP_Crash_Complex_Base_C",cp)
            T.log("PT|info carbreak guest sees %s %s",tostring(sa),tostring(ca))
            return sa~=nil and ca~=nil and not gone(sa)and not gone(ca)
        end},
        {run=function()send("ready")end},
        {check="host_break_reaches_guest",timeout=40,cond=function()return gone(sa)and gone(ca)end},
        {run=function()send("broke")end},{wait=2}}
end
