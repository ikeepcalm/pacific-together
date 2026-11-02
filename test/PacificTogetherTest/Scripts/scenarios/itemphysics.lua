-- Loose wheel pose, rotation-only updates, kinematic guest copy and pickup. Garage; mutation norotationsync.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local function alive(o) return o and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local got = {}
    local function poll()
        while true do local k,d = PTNative_MsgPoll("t."); if not k then return end; got[k]=d end
    end
    local function toHost(k,d) PTNative_MsgToHost(T.localPC():GetAddress(),k,d or "1") end
    local function toGuest(k,d) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),k,d or "1") end
    local function bodies(a)
        local list = {}
        for _, wrapped in ipairs(a:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))) do
            local c = wrapped.get and wrapped:get() or wrapped
            if alive(c) then list[#list+1] = c end
        end
        return list
    end
    local function eachItem(fn)
        for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
            if T.inWorld(a) and alive(a.Instance) and not a:GetAttachParentActor():IsValid() then fn(a) end
        end
    end
    local function angle(a,b) return math.abs((a-b+180)%360-180) end
    local function matches(a,l,r)
        local p,q=a:K2_GetActorLocation(),a:K2_GetActorRotation()
        return (p.X-l.X)^2+(p.Y-l.Y)^2+(p.Z-l.Z)^2 < 9 and angle(q.Pitch,r.Pitch)<2 and angle(q.Yaw,r.Yaw)<2 and angle(q.Roll,r.Roll)<2
    end
    local timeout = T.MUTATE=="norotationsync" and 15 or 60
    if T.ROLE=="host" then
        local steps,item,at = {},nil,nil
        local function add(s) steps[#steps+1]=s end
        local function reported(k) return function() poll(); return got[k]=="1" end end
        for _,s in ipairs(T.loadFixture("garage")) do add(s) end
        add({check="host_listen_garage",timeout=90,cond=function() return T.netMode()=="listen" and T.map()=="RB_Garage" end})
        add({check="host_guest_joined",timeout=240,cond=function() return L.guestChar()~=nil end})
        add({wait=12})
        add({run=function()
            local archetype
            eachItem(function(a)
                local name=a.Instance.Archetype:GetFName():ToString():lower()
                if not archetype and (name:find("wheel") or name:find("tire") or name:find("tyre")) then archetype=a.Instance.Archetype end
            end)
            assert(archetype,"no loose wheel archetype in garage fixture")
            local l=L.own():K2_GetActorLocation()
            at={X=l.X+500,Y=l.Y+500,Z=l.Z+150}
            local xf={Rotation={X=0,Y=0,Z=0,W=1},Translation=at,Scale3D={X=1,Y=1,Z=1}}
            item=T.first("InventorySystem"):SpawnItemActor(T.world(),xf,archetype,0,0)
            assert(alive(item),"wheel spawn failed")
            for _,c in ipairs(bodies(item)) do c:SetSimulatePhysics(false) end
            item:K2_SetActorLocationAndRotation(at,{Pitch=35,Yaw=15,Roll=55},false,{},true)
            toGuest("t.target", string.format("%s|%.1f|%.1f|%.1f",archetype:GetFullName():gsub("^%S+ ",""),at.X,at.Y,at.Z))
        end})
        add({check="guest_initial_full_pose",timeout=timeout,cond=reported("t.initial")})
        add({check="guest_copy_kinematic",timeout=timeout,cond=reported("t.kinematic")})
        add({wait=3})
        add({run=function()
            item:K2_SetActorLocationAndRotation(at,{Pitch=-45,Yaw=15,Roll=90},false,{},true)
            toGuest("t.rotated")
        end})
        add({check="guest_rotation_without_translation",timeout=timeout,cond=reported("t.rotated_ok")})
        add({run=function() toGuest("t.pickup") end})
        add({check="guest_pickup_reaches_host",timeout=30,cond=function() poll(); return got["t.picked"]=="1" and not alive(item) end})
        add({run=function() toGuest("t.done") end})
        add({wait=3})
        return steps
    end
    local target,at,item,picked
    local function report()
        poll()
        if not target and got["t.target"] then
            local path,x,y,z=got["t.target"]:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
            target,at=path,{X=tonumber(x),Y=tonumber(y),Z=tonumber(z)}
        end
        if not target then return end
        if picked and not alive(item) then toHost("t.picked"); return end
        if not alive(item) and not picked then
            eachItem(function(a)
                local l=a:K2_GetActorLocation()
                if a.Instance.Archetype:GetFullName():gsub("^%S+ ","")==target and (l.X-at.X)^2+(l.Y-at.Y)^2+(l.Z-at.Z)^2<150^2 then item=a end
            end)
        end
        if not alive(item) then return end
        if matches(item,at,{Pitch=35,Yaw=15,Roll=55}) then toHost("t.initial") end
        local physical=false
        for _,c in ipairs(bodies(item)) do if c:IsSimulatingPhysics(FName("None")) then physical=true end end
        if not physical then toHost("t.kinematic") end
        if got["t.rotated"] and matches(item,at,{Pitch=-45,Yaw=15,Roll=90}) then toHost("t.rotated_ok") end
        if got["t.pickup"] and not picked then
            picked=true
            T.myPawn()["Pickup Actor"](T.myPawn(),item,true)
            if not alive(item) then toHost("t.picked") end
        end
    end
    return {
        T.onMap("RB_MainMenu",90),
        {check="guest_in_garage",timeout=400,cond=function() return T.netMode()=="client" and T.map()=="RB_Garage" and T.cls(T.myPawn())==T.CHAR end},
        {check="guest_finished",timeout=600,tick=report,cond=function() return got["t.done"]~=nil end},
    }
end
