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
            if T.inWorld(v)and not v.IsBroken and v.BaseMesh and v.BaseMesh:IsValid()and not n:find("BP_IF_",1,true)and not n:find("Foliage",1,true)and not v.BaseMesh.StaticMesh:GetFullName():find("/VFX/",1,true)then
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
        local s,c,sp,cp,tree
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
            {check="guest_broke",timeout=40,cond=function()return has("broke")end},
            -- a real foliage instance (tree/shrub): the host's game swaps it into its crash actor and it falls; the guest must do the same
            {run=function()
                local me=T.myPawn():K2_GetActorLocation();local want={} -- only meshes the game can swap into a crash actor
                for _,a in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C")or{})do if a.BaseMesh.StaticMesh:IsValid()then want[a.BaseMesh.StaticMesh:GetFullName():match("^%S+ (.+)$")]=true end end
                for _,c in ipairs(FindAllOf("FoliageInstancedStaticMeshComponent")or{})do
                    local mp=c.StaticMesh:IsValid()and c.StaticMesh:GetFullName():match("^%S+ (.+)$")or""
                    if T.inWorld(c)and want[mp]then
                        for _,i in ipairs(c:GetInstancesOverlappingSphere(me,20000,true))do
                            local xf={}
                            if c:GetInstanceTransform(i:get(),xf,true)then
                                local t=xf.Translation;local dx,dy=t.X-me.X,t.Y-me.Y;local d=(dx*dx+dy*dy)^.5
                                -- not one the game already swapped (those sit 20 000 down) and not right under the host's swap radius
                                if math.abs(t.Z-me.Z)<1500 and d>2500 and d<15000 then tree={c=c,i=i:get(),xf=xf,mesh=mp};break end
                            end
                        end
                    end
                    if tree then break end
                end
                assert(tree,"no foliage instance near host")
                local t=tree.xf.Translation
                send("tree",string.format("%s|%f|%f|%f",tree.mesh,t.X,t.Y,t.Z))
            end},
            {check="guest_tree_ready",timeout=40,cond=function()return has("treeready")end},
            {run=function()
                local m=FindFirstOf("BP_FoliageManager_C");assert(m and m:IsValid(),"no foliage manager")
                local ok,err=pcall(function()m:ConvertInstanceToSwappable({OwningComponent_14_6824D4974A5EB8C238B737B8507E9571=tree.c,InstanceIndex_2_4C12DC584DB750C0F6F37E9B65AB16C4=tree.i,
                    InstanceTransform_11_06A4F5C7447701E17A7210BD5DE540B7=tree.xf,StaticMesh_8_8CBDF16941839081660D19B1C70D18EF=tree.c.StaticMesh,
                    Initialized_13_A81C055B4B2DB6E0D27C5292D399C857=false})end)
                T.log("PT|info carbreak host swap ok=%s err=%s",tostring(ok),tostring(err))
                local t=tree.xf.Translation;local a
                for _,v in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C")or{})do
                    if T.inWorld(v)then local q=v:K2_GetActorLocation();if (q.X-t.X)^2+(q.Y-t.Y)^2+(q.Z-t.Z)^2<40^2 then a=v;break end end
                end
                if not a then local n,best=0,1e18
                    for _,v in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C")or{})do n=n+1;local q=v:K2_GetActorLocation();local d=((q.X-t.X)^2+(q.Y-t.Y)^2+(q.Z-t.Z)^2)^.5;if d<best then best=d end end
                    T.log("PT|info carbreak no actor: foliage actors=%d nearest=%.1f tree=%.0f,%.0f,%.0f",n,best,t.X,t.Y,t.Z)
                    for _,v in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C")or{})do local q=v:K2_GetActorLocation();T.log("PT|info carbreak fa %s %.0f %.0f %.0f",v:GetClass():GetFName():ToString(),q.X,q.Y,q.Z)end end
                assert(a,"host swap made no crash actor");a:ComplexBreak({X=5e5,Y=0,Z=0},a.BaseMesh)
            end},
            {check="guest_tree_actor_broken",timeout=40,cond=function()return has("treebroke")end},{wait=2}}
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
        -- visual.lua mirrors destructibles too but only after its 5-11 s sweep; this module must land within seconds
        {check="simple_break_prompt",timeout=4,cond=function()return gone(sa)end},
        {check="complex_break_prompt",timeout=6,cond=function()return gone(ca)end},
        {run=function()send("broke")end},
        {check="tree_instance_seen",timeout=60,cond=function()return has("tree")end},
        {run=function()send("treeready")end},
        -- not just a removed instance: the tree must turn into a broken crash actor here
        {check="tree_becomes_broken_actor",timeout=15,cond=function()
            local m,p=parse(got["t.carbreak.tree"])
            for _,v in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C")or{})do
                if T.inWorld(v)and v.IsBroken then
                    local q=v:K2_GetActorLocation();if (q.X-p.X)^2+(q.Y-p.Y)^2+(q.Z-p.Z)^2<60^2 then return true end
                end
            end
        end},
        {run=function()send("treebroke")end},{wait=2}}
end
