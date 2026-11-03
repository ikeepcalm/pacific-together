return function(T)
    local plan=require("scenarios.drivev2")(T)
    plan[#plan+1]={check="shipping_motion_used_independent_datagrams",timeout=1,cond=function()
        local stats=PTNative_TunnelMotionStats()
        return (tonumber(stats:match((T.ROLE=="host" and "sent" or "received").."=(%d+)")) or 0)>0
    end}
    return plan
end
