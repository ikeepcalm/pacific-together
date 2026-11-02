-- M2 session core. Host: listens on every gameplay map (S1, D14), checks each guest's hello (S4), gives the guest a
-- character next to its own (P1) and removes it before any map change. Guest: joins by direct IP (S3) and rejoins
-- after the host's map changes (S5, S6). Both: the other player's body is drawn visible (X13).
-- With no guest connected and no join address, nothing here changes the game.
local UEHelpers = require("UEHelpers")
local common = require("common")
local survivor = require("survivor")
local log = common.log

local MENU = "RB_MainMenu"
-- the guest's hello only arrives once its first zone load ends: 20 s kicked slow loaders, who then sat frozen ~65 s until
-- the rejoin (two games on one PC, 2026-10-22)
local HELLO_WAIT_MS = 90000
-- X11: address resolution and the pending connection must both survive the host's map load.
local CONNECT_TIMEOUT = 120
local function connectTimeouts()
    if os.getenv("PT_MUTATE") == "shortconnect" then return end
    local driver = StaticFindObject("/Script/OnlineSubsystemUtils.Default__IpNetDriver")
    driver.ResolutionConnectionTimeout = CONNECT_TIMEOUT
    driver.InitialConnectTimeout = CONNECT_TIMEOUT
end
local CHAR_CLASS = "/Game/Characters/Player/PDP_MainCharacter.PDP_MainCharacter_C"

local DIR = (debug.getinfo(1, "S").source:match("^@(.*[\\/])Scripts[\\/]") or "")
-- direct IP (M2): env var PT_JOIN=<ip:port>, else the first line of join.txt next to the mod's Scripts folder
local function joinAddress()
    local env = os.getenv("PT_JOIN")
    if env and env ~= "" then return env end
    local f = io.open(DIR .. "join.txt", "r")
    if not f then return nil end
    local line = (f:read("l") or ""):match("^%s*(%S+)")
    f:close()
    return line
end
local JOIN = joinAddress()
-- guest: a session is wanted until the player quits to the menu or the host refuses us
local guestActive = JOIN ~= nil
-- M6: Steam join (steam.lua) hands us a tunnel address later through M.setJoin; M.join is what overlay.lua shows
local M = { join = JOIN, wanted = function() return guestActive end }
local okSteam, steam = pcall(require, "steam")
if not okSteam then steam = nil end

local function world() return UEHelpers.GetWorld() end
-- destroyed actors stay findable (and IsValid) until garbage collection; calling into them can crash the game
local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function fullName(o) return valid(o) and o:GetFullName() or "none" end
local function same(a, b) return valid(a) and valid(b) and a:GetFullName() == b:GetFullName() end
local function mapOf(w) return valid(w) and UEHelpers.GetGameplayStatics():GetCurrentLevelName(w, true):ToString() or "none" end
local function inWorld(o, w) return valid(o) and valid(o:GetWorld()) and same(o:GetWorld(), w) end
local function console(cmd)
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(world(), cmd, UEHelpers.GetPlayerController())
end
local function listening(w)
    if not valid(w) then return false end
    local d = w.NetDriver
    return valid(d) and not d.ServerConnection:IsValid()
end
local function localPC(w)
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if inWorld(pc, w) and pc:IsLocalController() then return pc end
    end
end
local function charManager()
    for _, m in ipairs(FindAllOf("BP_MainCharacterManager_C") or {}) do if valid(m) then return m end end
end

local function gameVersion()
    return StaticFindObject("/Script/EngineSettings.Default__GeneralProjectSettings").ProjectVersion:ToString()
end
local function gameBuild() return PTNative_GameBuild and PTNative_GameBuild() or 0 end
-- a guest without Steam keeps its backpack by this id (player_id.txt next to join.txt, made once; updates keep it).
-- Off in test runs: their checks find the backpack by the login name.
local function playerId()
    if os.getenv("PT_SCENARIO") then return nil end
    local f = io.open(DIR .. "player_id.txt", "r")
    local id = f and (f:read("l") or ""):match("^%x+$")
    if f then f:close() end
    if id then return id end
    id = string.format("%08x%08x", math.random(0, 0x7fffffff), os.time() & 0x7fffffff)
    f = io.open(DIR .. "player_id.txt", "w")
    if not f then return nil end
    f:write(id, "\n"); f:close()
    return id
