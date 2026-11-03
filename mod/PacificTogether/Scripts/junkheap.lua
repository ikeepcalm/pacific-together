-- MultiVoid-style host arbiter: guest input is intent, prizes exist only on the host, mirrors run presentation only.
local common, net = require("common"), require("net")
local UE = require("UEHelpers")
local function valid(a) return a and a:IsValid() and not a:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function same(a,b) return valid(a) and valid(b) and a:GetFullName()==b:GetFullName() end
local heap, mirror, owner, held, sequence, wanted = nil, nil, nil, nil, 0, nil
local seen, rendered = {}, {}
local ANIMS = { "GooChargeup", "PopFx", "DeniedTimeline" }
local function eventName(event) return "BndEvt__Highlight_K2Node_ComponentBoundEvent_"..event.."_OnHighlightInteract__DelegateSignature" end
local SUPPRESSED="ReceiveTick|MainLoopComplete|DispenseNow|RetrieveHeapParts|TryConsolationPrize|TryAdditionalPrize|TestAndSpawn|QueueLuckyItem|Start Chargeup"
for event=0,2 do SUPPRESSED=SUPPRESSED.."|"..eventName(event) end
local function restore()
    if mirror and valid(heap) then
        heap:SetActorTickEnabled(mirror.tick)
        heap.AllowHighlightInteraction = mirror.allow
        if valid(heap.ItemDispenser) then heap.ItemDispenser:SetComponentTickEnabled(mirror.dispenser);PTNative_Unmute(heap.ItemDispenser:GetAddress()) end
        if valid(heap.Highlight) then PTNative_Unmute(heap.Highlight:GetAddress()) end
        PTNative_Unmute(heap:GetAddress())
    end
    mirror = nil
end
RegisterLoadMapPreHook(function() heap,mirror,owner,held,wanted,seen,rendered=nil,nil,nil,nil,nil,{},{};sequence=0 end)
local function interaction(event)
    local name=eventName(event)
    heap[name](heap,heap.Highlight,nil)
end
local function release()
    if owner and valid(heap) then interaction(1) end -- OnInteractEnd stops the search loop; it does not grant items
    owner=nil
