-- PT6 radio: the in-car radio and the garage stereo work for the guest like for the host; both hear the same music.
-- The host is authoritative (same pattern as guestact.lua: intents up, state down).
--   g.radio.i     guest -> host  intent: gs/cr/vol=<value> (what the guest's own radio part or stereo just did), skip=<dir>@gs|cr
--                 (the radio component's ChangeChannel), miss=<track key> (the guest cannot play that custom file), resync=1
--   g.radio.s     host -> guests state: gs, cr, vol, trk=<track key>, r=1 (restart: both start the track now). Sent on every change,
--                 when a guest arrives, after a map load and as a 5 s heartbeat (a rejected intent is corrected by it)
--   g.radio.have  guest -> host: the custom music files the guest has (lower-case file names, "|" separated)
-- Track key: "B:<object name>" for the game's own tracks, "L:<lower-case file name>" for the player's custom files (MusicTrack with an
-- ExternalUrl). A custom file is matched by name only: hashing needs the file read on both sides and the game names tracks by file.
-- A custom track the guest does not have is skipped by the host (SkipTrack) until it plays one both have; the host never plays
-- one the guest lacks, the guest never keeps one the host lacks (the host's track overrides it). The game's own tracks are in every
-- copy, so a shared track exists unless a playlist holds nothing but custom files (then the guest has nothing to apply: silent).
-- Playing a chosen track: the game's SkipTrack picks a random entry of RadioPlaylist (not the last, which is the current track),
-- moves it to the end and drops every copy of it. So the front entries are all set to the wanted track for one SkipTrack, then the list
-- is restored from DefaultRadioPlaylist with the wanted track last (docs/spikes/PT6-radio.md).
-- Position inside a track cannot be set from Lua (no seek in the Wwise Blueprint API): a restart (r=1) starts the same track on both
-- sides at the same moment after a join and a map load; between those both sides start tracks within a message of each other.
-- Inert outside a session.
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local log = common.log

local M = {}
local MUT = os.getenv("PT_MUTATE")
if MUT == "noradio" or MUT == "nofeel" then
    log("PT|radio disabled (mutation %s)", MUT)
    return M
end

local first = common.first
local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function now()
    local s, p = {}, {}
    UEHelpers.GetGameplayStatics():GetAccurateRealTime(s, p)
    return s.Seconds + p.PartialSeconds
end
local function mode() return common.netMode() end
local function isHost() return mode() == "listen" and #net.guests() > 0 end
local function isGuest() return mode() == "client" end
local function split(s) local t = {} for x in (s .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = x end return t end
local function parse(data)
    local t = {}
    for _, f in ipairs(split(data)) do
        local k, v = f:match("^(%w+)=(.*)$")
        if k then t[k] = v end
    end
    return t
end
local function pack(t)
    local r = {}
    for k, v in pairs(t) do r[#r + 1] = k .. "=" .. tostring(v) end
    table.sort(r)
    return table.concat(r, "\t")
end

-- tracks ---------------------------------------------------------------------------------------------------------------

local function keyOf(t)
    if not valid(t) then return nil end
    local url = t.ExternalUrl:ToString()
    if url ~= "" then return "L:" .. (url:match("([^/\\]+)$") or url):lower() end
    return "B:" .. t:GetFName():ToString()
end
local function isCustom(k) return k ~= nil and k:sub(1, 2) == "L:" end

local function musicManager() return first("BP_MusicManager_C") end
-- the track that plays (the last entry of the playlist while the audio engine runs; headless has no current track)
local function curKey(mm)
    local ok, k = pcall(function()
        local c = mm:CurrentRadioTrack()
        return valid(c) and keyOf(c) or nil
    end)
    return ok and k or nil
end
local function findTrack(mm, key)
    local found
    pcall(function()
        mm.RadioPlaylist:ForEach(function(_, e) local o = e:get(); if not found and keyOf(o) == key then found = o end end)
        if not found then
            for _, o in ipairs(FindAllOf("MusicTrack") or {}) do if keyOf(o) == key then found = o; break end end
        end
    end)
    return found
end
-- The game makes a custom file's MusicTrack only when it is about to play it (the guest's list grew one by one, playtest 2026-10-31,
-- and the host skipped every custom track as "lacking"). So the guest looks for the file itself in its music folder (the folder of
-- any custom track it has) and makes the track object the game would.
local dirOf -- the music folder as the game writes it in ExternalUrl, with its trailing separator
local function musicDir()
    if dirOf then return dirOf end
    for _, o in ipairs(FindAllOf("MusicTrack") or {}) do
        local ok, url = pcall(function() return valid(o) and o.ExternalUrl:ToString() or "" end)
        local d = ok and url:match("^(.*[/\\])[^/\\]+$")
        if d then dirOf = d; return d end
    end
    -- none loaded yet: the game's own custom radio folder
    local la = os.getenv("LOCALAPPDATA")
    return la and (la:gsub("\\", "/") .. "/PenDriverPro/Custom/Radio/") or nil
end
local made = {} -- key -> MusicTrack made here
local function makeTrack(mm, key)
    if made[key] and valid(made[key]) then return made[key] end
    local d = musicDir()
    if not d then return nil end
    local name = key:sub(3) -- "L:<file>": lower case, Windows does not mind
    local f = io.open((d:gsub("^file:/*", "")) .. name, "rb")
    if not f then return nil end
    f:close()
    local ok, t = pcall(function()
        local o = StaticConstructObject(StaticFindObject("/Script/PenDriverPro.MusicTrack"), mm)
        o.ExternalUrl = d .. name
        o.Title = FText((name:gsub("%.%w+$", "")))
        return o
    end)
    if not ok or not valid(t) or keyOf(t) ~= key then log("PT|radio could not make %s: %s", key, tostring(t)); return nil end
    made[key] = t
    log("PT|radio made track %s", key)
    return t
end

local function haveList() -- custom files this copy knows (library scan results and anything in the playlists)
    local set = {}
    for _, o in ipairs(FindAllOf("MusicTrack") or {}) do
        local k = valid(o) and keyOf(o)
        if k and isCustom(k) then set[k] = true end
    end
    return set
end

-- play a chosen track now: see the header. `done` waits for the game to start it, then restores the list.
local playing -- { key, at, mm }
local function playTrack(mm, key)
    local t = findTrack(mm, key) or (isCustom(key) and makeTrack(mm, key))
    if not t then return false end
    local pl = mm.RadioPlaylist
    local n = pl:GetArrayNum()
    if n < 3 then mm.RadioPlaylist = mm.DefaultRadioPlaylist; pl = mm.RadioPlaylist; n = pl:GetArrayNum() end
    for i = 1, n - 1 do pl[i] = t end
    mm:SkipTrack(1)
    playing = { key = key, at = now(), mm = mm, t = t }
    log("PT|radio play %s", key)
    return true
end
local function finishPlay()
    local p = playing
    if not p then return end
    local mm = p.mm
    local k = valid(mm) and curKey(mm)
    if k ~= p.key and now() - p.at < 4 then return end -- the game picks it a moment after SkipTrack
    playing = nil
    pcall(function()
        mm.RadioPlaylist = mm.DefaultRadioPlaylist
        local pl, n = mm.RadioPlaylist, mm.RadioPlaylist:GetArrayNum()
        local at = n
        for i = 1, n do if keyOf(pl[i]) == p.key then at = i; break end end
        pl[at] = pl[n]
        pl[n] = p.t -- the current track is last
    end)
    log("PT|radio played %s now=%s", p.key, tostring(k))
end

-- radios (gs garage stereo, cr car radio, vol volume) -------------------------------------------------------------------

local function radioState()
    local mm, cm = musicManager(), first("BP_CarManager_C")
    if not mm or not cm then return end
    return { gs = mm.GarageStereoOn and 1 or 0, cr = cm.CarState_RadioOnOff and 1 or 0, vol = math.floor(mm.MusicVolume * 100 + 0.5) }, mm, cm
end
local function applyRadio(k, v, mm, cm)
    if k == "gs" then
        mm:SetGarageStereoOn(v == 1)
        local st = first("BP_Garage_Stereo_01_C")
        if st then
            pcall(function() if v == 1 then st:TurnStereoVisualsOn(true) else st:TurnStereoVisualsOff(true) end end)
            pcall(function() st:UpdateIcon() end)
        end
    elseif k == "cr" then cm:SetCarRadioOnOffState(v == 1, true)
    elseif k == "vol" then mm:SetRadioVolume(v / 100) end
end
local function applyPairs(t, mm, cm)
    local s = radioState()
    for _, k in ipairs({ "gs", "cr", "vol" }) do
        local v = tonumber(t[k])
        if v and s[k] ~= v then
            local ok, err = pcall(applyRadio, k, v, mm, cm)
            if not ok then log("PT|error radio %s %s", k, tostring(err)) end
            log("PT|radio %s=%d applied", k, v)
        end
    end
end

local last = {}        -- gs/cr/vol as last sent or received
local lastTrk          -- host: the track last sent
local hostKey          -- guest: the host's latest track
local missed = {}      -- guest: keys already reported missing
local guestHave = {}   -- host: guest controller name -> set of custom keys
local denied = {}      -- host: custom keys a guest said it cannot play
local skipAt, skipN = 0, 0
local lastGuests, hbAt, resyncAt = 0, 0, nil
local haveSent, haveAt = "", 0

-- a custom track the guest lacks: the host skips it (rate limited) until a shared one plays
local function lacking(k)
    if not isCustom(k) then return false end
    -- only a file the guest said it cannot play, for a minute (it may have been still loading), and never one it has: its
    -- have-list holds just the tracks its game has loaded so far (see makeTrack)
    if not denied[k] or now() - denied[k] > 60 then return false end
    for _, pc in ipairs(net.guests()) do
        local set = guestHave[pc:GetFullName()]
        if set and set[k] then return false end
    end
    return true
end

local function sendState(s, mm, restartKey, all)
    local t = {}
    for k, v in pairs(s) do if all or last[k] ~= v then t[k] = v end end
    for k, v in pairs(s) do last[k] = v end
    local k = restartKey or curKey(mm)
    if k and not lacking(k) then t.trk = k; lastTrk = k end -- a custom file the guest lacks is never announced
    if restartKey then t.r = 1 end
    if next(t) then
        net.toGuests("g.radio.s", pack(t))
        log("PT|radio sent %s", pack(t):gsub("\t", ";"))
    end
end

-- guest -> host intents -------------------------------------------------------------------------------------------------

net.on("g.radio.i", function(pc, data)
    if mode() ~= "listen" then return end
    local t = parse(data)
    local s, mm, cm = radioState()
    if not s then return end
    applyPairs(t, mm, cm)
    if t.skip then
        local d, which = t.skip:match("^(%-?%d+)@(%a+)$")
        d = tonumber(d)
        if d and (d == 1 or d == -1) then
            local rc
            if which == "gs" then local st = first("BP_Garage_Stereo_01_C"); rc = st and st.BP_RadioComponent
            else
                -- the radio part on the car (a loose copy without a parent exists too and does nothing)
                for _, c in ipairs(FindAllOf("BP_CarPart_Internal_Radio_C") or {}) do
                    if valid(c) and valid(c:GetAttachParentActor()) then rc = c.BP_RadioComponent; break end
                end
            end
            if not valid(rc) then rc = first("BP_RadioComponent_C") end
            if valid(rc) then pcall(function() rc:ChangeChannel(d) end) else pcall(function() mm:SkipTrack(d) end) end
            log("PT|radio skip %d@%s applied", d, which)
        end
    end
    if t.miss then denied[t.miss] = now(); log("PT|radio guest lacks %s", t.miss) end
    if t.resync then resyncAt = now() + 0.5 end
end)
net.on("g.radio.have", function(pc, data)
    if mode() ~= "listen" then return end
    local set = {}
    for n in data:gmatch("[^|]+") do set[n] = true end
    guestHave[pc:GetFullName()] = set
    log("PT|radio guest has %d custom file(s)", select(2, data:gsub("|", "|")) + (data == "" and 0 or 1))
end)

-- host -> guest state -----------------------------------------------------------------------------------------------------

net.on("g.radio.s", function(_, data)
    if mode() ~= "client" then return end
    local t = parse(data)
    local s, mm, cm = radioState()
    if not s then return end
    applyPairs(t, mm, cm)
    local s2 = radioState()
    for _, k in ipairs({ "gs", "cr", "vol" }) do if t[k] then last[k] = s2[k] end end
    if t.trk then
        hostKey = t.trk
        local mine = curKey(mm)
        if mine ~= t.trk or t.r == "1" then
            if not playTrack(mm, t.trk) and now() - (missed[t.trk] or -math.huge) > 50 then -- the host forgets a miss after 60 s
                missed[t.trk] = now()
                net.toHost("g.radio.i", pack({ miss = t.trk }))
                log("PT|radio cannot play %s, told the host", t.trk)
            end
        end
    end
end)

local hooked = false
local function hookSkip()
    if hooked then return end
    local ok, err = pcall(RegisterHook, "/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_RadioComponent.BP_RadioComponent_C:ChangeChannel", function(self, dir)
        local okc, e = pcall(function()
            if not isGuest() or playing then return end
            local d = dir:get()
            local owner = self:get():GetOwner()
            local which = valid(owner) and owner:GetClass():GetFName():ToString():find("Stereo") and "gs" or "cr"
            net.toHost("g.radio.i", pack({ skip = d .. "@" .. which }))
            log("PT|radio skip %d@%s sent", d, which)
        end)
        if not okc then log("PT|error radio skip hook %s", tostring(e)) end
    end)
    if ok then hooked = true else log("PT|error radio hook ChangeChannel %s", tostring(err)) end
end

RegisterLoadMapPostHook(function()
    if mode() == "client" then resyncAt = now() + 6 else hbAt = -1; resyncAt = now() + 6 end
end)

local function tick()
    hookSkip()
    finishPlay()
    local s, mm, cm = radioState()
    if not s then return end
    if isGuest() then
        local d = {}
        for k, v in pairs(s) do
            if last[k] == nil then last[k] = v elseif last[k] ~= v then d[k] = v; last[k] = v end
        end
        if next(d) and not playing then
            net.toHost("g.radio.i", pack(d))
            log("PT|radio intent %s", pack(d):gsub("\t", ";"))
        end
        local names, n = {}, 0
        for k in pairs(haveList()) do names[#names + 1] = k end
        table.sort(names)
        local have = table.concat(names, "|")
        if have ~= haveSent or now() - haveAt > 30 then
            haveSent, haveAt = have, now()
            net.toHost("g.radio.have", have)
        end
        if resyncAt and now() > resyncAt then
            resyncAt = nil
            net.toHost("g.radio.i", pack({ resync = 1 }))
        end
        return
    end
    if not isHost() then lastGuests, lastTrk = 0, nil; last = {}; return end
    local n = #net.guests()
    local arrived = n > lastGuests
    lastGuests = n
    local k = curKey(mm)
    -- a custom track a guest cannot play
    if lacking(k) and not playing and now() - skipAt > 1.5 and skipN < 12 then
        skipAt, skipN = now(), skipN + 1
        pcall(function() mm:SkipTrack(1) end)
        log("PT|radio host skips %s (the guest lacks it)", k)
        return
    end
    if not lacking(k) then skipN = 0 end
    if playing then return end
    local audible = s.gs == 1 or s.cr == 1
    if arrived or (resyncAt and now() > resyncAt) then
        resyncAt = nil
        -- restart the track on both sides now (the guest's own copy joined mid-track); not before the guest has told what it has
        local restarted = audible and k and not lacking(k) and playTrack(mm, k)
        sendState(s, mm, restarted and k or nil, true)
        hbAt = now()
        return
    end
    local changed = false
    for kk, v in pairs(s) do if last[kk] ~= v then changed = true end end
    if changed or (k and k ~= lastTrk and not lacking(k)) then sendState(s, mm); hbAt = now()
    elseif now() - hbAt > 5 then sendState(s, mm, false, true); hbAt = now() end
end

LoopInGameThreadWithDelay(200, function()
    local m = mode()
    if m == "standalone" or m == "none" then last, lastTrk, hostKey, lastGuests, playing = {}, nil, nil, 0, nil; return end
    local ok, err = pcall(tick)
    if not ok then log("PT|error radio tick %s", tostring(err)) end
end)
return M
