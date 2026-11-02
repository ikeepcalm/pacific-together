-- Test bot for tools/run-test.ps1. Never shipped. Inert unless PT_SCENARIO is set.
local UEHelpers = require("UEHelpers")

local TAG = "[PacificTogetherTest] "
local ROLE = os.getenv("PT_ROLE") or "host"
local SCENARIO = os.getenv("PT_SCENARIO")
local HOST = os.getenv("PT_HOST") or "127.0.0.1:7777"
local MUTATE = os.getenv("PT_MUTATE") or ""
local GARAGE = "/Game/Maps/RunProto/RB_Garage"

local function log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

if not SCENARIO then return end

local function world() return UEHelpers.GetWorld() end

local function map()
    local w = world()
    return w:IsValid() and UEHelpers.GetGameplayStatics():GetCurrentLevelName(w, true):ToString() or "none"
end

local function netMode()
    local ksl, w = UEHelpers.GetKismetSystemLibrary(), world()
    if not w:IsValid() then return "none" end
    if ksl:IsStandalone(w) then return "standalone" end
    return ksl:IsServer(w) and "listen" or "client"
end

-- Only controllers of the current world: the previous map's controllers linger until garbage collection.
local function pcs()
    local w, n = world(), 0
    if not w:IsValid() then return 0 end
    local wn = w:GetFullName()
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if pc:IsValid() and not pc:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) and pc:GetWorld():IsValid() and pc:GetWorld():GetFullName() == wn then n = n + 1 end
    end
    return n
end

local function state() return string.format("net=%s map=%s pcs=%d", netMode(), map(), pcs()) end

local function console(cmd)
    log("PT|console %s", cmd)
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(world(), cmd, UEHelpers.GetPlayerController())
end

-- Step kinds: {check=id, timeout=s, cond=fn, tick=fn(t)} | {wait=s} | {run=fn}
local function onMap(name, timeout) return { check = "map_" .. name, timeout = timeout, cond = function() return map() == name end } end

