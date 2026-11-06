-- Correct a forced local clock offset; repeat after real garage -> run travel, before the loading screen is released.
return function(T)
    local L=require('scenarios.sessionlib')(T)
    local got,last,lastDiff,count,history={},-10,nil,0,{}
    -- This oracle uses the OS clock shared by the two test processes, independent of the shipping clock estimator.
    local function wall()return assert(PTNative_TestMonotonicSeconds,'rebuild native test clock')()end
    local function read()
        local t=T.first('BP_ToDManager_C');if not t then return end
        local a={};t['Get Current Time Of Day'](t,a)
        return a['Returned Time Of Day'],t.DaysSinceEpoch
    end
    local function send(k,d)
        if T.ROLE=='host'then local pc=L.remotePCs()[1];if pc then PTNative_MsgToGuest(pc:GetAddress(),k,d or '')end
        else PTNative_MsgToHost(T.localPC():GetAddress(),k,d or '')end
    end
    LoopInGameThreadWithDelay(50,function()
        if T.netMode()~='listen'and T.netMode()~='client'then return end
        local now=wall()
        if T.ROLE~='host' then
            local time,day=read()
            if time then history[#history+1]={at=now,value=day+time} end
            while #history>2 and now-history[1].at>10 do table.remove(history,1) end
        elseif now-last>=0.2 then
            last=now;local time,day=read()
            if time then send('t.clock.h',string.format('%.9f|%d|%.6f',time,day,now)) end
        end
        while true do
            local k,d=PTNative_MsgPoll('t.');if not k then break end;got[k]=d
            if T.ROLE~='host' and k=='t.clock.h' then
                local time,day,stamp=d:match('^([^|]+)|([^|]+)|([^|]+)$')
                time,day,stamp=tonumber(time),tonumber(day),tonumber(stamp)
                for i=2,#history do
                    local a,b=history[i-1],history[i]
                    if a.at<=stamp and b.at>=stamp and b.at>a.at then
                        local own=a.value+(b.value-a.value)*(stamp-a.at)/(b.at-a.at)
                        lastDiff=math.abs(own-day-time)*86400
                        count=lastDiff<2.2 and count+1 or 0
                        T.log('PT|info clock error_game_seconds=%.3f stable_samples=%d',lastDiff,count)
                        break
                    end
                end
            end
        end
    end)
    RegisterLoadMapPreHook(function()lastDiff,count,history,last=nil,0,{},-10 end)
    local function locked()
        local t=T.first('BP_ToDManager_C')
        return t and t.LocalTODSpeedMultiplier==0 and count>=8
    end
    if T.MUTATE=='noworldclock' then
        if T.ROLE=='host'then
            local steps=T.loadFixture('garage')
            steps[#steps+1]={check='guest_joined',timeout=180,cond=function()return L.guestChar()~=nil end}
            steps[#steps+1]={wait=35}
            return steps
        end
        return {T.onMap('RB_MainMenu',90),
            {check='client_in_garage',timeout=240,cond=function()return T.netMode()=='client'and T.map()=='RB_Garage'end},
            {check='initial_clock_lock',timeout=15,cond=locked}}
    end
    local steps={};local function add(s)steps[#steps+1]=s end
    if T.ROLE=='host'then
        for _,s in ipairs(T.loadFixture('garage'))do add(s)end
        add({check='guest_joined',timeout=180,cond=function()return L.guestChar()~=nil end})
        add({check='guest_offset_corrected',timeout=120,cond=function()return got['t.clock.corrected']~=nil end})
        add({run=function()StaticFindObject('/Game/Systems/ScriptingLibraries/BFL_ProgressionHelpers.Default__BFL_ProgressionHelpers_C'):TravelToNextLeg(T.world())end})
        add({check='host_in_run',timeout=240,cond=function()return T.map()~='RB_Garage'and L.gameplay(T.map())and T.netMode()=='listen'and T.myPawn()~=nil end})
        add({check='guest_rejoined_run',timeout=240,cond=function()return L.guestChar()~=nil end})
        add({check='clock_ack_before_fade_release',timeout=100,cond=function()
            local f=io.open('ue4ss/UE4SS.log','rb');if not f then return false end;local s=f:read('*a');f:close()
            return s:find('guest clock ready',1,true)~=nil
        end})
        add({check='guest_run_clock_matches',timeout=90,cond=function()return got['t.clock.done']~=nil end})
    else
        add(T.onMap('RB_MainMenu',90))
        add({check='client_in_garage',timeout=240,cond=function()return T.netMode()=='client'and T.map()=='RB_Garage'and T.cls(T.myPawn())==T.CHAR end})
        add({check='initial_clock_lock',timeout=60,cond=locked})
        add({run=function()local t=T.first('BP_ToDManager_C');t['Set Current Time Of Day'](t,0.2);t.DaysSinceEpoch=t.DaysSinceEpoch+7;t['Set Time Of Day Speed Multiplier'](t,50);count=0 end})
        add({check='forced_clock_offset_corrected',timeout=10,cond=locked})
        add({run=function()send('t.clock.corrected')end})
        add({check='client_in_run',timeout=300,cond=function()return T.netMode()=='client'and T.map()~='RB_Garage'and L.gameplay(T.map())and T.cls(T.myPawn())==T.CHAR end})
        add({check='clock_lock_after_loading',timeout=30,cond=locked})
        add({run=function()send('t.clock.done')end});add({wait=75})
    end
    return steps
end
