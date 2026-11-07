return function(T)
    local plan=require("scenarios.drivev2")(T)
    if T.ROLE~="host" then return plan end
    local selected={plan[1],plan[2],plan[3],plan[4],plan[5]}
    local copying=false
    for _,step in ipairs(plan) do
        if step.tag=="heap_setup" then copying=true end
        if copying then selected[#selected+1]=step end
    end
    return selected
end
