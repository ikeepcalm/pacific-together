-- PT6 radio: the guest uses the car radio and the garage stereo like the host (intents to the host, state back to both), and both
-- hear the same track; a custom music file only one side has is skipped.
--   guest_*  : the guest turns the car radio on and skips a station with the radio part's own events; the host's state matches and
--              both sides play the same track. The host skips a station and the guest follows. Stereo and volume both ways.
--   custom   : both sides get synthetic custom tracks (MusicTrack with an ExternalUrl; the real library did not put scanned files into
--              RadioPlaylist in the probe, docs/spikes/PT6-radio.md). ptA is only on the host: playing it, the host skips it and never
--              announces it, the guest never plays it. ptB is on both: the host plays it and the guest plays it too.
-- Run (needs the audio engine, so NOT headless: CurrentRadioTrack is invalid with -nosound):
--   tools/run-test.ps1 -Scenario radio -Fixture garage -Root C:\PTLanes\radio -Port 7861
-- Mutation noradio: radio.lua does nothing (the host never sees the guest's radio, the guest never follows the host's track).
-- Not provable by a test run: that the music is audible and the same song position to the second (no seek from Lua).
return function(T)
    local L = require("scenarios.carlib")(T)
    local S = require("scenarios.sessionlib")(T)
    local log, ROLE = T.log, T.ROLE

    local function cm() return T.first("BP_CarManager_C") end
    local function mm() return T.first("BP_MusicManager_C") end
    local function radioPart()
        -- the one on the car (a loose copy without a parent does nothing)
        for _, c in ipairs(FindAllOf("BP_CarPart_Internal_Radio_C") or {}) do
            if c:IsValid() and c:GetAttachParentActor():IsValid() then return c end
        end
    end
    local function carRadioOn() local v = {}; cm():GetCarRadioOnOffState(v); return v.CarState_Radio == true end
    local function vol() return math.floor(mm().MusicVolume * 100 + 0.5) end
    local function key()
        local c = mm():CurrentRadioTrack()
        if not c:IsValid() then return nil end
        local u = c.ExternalUrl:ToString()
        if u ~= "" then return "L:" .. (u:match("([^/\\]+)$") or u):lower() end
        return "B:" .. c:GetFName():ToString()
    end
    -- occurrences of a plain text in this copy's UE4SS log (cwd is Binaries/Win64)
    local function count(pattern)
        local f = io.open("ue4ss/UE4SS.log", "rb")
        if not f then return -1 end
        local text, n, i = f:read("a"), 0, 1
        f:close()
        while true do
            local s = text:find(pattern, i, true)
            if not s then return n end
            n, i = n + 1, s + 1
        end
    end

    -- synthetic custom tracks: held in DefaultRadioPlaylist (a UPROPERTY, so they are not collected) and copied into the playlist
    local tracks = {}
    local function makeTrack(name)
        local o = StaticConstructObject(StaticFindObject("/Script/PenDriverPro.MusicTrack"), mm())
        o.ExternalUrl = "file://C:/PTLanes/radio/" .. (ROLE == "host" and "client1" or "client2") .. "/PenDriverPro/Custom/Radio/" .. name .. ".wav"
        tracks[name] = o
        local m, i = mm(), 1
        for _, t in pairs(tracks) do m.DefaultRadioPlaylist[i] = t; i = i + 1 end
        return o
    end
    local function hold() local m = mm(); m.RadioPlaylist = m.DefaultRadioPlaylist end
    -- the game's SkipTrack plays a random front entry: every front entry is the wanted track
    local function force(name)
        hold()
        local pl = mm().RadioPlaylist
        for i = 1, pl:GetArrayNum() - 1 do pl[i] = tracks[name] end
        mm():SkipTrack(1)
    end

    local inbox = {}
    local function drain()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then return end
            inbox[kind] = { data = data, at = os.time(), n = (inbox[kind] and inbox[kind].n or 0) + 1 }
        end
    end
    local function got(kind) drain(); return inbox[kind] end

    if ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function send(kind, data) PTNative_MsgToGuest(S.remotePCs()[1]:GetAddress(), kind, data or "") end
        local marks = {}
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return S.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function() if carRadioOn() then cm():SetCarRadioOnOffState(false, true) end; marks.skip1 = count("radio skip 1@cr applied"); send("t.go") end })
        add({ wait = 3 })

        -- the guest turns the car radio on (the part's own interaction), then skips a station
        add({ check = "host_car_radio_on_by_guest", timeout = 60, cond = function() return got("t.cr") ~= nil and carRadioOn() end })
        add({ wait = 4 })
        add({ check = "host_skip_applied_for_guest", timeout = 60, cond = function() return got("t.sk") ~= nil and count("radio skip 1@cr applied") > marks.skip1 end })
        add({ wait = 5 })
        local phase = 0
        local function announce()
            phase = phase + 1
            local p = phase
            LoopInGameThreadWithDelay(500, function()
                if phase == p then pcall(function() send("t.key", p .. "|" .. tostring(key())) end) end
            end)
        end
        add({ run = announce })
        add({ check = "host_guest_done_follow1", timeout = 60, cond = function() return got("t.f1") ~= nil end })
        -- the host skips a station, the guest follows
        add({ run = function() radioPart().BP_RadioComponent:ChangeChannel(1) end })
        add({ wait = 6 })
        add({ run = announce })
        add({ check = "host_guest_done_follow2", timeout = 60, cond = function() return got("t.f2") ~= nil end })

        -- garage stereo and volume, both ways
        add({ run = function() send("t.gs0") end })
        add({ check = "host_stereo_on_by_guest", timeout = 60, cond = function() return got("t.gs") ~= nil and mm().GarageStereoOn == true end })
        add({ run = function() mm():SetRadioVolume(0.33); send("t.vol1") end })
        add({ check = "host_volume_by_guest", timeout = 60, cond = function() return got("t.vol2") ~= nil and vol() == 61 end })

        -- custom music: ptA only here, ptB on both
        add({ run = function()
            makeTrack("ptA"); makeTrack("ptB"); hold()
            marks.skip, marks.sent = count("radio host skips L:pta.wav"), count("trk=L:pta.wav")
            send("t.mk")
        end })
        add({ wait = 6 })
        add({ run = function() force("ptA") end })
        add({ check = "host_skips_custom_the_guest_lacks", timeout = 60, cond = function()
            return count("radio host skips L:pta.wav") > marks.skip and key() ~= "L:pta.wav"
        end })
        -- the guest finds out from its own music folder (radio.lua makeTrack): the host may announce the file once, then the guest's
        -- miss stops it for a minute (the check runs after the 60 s wait above: at most two)
        add({ check = "host_announced_missing_custom_once_a_minute", timeout = 1, cond = function() return count("trk=L:pta.wav") <= marks.sent + 2 end })
        add({ run = function() marks.ptb = count("trk=L:ptb.wav"); marks.at = os.clock(); send("t.b") end })
        add({ run = function() force("ptB") end })
        add({ check = "host_announces_shared_custom", timeout = 60, cond = function()
            if count("trk=L:ptb.wav") > marks.ptb then return true end
            if os.clock() - marks.at > 6 then marks.at = os.clock(); pcall(force, "ptB") end -- a file the player cannot decode ends at once
            return false
        end })
        add({ check = "host_guest_done", timeout = 90, cond = function() return got("t.done") ~= nil end })
        add({ wait = 3 })
        return steps
    end

    -- guest ------------------------------------------------------------------------------------------------------------
    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local function toHost(kind, data) PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end
    local marks = {}
    local function follows(n)
        local m = got("t.key")
        if not m or os.time() - m.at > 3 then return false end
        local p, k = m.data:match("^(%d+)|(.*)$")
        local mine = tostring(key())
        if tonumber(p) < n then return false end
        if k ~= "nil" and k == mine then return true end
        log("PT|info follow host=%s guest=%s", k, mine)
        return false
    end
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_has_car_radio_part", timeout = 120, cond = function() return radioPart() ~= nil and got("t.go") ~= nil end })
    -- the part's own ToggleRadio does nothing for a guest standing outside the car (it needs the seated interaction): the manager call it ends in
    add({ run = function() if not carRadioOn() then cm():SetCarRadioOnOffState(true, true) end; toHost("t.cr") end })
    add({ wait = 5 })
    add({ run = function() radioPart().BP_RadioComponent:ChangeChannel(1); toHost("t.sk") end })
    add({ check = "guest_same_track_after_own_skip", timeout = 60, cond = function() return follows(1) end })
    add({ run = function() toHost("t.f1") end })
    add({ check = "guest_follows_host_skip", timeout = 60, cond = function() return follows(2) end })
    add({ run = function() toHost("t.f2") end })
    add({ check = "guest_gets_stereo_start", timeout = 60, cond = function() return got("t.gs0") ~= nil end })
    add({ run = function() mm():SetGarageStereoOn(true); toHost("t.gs") end })
    add({ check = "guest_sees_volume", timeout = 60, cond = function() return got("t.vol1") ~= nil and vol() == 33 end })
    add({ run = function() mm():SetRadioVolume(0.61); toHost("t.vol2") end })

    add({ check = "guest_custom_tracks_ready", timeout = 60, cond = function() return got("t.mk") ~= nil end })
    add({ run = function()
        makeTrack("ptB"); makeTrack("ptC"); hold()
        marks.a, marks.b = count("radio play L:pta.wav"), count("radio play L:ptb.wav")
    end })
    add({ check = "guest_host_custom_a_missing_here", timeout = 90, cond = function() return got("t.b") ~= nil end })
    add({ check = "guest_never_played_missing_custom", timeout = 1, cond = function()
        return count("radio play L:pta.wav") == marks.a and key() ~= "L:pta.wav"
    end })
    add({ check = "guest_plays_shared_custom", timeout = 90, cond = function() return count("radio play L:ptb.wav") > marks.b end })
    add({ run = function() toHost("t.done") end })
    add({ wait = 3 })
    return steps
end