local FOREST = "/Game/Maps/Wilderness/Forest/Wilderness_Forest_01"
local function name(o) return (o and o:IsValid()) and o:GetFullName() or "none" end
local function cls(o) return (o and o:IsValid()) and o:GetClass():GetFName():ToString() or "none" end
local function first(c) for _, o in ipairs(FindAllOf(c) or {}) do if o:IsValid() then return o end end end
local function saveMgr() return first("BP_SaveGameManager_C") end
-- "/Game/Maps/X/Map" of the current world
local function mapPath() return world():GetFullName():match("^%S+ ([^%.]+)") end
-- NetDriver of the current world: listening = has a driver and no server connection
local function driver()
    local d = world().NetDriver
    if not d:IsValid() then return "driver=none" end
    return string.format("driver=%s server=%s clients=%d", d:GetFName():ToString(), tostring(d.ServerConnection:IsValid()), #d.ClientConnections)
end
local function listening()
    local d = world().NetDriver
    return d:IsValid() and not d.ServerConnection:IsValid()
end
local function quitToMenu()
    log("PT|info QuitToMenu")
    StaticFindObject("/Script/PenDriverPro.Default__BaseSaveGameManager"):QuitToMenu(world())
end


-- "connected" = net=client and the server's map (the pending connect already reports net=client in the menu)
local function join(id, mapName, timeout, retry)
    local nextTry = 0
    return { check = id, timeout = timeout, cond = function() return netMode() == "client" and map() == mapName end,
             tick = function(t)
                 if MUTATE == "skipconnect" or t < nextTry or map() ~= "RB_MainMenu" or netMode() == "client" then return end
                 nextTry = retry and t + retry or math.huge
                 console("open " .. HOST)
             end }
end

-- X3: aggregate every actor of the current world by class, Role, bReplicates, loaded-from-map and owner class
local RF_WasLoaded = 0x00080000
local function survey(tag)
    local wn, agg, n, bad = world():GetFullName(), {}, 0, 0
    for _, a in ipairs(FindAllOf("Actor") or {}) do
        local ok, key = pcall(function()
            if not a:IsValid() or a:GetWorld():GetFullName() ~= wn then return nil end
            return string.format("class=%s role=%s rep=%d loaded=%d owner=%s", cls(a), tostring(a.Role),
                a.bReplicates and 1 or 0, a:HasAnyFlags(RF_WasLoaded) and 1 or 0, cls(a.Owner))
        end)
        if not ok then bad = bad + 1 elseif key then agg[key] = (agg[key] or 0) + 1; n = n + 1 end
    end
    local keys = {}
    for k in pairs(agg) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do log("PT|actors side=%s tag=%s %s n=%d", ROLE, tag, k, agg[k]) end
    log("PT|info survey %s: %d actors, %d keys, %d errors, map=%s", tag, n, #keys, bad, map())
end

-- X1: log every UEngine::LoadMap. The FURL arrives as a Lua userdata; probe what it exposes.
local lm = { pre = 0, post = 0, preAt = 0, furl = nil }
local function probeURL(url)
    local r = { "type=" .. type(url) }
    local ok, s = pcall(tostring, url); r[#r + 1] = "tostring=" .. (ok and s or "err")
    for _, k in ipairs({ "Map", "Host", "Port", "Op", "Portal", "Protocol" }) do
        local okk, v = pcall(function() return url[k] end)
        r[#r + 1] = k .. "=" .. (okk and tostring(v) or "err(" .. tostring(v):sub(1, 60) .. ")")
    end
    local okg, g = pcall(function() return url:get() end)
    r[#r + 1] = "get=" .. (okg and tostring(g) or "err(" .. tostring(g):sub(1, 60) .. ")")
    local okc, c = pcall(function() return url() end)
    r[#r + 1] = "call=" .. (okc and tostring(c) or "err(" .. tostring(c):sub(1, 60) .. ")")
    return table.concat(r, " ")
end
-- X1b -Mutate follow: before a native travel the host tells each remote PC to travel to the host's address
local function sendFollow(w)
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if pc:IsValid() and not pc:IsLocalController() and pc:GetWorld():GetFullName() == w:GetFullName() then
            log("PT|info follow ClientTravel %s -> %s", name(pc), HOST)
            pc:ClientTravel(HOST, 0, false, { A = 0, B = 0, C = 0, D = 0 })
        end
    end
end
local function onLoadMap(phase, engine, worldp, url, pending, err)
    local ok, msg = pcall(function()
        local w, p = worldp:get(), pending:get()
        if phase == "pre" and MUTATE == "follow" and ROLE == "host" and not p:IsValid() and w:IsValid() then sendFollow(w) end
        local extra = ""
        if phase == "post" then
            local ksl = UEHelpers.GetKismetSystemLibrary()
            extra = string.format(" standalone=%s server=%s %s took=%ds", tostring(ksl:IsStandalone(w)), tostring(ksl:IsServer(w)),
                (function() local okd, d = pcall(driver); return okd and d or "driver=err" end)(), os.time() - lm.preAt)
        else
            lm.preAt = os.time()
        end
        if not lm.furl then lm.furl = probeURL(url); log("PT|info furl %s", lm.furl) end
        return string.format("engine=%s world=%s pending=%s pendingDriver=%s error='%s'%s", name(engine:get()), name(w), name(p),
            p:IsValid() and name(p.NetDriver) or "none", tostring(err), extra)
    end)
    lm[phase] = lm[phase] + 1
    log("PT|loadmap %s n=%d %s", phase, lm[phase], ok and msg or ("err " .. tostring(msg)))
end
RegisterLoadMapPreHook(function(...) onLoadMap("pre", ...) end)
RegisterLoadMapPostHook(function(...) onLoadMap("post", ...) end)

-- X11: timeouts of the IpNetDriver CDO and of every live driver
local function timeouts()
    local r = {}
    for _, d in ipairs(FindAllOf("NetDriver") or {}) do
        if d:IsValid() then r[#r + 1] = string.format("%s{init=%.0f conn=%.0f res=%s noTimeouts=%s}", d:GetFName():ToString(), d.InitialConnectTimeout, d.ConnectionTimeout, tostring(d.ResolutionConnectionTimeout), tostring(d.bNoTimeouts)) end
    end
    local cdo = StaticFindObject("/Script/OnlineSubsystemUtils.Default__IpNetDriver")
    return string.format("cdo{init=%.0f conn=%.0f res=%.0f} live=%s", cdo.InitialConnectTimeout, cdo.ConnectionTimeout, cdo.ResolutionConnectionTimeout, table.concat(r, ","))
end

-- X10: the runner snapshots this side's Saved\SaveGames and Saved\Config on every PT|snap line
local function snap(tag) log("PT|snap side=%s tag=%s", ROLE, tag) end
local blocking = MUTATE ~= "noblock"
local saveHooks = false
local function hookSaves()
    if saveHooks then return end
    saveHooks = true
    local function try(fn, pre, post)
        local ok, err = pcall(RegisterHook, fn, pre, post)
        log("PT|info hook %s ok=%s %s", fn, tostring(ok), ok and "" or tostring(err))
    end
    -- native UFunctions: pre-hooks cannot cancel; the slot param is redirected instead
    try("/Script/PenDriverPro.BaseSaveGameManager:SaveGame", function(self, slot, level, kind)
        log("PT|save SaveGame slot=%s level='%s' type=%s block=%s", tostring(slot:get()), level:get():ToString(), tostring(kind:get()), tostring(blocking))
        if blocking then slot:set(-1) end
    end, function(self, ...) log("PT|save SaveGame done") end)
    for _, f in ipairs({ "SaveCheckpoint", "MakeBookmark", "WriteUserSettings", "WriteGameplaySettingsToSlot", "Rinse", "SetCurrentSlot", "DeleteGame" }) do
        try("/Script/PenDriverPro.BaseSaveGameManager:" .. f, function() log("PT|save %s", f) end)
    end
    for _, f in ipairs({ "SaveGameToSlot", "AsyncSaveGameToSlot" }) do
        local owner = f == "SaveGameToSlot" and "/Script/Engine.GameplayStatics:" or "/Script/Engine.AsyncActionHandleSaveGame:"
        try(owner .. f, function() log("PT|save %s", f) end)
    end
    -- Blueprint gates (BP hooks run after the body, so out params can still be overwritten). The game polls them every frame: log changes only
    local last = {}
    local function gate(id, v) if last[id] ~= v then last[id] = v; log("PT|save %s was=%s block=%s", id, v, tostring(blocking)) end end
    local dir, mgr = first("BP_AutoSaveDirector_C"), saveMgr()
    if dir then
        local path = dir:GetClass():GetFullName():match("^%S+ (.+)$")
        try(path .. ":CanAutoSave", function(self, enabled)
            gate("CanAutoSave", tostring(enabled:get()))
            if blocking then enabled:set(false) end
        end)
        try(path .. ":TriggerAutosave", function() log("PT|save TriggerAutosave") end)
    else
        log("PT|info no BP_AutoSaveDirector_C")
    end
    if mgr then
        local path = mgr:GetClass():GetFullName():match("^%S+ (.+)$")
        try(path .. ":CanUserSaveGame", function(self, can)
            gate("CanUserSaveGame", tostring(can:get()))
            if blocking then can:set(false) end
        end)
    end
end
local function mgrState()
    local m = saveMgr()
    return m and string.format("slot=%s mode=%s", tostring(m:GetCurrentSlot()), tostring(m:GetActivePlayMode())) or "no manager"
end

-- X13: remote player body
local CHAR = "PDP_MainCharacter_C"
-- destroyed actors stay findable (and IsValid) until garbage collection
local function gone(o) return not o:IsValid() or o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function inWorld(o) return not gone(o) and o:GetWorld():IsValid() and o:GetWorld():GetFullName() == world():GetFullName() end
local function localPC()
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do if inWorld(pc) and pc:IsLocalController() then return pc end end
end
local function myPawn() local pc = localPC(); return pc and pc.Pawn:IsValid() and pc.Pawn or nil end
-- M2 S4: the hello the shipping guest sends (session.lua); mod/protocol override it for refusal tests
local function hello(mod, protocol)
    local common = dofile("ue4ss/Mods/PacificTogether/Scripts/common.lua")
    local game = StaticFindObject("/Script/EngineSettings.Default__GeneralProjectSettings").ProjectVersion:ToString()
    return string.format("PT|hello mod=%s protocol=%d game=%s build=%d", mod or common.MOD_VERSION, protocol or common.PROTOCOL_VERSION,
        game, PTNative_GameBuild and PTNative_GameBuild() or 0)
end
-- the shipping host refuses a guest that sends no hello. Its own mod sends one only after a PT_JOIN join; the scenarios
-- that join with the test's own `open` send the same hello here (body -Mutate nospawn: none, so no character)
if ROLE == "client" and (os.getenv("PT_JOIN") or "") == "" and SCENARIO ~= "sessionmismatch" and SCENARIO ~= "steamsession" and MUTATE ~= "nospawn" then
    RegisterHook("/Script/Engine.PlayerController:ClientSetHUD", function(self)
        local pc = self:get()
        if netMode() == "client" and pc:IsLocalController() then pc:ServerChangeName(hello()); log("PT|info hello sent") end
    end)
end
-- the other player's character: a PDP_MainCharacter_C of this world that is not ours
local function otherChar()
    local me = myPawn()
    for _, c in ipairs(FindAllOf(CHAR) or {}) do
        if inWorld(c) and not (me and c:GetFullName() == me:GetFullName()) then return c end
    end
end
local function get(o, k) local ok, v = pcall(function() return o[k] end); if ok then return v end end
local function str(v) if type(v) == "userdata" then return name(v) end; return tostring(v) end
local function dist(a, b) local p, q = a:K2_GetActorLocation(), b:K2_GetActorLocation(); return math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2 + (p.Z - q.Z) ^ 2) end
local function yawTo(a, b) local p, q = a:K2_GetActorLocation(), b:K2_GetActorLocation(); return math.deg(math.atan(q.Y - p.Y, q.X - p.X)) end

-- every mesh component owned by char (or by an actor attached to it), with asset and visibility flags
local function bodyMeshes(char, quiet)
    local r, cn = {}, char:GetFullName()
    for _, c in ipairs(FindAllOf("MeshComponent") or {}) do
        local ok, err = pcall(function()
            if not c:IsValid() then return end
            local o = c:GetOwner()
            if not o:IsValid() then return end
            local via = ""
            if o:GetFullName() ~= cn then
                local p = o:GetAttachParentActor()
                if not (p:IsValid() and p:GetFullName() == cn) then return end
                via = " via=" .. cls(o)
            end
            r[#r + 1] = c
            if quiet then return end
            local skel = get(c, "SkeletalMesh")
            local asset = skel or get(c, "StaticMesh")
            local anim, head = "-", "-"
            if skel then
                local oka, a = pcall(function() return c:GetAnimInstance() end); anim = oka and cls(a) or "err"
                local okh, h = pcall(function() return c:IsBoneHiddenByName(FName("head")) end); head = okh and tostring(h) or "err"
            end
            log("PT|body side=%s comp=%s name=%s%s parent=%s asset=%s visible=%s hiddenInGame=%s ownerNoSee=%s onlyOwnerSee=%s rendered=%s anim=%s headHidden=%s",
                ROLE, cls(c), c:GetFName():ToString(), via, name(c:GetAttachParent()), str(asset), tostring(c:IsVisible()),
                str(get(c, "bHiddenInGame")), str(get(c, "bOwnerNoSee")), str(get(c, "bOnlyOwnerSee")), tostring(c:WasRecentlyRendered(0.5)), anim, head)
            local sc, mats = get(c, "RelativeScale3D"), {}
            for i = 0, 3 do local okm, m = pcall(function() return c:GetMaterial(i) end); mats[#mats + 1] = okm and name(m) or "err" end
            log("PT|body side=%s render name=%s mainPass=%s depthPass=%s castShadow=%s hiddenShadow=%s hideSkin=%s maxDraw=%s lod=%s scale=%s mats=%s",
                ROLE, c:GetFName():ToString(), str(get(c, "bRenderInMainPass")), str(get(c, "bRenderInDepthPass")), str(get(c, "CastShadow")),
                str(get(c, "bCastHiddenShadow")), str(get(c, "bHideSkin")), str(get(c, "LDMaxDrawDistance")), str(get(c, "ForcedLodModel")),
                sc and string.format("%.2f,%.2f,%.2f", sc.X, sc.Y, sc.Z) or "nil", table.concat(mats, "|"))
        end)
        if not ok then log("PT|info body comp err %s", tostring(err)) end
    end
    return r
end
local function bodyReport(tag, char)
    if not char then log("PT|body side=%s tag=%s char=none", ROLE, tag); return end
    log("PT|body side=%s tag=%s char=%s role=%s local=%s hidden=%s rendered=%s mesh=%s", ROLE, tag, name(char), str(char.Role),
        tostring(char:IsLocallyControlled()), str(get(char, "bHidden")), tostring(char:WasRecentlyRendered(0.5)), name(get(char, "Mesh")))
    bodyMeshes(char)
end
local function moveState(tag)
    local function one(c)
        if not c then return "none" end
        local v, cm = c:GetVelocity(), c.CharacterMovement
        return string.format("%s{speed=%.0f crouched=%s maxWalk=%.0f sprint=%s}", c:IsLocallyControlled() and "own" or "other",
            math.sqrt(v.X ^ 2 + v.Y ^ 2), str(get(c, "bIsCrouched")), cm.MaxWalkSpeed, str(get(c, "ShouldSprint")))
    end
    local me, o = myPawn(), otherChar()
    log("PT|move side=%s tag=%s %s %s d=%.0f", ROLE, tag, one(me), one(o), (me and o) and dist(me, o) or -1)
    -- where our camera looks vs where the other character is
    local pc = localPC()
    local cm, cr = pc.PlayerCameraManager, pc:GetControlRotation()
    local cl, crot = cm:GetCameraLocation(), cm:GetCameraRotation()
    local mr, ml = me:K2_GetActorRotation(), me:K2_GetActorLocation()
    local ol = o and o:K2_GetActorLocation()
    log("PT|cam side=%s tag=%s cam=(%.0f,%.0f,%.0f) camRot=(p%.0f y%.0f) control=(p%.0f y%.0f) pawn=(%.0f,%.0f,%.0f y%.0f) other=%s viewTarget=%s",
        ROLE, tag, cl.X, cl.Y, cl.Z, crot.Pitch, crot.Yaw, cr.Pitch, cr.Yaw, ml.X, ml.Y, ml.Z, mr.Yaw,
        ol and string.format("(%.0f,%.0f,%.0f) yawFromCam=%.0f", ol.X, ol.Y, ol.Z, math.deg(math.atan(ol.Y - cl.Y, ol.X - cl.X))) or "none",
        name(pc:GetViewTarget()))
end
local shots = 0
local function shot(tag) shots = shots + 1; log("PT|shot side=%s n=%d tag=%s", ROLE, shots, tag); console("HighResShot 1") end
-- on the other player's character only: make every mesh visible to us, then give it a visible engine material
local function flip(char)
    local grid = StaticFindObject("/Engine/EngineMaterials/WorldGridMaterial.WorldGridMaterial")
    for _, c in ipairs(bodyMeshes(char, true)) do
        pcall(function() c:SetOnlyOwnerSee(false); c:SetOwnerNoSee(false); c:SetHiddenInGame(false, false); c:SetVisibility(true, false); c:SetRenderInMainPass(true) end)
        pcall(function() if get(c, "bHideSkin") then c.bHideSkin = false end end)
        for i = 0, c:GetNumMaterials() - 1 do c:SetMaterial(i, grid) end
    end
    log("PT|info flipped %s material=%s", name(char), name(grid))
end

-- Timeline from the moment the guest stands in front of the host. Movement needs input every frame, so it runs
-- in its own fast loop; both sides start it when they see the guest placed (within a frame or two of each other).
-- g* phases: the guest moves, h*: the host moves. A mover strafes along one fixed world direction across the other's
-- view (+1 s, -2 s, +2 s, -1 s), so it starts and ends in the middle and the screenshot at +4 s is taken there.
-- After "flip" the same phases repeat with the remote body made visible.
local PHASES = { "idle", "gwalk", "gcrouch", "gsprint", "hwalk", "hcrouch", "flip", "gwalk", "gcrouch", "gsprint", "hwalk", "hcrouch", "end" }
local function bodyTimeline(onDone)
    local gs = UEHelpers.GetGameplayStatics()
    local t0, loop, cur, shotAt = gs:GetRealTimeSeconds(world()), nil, 0, -1
    local me0, other0 = myPawn(), otherChar()
    local across = math.rad((ROLE == "host" and yawTo(me0, other0) or yawTo(other0, me0)) + 90)
    -- the host (authority) puts both back on their start spots at every phase, so drift does not add up
    local spots = { { me0, me0:K2_GetActorLocation(), me0:K2_GetActorRotation() }, { other0, other0:K2_GetActorLocation(), other0:K2_GetActorRotation() } }
    local function step(fn) local ok, e = pcall(fn); if not ok then log("PT|error timeline %s", tostring(e)) end end
    loop = LoopInGameThreadWithDelay(10, function()
        local me, other = myPawn(), otherChar()
        if not me or not other then return end
        local t = gs:GetRealTimeSeconds(world()) - t0
        while PHASES[cur + 1] and t >= cur * 7 do
            local was = PHASES[cur] or ""
            cur = cur + 1
            local mode = PHASES[cur]
            local mine = function(m) return (m:sub(1, 1) == "g") == (ROLE == "client") and m:sub(1, 1) ~= "i" end
            step(function()
                if was:find("crouch") and mine(was) then me:UnCrouch(false) end
                if was == "gsprint" and ROLE == "client" then me["Command Sprint"](me, false) end
                if mode:find("crouch") and mine(mode) then me:Crouch(false) end
                if mode == "gsprint" and ROLE == "client" then me["Command Sprint"](me, true) end
                if ROLE == "host" then for _, sp in ipairs(spots) do sp[1]:K2_TeleportTo(sp[2], sp[3]) end end
                if mode == "idle" then moveState("start"); bodyReport("remote", other); bodyReport("own", me) end
                if mode == "flip" then flip(other); bodyReport("flipped", other) end
            end)
            if mode == "end" then CancelDelayedAction(loop); onDone(); return end
        end
        local mode, dt = PHASES[cur], t - (cur - 1) * 7
        if dt >= 4 and shotAt ~= cur then
            shotAt = cur
            step(function() moveState(mode); shot(mode .. (cur >= 7 and "-visible" or "")) end)
        end
        local sign = math.floor(dt + 1) // 2 % 2 == 0 and 1 or -1
        local dir = { X = math.cos(across) * sign, Y = math.sin(across) * sign, Z = 0 }
        local moves = mode ~= "idle" and mode ~= "flip" and (mode:sub(1, 1) == "g") == (ROLE == "client")
        if ROLE == "client" then
            -- face the host, except while sprinting (sprint wants forward input)
            local face = mode == "gsprint" and math.deg(math.atan(dir.Y, dir.X)) or yawTo(me, other)
            localPC():SetControlRotation({ Pitch = 0, Yaw = face, Roll = 0 })
        end
        if moves then me:AddMovementInput(dir, 1.0, false) end
    end)
end

local function dumpers(at)
    local steps = {}
    for _, f in ipairs({ "GenerateUHTCompatibleHeaders", "GenerateLuaTypes", "DumpUSMAP", "GenerateSDK" }) do
        table.insert(steps, { check = at .. "_" .. f, timeout = 0, cond = function()
            assert(type(_G[f]) == "function", f .. " not in this UE4SS build")
            local t0 = os.time()
            _G[f]()
            log("PT|info %s took %ds", f, os.time() - t0)
            return true
        end })
    end
    return steps
end

local scenarios = {
    boot = function() return { onMap("RB_MainMenu", 90) } end,

    listen = function()
        if ROLE == "host" then
            return {
                onMap("RB_MainMenu", 90),
                { wait = 5 },
                { run = function() console("open " .. GARAGE .. "?listen") end },
                { check = "host_listen_garage", timeout = 120, cond = function() return netMode() == "listen" and map() == "RB_Garage" end },
                { check = "host_two_pcs", timeout = 180, cond = function() return pcs() == 2 end },
            }
        end
        -- the host may still be loading, and a pending connect gives up after 20 s, so retry
        return { onMap("RB_MainMenu", 90), join("client_connected_garage", "RB_Garage", 210, 30) }
    end,

    -- X1 + X1b + X3 garage: the game's own travel (UserNewGame, QuitToMenu) with a client connected.
    -- X1b: the native LoadMap patch keeps the host listening; -Mutate nokeep/norehost turn it off.
    travel = function()
        local t0, newMap = 0, nil
        local keep = MUTATE ~= "nokeep" and MUTATE ~= "norehost"
        if ROLE == "host" then
            return {
                onMap("RB_MainMenu", 90),
                { run = function()
                    -- M2: the shipping mod's auto-listen (session.lua) does the same, so the mutations turn it off too
                    if not keep then log("PT|info autolisten off %s", tostring(PTNative_SetAutoListen and PTNative_SetAutoListen(false))) end
                    log("PT|info keeplisten=%s patched=%s", tostring(keep), tostring(PTNative_SetKeepListen and PTNative_SetKeepListen(keep)))
                end },
                { wait = 5 },
                { run = function() console("open " .. GARAGE .. "?listen") end },
                { check = "host_listen_garage", timeout = 120, cond = function() return netMode() == "listen" and map() == "RB_Garage" end },
                { check = "host_two_pcs", timeout = 180, cond = function() return pcs() == 2 end },
                { wait = 20 },
                { run = function() survey("garage") end },
                { run = function()
                    lm.mark, t0 = lm.post, os.time()
                    log("PT|info UserNewGame(5, STORY) -> %s", tostring(saveMgr():UserNewGame(5, 1)))
                end },
                { check = "host_native_travel", timeout = 240, cond = function()
                    return lm.post > lm.mark and not ({ RB_Garage = 1, RB_MainMenu = 1, none = 1 })[map()]
                end },
                { run = function() newMap = mapPath(); log("PT|info native travel to %s in %ds, loadmaps pre=%d post=%d", newMap, os.time() - t0, lm.pre, lm.post) end },
                { wait = 5 },
                { check = "host_listen_after_native_travel", timeout = 5, cond = function() return netMode() == "listen" and listening() end },
                { run = function()
                    log("PT|info after native travel: %s %s", state(), driver())
                    if netMode() ~= "listen" and MUTATE ~= "norehost" then t0 = os.time(); console("servertravel " .. newMap .. "?listen") end
                end },
                { check = "host_listen_after_rehost", timeout = 240, cond = function() return netMode() == "listen" and listening() and map() ~= "none" end },
                { run = function() log("PT|info rehost took %ds: %s %s", os.time() - t0, state(), driver()) end },
                { check = "host_two_pcs_after_rehost", timeout = 300, cond = function() return pcs() == 2 end },
                { wait = 15 },
                { run = function() log("PT|info before quit: %s %s", state(), driver()); t0 = os.time(); quitToMenu() end },
                { check = "host_menu_after_quit", timeout = 180, cond = function() return map() == "RB_MainMenu" and netMode() == "standalone" end },
                { run = function() log("PT|info quit took %ds", os.time() - t0) end },
                { wait = 15 },
            }
        end
        local left
        return {
            onMap("RB_MainMenu", 90),
            -- X11 fix, so a rejoin sent while the host still loads waits instead of timing out at 20 s
            { run = function() StaticFindObject("/Script/OnlineSubsystemUtils.Default__IpNetDriver").ResolutionConnectionTimeout = 120 end },
            join("client_connected_garage", "RB_Garage", 210, 30),
            { wait = 20 },
            { run = function() survey("garage") end },
            { check = "client_left_garage", timeout = 300, cond = function() return map() ~= "RB_Garage" and map() ~= "none" end },
            { run = function() left = os.time(); log("PT|info client left the garage: %s", state()) end },
            { check = "client_at_menu_after_host_travel", timeout = 60, cond = function() return map() == "RB_MainMenu" end },
            { check = "client_rejoined_new_map", timeout = 400, cond = function()
                return netMode() == "client" and not ({ RB_Garage = 1, RB_MainMenu = 1, none = 1 })[map()]
            end, tick = (function()
                local nextTry = 0
                return function(t)
                    if MUTATE == "follow" or t < nextTry or map() ~= "RB_MainMenu" or netMode() == "client" then return end
                    nextTry = t + 30
                    console("open " .. HOST)
                end
            end)() },
            { run = function() log("PT|info rejoined %ds after leaving: %s", os.time() - left, state()) end },
            { check = "client_menu_after_host_quit", timeout = 400, cond = function() return map() == "RB_MainMenu" end },
            { run = function() log("PT|info after host quit: %s", state()) end },
        }
    end,

    -- X11 + X3 zone: the client connects before the host starts a long zone load and must not time out
    zonejoin = function()
        if ROLE == "host" then
            return {
                onMap("RB_MainMenu", 90),
                { run = function() log("PT|info timeouts %s", timeouts()) end },
                { wait = 75 }, -- exceed the game's 60 s InitialConnectTimeout; mutation shortconnect retains that limit
                { run = function() console("open " .. FOREST .. "?listen") end },
                { check = "host_listen_zone", timeout = 180, cond = function() return netMode() == "listen" and map() == "Wilderness_Forest_01" end },
                { check = "host_two_pcs", timeout = 120, cond = function() return pcs() == 2 end },
                { wait = 20 },
                { run = function() survey("zone") end },
                { wait = 30 },
            }
        end
        local opened = 0
        return {
            onMap("RB_MainMenu", 90),
            { run = function()
                -- -Mutate cdo: no ini, the fix is set on the class default object instead (new drivers copy it)
                if MUTATE == "cdo" then StaticFindObject("/Script/OnlineSubsystemUtils.Default__IpNetDriver").ResolutionConnectionTimeout = 120 end
                log("PT|info timeouts %s", timeouts()); opened = os.time(); console("open " .. HOST)
            end },
            -- one open only: a timeout must show as a failure, not be hidden by a retry
            { check = "client_connected_zone", timeout = 180, cond = function() return netMode() == "client" and map() == "Wilderness_Forest_01" end,
              tick = function(t) if t % 2 == 0 then log("PT|info t=%d %s %s", t, state(), timeouts()) end end },
            { run = function() log("PT|info connected %ds after open", os.time() - opened) end },
            { wait = 20 },
            { run = function() survey("zone") end },
        }
    end,

    -- X10: a guest who played their own save (slot 6) joins, follows a map change; do the guest's saves change?
    guestsave = function()
        if ROLE == "host" then
            return {
                onMap("RB_MainMenu", 90),
                { wait = 5 },
                { run = function() console("open " .. GARAGE .. "?listen") end },
                { check = "host_listen_garage", timeout = 120, cond = function() return netMode() == "listen" and map() == "RB_Garage" end },
                { check = "host_two_pcs", timeout = 400, cond = function() return pcs() == 2 end },
                { wait = 40 },
                { run = function() console("servertravel " .. GARAGE .. "?listen") end },
                { wait = 10 },
                { check = "host_two_pcs_after_travel", timeout = 240, cond = function() return netMode() == "listen" and pcs() == 2 end },
                { wait = 120 },
            }
        end
        local loads
        return {
            onMap("RB_MainMenu", 90),
            -- one machine: the shipping mod's auto-listen (D14) would put the guest's own game on the host's port
            { run = function() log("PT|info autolisten off %s", tostring(PTNative_SetAutoListen and PTNative_SetAutoListen(false))) end },
            { wait = 5 },
            { run = function() log("PT|info own game: UserNewGame(6, STORY) -> %s", tostring(saveMgr():UserNewGame(6, 1))) end },
            { check = "client_own_game", timeout = 240, cond = function() return not ({ RB_MainMenu = 1, none = 1 })[map()] end },
            { wait = 20 },
            { run = function() log("PT|info own game %s %s", map(), mgrState()); quitToMenu() end },
            { check = "client_back_in_menu", timeout = 180, cond = function() return map() == "RB_MainMenu" end },
            { wait = 5 },
            { run = function() log("PT|info menu %s", mgrState()); hookSaves(); snap("menu") end },
            join("client_connected_garage", "RB_Garage", 300, 30),
            { run = function() loads = lm.post end },
            { wait = 30 },
            { run = function() log("PT|info joined %s", mgrState()); snap("joined") end },
            { check = "client_followed_travel", timeout = 240, cond = function()
                return netMode() == "client" and map() == "RB_Garage" and lm.post > loads
            end },
            { wait = 30 },
            { run = function() log("PT|info travelled %s", mgrState()); snap("travelled") end },
            -- the game's own autosave path, then a direct save call
            { run = function()
                local d = first("BP_AutoSaveDirector_C")
                log("PT|info autosave director %s", name(d))
                d:FlagAutosave(); d:CheckFlagAndTrigger()
            end },
            { wait = 15 },
            { run = function() snap("autosave") end },
            { run = function() log("PT|info SaveGame -> %s", tostring(saveMgr():SaveGame(saveMgr():GetCurrentSlot(), "", 2))) end },
            { wait = 15 },
            { run = function() snap("savegame") end },
        }
    end,

    -- X13: the host spawns a character for the guest and puts it 300 uu in front of its camera; both sides list the
    -- other's meshes, screenshot, and animate (walk, crouch, sprint). -Mutate nospawn: the guest stays a spectator.
    body = function()
        local done, placed = false, false
        if ROLE == "host" then
            local guest
            return {
                onMap("RB_MainMenu", 90),
                { wait = 5 },
                { run = function() console("open " .. GARAGE .. "?listen") end },
                { check = "host_listen_garage", timeout = 120, cond = function() return netMode() == "listen" and map() == "RB_Garage" end },
                { check = "host_two_pcs", timeout = 180, cond = function() return pcs() == 2 end },
                { wait = 10 },
                -- M2: the shipping mod (session.lua, P1) gives the guest its character after the hello
                { check = "host_spawned_guest", timeout = 30, cond = function()
                    local hostChar = myPawn()
                    assert(hostChar and cls(hostChar) == CHAR, "host pawn " .. cls(hostChar))
                    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
                        if inWorld(pc) and not pc:IsLocalController() and cls(pc.Pawn) == CHAR then guest = pc.Pawn end
                    end
                    if guest then log("PT|info guest character %s manager=%s", name(guest), name(first("BP_MainCharacterManager_C").CharacterActor)) end
                    return guest ~= nil
                end },
                { wait = 10 },
                { run = function() bodyReport("remote-before", guest); bodyReport("own-before", myPawn()) end },
                { check = "host_placed_guest", timeout = 10, cond = function()
                    local pc, me = localPC(), myPawn()
                    local cam = pc.PlayerCameraManager
                    local cl, yaw = cam:GetCameraLocation(), cam:GetCameraRotation().Yaw
                    -- 300 uu in front of the camera, on our floor; try four directions until the teleport finds room
                    for i = 0, 3 do
                        local y = yaw + 90 * i
                        local to = { X = cl.X + math.cos(math.rad(y)) * 300, Y = cl.Y + math.sin(math.rad(y)) * 300, Z = me:K2_GetActorLocation().Z }
                        if guest:K2_TeleportTo(to, { Pitch = 0, Yaw = y + 180, Roll = 0 }) then
                            if i > 0 then pc:SetControlRotation({ Pitch = 0, Yaw = y, Roll = 0 }) end
                            log("PT|info placed guest at yaw=%.0f (try %d) d=%.0f", y, i, dist(me, guest))
                            return true
                        end
                    end
                    return false
                end },
                { run = function() bodyTimeline(function() done = true end) end },
                { check = "host_timeline_done", timeout = 150, cond = function() return done end },
                { wait = 5 },
            }
        end
        return {
            onMap("RB_MainMenu", 90),
            join("client_connected_garage", "RB_Garage", 210, 30),
            { check = "client_possessed", timeout = 60, cond = function() return cls(myPawn()) == CHAR end },
            { wait = 3 },
            { run = function() bodyReport("remote-before", otherChar()); bodyReport("own-before", myPawn()) end },
            { run = function()
                local poll
                poll = LoopInGameThreadWithDelay(10, function()
                    local me, o = myPawn(), otherChar()
                    if me and o and dist(me, o) < 400 then CancelDelayedAction(poll); placed = true; bodyTimeline(function() done = true end) end
                end)
            end },
            { check = "client_placed", timeout = 60, cond = function() return placed end },
            { check = "client_timeline_done", timeout = 150, cond = function() return done end },
        }
    end,

    dump = function()
        local steps = { onMap("RB_MainMenu", 90), { wait = 5 } }
        for _, s in ipairs(dumpers("menu")) do table.insert(steps, s) end
        table.insert(steps, { run = function() console("open " .. GARAGE) end })
        table.insert(steps, onMap("RB_Garage", 120))
        table.insert(steps, { wait = 10 })
        for _, s in ipairs(dumpers("garage")) do table.insert(steps, s) end
        return steps
    end,
}

local function check(name, pass, detail)
    log("PT|check side=%s name=%s result=%s detail=%s", ROLE, name, pass and "PASS" or "FAIL", detail)
end

-- New scenarios go in Scripts/scenarios/<name>.lua (one file per scenario, so parallel work does not collide):
-- the module returns function(T) -> steps, with T = the helpers below.
local T = {
    ROLE = ROLE, MUTATE = MUTATE, HOST = HOST, GARAGE = GARAGE, FOREST = FOREST, CHAR = CHAR,
    log = log, check = check, world = world, map = map, netMode = netMode, pcs = pcs, state = state, console = console,
    onMap = onMap, name = name, cls = cls, first = first, saveMgr = saveMgr, mapPath = mapPath, driver = driver,
    listening = listening, quitToMenu = quitToMenu, join = join, survey = survey, timeouts = timeouts, snap = snap,
    hookSaves = hookSaves, mgrState = mgrState, inWorld = inWorld, localPC = localPC, myPawn = myPawn,
    otherChar = otherChar, hello = hello, get = get, str = str, dist = dist, yawTo = yawTo, bodyMeshes = bodyMeshes,
    bodyReport = bodyReport, moveState = moveState, shot = shot, flip = flip,
}

require("repl")(T)
require("fixtures")(T)
require("gamemcp")(T)
-- optional game-MCP tool families (Scripts/mcp_*.lua, one per file); a missing one is fine, a broken one is an error
for _, m in ipairs({ "mcp_state", "mcp_actions", "mcp_observe" }) do
    local ok, f = pcall(require, m)
    if ok then f(T)
    elseif not tostring(f):find("module '" .. m .. "' not found", 1, true) then log("PT|error %s %s", m, tostring(f)) end
end
-- X5: run-test.ps1 -Tunnel puts the scenario through the native tunnel (tunnel.lua); the client then opens 10.77.0.1
local tunnel, realHost = os.getenv("PT_TUNNEL") and require("tunnel"), HOST
if tunnel then HOST = tunnel.host(HOST); T.HOST = HOST end

local make = scenarios[SCENARIO]
if not make then
    local ok, mod = pcall(require, "scenarios." .. SCENARIO)
    if not ok then
        log("PT|error unknown scenario %s: %s", SCENARIO, tostring(mod))
        return
    end
    make = function() return mod(T) end
end
local steps = make()
if tunnel then steps = tunnel.wrap(T, steps, realHost) end
local planned = 0
for _, s in ipairs(steps) do if s.check then planned = planned + 1 end end
log("PT|plan side=%s checks=%d scenario=%s mutate=%s", ROLE, planned, SCENARIO, MUTATE)

local i, started, loop = 1, os.time(), nil
loop = LoopInGameThreadWithDelay(1000, function()
    local s, t = steps[i], os.time() - started
    local finished = true
    if s.run then
        local ok, err = pcall(s.run)
        if not ok then log("PT|error step %d: %s", i, tostring(err)) end
    elseif s.wait then
        finished = t >= s.wait
    else
        -- errors during map loads are transient, so they count as "not yet" until the timeout
        local ok, r = pcall(s.cond)
        local pass = ok and r == true
        if pass or t >= s.timeout then
            local okd, d = pcall(state)
            check(s.check, pass, (ok and "" or "error=" .. tostring(r) .. " ") .. (okd and d or "") .. " t=" .. t)
        else
            finished = false
            if s.tick then
                local okt, err = pcall(s.tick, t)
                if not okt then log("PT|error step %d tick: %s", i, tostring(err)) end
            end
        end
    end
    if not finished then return end
    i, started = i + 1, os.time()
    if i > #steps then
        log("PT|done side=%s", ROLE)
        CancelDelayedAction(loop)
    end
end)