end
-- S4 hello, guest -> host over the stock reliable ServerChangeName RPC; the host puts the login name back afterwards.
-- Never rewrite the hooked RPC's string parameter: that corrupted the host's heap (docs/spikes/M2-session.md).
local function hello()
    local s = string.format("PT|hello mod=%s protocol=%d game=%s build=%d", common.MOD_VERSION, common.PROTOCOL_VERSION,
        gameVersion(), gameBuild())
    -- S2: the Steam id and name, so the host names us by the persona and keys our backpack by the id (spaces and more percent-encoded)
    local sid, persona
    if steam then sid, persona = steam.identity() end
    if sid then s = s .. " sid=" .. sid .. " name=" .. persona:gsub("[^%w]", function(c) return string.format("%%%02X", c:byte()) end) end
    local pid = playerId()
    if pid then s = s .. " pid=" .. pid end
    return s
end
local function parseHello(s)
    if not s:find("^PT|hello ") then return nil end
    local h = {}
    for k, v in s:gmatch("(%w+)=(%S*)") do h[k] = v end
    return h
end

-- X13: every character is drawn with an invisible material (first-person game), its mesh's own materials too. Give
-- the other player's body a cooked cloth material, falling back to the engine grid; never touch our own.
local BODY = { "/Game/Env/Generic/Props/Cloth/MI_GenManMade_Cloth_01.MI_GenManMade_Cloth_01",
               "/Engine/EngineMaterials/WorldGridMaterial.WorldGridMaterial" }
local changed = {} -- character full name -> original materials
local function visibleMaterial()
    for _, path in ipairs(BODY) do
        local m = StaticFindObject(path)
        if not valid(m) then m = LoadAsset(path) end
        if valid(m) then return m end
    end
end
local function setBody(c, visible)
    local mesh, key = c.Mesh, c:GetFullName()
    if not valid(mesh) or (not visible and not changed[key]) then return end
    -- done already, unless the game put its invisible material back since
    if visible and changed[key] and same(mesh:GetMaterial(0), visibleMaterial()) then return end
    if visible and changed[key] then changed[key] = nil end
    if visible then
        local orig = {}
        for i = 0, mesh:GetNumMaterials() - 1 do
            orig[i] = mesh:GetMaterial(i)
            mesh:SetMaterial(i, visibleMaterial())
        end
        changed[key] = orig
    else
        for i, m in pairs(changed[key]) do mesh:SetMaterial(i, m) end
        changed[key] = nil
    end
    log("PT|session body %s visible=%s material=%s", key, tostring(visible), fullName(mesh:GetMaterial(0)))
