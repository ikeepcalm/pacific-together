-- Host break events remove the same visual on the guest, including unswapped mesh instances.
local common,net=require("common"),require("net")
local M={}
local records,pending,seen,work,admitted,tracked={}, {}, {}, nil, {}, {}
local function live(a) return a and a:IsValid() and not a:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function path(a) return a:GetFullName():match("^%S+ (.+)$") end
local function close(p,q) return (p.X-q.X)^2+(p.Y-q.Y)^2+(p.Z-q.Z)^2<100^2 end
RegisterLoadMapPreHook(function() records,pending,seen,work,admitted,tracked={},{},{},nil,{},{} end)
net.on("g.foliage.break",function(_,data)
    if common.netMode()~="client" or not net.hostSupports("foliage") or #data>4096 then return end
    local epoch,mesh,x,y,z=data:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    x,y,z=tonumber(x),tonumber(y),tonumber(z)
    if epoch~=net.worldToken() or not mesh or not mesh:find("^/Game/") or not x or not y or not z
        or x~=x or y~=y or z~=z or math.abs(x)>1e8 or math.abs(y)>1e8 or math.abs(z)>1e8 then return end
    if seen[data] or #pending>=256 then return end
    seen[data]=true;pending[#pending+1]={mesh=mesh,p={X=x,Y=y,Z=z}}
end)
LoopInGameThreadWithDelay(250,function()
    if common.netMode()~="listen" or os.getenv("PT_MUTATE")=="nofoliage" then return end
    local guests=net.guests()
    for _,a in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C") or {}) do
        if live(a) and live(a.BaseMesh) and live(a.BaseMesh.StaticMesh) then
            local key=common.identity(a);local state=tracked[key]
            if not state then state={p=a:K2_GetActorLocation(),mesh=path(a.BaseMesh.StaticMesh)};tracked[key]=state end
            if not a.IsBroken then state.p=a:K2_GetActorLocation() end
            if a.IsBroken and not state.sent then
                state.sent=true;local p=state.p
                local row=string.format("%s|%s|%.1f|%.1f|%.1f",net.worldToken(),state.mesh,p.X,p.Y,p.Z)
                if not records[row] then records[row]=true;for _,pc in ipairs(guests)do if net.peerSupports(pc,"foliage")then net.toGuest(pc,"g.foliage.break",row)end end end
            end
        end
    end
    for _,pc in ipairs(guests)do
        local key=common.identity(pc)
        if key and net.peerSupports(pc,"foliage") and net.lifecycle(pc)=="active" and not admitted[key] then
            admitted[key]=true
            for row in pairs(records)do net.toGuest(pc,"g.foliage.break",row)end
        end
    end
end)
LoopInGameThreadWithDelay(16,function()
    if common.netMode()~="client" then return end
    if not work then
        local p=table.remove(pending,1);if not p then return end
        local components={}
        for _,c in ipairs(FindAllOf("InstancedStaticMeshComponent") or {})do
            local lease=common.lease(c);if lease then components[#components+1]=lease end
        end
        work={job=p,components=components,component=1,index=0}
        for _,a in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C") or {})do
            if live(a) and live(a.BaseMesh) and live(a.BaseMesh.StaticMesh) and path(a.BaseMesh.StaticMesh)==p.mesh and close(a:K2_GetActorLocation(),p.p) then
                if not a.IsBroken then a:ComplexBreak({X=0,Y=0,Z=0},a.BaseMesh)end
                work=nil;return
            end
        end
    end
    local w=work;local start=os.clock();local calls=0
    while w.component<=#w.components and calls<64 and os.clock()-start<0.002 do
        local c=common.resolve(w.components[w.component])
        if live(c) and live(c.StaticMesh) and path(c.StaticMesh)==w.job.mesh and w.index<c:GetInstanceCount()then
            local xf={};local ok=c:GetInstanceTransform(w.index,xf,true);calls=calls+1
            if ok and close(xf.Translation,w.job.p)then c:RemoveInstance(w.index);work=nil;return end
            w.index=w.index+1
        else w.component=w.component+1;w.index=0 end
    end
    if w.component>#w.components then
        -- shortcut: retry streamed-out foliage for five minutes; increase only with a streaming regression.
        w.job.tries=(w.job.tries or 0)+1
        if w.job.tries<300 then common.defer(1000,function()pending[#pending+1]=w.job end)end
        work=nil
    end
end)
return M
