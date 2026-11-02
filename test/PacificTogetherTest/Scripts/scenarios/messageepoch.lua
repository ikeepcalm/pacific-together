-- Real native RPC capture/reassembly, with net.lua's actual map-reset callbacks invoked in an isolated Lua environment.
return function(T)
    local callbacks, net
    local function inject(pc, kind, last, data)
        pc:ClientMessage("PT1|" .. kind .. "|" .. last .. "|" .. data, FName("None"), 0)
    end
    return {
        T.onMap("RB_MainMenu", 90),
        {check="native_message_epoch_api",timeout=1,cond=function() return type(PTNative_MsgReset)=="function" end},
        {run=function()
            callbacks = {}
            local env=setmetatable({
                require=function(name)
                    if name=="common" then return {log=function() end} end
                    return require(name)
                end,
                RegisterLoadMapPreHook=function(fn) callbacks[#callbacks+1]=fn end,
                LoopInGameThreadWithDelay=function() end,
            },{__index=_G})
            net=assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/net.lua","t",env))()
        end},
        {check="fragment_reassembly_preserved",timeout=1,cond=function()
            local pc=T.localPC()
            inject(pc,"t.epoch.control","m","first-")
            inject(pc,"t.epoch.control","e","second")
            local k,d,from=PTNative_MsgPoll("t.epoch.")
            return k=="t.epoch.control" and d=="first-second" and from==pc:GetAddress()
        end},
        {run=function()
            local pc=T.localPC()
            inject(pc,"t.epoch.partial","m","old-")
            inject(pc,"t.epoch.queued","e","old-world")
            net.heardAt.old=1
            for _,fn in ipairs(callbacks) do fn() end
        end},
        {check="old_world_inbox_discarded",timeout=1,cond=function() return PTNative_MsgPoll("t.epoch.")==nil end},
        {check="old_world_fragment_discarded",timeout=1,cond=function()
            inject(T.localPC(),"t.epoch.partial","e","new-world")
            local k,d=PTNative_MsgPoll("t.epoch.")
            return k=="t.epoch.partial" and d=="new-world"
        end},
        {check="old_world_handler_times_discarded",timeout=1,cond=function() return next(net.heardAt)==nil end},
        {check="reset_is_idempotent",timeout=1,cond=function()
            for _,fn in ipairs(callbacks) do fn(); fn() end
            inject(T.localPC(),"t.epoch.fresh","e","fresh")
            local k,d=PTNative_MsgPoll("t.epoch.")
            return k=="t.epoch.fresh" and d=="fresh"
        end},
        {run=function()
            inject(T.localPC(),"t.epoch.travel","e","previous-world")
            T.console("open /Game/Maps/RunProto/RB_Garage")
        end},
        T.onMap("RB_Garage",90),
        {check="previous_world_cannot_deliver_after_travel",timeout=1,cond=function()
            return PTNative_MsgPoll("t.epoch.")==nil
        end},
    }
end
