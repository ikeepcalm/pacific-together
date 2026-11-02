-- Execute the shipping common.lua with a deterministic timer/map boundary; never touch real saves.
return function(T)
    return {{check="deferred_actions_belong_to_their_world",timeout=1,cond=function()
        local timers, pre, ran = {}, {}, 0
        local env=setmetatable({
            require=function(name) assert(name=="UEHelpers");return {GetWorld=function() end} end,
            FindAllOf=function() return {} end,FindFirstOf=function() end,StaticFindObject=function() end,
            RegisterHook=function() end,PTNative_Find=false,LoopInGameThreadWithDelay=function() end,
            RegisterLoadMapPreHook=function(fn) pre[#pre+1]=fn end,RegisterLoadMapPostHook=function() end,
            ExecuteInGameThreadWithDelay=function(ms,fn) timers[#timers+1]=fn;return #timers end,
        },{__index=_G})
        local c=assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/common.lua","t",env))()
        assert(c.defer(150,function() ran=ran+1 end)==1,"timer identity lost")
        timers[1]();assert(ran==1,"current world callback lost")
        c.defer(150,function() ran=ran+10 end)
        for _,fn in ipairs(pre) do fn() end
        timers[2]();assert(ran==1,"old world callback executed")
        c.defer(150,function() ran=ran+1;c.defer(500,function() ran=ran+100 end) end)
        timers[3]();assert(ran==2,"new world callback lost")
        for _,fn in ipairs(pre) do fn() end
        timers[4]();assert(ran==2,"nested callback crossed world boundary")
        return true
    end}}
end