end
RegisterHook("/Script/PenDriverPro.BaseHighlightManager:PassesFilter",function(_,highlight)
    if common.netMode()=="listen" and owner and valid(heap) and same(highlight:get(),heap.Highlight) then return false end
end)
net.on("g.heap.intent", function(pc, data)
    if common.netMode()~="listen" or not net.peerSupports(pc,"heap") or not valid(heap) then return end
    local token, serial, edge = data:match("^([%w_]+)|(%d+)|([pr])$")
    if token~=heap:GetFName():ToString() then return end
    serial=tonumber(serial)
    if not serial or serial>1e9 or not valid(pc) then return end
    local key=pc:GetFullName()
    if serial<=(seen[key] or 0) then return end
    seen[key]=serial
    if edge=="r" then if owner and same(owner.pc,pc) then release() end;return end
    local char=pc.Pawn
    if not valid(char) or valid(char:GetAttachParentActor()) then return end
    local p,q=char:K2_GetActorLocation(),heap.Highlight:GetCollisionCenter()
    local distance2=(p.X-q.X)^2+(p.Y-q.Y)^2+(p.Z-q.Z)^2
    if distance2>400^2 then common.log("PT|heap refused distant interaction %.0f uu",math.sqrt(distance2));return end
    if owner or heap.Highlight:IsBeingInteracted() or not heap.AllowHighlightInteraction or not heap:K2_ShouldHighlight(heap.Highlight) then return end
    local request={pc=pc,char=char,pcLease=common.lease(pc),charLease=common.lease(char),at=os.clock()}
    owner=request
    common.log("PT|heap press %d accepted",serial)
    interaction(0) -- OnInteractStart: search sound only
    common.defer(math.floor(math.max(0,heap.Highlight:GetLongDuration())*1000+.5)+20,function()
        if owner~=request or not valid(heap) then return end
        if not common.resolve(request.pcLease) or not common.resolve(request.charLease) or not same(pc.Pawn,char) then release();return end
        local current,center=char:K2_GetActorLocation(),heap.Highlight:GetCollisionCenter()
        if (current.X-center.X)^2+(current.Y-center.Y)^2+(current.Z-center.Z)^2>400^2 then release();return end
        request.completed=true
        common.log("PT|heap hold %d completed",serial)
        interaction(2) -- OnInteractLong: the game's authoritative prize calculation/dispenser

    end)
end)
net.on("g.motion.heap", function(_,data)
    if common.netMode()~="client" then return end
    local key,numbers=data:match("^([%w_]+)|(.+)$")
    if not key or #key>96 then return end
    local fields={}
    for token in (numbers..","):gmatch("([^,]*),") do
        local n=tonumber(token);if not n or n~=n or math.abs(n)>1e7 then return end;fields[#fields+1]=n
    end
    if #fields~=10 then return end
    wanted={at=os.clock(),fields=fields,key=key}
end)
local FX = {
    search=eventName(0), stop=eventName(1),
    lid="PopFx__LidHeavyDown__EventFunc", light="PopFx__LidLightDown__EventFunc",
}
net.on("g.heap.fx",function(_,data)
    if common.netMode()~="client" or not mirror or not wanted or not valid(heap) then return end
    local key,fx=data:match("^([%w_]+)|(%w+)$")
    if key~=wanted.key then return end
    if fx=="search" or fx=="stop" then
        -- Delegate entry points are muted too: Blueprint calls to native Highlight methods bypass ProcessEvent.
        PTNative_Unmute(heap:GetAddress())
        local ok,err=pcall(heap[FX[fx]],heap,heap.Highlight,nil)
        PTNative_Mute(heap:GetAddress(),SUPPRESSED)
        if not ok then error(err) end
    elseif FX[fx] then heap[FX[fx]](heap)
    elseif fx=="charge" then
        local library=StaticFindObject("/Game/Sound/Blueprints/BPFL_AudioFunctions.Default__BPFL_AudioFunctions_C")
        local event=StaticFindObject("/Game/WwiseAudio/Events/Props/garage/stations/luckyJunkHeap/sfx_station_luckyJunkHeap_chargeUp.sfx_station_luckyJunkHeap_chargeUp")
        if valid(library) and valid(event) then library:SpawnAndAttachOneShotAkComponent(heap.LidSFXAttach,event,heap,{},{}) end
    end
end)
local fxHooked=false
local function hookFx()
    if fxHooked then return end
    local path=heap:GetClass():GetFullName():gsub("^%S+ ","")..":"
    for code,name in pairs(FX) do
        RegisterHook(path..name,function(self)
            if common.netMode()=="listen" and valid(heap) and same(self:get(),heap) then
                net.toGuests("g.heap.fx",heap:GetFName():ToString().."|"..code)
            end
        end)
    end
    fxHooked=true
end
common.onKey("E",function()
    if common.netMode()~="client" or not mirror or held or not valid(heap) or not wanted then return end
    local hm=common.first("BP_HighlightManager_C")
    if hm and same(hm.CurrentHighlight,heap.Highlight) then
        sequence=sequence+1;held=sequence
        net.toHost("g.heap.intent",wanted.key.."|"..sequence.."|p")
    end
end)
LoopInGameThreadWithDelay(250,function()
    local mode=common.netMode()
    if mode~="client" and mode~="listen" then restore();heap=nil;return end
    if not valid(heap) then heap=common.first("BP_Garage_LuckyJunkHeap_C") end
    if valid(heap) then hookFx() end
    if mode=="client" and net.hostSupports("heap") and valid(heap) and not mirror then
        mirror={tick=heap:IsActorTickEnabled(),dispenser=heap.ItemDispenser:IsComponentTickEnabled(),allow=heap.AllowHighlightInteraction}
        heap:SetActorTickEnabled(false)
        heap.ItemDispenser:Cancel({})
        heap.ItemDispenser:SetComponentTickEnabled(false)
        for _,name in ipairs(ANIMS) do heap[name]:Stop() end
        PTNative_Mute(heap.Highlight:GetAddress(),"InteractPressed|InteractReleased")
        PTNative_Mute(heap:GetAddress(),SUPPRESSED)
    end
end)
local last, sentAt, charging=nil,0,false
RegisterLoadMapPreHook(function() last,sentAt,charging=nil,0,false end)
LoopInGameThreadWithDelay(50,function()
    local mode=common.netMode()
    if not valid(heap) then return end
    if mode=="listen" then
        if owner and (not common.resolve(owner.pcLease) or not common.resolve(owner.charLease) or not same(owner.pc.Pawn,owner.char) or os.clock()-owner.at>8) then release() end
        if #net.guests()==0 then return end
        local nowCharging=heap.GooChargeup:IsPlaying()
        if nowCharging and not charging and heap.Count==0 then net.toGuests("g.heap.fx",heap:GetFName():ToString().."|charge") end
        charging=nowCharging
        local values={heap.AllowHighlightInteraction and "1" or "0"}
        for _,name in ipairs(ANIMS) do
            local t=heap[name]
            values[#values+1]=string.format("%.4f",t:GetPlaybackPosition())
            values[#values+1]=string.format("%.4f",t:IsPlaying() and t:GetPlayRate()*(t:IsReversing() and -1 or 1) or 0)
            values[#values+1]=string.format("%.4f",t:GetTimelineLength())
        end
        local data=heap:GetFName():ToString().."|"..table.concat(values,",")
        if data~=last or os.clock()-sentAt>1 then
            net.toGuests("g.motion.heap",data)
            last,sentAt=data,os.clock()
        end
    elseif mode=="client" and held then
        local pc=UE.GetPlayerController()
        local down=valid(pc) and pc:IsInputKeyDown({KeyName=FName("E")})
        if not down then sequence=sequence+1;if wanted then net.toHost("g.heap.intent",wanted.key.."|"..sequence.."|r") end;held=nil end
    end
end)
LoopInGameThreadWithDelay(16,function()
    if common.netMode()~="client" or not mirror or not wanted or not valid(heap) then return end
    local f,age=wanted.fields,math.min(0.2,math.max(0,os.clock()-wanted.at))
    heap.AllowHighlightInteraction=f[1]==1
    for i,name in ipairs(ANIMS) do
        local base=2+(i-1)*3
        local position=math.max(0,math.min(f[base+2],f[base]+age*f[base+1]))
        if not rendered[name] or math.abs(position-rendered[name])>.001 then
            heap[name]:SetPlaybackPosition(position,false,true)
            rendered[name]=position
        end
    end
end)
return {}
