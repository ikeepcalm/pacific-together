-- Transfer a real test WAV and ensure the guest does not repeatedly restart it.
return function(T)
    local L=require("scenarios.sessionlib")(T)
    local function mm() return T.first("BP_MusicManager_C") end
    local function count(s)
        local f=io.open("ue4ss/UE4SS.log","rb");if not f then return 0 end
        local text=f:read("a");f:close();local n,i=0,1
        while true do local p=text:find(s,i,true);if not p then return n end;n=n+1;i=p+1 end
    end
    local got={}
    local function poll() while true do local k,d=PTNative_MsgPoll("t.radioshared.");if not k then return end;got[k]=d end end
    local function send(k,d)
        if T.ROLE=="host" then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.radioshared."..k,d or "1")
        else PTNative_MsgToHost(T.localPC():GetAddress(),"t.radioshared."..k,d or "1") end
    end
    local function has(k) poll();return got["t.radioshared."..k]~=nil end
    local steps={};local function add(s) steps[#steps+1]=s end
    if T.ROLE=="host" then
        local track,orig,bt
        local function ms() return PTNative_MediaTime(mm().ExternalMediaPlayer:GetAddress()) end
        for _,s in ipairs(T.loadFixture("garage")) do add(s) end
        add({check="guest_joined",timeout=240,cond=function() return L.guestChar()~=nil end})
        add({wait=20})
        add({run=function()
            local m=mm();m:SetGarageStereoOn(true)
            local samples={};for i=0,7999 do samples[#samples+1]=string.char(math.floor(128+25*math.sin(2*math.pi*440*i/8000))) end
            local audio=string.rep(table.concat(samples),150)
            local f=assert(io.open("ue4ss/pt-radio-test.wav","wb"))
            f:write("RIFF",string.pack("<I4",36+#audio),"WAVEfmt ",string.pack("<I4I2I2I4I4I2I2",16,1,1,8000,8000,1,8),"data",string.pack("<I4",#audio),audio);f:close()
            orig=m.DefaultRadioPlaylist[1]
            track=StaticConstructObject(StaticFindObject("/Script/PenDriverPro.MusicTrack"),m)
            track.Title=FText("PT shared test");track.Artist=FText("PT fixture")
            local ph=io.popen("cd");local cwd=ph:read("l"):gsub("\\","/");ph:close()
            track.ExternalUrl="file://"..cwd.."/ue4ss/pt-radio-test.wav"
            m.DefaultRadioPlaylist[1]=track;m.RadioPlaylist=m.DefaultRadioPlaylist
            for i=1,m.RadioPlaylist:GetArrayNum()-1 do m.RadioPlaylist[i]=track end
            m:SkipTrack(1);send("start")
        end})
        add({check="host_playing_test_file",timeout=30,cond=function()
            local t=mm():CurrentRadioTrack();return t:IsValid() and t.ExternalUrl:ToString():find("pt-radio-test.wav",1,true)~=nil
        end})
        add({check="guest_playback_stable",timeout=120,cond=function() return has("stable") end})
        -- the playtest loop (2026-11-15): a resync reopened the host's file, ending its song. Over ~40 s the host keeps one track and
        -- sends no further restart (r=1), and its file is never reopened
        local mark
        add({run=function() mark={r=count("r=1"),opens=count("PT|radio play"),key=mm():CurrentRadioTrack():GetFName():ToString()} end})
        add({wait=40})
        add({check="host_track_not_restarted_or_skipped",timeout=3,cond=function()
            local t=mm():CurrentRadioTrack();local same=t:IsValid() and t:GetFName():ToString()==mark.key
            T.log("PT|info host radio same=%s r=%d->%d",tostring(same),mark.r,count("r=1"))
            return same and count("r=1")<=mark.r
        end})
        -- same position: the host jumps 70 s into its song (like a guest that joined, or got the file, late); the guest follows
        add({run=function() PTNative_MediaSeek(mm().ExternalMediaPlayer:GetAddress(),70000);T.log("PT|info host seek 70 s, now %d",ms());send("seeked") end})
        add({wait=22})
        add({run=function() send("posdone") end})
        -- built-in tracks: back to the game's own playlist; the host plays three of its tracks one after the other. The guest
        -- (custom-music mode, a library of its own) must land on each and never be heard on a song of its own
        for n=1,3 do
            add({run=function()
                local m=mm();m.DefaultRadioPlaylist[1]=orig
                local k=0
                for i=3,m.DefaultRadioPlaylist:GetArrayNum() do
                    local t=m.DefaultRadioPlaylist[i]
                    if t.ExternalUrl:ToString()=="" then k=k+1;if k==n then bt=t;break end end
                end
                m.RadioPlaylist=m.DefaultRadioPlaylist
                for i=1,m.RadioPlaylist:GetArrayNum()-1 do m.RadioPlaylist[i]=bt end
                m:SkipTrack(1);T.log("PT|info host builtin %d %s",n,bt:GetFName():ToString());send("b"..n,bt:GetFName():ToString())
            end})
            add({check="host_on_builtin_"..n,timeout=10,cond=function() local t=mm():CurrentRadioTrack();return t:IsValid() and t:GetFName():ToString()==bt:GetFName():ToString() end})
            add({check="guest_builtin_done_"..n,timeout=60,cond=function() return has("bdone"..n) end})
        end
        add({check="guest_builtin_stable",timeout=60,cond=function() return has("bstable") end})
        add({check="host_builtin_unchanged",timeout=3,cond=function() return mm():CurrentRadioTrack():GetFName():ToString()==bt:GetFName():ToString() end})
        add({run=function() send("done") end});add({wait=2});return steps
    end
    add(T.onMap("RB_MainMenu",90))
    add({check="guest_in_garage",timeout=240,cond=function() return T.netMode()=="client" and T.map()=="RB_Garage" end})
    -- the friend's setup: custom-music mode with a big library of its own (the game's SkipTrack then draws from it too)
    add({run=function()
        local us
        for _,u in ipairs(FindAllOf("DrivingGameUserSettings") or {}) do if u:GetFullName():find("Transient.DrivingGameUserSettings_",1,true) then us=u end end
        if us then us.RadioSource=1 end
        for i=1,150 do
            local name=string.format("../../Custom/Radio/ptfill%03d.wav",i)
            local f=io.open(name,"rb")
            if f then f:close() else
                f=assert(io.open(name,"wb"))
                f:write("RIFF",string.pack("<I4",36+8000),"WAVEfmt ",string.pack("<I4I2I2I4I4I2I2",16,1,1,8000,8000,1,8),"data",string.pack("<I4",8000),string.rep("\128",8000));f:close()
            end
        end
        mm():RescanLocalFiles()
    end})
    add({wait=6})
    add({check="guest_library_scanned",timeout=30,cond=function() T.log("PT|info library %d",mm():GetNumLocalFilesScanned());return mm():GetNumLocalFilesScanned()>=120 end})
    add({check="host_started",timeout=240,cond=function() return has("start") end})
    add({check="guest_opened_shared_file",timeout=100,cond=function() return count("PT|radio opened L:pt-radio-test.wav")>=1 end})
    add({wait=15})
    add({check="guest_playing_without_restart_loop",timeout=3,cond=function()
        local n=count("PT|radio opened L:pt-radio-test.wav");local p=mm().ExternalMediaPlayer
        T.log("PT|info shared radio opened=%d playing=%s url=%s",n,tostring(p:IsPlaying()),p:GetUrl():ToString())
        local track=mm():CurrentRadioTrack()
        return n==1 and p:IsPlaying() and p:GetUrl():ToString():find("pt_music",1,true)~=nil
            and track:IsValid() and track.Title:ToString()=="PT shared test" and track.Artist:ToString()=="PT fixture"
    end})
    add({run=function() send("stable") end})
    -- same position: the host jumps 70 s ahead; within 22 s the guest has followed (seek) and its position as each state message
    -- arrives (radio.lua logs the drift) stays within 1 s
    add({check="host_seeked",timeout=120,cond=function() return has("seeked") end})
    add({check="guest_position_within_1s",timeout=60,cond=function()
        if not has("posdone") then return false end
        local f=io.open("ue4ss/UE4SS.log","rb");local text=f:read("a");f:close()
        local from=0;for p in text:gmatch("()PT|radio seek L:pt%-radio%-test") do from=p end
        local n,worst=0,0
        if from>0 then for d in text:sub(from):gmatch("PT|radio pos L:pt%-radio%-test%.wav drift=(%-?%d+)") do n=n+1;worst=math.max(worst,math.abs(tonumber(d))) end end
        T.log("PT|info seeks=%d drifts after the last seek=%d worst=%d ms opened=%d",count("PT|radio seek"),n,worst,count("PT|radio opened L:pt-radio-test.wav"))
        return from>0 and n>=2 and worst<1000 and count("PT|radio opened L:pt-radio-test.wav")==1
    end})
    local want,audible,grace
    for n=1,3 do
        add({check="guest_follows_builtin_"..n,timeout=30,cond=function()
            if not has("b"..n) then return false end
            want=got["t.radioshared.b"..n]
            local t=mm():CurrentRadioTrack();local nm=t:IsValid() and t:GetFName():ToString() or "?"
            grace=(grace or 0)+1
            if grace>2 and nm~=want and mm().MusicVolume>0.05 then audible=(audible or 0)+1;T.log("PT|info audible %s while the host plays %s",nm,want) end
            return nm==want and t.ExternalUrl:ToString()=="" and not mm().ExternalMediaPlayer:IsPlaying()
        end})
        add({wait=8});add({run=function() grace=0;send("bdone"..n) end})
    end
    -- 25 s on the last track: no hop, no restart of its own
    local polls=0
    add({check="guest_stays_on_builtin",timeout=60,cond=function()
        polls=polls+1
        local t=mm():CurrentRadioTrack();if not(t:IsValid() and t:GetFName():ToString()==want) then audible=(audible or 0)+1 end
        return polls>=25
    end})
    add({check="guest_never_audibly_wrong",timeout=3,cond=function()
        T.log("PT|info audible wrong polls=%s volume=%.2f",tostring(audible),mm().MusicVolume)
        return audible==nil and mm().MusicVolume>0.05
    end})
    add({run=function() send("bstable") end})
    add({check="host_done",timeout=60,cond=function() return has("done") end})
    return steps
end
