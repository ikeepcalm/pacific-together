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
        local track
        for _,s in ipairs(T.loadFixture("garage")) do add(s) end
        add({check="guest_joined",timeout=240,cond=function() return L.guestChar()~=nil end})
        add({wait=20})
        add({run=function()
            local m=mm();m:SetGarageStereoOn(true)
            local samples={};for i=0,7999 do samples[#samples+1]=string.char(math.floor(128+25*math.sin(2*math.pi*440*i/8000))) end
            local audio=string.rep(table.concat(samples),75)
            local f=assert(io.open("ue4ss/pt-radio-test.wav","wb"))
            f:write("RIFF",string.pack("<I4",36+#audio),"WAVEfmt ",string.pack("<I4I2I2I4I4I2I2",16,1,1,8000,8000,1,8),"data",string.pack("<I4",#audio),audio);f:close()
            track=StaticConstructObject(StaticFindObject("/Script/PenDriverPro.MusicTrack"),m)
            track.ExternalUrl="file://D:/PTLanes/vehicle-proxy/client1/PenDriverPro/Binaries/Win64/ue4ss/pt-radio-test.wav"
            m.DefaultRadioPlaylist[1]=track;m.RadioPlaylist=m.DefaultRadioPlaylist
            for i=1,m.RadioPlaylist:GetArrayNum()-1 do m.RadioPlaylist[i]=track end
            m:SkipTrack(1);send("start")
        end})
        add({check="host_playing_test_file",timeout=30,cond=function()
            local t=mm():CurrentRadioTrack();return t:IsValid() and t.ExternalUrl:ToString():find("pt-radio-test.wav",1,true)~=nil
        end})
        add({check="guest_playback_stable",timeout=120,cond=function() return has("stable") end})
        add({run=function() send("done") end});add({wait=2});return steps
    end
    add(T.onMap("RB_MainMenu",90))
    add({check="guest_in_garage",timeout=240,cond=function() return T.netMode()=="client" and T.map()=="RB_Garage" end})
    add({check="host_started",timeout=240,cond=function() return has("start") end})
    add({check="guest_opened_shared_file",timeout=100,cond=function() return count("PT|radio opened L:pt-radio-test.wav")>=1 end})
    add({wait=15})
    add({check="guest_playing_without_restart_loop",timeout=3,cond=function()
        local n=count("PT|radio opened L:pt-radio-test.wav");local p=mm().ExternalMediaPlayer
        T.log("PT|info shared radio opened=%d playing=%s url=%s",n,tostring(p:IsPlaying()),p:GetUrl():ToString())
        return n<=2 and p:IsPlaying() and p:GetUrl():ToString():find("pt_music",1,true)~=nil
    end})
    add({run=function() send("stable") end})
    add({check="host_done",timeout=60,cond=function() return has("done") end})
    return steps
end
