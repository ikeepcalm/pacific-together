-- Isolated common.lua check: duplicate key subscribers, held keys, release/repress and callback errors.
return function(T)
    return {{check="all_key_subscribers_receive_each_edge",timeout=1,cond=function()
        local poll, down, reads, count, errors = nil, {}, {}, {0,0,0,0}, 0
        local pc={IsValid=function() return true end,HasAnyInternalFlags=function() return false end,IsLocalController=function() return true end}
        function pc:IsInputKeyDown(key) reads[key.KeyName]=(reads[key.KeyName] or 0)+1; return down[key.KeyName]==true end
        local helpers={GetWorld=function() end}
        local env=setmetatable({
            require=function(name) assert(name=="UEHelpers"); return helpers end,
            FindAllOf=function() return {pc} end, FindFirstOf=function() end,
            StaticFindObject=function() end, RegisterHook=function() end, PTNative_Find=false,
            FName=function(s) return s end,
            LoopInGameThreadWithDelay=function(_,fn) poll=fn end,
            RegisterLoadMapPreHook=function() end, RegisterLoadMapPostHook=function() end,
            print=function() errors=errors+1 end,
        },{__index=_G})
        local common=assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/common.lua","t",env))()
        common.onKey("E",function() count[1]=count[1]+1 end)
        common.onKey("E",function() count[2]=count[2]+1 end)
        common.onKey("E",function() error("expected callback failure") end)
        common.onKey("E",function() count[3]=count[3]+1 end)
        common.onKey("X",function() count[4]=count[4]+1 end)
        poll(); down.E=true; reads={}; poll()
        assert(count[1]==1 and count[2]==1 and count[3]==1,"E was consumed before every subscriber ran")
        assert(reads.E==1 and reads.X==1,"keys must be sampled once per poll")
        poll(); assert(count[1]==1 and count[2]==1 and count[3]==1,"held key repeated")
        down.E=false; poll(); down.E=true; down.X=true; poll()
        assert(count[1]==2 and count[2]==2 and count[3]==2 and count[4]==1,"release/repress or independent key lost")
        assert(errors==2,"callback failures must be contained and logged")
        return true
    end}}
end
