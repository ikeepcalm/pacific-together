-- Host break events remove the same visual on the guest, including unswapped mesh instances.
local common,net=require("common"),require("net")
local UEHelpers=require("UEHelpers")
local M={}
local records,pending,seen,work,admitted={}, {}, {}, nil, {}
local function live(a) return a and a:IsValid() and not a:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function inWorld(a)
    if not live(a) then return false end
    local w=a:GetWorld()
    if not live(w)then return false end
    -- UE4SS returns a streamed actor's package world, not its level's active owning world.
    local level=w.PersistentLevel;local owner=live(level)and level.OwningWorld
    return live(owner) and owner:GetFullName()==UEHelpers.GetWorld():GetFullName()
end
local function path(a) return a:GetFullName():match("^%S+ (.+)$") end
local function close(p,q) return (p.X-q.X)^2+(p.Y-q.Y)^2+(p.Z-q.Z)^2<5^2 end
local function source(a)
    local s=a.InstanceSwappableData
    if s.Initialized_13_A81C055B4B2DB6E0D27C5292D399C857 and live(s.StaticMesh_8_8CBDF16941839081660D19B1C70D18EF) then
        local p=s.InstanceTransform_11_06A4F5C7447701E17A7210BD5DE540B7.Translation
        return {p={X=p.X,Y=p.Y,Z=p.Z},mesh=path(s.StaticMesh_8_8CBDF16941839081660D19B1C70D18EF)}
    end
    return {p=a:K2_GetActorLocation(),mesh=path(a.BaseMesh.StaticMesh)}
end
local function publish(a)
    if common.netMode()~="listen" or os.getenv("PT_MUTATE")=="nofoliage" or not inWorld(a) then return end
    local cls=StaticFindObject('/Game/Gameplay/Destruction/Base/BP_Crash_Complex_Foliage_Base.BP_Crash_Complex_Foliage_Base_C')
    if not live(cls) or not a:IsA(cls) or not live(a.BaseMesh) or not live(a.BaseMesh.StaticMesh) then return end
    local state=source(a);local p=state.p
    local row=string.format("%s|%s|%.1f|%.1f|%.1f",net.worldToken(),state.mesh,p.X,p.Y,p.Z)
    if records[row] then return end
    records[row]=true
    common.log('PT|foliage break %.1f %.1f %.1f',p.X,p.Y,p.Z)
    for _,pc in ipairs(net.guests())do if net.peerSupports(pc,"foliage")then net.toGuest(pc,"g.foliage.break",row)end end
