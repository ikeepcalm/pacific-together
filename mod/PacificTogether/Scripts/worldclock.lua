-- Host day clock, independent of the guest's loading time and local ToD simulation.
local common=require('common')
local net=require('net')
local UEHelpers=require('UEHelpers')
local M={}
local sample,pending,askedAt,sequence,acks=nil,nil,-10,0,{}
local originalSpeed,owner
local probes,offset,ack={},nil,nil
local hostSamples,lastHost={},-10
local function restore()
    local t=common.resolve(owner)
    if not t and owner and PTNative_ObjectMatches and PTNative_ObjectMatches(owner.key) then t=owner.object end
    if t and originalSpeed then t['Set Time Of Day Speed Multiplier'](t,originalSpeed) end
end
local function tod()return common.first('BP_ToDManager_C')end
local function finite(v,limit)return v and v==v and math.abs(v)<=limit end
local function state()
    local t=tod();if not t then return end
    local time={}
    t['Get Current Time Of Day'](t,time)
    local now,value=os.clock(),t.DaysSinceEpoch+(time['Returned Time Of Day'] or 0)
    local prev=hostSamples[#hostSamples]
    if prev and (value<prev.value or value-prev.value>0.002) then hostSamples={} end
    hostSamples[#hostSamples+1]={at=now,value=value}
    while #hostSamples>2 and now-hostSamples[1].at>1 do table.remove(hostSamples,1) end
    local first=hostSamples[1]
    local rate=now>first.at and (value-first.value)/(now-first.at) or 0
    if UEHelpers.GetGameplayStatics():IsGamePaused(UEHelpers.GetWorld()) then rate=0 end
    return string.format('%.9f|%.9f|%d|%.6f',time['Returned Time Of Day'] or 0,rate,t.DaysSinceEpoch,now)
end
local function send(pc,kind,id)
    local s=state()
    if s then net.toGuest(pc,'g.world.clock',net.worldToken()..'|'..kind..'|'..id..'|'..s) end
end
function M.begin(pc)
    if not net.peerSupports(pc,'world-clock') then return end
    sequence=sequence+1
    acks[pc:GetAddress()]={lease=common.lease(pc),id=tostring(sequence),ready=false}
    send(pc,'s',tostring(sequence))
end
function M.ready(pc)
    local a=acks[pc:GetAddress()]
    return not net.peerSupports(pc,'world-clock') or (a and common.resolve(a.lease) and a.ready) or false
end
function M.active()return sample~=nil and net.hostSupports('world-clock')end
local function receive(pc,data)
    if #data>256 then return end
    local epoch,kind,id,body=data:match('^([^|]+)|([qrsav])|([^|]+)|?(.*)$')
    if epoch~=net.worldToken() then return end
    if common.netMode()=='listen' and net.peerSupports(pc,'world-clock') then
        if kind=='q' and id:match('^%d+%.?%d*$') then
            send(pc,'r',id)
            if not acks[pc:GetAddress()] then M.begin(pc) end
        elseif kind=='a' then local a=acks[pc:GetAddress()];if a and common.resolve(a.lease) and a.id==id then a.ready=true end end
    elseif common.netMode()=='client' and net.hostSupports('world-clock') and (kind=='r' or kind=='s' or kind=='v') then
        local time,rate,days,source=body:match('^([^|]+)|([^|]+)|([^|]+)|([^|]+)$')
        time,rate,days,source=tonumber(time),tonumber(rate),tonumber(days),tonumber(source)
        if not finite(time,1) or time<0 or not finite(rate,0.01) or not finite(days,1000000) or days%1~=0 or not finite(source,1e12) then return end
        local now=os.clock()
        if kind=='r' then
            if not pending or id~=pending.id then return end
            local rtt=now-pending.at
            if rtt<0 or rtt>5 then pending=nil;return end
            probes[#probes+1]={rtt=rtt,offset=(pending.at+now)/2-source}
            if #probes>32 then table.remove(probes,1) end
            local best=probes[1]
            for _,p in ipairs(probes)do if p.rtt<best.rtt then best=p end end
            offset=best.offset;pending=nil
        end
        if kind=='s' then ack=id end
        if sample and source<sample.source then return end
        sample={time=time,rate=rate,days=days,source=source,at=source+(offset or (now-source))}
    end
end
net.on('g.world.clock',receive)
net.on('g.motion.worldclock',receive)
LoopInGameThreadWithDelay(50,function()
    if common.netMode()=='listen' then
        local now=os.clock()
        if now-lastHost>=0.1 then
            lastHost=now
            local data
            for _,pc in ipairs(net.guests())do
                if net.peerSupports(pc,'world-clock') and net.peerSupports(pc,'motion') then
                    data=data or state()
                    if data then net.toGuest(pc,'g.motion.worldclock',net.worldToken()..'|v|0|'..data) end
                end
            end
        end
        return
    end
    if common.netMode()~='client' or not net.hostSupports('world-clock') then
        restore()
        owner,originalSpeed,sample,pending,probes,offset,ack=nil,nil,nil,nil,{},nil,nil
        return
    end
    local now=os.clock()
    if now-askedAt>=0.25 and (not pending or now-pending.at>3) then
        askedAt=now;pending={at=now,id=string.format('%.6f',now)}
        net.toHost('g.world.clock',net.worldToken()..'|q|'..pending.id)
    end
    local t=tod()
    if not t or not sample then return end
    if not common.resolve(owner) then owner=common.lease(t);originalSpeed=t.LocalTODSpeedMultiplier end
    t['Set Time Of Day Speed Multiplier'](t,0)
    local elapsed=math.min(3,math.max(0,now-sample.at))
    local time=sample.time+sample.rate*elapsed
    t.DaysSinceEpoch=sample.days+math.floor(time)
    t['Set Current Time Of Day'](t,time%1)
    if ack then net.toHost('g.world.clock',net.worldToken()..'|a|'..ack);ack=nil end
end)
RegisterLoadMapPreHook(function()restore();sample,pending,askedAt,acks,owner,originalSpeed,probes,offset,ack,hostSamples,lastHost=nil,nil,-10,{},nil,nil,{},nil,nil,{},-10 end)
return M
