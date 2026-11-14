-- M6 Steam join (S1, S2, D14), on top of the native layer's Steam calls (steam.cpp, docs/spikes/X6.md, docs/spikes/PT2-steam.md).
-- Host: every listening map gets a friends-only lobby with rich presence "connect" = "+connect_lobby <id>" (Join game in the
-- friends list, overlay invites), UE's traffic goes through the Steam tunnel (10.77.x.y), channel 1 answers the guest's warm-up pings.
-- Guest: a join request (command line Steam started the game with, or a callback while it runs) joins the lobby, maps the
-- lobby owner as 10.77.0.1, warms the Steam session with pings, then hands the address to session.lua as an ordinary guest.
-- Off in test runs (PT_SCENARIO set) unless PT_STEAM=1, off for players with PT_STEAM=0. Direct IP (PT_JOIN, join.txt) never goes through here.
local UEHelpers = require("UEHelpers")
local common = require("common")
local log = common.log

local M = {}
local function wanted()
    local env = os.getenv("PT_STEAM")
    if env then return env == "1" end
    return os.getenv("PT_SCENARIO") == nil
end
if os.getenv("PT_MUTATE") == "nosteamjoin" or not wanted() then
    function M.identity() end
    function M.pendingJoin() end
    function M.joinLobby() end
    return M
end

local FAKE_HOST = "10.77.0.1"
-- tests only: the tunnel's link is loopback UDP (host binds this port) instead of Steam, for runs that cannot reach each other over Steam
local TEST_LINK = tonumber(os.getenv("PT_STEAM_UDP") or "")
local INBOX = os.getenv("PT_STEAM_INBOX") -- tests only: a file whose text is handled like the command line Steam would give us
local LEAVE_AFTER = 30 -- seconds without listening before the lobby is dropped (a map load is not listening for a few seconds)
local JOIN_TIMEOUT, WARM_TIMEOUT = 60, 20

local enabled, id, persona = false, nil, ""
local lobby, creating, published, notListening, named = nil, nil, false, 0, nil
local g -- guest: { lobby, phase = entering | warm | joined | failed, t0, host, port, n, echo, echoU }
local launch, launchUsed
local greeted = {}

local function session() return require("session") end

function M.parseConnect(s) return s and s:match("%+connect_lobby%s+\"?(%d+)") end

local function enable()
    if enabled then return true end
    if not PTNative_SteamEnable then return false end
    enabled = PTNative_SteamEnable(true) == true
    if enabled then
        id, persona = PTNative_SteamId(), PTNative_SteamPersona() or ""
        log("PT|steam on id=%s persona=%s", tostring(id), persona)
    end
    return enabled
end

-- the guest's hello (session.lua) carries these; the host names the guest after the persona and keys its backpack by the id
function M.identity()
    if enable() and id and persona ~= "" then return id, persona end
end

-- the lobby id Steam started the game for ("Join game" while the game is closed), read once
function M.pendingJoin()
    if launch == nil then
        launch = false
        local line = PTNative_CommandLine and PTNative_CommandLine() or ""
        launch = M.parseConnect(line) or false
        if launch then log("PT|steam command line join lobby=%s", launch) end
    end
    return launch or nil
end

local function linkUp(host)
    if TEST_LINK then return PTNative_TunnelUdp(host and TEST_LINK or 0) end
    return PTNative_TunnelSteam(0)
end

local function leaveLobby()
    if lobby or g then PTNative_SteamLeaveLobby(); PTNative_SteamRichPresence() end
    lobby, creating, published, greeted = nil, nil, false, {}
end

-- host ------------------------------------------------------------------------------------------------------------------

local function port()
    return tonumber((PTNative_CommandLine and PTNative_CommandLine() or ""):match("%-port=(%d+)")) or 7777
end

local function publish()
    published = true
    PTNative_SteamLobbyData("pt_version", common.MOD_VERSION)
    PTNative_SteamLobbyData("pt_protocol", tostring(common.PROTOCOL_VERSION))
    PTNative_SteamLobbyData("pt_port", tostring(port()))
    PTNative_SteamLobbyData("pt_host", persona)
    if TEST_LINK then PTNative_SteamLobbyData("pt_link", tostring(TEST_LINK)) end
    PTNative_SteamRichPresence("status", "Hosting a Pacific Together session")
    PTNative_SteamRichPresence("connect", "+connect_lobby " .. lobby)
    log("PT|steam lobby=%s port=%d tunnel=%s", lobby, port(), tostring(linkUp(true)))
end

-- the host's own name for the guest's name tag and overlay
local function nameHost()
    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() or persona == "" or named == pc:GetFullName() then return end
    named = pc:GetFullName()
    UEHelpers.GetGameModeBase():ChangeName(pc, persona, false)
    log("PT|steam host named %s", persona)
end

local function hostTick()
    if common.netMode() ~= "listen" then
        notListening = notListening + 1
        if lobby and notListening >= LEAVE_AFTER then log("PT|steam lobby %s closed", lobby); leaveLobby() end
        return
    end
    notListening = 0
    pcall(nameHost)
    if lobby then
        if not published then publish() end
        return
    end
    if creating then
        local l = PTNative_SteamLobby()
        if l then lobby, creating = l, nil
        elseif os.clock() - creating > 30 then creating = nil end
        return
    end
    creating = os.clock()
    log("PT|steam creating lobby, create=%s", tostring(PTNative_SteamCreateLobby(4))) -- host + 3 guests (D1)