end
local hooked=false
RegisterLoadMapPreHook(function() records,pending,seen,work,admitted={},{},{},nil,{} end)
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
    if not hooked and os.getenv('PT_MUTATE')~='nofoliageedge' then
        -- A swapped actor can disappear between polls; its saved instance transform survives the break.
        hooked=pcall(RegisterHook,"/Game/Gameplay/Destruction/Base/BP_Crash_Base.BP_Crash_Base_C:PostBreakLogic",function(self)publish(self:get())end)
    end
    local guests=net.guests()
    for _,a in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C") or {}) do
        if inWorld(a) and live(a.BaseMesh) and live(a.BaseMesh.StaticMesh) then
            if a.IsBroken then publish(a) end
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
        for _,a in ipairs(FindAllOf("BP_Crash_Complex_Foliage_Base_C") or {})do
            if inWorld(a) and live(a.BaseMesh) and live(a.BaseMesh.StaticMesh) then
                local s=source(a)
                if s.mesh==p.mesh and close(s.p,p.p) then
                    if not a.IsBroken then a:ComplexBreak({X=0,Y=0,Z=0},a.BaseMesh)end
                    common.log('PT|foliage applied actor %.1f %.1f %.1f',p.p.X,p.p.Y,p.p.Z)
                    return
                end
            end
        end
        local components={}
        for _,c in ipairs(FindAllOf("InstancedStaticMeshComponent") or {})do
            if live(c) and live(c.StaticMesh) and path(c.StaticMesh)==p.mesh and inWorld(c) then
                local lease=common.lease(c)
                if lease then
                    local indices={}
                    for _,i in ipairs(c:GetInstancesOverlappingSphere(p.p,100,true))do indices[#indices+1]=i:get() end
                    components[#components+1]={lease=lease,indices=indices}
                end
            end
        end
        work={job=p,components=components,component=1,index=1}
    end
    local w=work;local start=os.clock();local calls=0
    while w.component<=#w.components and calls<64 and os.clock()-start<0.002 do
        local entry=w.components[w.component];local c=common.resolve(entry.lease)
        if live(c) and w.index<=#entry.indices then
            local idx=entry.indices[w.index]
            local xf={};local ok=c:GetInstanceTransform(idx,xf,true);calls=calls+1
            if ok and close(xf.Translation,w.job.p) and c:RemoveInstance(idx) then
                common.log('PT|foliage applied instance %.1f %.1f %.1f',w.job.p.X,w.job.p.Y,w.job.p.Z)
                work=nil;return
            end
            w.index=w.index+1
        else w.component=w.component+1;w.index=1 end
    end
    if w.component>#w.components then
        -- shortcut: retry streamed-out foliage for five minutes; increase only with a streaming regression.
        w.job.tries=(w.job.tries or 0)+1
        if w.job.tries<300 then common.defer(1000,function()pending[#pending+1]=w.job end)end
        work=nil
    end
end)
-- A saved host world can already lack foliage before any break observer runs.
local presence,readyAt=nil,0
RegisterLoadMapPreHook(function()presence=nil;readyAt=os.clock()+5 end)
local function vegetation(mesh)
    return mesh and mesh:find('^/Game/') and (mesh:find('/Trees/',1,true)or mesh:find('/Shrubs/',1,true))
end
local function inside(p,c,r)return(p.X-c.X)^2+(p.Y-c.Y)^2+(p.Z-c.Z)^2<r*r end
local function finite(v)return v and v==v and math.abs(v)<1e8 end
net.on('g.foliage.presence',function(_,data)
    if common.netMode()~='client' or not net.hostSupports('foliage-state')or #data>30000 then return end
    local header,body=data:match('^([^\n]+)\n(.*)$');if not header then return end
    local epoch,x,y,z,r=header:match('^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$')
    x,y,z,r=tonumber(x),tonumber(y),tonumber(z),tonumber(r)
    if epoch~=net.worldToken()or not finite(x)or not finite(y)or not finite(z)or not r or r~=r or r<100 or r>2500 then return end
    local groups,n,total={},0,0
    for row in body:gmatch('[^\n]+')do
        local mesh,points=row:match('^([^|]+)|(.*)$')
        if not vegetation(mesh)or #mesh>512 or groups[mesh]then return end
        n=n+1;if n>256 then return end
        local list={};groups[mesh]=list
        for point in points:gmatch('[^;]+')do
            local a,b,c=point:match('^([^,]+),([^,]+),([^,]+)$');a,b,c=tonumber(a),tonumber(b),tonumber(c)
            if not finite(a)or not finite(b)or not finite(c)then return end
            total=total+1;if total>2048 then return end
            list[#list+1]={X=a,Y=b,Z=c}
        end
    end
    presence={p={X=x,Y=y,Z=z},r=r,groups=groups,components=nil,i=1}
end)
LoopInGameThreadWithDelay(1000,function()
    if common.netMode()~='listen' or os.clock()<readyAt or os.getenv('PT_MUTATE')=='nofoliagepresence'then return end
    local guests={}
    for _,pc in ipairs(net.guests())do if net.peerSupports(pc,'foliage-state')and net.lifecycle(pc)=='active'then guests[#guests+1]=pc end end
    if #guests==0 then return end
    local cm=FindFirstOf('BP_CarManager_C');local car=live(cm)and cm.NewCarActor
    if not live(car)then return end
    local center,radius=car:K2_GetActorLocation(),2000
    local groups={}
    local function include(mesh,p)
        if not vegetation(mesh)then return end
        groups[mesh]=groups[mesh]or{}
        if p and inside(p,center,radius)then groups[mesh][#groups[mesh]+1]=string.format('%.1f,%.1f,%.1f',p.X,p.Y,p.Z)end
    end
    for _,c in ipairs(FindAllOf('FoliageInstancedStaticMeshComponent')or{})do
        if inWorld(c)and live(c.StaticMesh)then
            local mesh=path(c.StaticMesh);include(mesh)
            if vegetation(mesh)then for _,i in ipairs(c:GetInstancesOverlappingSphere(center,radius,true))do
                local xf={};if c:GetInstanceTransform(i:get(),xf,true)then include(mesh,xf.Translation)end
            end end
        end
    end
    for _,a in ipairs(FindAllOf('BP_Crash_Complex_Foliage_Base_C')or{})do
        if live(a)and live(a.BaseMesh)and live(a.BaseMesh.StaticMesh)then
            -- Preview actors supply mesh names only, never world instances at the origin.
            include(path(a.BaseMesh.StaticMesh))
            if inWorld(a)and not a.IsBroken then local s=source(a);include(s.mesh,s.p)end
        end
    end
    local rows={string.format('%s|%.1f|%.1f|%.1f|%d',net.worldToken(),center.X,center.Y,center.Z,radius)}
    for mesh,points in pairs(groups)do rows[#rows+1]=mesh..'|'..table.concat(points,';')end
    local data=table.concat(rows,'\n');if #data>30000 or #rows>257 then return end
    for _,pc in ipairs(guests)do net.toGuest(pc,'g.foliage.presence',data)end
end)
LoopInGameThreadWithDelay(16,function()
    local w=presence
    if common.netMode()~='client' or not w then return end
    local function missing(mesh,p)
        local list=w.groups[mesh]
        if not list or not inside(p,w.p,w.r-5)then return false end
        for _,q in ipairs(list)do if close(p,q)then return false end end
        return true
    end
    if not w.components then
        w.components={}
        for _,c in ipairs(FindAllOf('FoliageInstancedStaticMeshComponent')or{})do
            if inWorld(c)and live(c.StaticMesh)and w.groups[path(c.StaticMesh)]then w.components[#w.components+1]=common.lease(c)end
        end
        for _,a in ipairs(FindAllOf('BP_Crash_Complex_Foliage_Base_C')or{})do
            if inWorld(a)and not a.IsBroken and live(a.BaseMesh)and live(a.BaseMesh.StaticMesh)then
                local s=source(a);if missing(s.mesh,s.p)then
                    a:ComplexBreak({X=0,Y=0,Z=0},a.BaseMesh)
                    common.log('PT|foliage saved actor removed %.1f %.1f %.1f',s.p.X,s.p.Y,s.p.Z)
                end
            end
        end
    end
    local start,removed=os.clock(),0
    while w.i<=#w.components and os.clock()-start<0.002 do
        local c=common.resolve(w.components[w.i]);local done=true
        if live(c)and live(c.StaticMesh)then
            local mesh=path(c.StaticMesh);local indices={}
            for _,i in ipairs(c:GetInstancesOverlappingSphere(w.p,w.r,true))do indices[#indices+1]=i:get()end
            table.sort(indices,function(a,b)return a>b end)
            for _,i in ipairs(indices)do
                local xf={}
                if c:GetInstanceTransform(i,xf,true)and missing(mesh,xf.Translation)and c:RemoveInstance(i)then
                    removed=removed+1
                    common.log('PT|foliage saved instance removed %.1f %.1f %.1f',xf.Translation.X,xf.Translation.Y,xf.Translation.Z)
                    if removed>=8 then done=false;break end
                end
            end
        end
        if done then w.i=w.i+1 end
    end
    if w.i>#w.components then presence=nil end
end)
return M
