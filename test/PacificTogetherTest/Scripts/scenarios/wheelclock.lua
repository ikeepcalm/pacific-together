-- Render-clock and phase-unwrapping regressions; no graphics or game physics needed.
return function(T)
    local motion=assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/wheelmotion.lua"))()
    local checks={}
    local function add(name,fn) checks[#checks+1]={check=name,timeout=1,cond=fn} end
    local function run(fps,omega,jitter)
        local buffer,queue={},{}
        for n=0,120 do
            local t=n*.05
            queue[#queue+1]={t=t,at=t+(jitter and n>0 and (n%3)*.018 or 0),wheels={{phase=(omega*t)%(2*math.pi),omega=omega}}}
        end
        table.sort(queue,function(a,b)return a.at<b.at end)
        local head,last,maxError,backwards=1,nil,0,0
        for frame=0,math.floor(5*fps) do
            local now=frame/fps
            while queue[head] and queue[head].at<=now do motion.push(buffer,queue[head]);head=head+1 end
            local a,b,u,e=motion.sample(buffer,now)
            if a then
                local phase=motion.phase(a.wheels[1],b.wheels[1],u,e)
                if now>.3 then maxError=math.max(maxError,math.abs(phase-omega*(now-.1)));if last and omega*(phase-last)<-1e-7 then backwards=backwards+1 end end
                last=phase
            end
        end
        return maxError<1e-6 and backwards==0
    end
    for _,fps in ipairs({12,15,30,60,144}) do
        add("constant_spin_"..fps.."fps",function()return run(fps,160,false) end)
        add("jittered_spin_"..fps.."fps",function()return run(fps,160,true) end)
    end
    add("reverse_spin",function()return run(60,-100,true) end)
    add("out_of_order_snapshot_rejected",function()
        local b={};motion.push(b,{t=2,at=2,wheels={{phase=1,omega=0}}})
        return not motion.push(b,{t=1,at=3,wheels={{phase=0,omega=0}}}) and #b==1
    end)
    add("network_gap_extrapolation_bounded",function()
        local b={};motion.push(b,{t=1,at=1,wheels={{phase=1,omega=10}}})
        local a,z,u,e=motion.sample(b,5)
        return math.abs(motion.phase(a.wheels[1],z.wheels[1],u,e)-2)<1e-6
    end)
    add("steering_axis_does_not_wobble",function()
        local k=StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        for spin=0,720,9 do
            local r=k:ComposeRotators({Pitch=-spin,Yaw=0,Roll=0},{Pitch=0,Yaw=24,Roll=0})
            local axle=k:GetRightVector(r)
            if math.abs(axle.Z)>.0001 or math.abs(axle.X+math.sin(math.rad(24)))>.0001 or math.abs(axle.Y-math.cos(math.rad(24)))>.0001 then return false end
        end
        return true
    end)
    table.insert(checks,1,T.onMap("RB_MainMenu",90))
    return checks
end