end

-- answers the guests' warm-up pings on channel 1 (a reliable ping gets a reliable echo, an unreliable one an unreliable echo), 4 times a second
local function serve()
    if not lobby then return end
    local _, members = PTNative_SteamLobbyMembers()
    for m in (members or ""):gmatch("%d+") do
        if m ~= id then
            if not greeted[m] then greeted[m] = true; log("PT|steam guest %s in the lobby", m) end
            PTNative_SteamAccept(m)
        end
    end
    while true do
        local from, text = PTNative_SteamReceive(1)
        if not from then break end
        if text:match("^ping") then PTNative_SteamSend(from, 1, "echo" .. text:sub(5), not text:match("^ping%-u")) end
    end
end

-- guest -----------------------------------------------------------------------------------------------------------------

function M.joinLobby(l)
    if not enable() or (g and g.lobby == l and g.phase ~= "failed") then return end
    if lobby == l then return end -- our own lobby
    log("PT|steam join lobby=%s", l)
    leaveLobby()
    g = { lobby = l, phase = "entering", t0 = os.clock(), n = 0, echo = false, echoU = false }
    PTNative_SteamJoinLobby(l)
end

local function fail(why)
    log("PT|steam join failed: %s", why)
    g = nil -- hosting works again (hostTick is skipped while g is set), and so does a new join request
    PTNative_SteamLeaveLobby()
    session().setJoin(nil)
end

local function guestTick()
    if g.phase == "entering" then
        local cur, status = PTNative_SteamLobby()
        if cur == g.lobby then
            g.host = PTNative_SteamLobbyMembers()
            g.port = tonumber(PTNative_SteamLobbyData("pt_port")) or 7777
            local v = PTNative_SteamLobbyData("pt_version")
            if v ~= common.MOD_VERSION then return fail(string.format("host has mod %s, we have %s", v, common.MOD_VERSION)) end
            local to = TEST_LINK and ("127.0.0.1:" .. tostring(PTNative_SteamLobbyData("pt_link"))) or ("steam:" .. g.host)
            log("PT|steam entered lobby=%s host=%s port=%d tunnel=%s peer=%s", g.lobby, g.host, g.port, tostring(linkUp(false)), tostring(PTNative_TunnelPeer(FAKE_HOST, to)))
            g.phase, g.t0 = "warm", os.clock()
        elseif os.clock() - g.t0 > JOIN_TIMEOUT or (cur == nil and status and status:match("^entered") and not status:match("response=1")) then
            fail("lobby not entered: " .. tostring(status))
        end
    elseif g.phase == "warm" then
        -- the first unreliable send after a reliable one stalled the game thread for seconds (X6): take that hitch here, not in UE's sendto
        g.n = g.n + 1
        if not TEST_LINK then
            PTNative_SteamSend(g.host, 1, "ping " .. g.n, true)
            PTNative_SteamSend(g.host, 1, "ping-u " .. g.n, false)
        end
        while true do
            local from, text = PTNative_SteamReceive(1)
            if not from then break end
            if text:match("^echo%-u") then g.echoU = true elseif text:match("^echo") then g.echo = true end
        end
        local ready = TEST_LINK or (g.echo and g.echoU)
        if ready or os.clock() - g.t0 > WARM_TIMEOUT then
            g.phase = "joined"
            log("PT|steam warm echo=%s echoU=%s after %.1fs, joining 10.77.0.1:%d", tostring(g.echo), tostring(g.echoU), os.clock() - g.t0, g.port)
            session().setJoin(FAKE_HOST .. ":" .. g.port)
        end
    elseif g.phase == "joined" and not session().wanted() then
        log("PT|steam left lobby %s", g.lobby)
        PTNative_SteamLeaveLobby()
        g = nil
        session().setJoin(nil) -- back to a host that listens on its own
    end
end

-- events and the loop -----------------------------------------------------------------------------------------------------

local function event(e)
    local kind, a, b = e:match("^(%S+) (%S+) ?(.*)$")
    log("PT|steam event %s", e)
    if kind == "join_lobby" then M.joinLobby(a)
    elseif kind == "join_connect" then
        local l = M.parseConnect(b)
        if l then M.joinLobby(l) end
    end
end

local function inbox()
    local f = INBOX and not lobby and io.open(INBOX, "r")
    if not f then return end
    local text = f:read("a"); f:close()
    local l = M.parseConnect(text)
    if l then os.remove(INBOX); log("PT|steam inbox join lobby=%s", l); M.joinLobby(l) end
end

local beat = 0
LoopInGameThreadWithDelay(250, function()
    local ok, err = pcall(function()
        if not enable() then return end
        serve()
        beat = beat + 1
        if beat % 4 ~= 0 then return end
        while true do
            local e = PTNative_SteamEvent()
            if not e then break end
            event(e)
        end
        inbox()
        local p = M.pendingJoin()
        if p and not g and not launchUsed then launchUsed = true; M.joinLobby(p) end
        if g then return guestTick() end
        if not session().join then hostTick() end
    end)
    if not ok then log("PT|error steam %s", tostring(err)) end
end)

return M