end
-- Every PDP_MainCharacter binds these to the process's single-player managers (BP_MainCharacterManager CommandEnterCar /
-- CommandExitCar, storm and feedback managers), so the local player's enter-car also ran on the other player's character:
-- it attached itself to the car, replicated to the guest and dropped them through the map (playtest 2026-10-20).
-- Only events: a muted call returns zeros, so a pipeline step with a return value (FOVZoomPipelineStep: max(Input - zoom, 25))
-- would clamp the local player's FOV to 25 (playtest 2 "weird FOV"). The other player's zoom is 0 on our side, so it may run.
-- ReceiveHit: only fall damage (to the process's one player health), so the other player's landing must not hurt us (health.lua).
local LOCAL_ONLY = "CommandEnterCar|Exit Car|PlayerEnteredStorm|PlayerExitStorm|LongInventoryInteract|On player Burst feedback|On Player Ambient Feedback|ReceiveHit"
local function isolate(c, remote)
    if not PTNative_Mute then return end
    if remote then PTNative_Mute(c:GetAddress(), LOCAL_ONLY) else PTNative_Unmute(c:GetAddress()) end
end
local function refreshBodies()
    local w = world()
    local pc, cm = localPC(w), charManager()
    if not pc then return end
    -- ours: the pawn when it is a character, else (the host driving: the car is the pawn) the manager's character.
    -- Not the manager's first: on a guest it could point at the host's body, which then got our invisible material back.
    local own = (valid(pc.Pawn) and pc.Pawn:IsA(StaticFindObject("/Script/PenDriverPro.BaseCharacter"))) and pc.Pawn or (cm and cm.CharacterActor)
    for _, c in ipairs(FindAllOf("BaseCharacter") or {}) do
        if inWorld(c, w) then
            local remote = not same(c, pc.Pawn) and not same(c, own)
            isolate(c, remote)
            -- the survivor parts (survivor.lua, the Rogue) replace the visible mannequin when they are on
            local sv = survivor and survivor.set(c, remote)
            setBody(c, remote and not sv)
        end
    end
end

-- host --------------------------------------------------------------------------------------------------------------

local greeted = {} -- remote PC full name -> true once its hello was accepted
local guests = {} -- remote PC full name -> { login = name it came with, sid = SteamID or nil, pid = player_id.txt or nil }

-- for backpack.lua: who a guest is as the host's hello learned it
function M.guestInfo(pc) return guests[pc:GetFullName()] end

local function refuse(pc, reason)
    log("PT|session refused %s: %s", fullName(pc), reason)
    local text = FText("Pacific Together: " .. reason)
    pc:ClientWasKicked(text)
    pc:ClientReturnToMainMenuWithTextReason(text)
end

-- returns false while there is nothing to spawn next to yet and last is not set
local function spawnFor(pc, last)
    local w = pc:GetWorld()
    local me, cm = localPC(w), charManager()
    local own = cm and cm.CharacterActor
    local base = me and me.Pawn
    if not valid(base) then base = own end
    local cls = valid(own) and own:GetClass() or StaticFindObject(CHAR_CLASS)
    if not valid(base) or not valid(cls) then
        if not last then return false end
        log("PT|error session no host pawn or character class to spawn next to (%s)", fullName(base))
        return true
    end
    -- next to whatever the host controls (character or car): the first spot around it that the host can see (nothing on the
    -- line to it, half a capsule beyond) and that does not collide. Only 150 uu to the right, the spawn's own adjustment put
    -- the guest inside a garage station (the pneumatic storage, hand playtest 2026-10-24).
    local l, r, f = base:K2_GetActorLocation(), base:GetActorRightVector(), base:GetActorForwardVector()
    local yaw = base:K2_GetActorRotation().Yaw
    local rot = { X = 0, Y = 0, Z = math.sin(math.rad(yaw) / 2), W = math.cos(math.rad(yaw) / 2) }
    local gs, ks = UEHelpers.GetGameplayStatics(), UEHelpers.GetKismetSystemLibrary()
    local from = { X = l.X, Y = l.Y, Z = l.Z + 50 }
    local ignore = { base }
    if valid(own) then ignore[2] = own end
    local function clear(d, dist)
        local hit = {}
        local to = { X = l.X + d.X * (dist + 50), Y = l.Y + d.Y * (dist + 50), Z = l.Z + 50 }
        return not ks:LineTraceSingle(w, from, to, 0, false, ignore, 0, hit, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
    end
    local c
    local tries = os.getenv("PT_MUTATE") == "oldspawn" and {} or { 150, 250 } -- tests only: straight to the old placement
    for _, dist in ipairs(tries) do
        for _, d in ipairs({ r, { X = -r.X, Y = -r.Y }, { X = -f.X, Y = -f.Y }, f }) do
            if not valid(c) and clear(d, dist) then
                local xf = { Rotation = rot, Translation = { X = l.X + d.X * dist, Y = l.Y + d.Y * dist, Z = l.Z + 50 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
                c = gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(w, cls, xf, 3, nil), xf) -- 3: not where it collides
            end
        end
    end
    if not valid(c) then -- nowhere free: as before, to the right, the spawn moves it out of collisions as it can
        local xf = { Rotation = rot, Translation = { X = l.X + r.X * 150, Y = l.Y + r.Y * 150, Z = l.Z + 50 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        c = gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(w, cls, xf, 2, nil), xf)
    end
    if not valid(c) then
        log("PT|error session spawn failed for %s", fullName(pc))
        return true
    end
    pc:Possess(c)
    -- the game's single-player manager follows the newest character; it must keep the host's
    if cm and valid(own) and not same(cm.CharacterActor, own) then cm.CharacterActor = own end
    log("PT|session spawned %s for %s possessed=%s manager=%s", fullName(c), fullName(pc), tostring(same(pc.Pawn, c)), fullName(cm and cm.CharacterActor))
    refreshBodies()
    return true
end

local function onHello(pc, s)
    local h = parseHello(s:get():ToString())
    if not h then return end
    local key = pc:GetFullName()
    if greeted[key] then return end
    -- the login name, before the engine applies the hello as the new name
    local name = valid(pc.PlayerState) and pc.PlayerState:GetPlayerName():ToString() or "Guest"
    local mine = { mod = common.MOD_VERSION, protocol = tostring(common.PROTOCOL_VERSION), game = gameVersion(), build = tostring(gameBuild()) }
    log("PT|session hello from %s mod=%s protocol=%s game=%s build=%s", key, tostring(h.mod), tostring(h.protocol), tostring(h.game), tostring(h.build))
    -- the Steam build id only warns: the game version string still must match
    if h.build ~= mine.build then log("PT|session guest build %s differs from ours %s, allowed (game %s)", tostring(h.build), mine.build, tostring(h.game)) end
    for _, k in ipairs({ "mod", "protocol", "game" }) do
        if h[k] ~= mine[k] then
            refuse(pc, string.format("%s mismatch: host has %s, you have %s. Both players need the same game build and mod version.", k, mine[k], tostring(h[k])))
            return
        end
    end
    greeted[key] = true
    -- S2: a guest with Steam is named by its persona and keyed by its SteamID; the login name stays as the backpack's old key
    guests[key] = { login = name, sid = h.sid and h.sid:match("^%d+$"), pid = h.pid and h.pid:match("^%x+$") }
    log("PT|session guest %s login=%s sid=%s pid=%s", key, name, tostring(guests[key].sid), tostring(guests[key].pid))
    if guests[key].sid and h.name then
        name = h.name:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
    end
    -- outside the RPC's hook, so the spawn's own hooks and Blueprint events do not run nested in it. A guest that
    -- connects while the host still loads a zone logs in before the host's own character exists: look again each second.
    local function try(n)
        ExecuteInGameThreadWithDelay(n == 0 and 100 or 1000, function()
            local ok, err = pcall(function()
                if not valid(pc) or not greeted[key] then return end
                if n == 0 then UEHelpers.GetGameModeBase():ChangeName(pc, name, false) end
                if not spawnFor(pc, n >= 60) then try(n + 1) end
            end)
            if not ok then log("PT|error session spawn %s", tostring(err)) end
        end)
    end
    try(0)
end

-- Opening the pause menu runs PenDriverViewportClient::ClearAllPressedInputs, whose timer calls PlayerTick on every
-- PlayerController (PenDriverPro+0x10a5b60);
-- the engine gives a remote player's controller no PlayerInput, so the host crashed in PlayerInput->Tick (AV reading 0x178
-- at +0x3160a56, playtest 2026-10-21). An empty PlayerInput makes that tick a no-op for the guest's controller.
local function giveInput(pc)
    if valid(pc.PlayerInput) or os.getenv("PT_MUTATE") == "nopausefix" then return end
    pc.PlayerInput = StaticConstructObject(StaticFindObject("/Script/Engine.PlayerInput"), pc)
    log("PT|session input %s", tostring(valid(pc.PlayerInput)))
end

local function onLogin(pc)
    if pc:IsLocalController() then return end
    local key = pc:GetFullName()
    log("PT|session login %s", key)
    giveInput(pc)
    common.defer(HELLO_WAIT_MS, function()
        if valid(pc) and not greeted[key] and listening(pc:GetWorld()) then
            refuse(pc, "no handshake received. Install the same Pacific Together version as the host.")
        end
    end)
end

-- the reference saw the host crash tearing down a world that still had the guest's character in it
local function removeRemoteCharacters(w)
    local n = 0
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if inWorld(pc, w) and not pc:IsLocalController() and valid(pc.Pawn) then
            local p = pc.Pawn
            pc:UnPossess()
            p:K2_DestroyActor()
            n = n + 1
        end
    end
    greeted = {}
    if n > 0 then log("PT|session cleanup removed=%d map=%s", n, mapOf(w)) end
end

-- guest -------------------------------------------------------------------------------------------------------------

local attempt, lastJoin = 0, -100
local function join()
    -- the boot menu load and the start-up both ask; one open at a time
    if not JOIN or not guestActive or mapOf(world()) ~= MENU or os.time() - lastJoin < 5 then return end
    attempt, lastJoin = attempt + 1, os.time()
    local mine = attempt
    connectTimeouts()
    log("PT|session join %s attempt=%d", JOIN, mine)
    console("open " .. JOIN)
    -- a connect that fails without a map load leaves us in the menu: try again once it has surely timed out
    ExecuteInGameThreadWithDelay((CONNECT_TIMEOUT + 10) * 1000, function() if mine == attempt then join() end end)
end

-- M6: steam.lua resolved the lobby's host to a tunnel address; from here on we are an ordinary guest
function M.setJoin(addr)
    if not addr then -- the Steam join failed or the guest session ended: a host again
        JOIN, M.join, guestActive = nil, nil, false
        if PTNative_SetAutoListen then PTNative_SetAutoListen(true) end
        if PTNative_SetRejoin then PTNative_SetRejoin("") end
        return
    end
    JOIN, M.join, guestActive, lastJoin = addr, "via Steam", true, -100
    if PTNative_SetAutoListen then PTNative_SetAutoListen(false) end
    connectTimeouts()
    log("PT|session steam join %s rejoin without menu=%s", addr, tostring(PTNative_SetRejoin and PTNative_SetRejoin(addr)))
    -- a host who was in a world when the request came leaves it for the other host
    if mapOf(world()) ~= MENU then console("open " .. addr) else join() end
end

-- hooks -------------------------------------------------------------------------------------------------------------

local function hook(fn, pre)
    local ok, err = pcall(RegisterHook, fn, function(...)
        local okc, e = pcall(pre, ...)
        if not okc then log("PT|error session %s %s", fn, tostring(e)) end
    end)
    if not ok then log("PT|error session hook %s %s", fn, tostring(err)) end
end

local hooked = false
local function hookAll()
    if hooked then return end
    hooked = true
    -- PostLogin's native event for every joining player (K2_PostLogin never fires: no Blueprint implements it)
    hook("/Script/Engine.GameModeBase:HandleStartingNewPlayer", function(gm, pc) onLogin(pc:get()) end)
    hook("/Script/Engine.PlayerController:ServerChangeName", function(self, s)
        local pc = self:get()
        if pc:HasAuthority() and not pc:IsLocalController() then onHello(pc, s) end
    end)
    -- the server set up our controller: say hello
    hook("/Script/Engine.PlayerController:ClientSetHUD", function(self)
        local pc = self:get()
        if JOIN and guestActive and common.netMode() == "client" and pc:IsLocalController() then
            pc:ServerChangeName(hello())
            log("PT|session hello sent")
        end
    end)
    hook("/Script/Engine.PlayerController:ClientWasKicked", function(self, reason)
        if not self:get():IsLocalController() then return end
        guestActive = false
        if PTNative_SetRejoin then PTNative_SetRejoin("") end
        log("PT|session refused by host: %s", reason:get():ToString())
    end)
    hook("/Script/Engine.PlayerController:ClientRestart", function(self, pawn)
        local pc, cm = self:get(), charManager()
        if not pc:IsLocalController() or common.netMode() ~= "client" then return end
        -- the guest's own managers follow its own character
        if cm and valid(pawn:get()) and not same(cm.CharacterActor, pawn:get()) then cm.CharacterActor = pawn:get() end
        -- the host's character is replicated by now (we spawn next to it); look again once for a late one.
        -- shortcut: a host character that becomes relevant later (far apart in a zone) stays invisible; hook its arrival in M3/M4
        -- (NotifyOnNewObject would fire on the loading thread)
        refreshBodies()
        common.defer(3000, function() pcall(refreshBodies) end)
    end)
    -- the save manager starts most native travel: remove the guest's character before the travel is even queued
    -- (removing it in the LoadMap pre-hook alone crashed the host's next map load, seen before the s:set heap fix;
    -- run travel (BaseRouteState::TravelTo) has only that fallback, untested)
    for _, f in ipairs({ "UserNewGame", "UserLoadGame", "LoadGame", "LoadFromCheckpoint", "Rinse", "LoadGameCmd", "LoadBookmarkCmd", "QuitToMenu" }) do
        hook("/Script/PenDriverPro.BaseSaveGameManager:" .. f, function()
            local w = world()
            if listening(w) then removeRemoteCharacters(w) end
            -- leaving on purpose ends the guest's session
            if f == "QuitToMenu" and common.netMode() == "client" and guestActive then
                guestActive = false
                if PTNative_SetRejoin then PTNative_SetRejoin("") end
                log("PT|session left")
            end
        end)
    end
end

RegisterLoadMapPreHook(function(engine, worldp, url, pending)
    local ok, err = pcall(function()
        local w = worldp:get()
        if not valid(pending:get()) and listening(w) then removeRemoteCharacters(w) end
        changed = {}
        if PTNative_MuteClear then PTNative_MuteClear() end
    end)
    if not ok then log("PT|error session loadmap pre %s", tostring(err)) end
end)

RegisterLoadMapPostHook(function(engine, worldp)
    local ok, err = pcall(function()
        hookAll()
        local m = mapOf(worldp:get())
        if JOIN and guestActive and m == MENU then ExecuteInGameThreadWithDelay(2000, join) end
    end)
    if not ok then log("PT|error session loadmap post %s", tostring(err)) end
end)

-- the native layer registers its functions only after the scripts started
ExecuteInGameThreadWithDelay(1000, function()
    connectTimeouts() -- pending connections on either side must survive a long host map load
    hookAll()
    -- Steam started the game for a friend's lobby: a guest, whose address steam.lua sets once the lobby is entered
    local viaSteam = JOIN == nil and steam and steam.pendingJoin() ~= nil
    if viaSteam then M.join, guestActive = "via Steam", true end
    local host = JOIN == nil and not viaSteam
    if host and not PTNative_SetAutoListen then log("PT|error session native layer missing, cannot host") end
    local patched = host and PTNative_SetAutoListen and PTNative_SetAutoListen(true)
    log("PT|session ready role=%s join=%s autolisten=%s game=%s build=%d", host and "host" or "guest", viaSteam and "steam" or tostring(JOIN), tostring(patched), gameVersion(), gameBuild())
    if JOIN then
        -- the host's map changes drop us: go straight back to the host instead of through the menu (native Browse swap)
        connectTimeouts()
        log("PT|session rejoin without menu=%s", tostring(PTNative_SetRejoin and PTNative_SetRejoin(JOIN)))
        join()
    end
end)

-- Guest: the game's single-player managers can end up on the host's character (seen 2026-10-23 after car enter/exit:
-- BP_MainCharacterManager.CharacterActor = the host's body). The guest's input then drove the host's body (stuck after a
-- car exit, camera and walking dead) and the host's body got the invisible first-person material. Put it back.
local lastFix, beat = 0, 0
LoopInGameThreadWithDelay(250, function()
    local mode = common.netMode()
    beat = beat + 1
    -- both sides: the other player's body is looked at again every 2 s (the game can put its invisible material back)
    if (mode == "client" or mode == "listen") and beat % 8 == 0 then pcall(refreshBodies) end
    if mode ~= "client" then return end
    local ok, err = pcall(function()
        local pc, cm = localPC(world()), charManager()
        local me = pc and pc.Pawn
        if not (cm and valid(me) and me:IsA(StaticFindObject("/Script/PenDriverPro.BaseCharacter"))) or same(cm.CharacterActor, me) then return end
        local was = fullName(cm.CharacterActor)
        cm.CharacterActor = me
        refreshBodies()
        if os.clock() - lastFix > 5 then log("PT|session guest manager was on %s, back on our own character", was) end
        lastFix = os.clock()
    end)
    if not ok then log("PT|error session manager guard %s", tostring(err)) end
end)

-- for overlay.lua, steam.lua, backpack.lua
return M
