-- Exercise a real host foliage actor against an unswapped client mesh instance at an isolated test position.
return function(T)
    local L=require("scenarios.sessionlib")(T);local got={};local map="Rural_Forest_Radio_Scylla_02"
    local function poll()while true do local k,d=PTNative_MsgPoll("t.foliage.");if not k then return end;got[k]=d end end
    local function has(k)poll();return got["t.foliage."..k]~=nil end
    local function send(k,d)if T.ROLE=="host"then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.foliage."..k,d or "1")else PTNative_MsgToHost(T.localPC():GetAddress(),"t.foliage."..k,d or "1")end end
    if T.ROLE=="host"then
        local a
        return {T.onMap("RB_MainMenu",90),{run=function()T.console("open /Game/Maps/Rural/"..map.."/"..map.."?listen")end},T.onMap(map,120),
            {check="guest_joined",timeout=240,cond=function()return L.guestChar()~=nil end},{wait=15},
            {run=function()
                for _,v in ipairs(FindAllOf("BP_IF_Shrub_01_Medium_C")or{})do if T.inWorld(v)then a=v;break end end;assert(a)
                local p=a:K2_GetActorLocation();p={X=p.X+5000,Y=p.Y,Z=p.Z+1000};a:K2_SetActorLocation(p,false,{},true)
                send("target",string.format("%s|%f|%f|%f",a.BaseMesh.StaticMesh:GetFullName():match("^%S+ (.+)$"),p.X,p.Y,p.Z))
            end},
            {check="guest_instance_ready",timeout=30,cond=function()return has("ready")end},
            {run=function()a:ComplexBreak({X=0,Y=0,Z=0},a.BaseMesh)end},
            {check="host_shrub_broken",timeout=5,cond=function()return a.IsBroken end},
            {check="client_instance_removed",timeout=40,cond=function()return has("removed")end},
            {run=function()send("done")end},{wait=2}}
    end
    local c
    return {T.onMap("RB_MainMenu",90),{check="guest_in_forest",timeout=240,cond=function()return T.netMode()=="client"and T.map()==map end},
        {check="target_received",timeout=240,cond=function()return has("target")end},
        {run=function()
            local mesh,x,y,z=got["t.foliage.target"]:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)")
            local xf={Rotation={X=0,Y=0,Z=0,W=1},Translation={X=tonumber(x),Y=tonumber(y),Z=tonumber(z)},Scale3D={X=1,Y=1,Z=1}}
            local asset=StaticFindObject(mesh);if not asset:IsValid()then LoadAsset(mesh);asset=StaticFindObject(mesh)end
            c=T.myPawn():AddComponentByClass(StaticFindObject("/Script/Engine.InstancedStaticMeshComponent"),false,xf,false)
            assert(c:IsValid());c:SetStaticMesh(asset);c:AddInstanceWorldSpace(xf);assert(c:GetInstanceCount()==1);send("ready")
        end},
        {check="host_break_removes_client_foliage",timeout=45,cond=function()return c and c:IsValid()and c:GetInstanceCount()==0 end},
        {run=function()send("removed")end},
        {check="host_done",timeout=60,cond=function()return has("done")end},
        {run=function()c:K2_DestroyComponent(T.myPawn())end}}
end
