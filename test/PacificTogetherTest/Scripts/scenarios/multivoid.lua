-- Execute production ordering/negotiation logic with deterministic loss, duplication and object reuse.
return function(T)
    local R=assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/replica.lua"))()
    local rawTestWorld,post=nil,{}
    local U={GetWorld=function()return rawTestWorld end,GetWorldContextObject=function()end,GetKismetSystemLibrary=function()return {}end}
    local env=setmetatable({require=function()return U end,
        LoopInGameThreadWithDelay=function()end,RegisterLoadMapPreHook=function()end,RegisterLoadMapPostHook=function(fn)post[#post+1]=fn end}, {__index=_G})
    local C=assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/common.lua","t",env))()
    local steps={}
    local function check(name,fn) steps[#steps+1]={check=name,timeout=1,cond=function()fn();return true end} end
    check("shipping_scripts_compile",function()
        for _,name in ipairs({"ambient.lua","anomalies.lua","anomalies2.lua","anomalies3.lua","backpack.lua","car.lua","carfeel.lua","common.lua","cutscene.lua","desync.lua","garage.lua","guestact.lua","guestparts.lua","guestswap.lua","guestui.lua","hands.lua","heal.lua","health.lua","ids.lua","junkheap.lua","loot.lua","main.lua","mapmark.lua","nametag.lua","net.lua","overlay.lua","pause.lua","perf.lua","ping.lua","progression.lua","radiation.lua","radio.lua","replica.lua","rescue.lua","safety.lua","session.lua","stations.lua","steam.lua","story.lua","survivor.lua","survivor_mesh.lua","transition.lua","upgrades.lua","visual.lua","wheelflat.lua","wheelmotion.lua","world.lua"})do assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/"..name)) end
    end)
    check("world_teardown_without_context_is_none",function()
        assert(C.netMode()=="none");assert(not U.GetWorld():IsValid())
        U.GetWorldContextObject=U.GetWorld;assert(C.netMode()=="none")
    end)
    check("cache_reset_clears_objects_and_their_leases",function()
        rawTestWorld=T.world();local pc=T.localPC()
        env.FindAllOf=function()return {pc}end
        assert(U.GetPlayerController()==pc and U.GetWorld()==rawTestWorld)
        for _,fn in ipairs(post)do fn()end
        assert(U.GetPlayerController()==pc and U.GetWorld()==rawTestWorld,"reset returned a nil cache through a live lease")
        rawTestWorld=nil
    end)
    check("protocol_matches_author",function() assert(C.PROTOCOL_VERSION==6) end)
    check("pose_waits_for_creation",function()
        local s=R.new("world");assert(R.offer(s,"world","W1",3,{3}));assert(not R.take(s,"W1"))
        assert(R.adopt(s,"W1"));assert(R.take(s,"W1")[1]==3 and s.pending==0)
    end)
    check("reordered_and_duplicate_poses_rejected",function()
        local s=R.new("world");R.adopt(s,"W1")
        assert(R.offer(s,"world","W1",8,{8}));assert(not R.offer(s,"world","W1",7,{7}));assert(not R.offer(s,"world","W1",8,{80}));assert(R.take(s,"W1")[1]==8)
    end)
    check("reliable_final_survives_pose_loss",function()
        local s=R.new("world");R.adopt(s,"W1")
        for seq=1,99 do if seq%7==0 then R.offer(s,"world","W1",seq,{seq}) end end
        assert(R.offer(s,"world","W1",100,{100}));assert(not R.offer(s,"world","W1",98,{98}));assert(R.take(s,"W1")[1]==100)
    end)
    check("destroyed_id_never_rebinds",function()
        local s=R.new("world");R.adopt(s,"W1");R.remove(s,"W1")
        assert(not R.adopt(s,"W1"));assert(not R.offer(s,"world","W1",100,{100}));assert(not R.take(s,"W1"))
    end)
    check("previous_world_pose_is_inert",function()
        local s=R.new("new");R.adopt(s,"W1");assert(not R.offer(s,"old","W1",100,{100}));assert(not R.take(s,"W1"))
    end)
    check("pending_creation_buffer_is_bounded",function()
        local s=R.new("world",2);assert(R.offer(s,"world","W1",1,{}));assert(R.offer(s,"world","W2",1,{}));assert(not R.offer(s,"world","W3",1,{}))
        R.remove(s,"W1");assert(R.offer(s,"world","W3",1,{}))
    end)
    check("invalid_pose_ids_and_serials_rejected",function()
        local s=R.new("world")
        for _,seq in ipairs({-1,.5,math.huge,0/0}) do assert(not R.offer(s,"world","W1",seq,{})) end
        assert(not R.offer(s,"world","I:Inventory_Garage",1,{}))
    end)
    check("weak_lease_rejects_reused_object_address",function()
        local c=C;local pc=T.localPC();local lease=c.lease(pc)
        assert(c.resolve(lease)==pc);lease.key=lease.key.."-old";assert(c.resolve(lease)==nil)
        assert(type(PTNative_ObjectIdentity)=="function" and PTNative_ObjectIdentity(pc:GetAddress()):match("^%d+:%d+$"))
        assert(PTNative_ObjectMatches(c.lease(pc).key));assert(not PTNative_ObjectMatches("invalid"));assert(not PTNative_ObjectMatches("2147483647:2147483647"))
        env.PTNative_ObjectIdentity=function()return nil end;assert(c.identity(pc)==nil,"dead weak pointer fell back to a name");env.PTNative_ObjectIdentity=nil
    end)
    local function network()
        local incoming, outgoing, loops, pre, errors, datagrams={},{},{},{},{},{}
        local mode,info="listen",{caps=nil}
        local pawn={uid=1,IsValid=function()return true end,GetFName=function()return {ToString=function()return "Pawn1" end}end}
        local pc={uid=1,Pawn=pawn,IsValid=function()return true end,GetAddress=function()return 1 end,GetFullName=function()return "PC1" end}
        pc.IsLocalController=function()return mode=="client" end
        local common={netMode=function()return mode end,log=function(fmt,...) if fmt:find("PT|error",1,true) then errors[#errors+1]=string.format(fmt,...) end end,
            identity=function(o)return tostring(o.uid)end,lease=function(o)return {object=o,key=tostring(o.uid)}end,resolve=function(l)return l and l.key==tostring(l.object.uid) and l.object or nil end}
        local env=setmetatable({
            require=function(n)if n=="common" then return common elseif n=="session" then return {guestInfo=function()return info end} else assert(n=="UEHelpers");return {GetPlayerController=function()return pc end} end end,
            PTNative_TunnelMotionReset=function()datagrams={}end,
            PTNative_TunnelMotionPoll=function()local m=table.remove(datagrams,1);if m then return m[1],m[2],m[3] end end,
            PTNative_MsgReset=function()end,PTNative_MsgToGuest=function(_,k,d)outgoing[#outgoing+1]={k,d};return true end,
            PTNative_MsgMotionToGuest=function(_,k,d)outgoing[#outgoing+1]={k,d};return true end,
            PTNative_MsgToHost=function(_,k,d)outgoing[#outgoing+1]={k,d};return true end,
            PTNative_MsgPoll=function()local m=table.remove(incoming,1);if m then return m[1],m[2],1 end end,
            FindAllOf=function()return {pc}end,RegisterLoadMapPreHook=function(fn)pre[#pre+1]=fn end,
            LoopInGameThreadWithDelay=function(ms,fn)loops[ms]=loops[ms] or {};table.insert(loops[ms],fn)end,
        },{__index=_G})
        local n=assert(loadfile("ue4ss/Mods/PacificTogether/Scripts/net.lua","t",env))()
        local function inject(k,d)incoming[#incoming+1]={k,d};for _,fn in ipairs(loops[16])do fn()end;assert(#errors==0,table.concat(errors,";"))end
        return n,pc,inject,outgoing,pre,function(v)info=v end,function(v)mode=v end,
            function(k,d,seq)datagrams[#datagrams+1]={k,d,seq};for _,fn in ipairs(loops[16])do fn()end end
    end
    check("legacy_peer_receives_no_optional_motion",function()
        local n,pc,inject,out=network();inject("g.net.ack","0");assert(#out==0);assert(not n.toGuest(pc,"g.motion.items","test"));assert(#out==0)
    end)
    check("cloud_keypad_uses_legacy_or_negotiated_intent",function()
        local n,pc,inject,out,pre,info,mode=network();mode("client")
        assert(n.toHost("g.vis.keypad","lock"));assert(out[1][1]=="g.vis.keypad")
        inject("g.net.cap","world|motion,drop-velocity,intents|ticket")
        n.toHost("g.vis.keypad","lock");assert(out[#out][1]=="g.net.intent" and out[#out][2]:find("g.vis.keypad|lock",1,true))
    end)
    check("legacy_intent_wire_unchanged",function()
        local n,pc,inject,out,pre,info,mode=network();mode("client");assert(n.toHost("g.car.ctl","ign"));assert(out[1][1]=="g.car.ctl" and out[1][2]=="ign")
    end)
    check("intent_replay_and_stale_world_do_not_repeat_effect",function()
        local n,pc,inject,out,pre,info=network();info({caps="mv"})
        local effects=0;n.on("g.act.test",function()effects=effects+1 end)
        inject("g.net.ack","0");assert(out[1][1]=="g.net.cap")
        local epoch=n.worldToken();local ticket=epoch..":1";inject("g.net.cap",epoch.."|motion,intents|"..ticket);assert(n.peerSupports(pc,"motion"))
        inject("g.net.ready","");assert(n.lifecycle(pc)=="baseline")
        local req=epoch.."|1|"..ticket.."|g.act.test|spend"
        inject("g.net.intent",req);assert(effects==0,"baseline not yet applied")
        inject("g.net.baseline",epoch);assert(n.lifecycle(pc)=="active")
        inject("g.net.intent",req);inject("g.net.intent",req);assert(effects==1)
        inject("g.net.intent","old|2|"..ticket.."|g.act.test|spend");inject("g.net.intent",epoch.."|2|old-pawn|g.act.test|spend");assert(effects==1)
        inject("g.act.test","unwrapped");assert(effects==1)
        info(nil);inject("g.net.intent",epoch.."|2|"..ticket.."|g.act.test|spend");assert(effects==1,"unauthenticated peer")
        info({caps="mv"});for _,fn in ipairs(pre)do fn()end;inject("g.net.intent",req);assert(effects==1 and n.lifecycle(pc)=="disconnected")
    end)
    check("all_baseline_sections_apply_before_active",function()
        local n,pc,inject,out,pre,info,mode=network();mode("client")
        inject("g.net.cap","host-world|motion,intents|pawn-ticket")
        n.baselineComplete("car");n.baselineComplete("loot");assert(n.lifecycle()=="loading")
        n.baselineComplete("visual");assert(n.lifecycle()=="active");assert(out[#out][1]=="g.net.baseline")
    end)
    check("replacement_pawn_requires_new_ticket",function()
        local n,pc,inject,out,pre,info=network();info({caps="mv"});local effects=0;n.on("g.act.test",function()effects=effects+1 end)
        inject("g.net.ack","0");local epoch=n.worldToken();inject("g.net.cap",epoch.."|intents|"..epoch..":1")
        inject("g.net.ready","");inject("g.net.baseline",epoch)
        pc.Pawn.uid=2;inject("g.net.intent",epoch.."|1|"..epoch..":1|g.act.test|spend");assert(effects==0)
        inject("g.net.ack","0");inject("g.net.cap",epoch.."|intents|"..epoch..":2")
        inject("g.net.intent",epoch.."|1|"..epoch..":2|g.act.test|spend");assert(effects==1)
    end)
    check("datagrams_reject_old_world_and_reordering",function()
        local n,pc,inject,out,pre,info,mode,pose=network();mode("client");local received=0
        n.on("g.motion.test",function()received=received+1 end)
        inject("g.net.cap","world|motion,intents,datagrams|ticket")
        pose("g.motion.test","old|wrong-world",10);assert(received==0)
        pose("g.motion.test","world|current",7);pose("g.motion.test","world|old",6);pose("g.motion.test","world|duplicate",7);assert(received==1)
        pose("g.motion.test","world|next",8);assert(received==2)
        for _,fn in ipairs(pre)do fn()end;pose("g.motion.test","world|previous",9);assert(received==2)
    end)
    check("invalid_ack_cannot_block_game_thread",function()
        local n,pc,inject=network();inject("g.net.ack","9007199254740991");inject("g.net.ack","nan");inject("g.net.ack","-1")
    end)
    return steps
end
