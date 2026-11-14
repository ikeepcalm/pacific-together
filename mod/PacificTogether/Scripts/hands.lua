-- P1 hands: what the other player holds and does with it. The game is first person: a held item is a hand manifestation actor
-- (BP_BaseHandManifestation_C, local to each process, drawn on the first-person arms), so nothing of it reaches the other player's
-- view of the character. Each side reports its own hand (item meshes, size, toggle state) and tool use; the other side mirrors it
-- on the character it has of us: StaticMeshActors on the hand_r bone (large items in front of the chest), a spot light for an
-- "on" flashlight, a swing of the item on use. Nothing replicates, nothing exists outside a session (Q7).
-- The mannequin skeleton has no tool animation (only ALS turn and get-up montages), so the swing is procedural.
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local tint=require("itemtint")
local log = common.log

local M = {}
if os.getenv("PT_MUTATE") == "nohands" then return M end

local CHAR = "PDP_MainCharacter_C"
local SWING_S = 0.45
local function valid(o) return type(o) == "userdata" and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function path(o) return valid(o) and (o:GetFullName():match("^%S+ (.+)$")) or nil end

-- ours ----------------------------------------------------------------------------------------------------------------

local function ownChar()
    local pc = UEHelpers.GetPlayerController()
    local p = valid(pc) and pc.Pawn
    if valid(p) and p:GetClass():GetFName():ToString() == CHAR then return p end
    local cm = FindFirstOf("BP_MainCharacterManager_C")
    return valid(cm) and valid(cm.CharacterActor) and cm.CharacterActor or nil
end

local SMC, LIGHT = StaticFindObject("/Script/Engine.StaticMeshComponent"), StaticFindObject("/Script/Engine.LightComponent")

-- What the item shows in the hand: its visible static meshes (an item's CurrentItemMesh; a tool has a few: can body, handle, ...),
-- the biggest as drawn first (the Scrapper's canister fill is r=137 at scale 0.1: unscaled it was taken for the base and shown 10x as a
-- blob of textures, 2026-10-30). SM_bboxTube is a VFX volume some tools carry; so is the Impact Hammer's /Engine/BasicShapes/Cylinder (100 uu
-- tall, untextured: a giant green body on the guest, 2026-10-23), so engine meshes are skipped.
local function heldParts(h)
    local list = {}
    for _, c in ipairs(h:K2_GetComponentsByClass(SMC)) do
        c = c:get()
        local sm = valid(c) and c:IsVisible() and c.StaticMesh
        if valid(sm) and not sm:GetFullName():find("bboxTube", 1, true)
            and not (sm:GetFullName():find("/Engine/", 1, true) and os.getenv("PT_MUTATE") ~= "engmesh") then list[#list + 1] = { c = c, sm = sm, r = sm:GetBounds().SphereRadius * c:K2_GetComponentScale().X } end
    end
    table.sort(list, function(a, b) return a.r > b.r end)
    return list
end

local IDENT = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
local SKC = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
-- "<mesh>@<tx,ty,tz,qx,qy,qz,qw,sx,sy,sz>" per part: the first relative to the first-person arms' Hand bone (grip and size), the
-- others relative to the first
local function encodeParts(h, list)
    local out, kml = {}, UEHelpers.GetKismetMathLibrary()
    local base = list[1] and list[1].c:K2_GetComponentToWorld()
    local arms = h:K2_GetComponentsByClass(SKC)[1]
    arms = arms and arms:get()
    local hand = valid(arms) and arms:DoesSocketExist(FName("Hand")) and arms:GetSocketTransform(FName("Hand"), 0) or nil
    for i, p in ipairs(list) do
        local t = i == 1 and (hand and kml:MakeRelativeTransform(base, hand) or IDENT)
            or kml:MakeRelativeTransform(p.c:K2_GetComponentToWorld(), base)
        out[#out + 1] = string.format("%s@%.2f,%.2f,%.2f,%.5f,%.5f,%.5f,%.5f,%.3f,%.3f,%.3f", path(p.sm), t.Translation.X, t.Translation.Y, t.Translation.Z,
            t.Rotation.X, t.Rotation.Y, t.Rotation.Z, t.Rotation.W, t.Scale3D.X, t.Scale3D.Y, t.Scale3D.Z)
    end
    return table.concat(out, ";")
end

-- "<archetype>|<size>|<on 0/1>|<light kind>|<parts>"; "" for an empty hand
local held = {} -- the hand item now: { id, at = when it came, parts = its encoded parts once read }
local function localState()
    local c = ownChar()
    if not c then return "" end
    local o = {}
    c:GetActiveHandItem(false, o)
    local h = o["Hand Item"]
    if not valid(h) or not valid(h.Instance) then return "" end
    local arch = h.Instance.Archetype
    -- the grip is read off the animating first-person arms: it changed every report (Scrapper 52 -> 17 uu in 0.3 s, rendered guest
    -- 2026-10-30) and the mirror was rebuilt at a new spot each time. Read once, 1 s after the item is in the hand (equip anim done).
    local id = h:GetFullName() .. (valid(arch) and arch:GetFName():ToString() or "")
    if held.id ~= id then held = { id = id, at = os.clock() } end
    if not held.parts then
        if os.clock() - held.at < 1 then return "" end
        held.parts = encodeParts(h, heldParts(h))
    end
    local on, kind = 0, "none"
    local ok, v = pcall(function() return h.IsOn end)
    if ok and v == true then on = 1 end
    if h:K2_GetComponentsByClass(LIGHT)[1] then kind = h:GetClass():GetFName():ToString():find("Camping", 1, true) and "point" or "spot" end
    return string.format("%s|%d|%d|%s|%s", valid(arch) and arch:GetFName():ToString() or "?", arch.Size or 0, on, kind, held.parts)
end

-- theirs ----------------------------------------------------------------------------------------------------------------

local remotes = {} -- PlayerState.PlayerId -> { state, at, useAt, tint }: each other player's last report (3-4 players, net.share)
local ids = {} -- character full name -> its PlayerId (read again only while unknown: the PlayerState can arrive late)
local function remoteOf(id) remotes[id] = remotes[id] or { state = "", at = 0, tint = "" }; return remotes[id] end
local mirrors = {}                    -- character full name -> { actor, parts, light, state, tint, swingAt, handledUse }

-- never our own body: the guest's Scrapper was built on the host's own character (while driving ownChar had no character) and sat
-- over the host's hotbar for good (playtest 2026-10-31). On the host the other body is the one a guest's controller drives.
local function otherChars()
    local list, mine = {}, {}
    local pc = UEHelpers.GetPlayerController()
    local cm = FindFirstOf("BP_MainCharacterManager_C")
    for _, o in ipairs({ ownChar(), valid(pc) and pc.Pawn or nil, valid(cm) and cm.CharacterActor or nil }) do
        if valid(o) then mine[o:GetAddress()] = true end
    end
    local host = not safety.guest()
    local wn = UEHelpers.GetWorld():GetFullName()
    for _, c in ipairs(FindAllOf(CHAR) or {}) do
        if valid(c) and not mine[c:GetAddress()] and c:GetWorld():GetFullName() == wn then
            local ctl = c.Controller
            if not host or (valid(ctl) and not ctl:IsLocalController()) then list[#list + 1] = c end
        end
    end
    return list
end

local function spawn(char, class)
    local gs = UEHelpers.GetGameplayStatics()
    local l = char:K2_GetActorLocation()
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = l.X, Y = l.Y, Z = l.Z }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    return gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(char, StaticFindObject(class), xf, 1, nil), xf)
end

local function dropMirror(key)
    local m = mirrors[key]
    if not m then return end
    for _, a in ipairs(m.parts) do if valid(a) then a:K2_DestroyActor() end end
    if valid(m.light) then m.light:K2_DestroyActor() end
    mirrors[key] = nil
end

local function loadMesh(p)
    local m = StaticFindObject(p)
    if not valid(m) then pcall(LoadAsset, p); m = StaticFindObject(p) end
    return valid(m) and m or nil
end

local noWorld = {} -- first-person mesh paths without a "_World" twin
local function worldMesh(p)
    if noWorld[p] then return nil end
    local w = p:gsub("([^/%.]+)%.([^/%.]+)$", "%1_World.%2_World")
    if w ~= p and loadMesh(w) then return w end
    -- the Scrapper's first-person base is SM_Tool_ItemHarvester_Base_01, its world mesh SM_Tool_ItemHarvester_01_World (2026-10-30)
    local nb = w:gsub("_Base_", "_")
    if nb ~= w and loadMesh(nb) then return nb end
    noWorld[p] = true
end

local function meshActor(char, p)
    local sm = loadMesh(p)
    if not sm then return nil end
    local a = spawn(char, "/Script/Engine.StaticMeshActor")
    local comp = a.StaticMeshComponent
    comp:SetMobility(2)
    comp:SetStaticMesh(sm)
    comp:SetCollisionEnabled(0)
    comp:SetCastShadow(false)
    return a
end

-- first-person Hand bone -> third-person hand_r: the Prybar's pose on the first-person arms (measured 2026-10-30), which shows right
-- on hand_r untransformed; every other tool keeps its own grip and size relative to it. Mutation nograsp: the old identity pose.
local GRIP = { Translation = { X = 31.4, Y = 24.4, Z = 47.0 }, Rotation = { X = 0.9924, Y = -0.0790, Z = 0.0868, W = 0.0368 }, Scale3D = { X = 1.2, Y = 1.2, Z = 1.2 } }

-- A world mesh (the tool as it lies on the ground) is held level, its front (+X) where the player faces, its pivot in the right hand.
-- The grip read off the first-person arms suits only the first-person part's pivot: on world meshes it put the Scrapper 59 cm up the
-- arm pointing up, and the Impact Hammer and blowtorch were off the same way (rendered guest 2026-10-30).
local function levelHold(char)
    local kml = UEHelpers.GetKismetMathLibrary()
    local hand = char.Mesh:GetSocketTransform(FName("hand_r"), 0)
    local f = char:GetActorForwardVector()
    local want = { Translation = hand.Translation, Rotation = kml:Conv_RotatorToTransform({ Pitch = 0, Yaw = math.deg(math.atan(f.Y, f.X)), Roll = 0 }).Rotation,
        Scale3D = { X = 1, Y = 1, Z = 1 } }
    return kml:MakeRelativeTransform(want, hand)
end

local function build(char, st, remote) -- remote: that player's report (tint, last use)
    local arch, size, on, kind, parts = st:match("^([^|]*)|(%d+)|(%d)|(%a+)|(.*)$")
    local m = { state = st, tint = remote.tint, arch = arch, size = tonumber(size), on = on == "1", kind = kind, parts = {}, swingAt = nil }
    for p, t in parts:gmatch("([^;@]+)@([^;]+)") do
        -- a tool's world mesh (what lies on the ground: one piece, world materials, true size) beside its first-person one
        -- ("SM_Tool_Breaker_01" -> "SM_Tool_Breaker_01_World"): first-person parts carry first-person materials and sizes and
        -- showed as a jumble on the other player (2026-10-30). Mutation noworldmesh: first-person parts only.
        local world = #m.parts == 0 and os.getenv("PT_MUTATE") ~= "noworldmesh" and worldMesh(p)
        local a = meshActor(char, world or p)
        if a then
            local v = {}
            for n in t:gmatch("[^,]+") do v[#v + 1] = tonumber(n) end
            if #m.parts == 0 then
                -- large items: both hands, in front of the chest (the mannequin has no carry animation); the rest in the right hand
                if m.size == 1 then
                    a:K2_AttachToComponent(char.RootComponent, FName("None"), 2, 2, 2, false)
                    a:K2_SetActorRelativeLocation({ X = 45, Y = 0, Z = 0 }, false, {}, true)
                else
                    a:K2_AttachToComponent(char.Mesh, FName("hand_r"), 2, 2, 2, false)
                    if os.getenv("PT_MUTATE") ~= "nograsp" then
                        local kml = UEHelpers.GetKismetMathLibrary()
                        local rel = { Translation = { X = v[1], Y = v[2], Z = v[3] }, Rotation = { X = v[4], Y = v[5], Z = v[6], W = v[7] }, Scale3D = { X = v[8], Y = v[9], Z = v[10] } }
                        m.base = world and levelHold(char) or kml:ComposeTransforms(rel, kml:InvertTransform(GRIP))
                        if world then m.base.Scale3D = { X = 1, Y = 1, Z = 1 } end -- a world mesh is at its true size at 1
                        a:K2_SetActorRelativeTransform(m.base, false, {}, true)
                    end
                end
            else
                a:K2_AttachToActor(m.parts[1], FName("None"), 2, 2, 2, false)
                a:K2_SetActorRelativeTransform({ Translation = { X = v[1], Y = v[2], Z = v[3] }, Rotation = { X = v[4], Y = v[5], Z = v[6], W = v[7] },
                    Scale3D = { X = v[8], Y = v[9], Z = v[10] } }, false, {}, true)
            end
            tint.mesh(a.StaticMeshComponent,remote.tint)
            m.parts[#m.parts + 1] = a
            if world then break end -- the world mesh is the whole tool
        end
    end
    m.actor = m.parts[1]
    if m.on then
        local a = spawn(char, m.kind == "point" and "/Script/Engine.PointLight" or "/Script/Engine.SpotLight")
        local lc = a.LightComponent
        lc:SetMobility(2)
        -- the potato flashlight's own values (intensity is unitless here: the level's lamps are 2..160, the torch 80000)
        local bio = m.arch == "IA_Tool_Toggle_Flashlight_Bio"
        lc:SetLightColor(bio and { R = 1, G = 0.165, B = 0.888, A = 1 } or { R = 1, G = 0.77, B = 0.75, A = 1 }, true)
        if bio then
            lc.bUseInverseSquaredFalloff = false; lc.LightFalloffExponent = 2
            lc:SetIntensity(100); lc:SetAttenuationRadius(2000); lc:SetOuterConeAngle(75)
        elseif m.kind == "point" then
            lc:SetIntensity(20000); lc:SetAttenuationRadius(800)
        else
            lc:SetIntensity(80000); lc:SetAttenuationRadius(1350); lc:SetOuterConeAngle(36)
        end
        m.light = a
    end
    -- a toggle press arrives just before the state it changes: the swing goes on in the rebuilt mirror
    if remote.useAt and os.clock() - remote.useAt < SWING_S then m.swingAt = remote.useAt end
    return m
end

local function swing(m)
    if not (m.swingAt and valid(m.actor)) then return end
    local t = (os.clock() - m.swingAt) / SWING_S
    local kml = UEHelpers.GetKismetMathLibrary()
    local base = m.base and kml:TransformRotation(m.base, { Pitch = 0, Yaw = 0, Roll = 0 }) or { Pitch = 0, Yaw = 0, Roll = 0 }
    if t >= 1 then
        m.swingAt = nil
        m.actor:K2_SetActorRelativeRotation(base, false, {}, true)
        return
    end
    m.actor:K2_SetActorRelativeRotation(kml:ComposeRotators(base, { Pitch = -70 * math.sin(t * math.pi), Yaw = 0, Roll = 0 }), false, {}, true)
end

local function follow(char, m)
    if valid(m.light) then
        local head = char.Mesh:GetSocketLocation(FName("head"))
        local aim = char:GetBaseAimRotation()
        local f = UEHelpers.GetKismetMathLibrary():GetForwardVector(aim)
        m.light:K2_SetActorLocationAndRotation({ X = head.X + f.X * 30, Y = head.Y + f.Y * 30, Z = head.Z + f.Z * 30 }, aim, false, {}, true)
    end
    swing(m)
end

local nextScan, others = 0, {}
local function update()
    if not safety.active() then
        for k in pairs(mirrors) do dropMirror(k) end
        remotes = {}
        return
    end
    if os.time() >= nextScan then nextScan = os.time() + 2; others = otherChars() end
    local seen = {}
    for _, c in ipairs(others) do
        if valid(c) then
            local key = c:GetFullName()
            seen[key] = true
            local m = mirrors[key]
            if (ids[key] or -1) < 0 then ids[key] = net.idOf(c) end
            local remote = remoteOf(ids[key])
            if remote.state == "" then
                if m then dropMirror(key) end
            else
                if m and (m.state ~= remote.state or m.tint ~= remote.tint) then dropMirror(key); m = nil end
                if not m then m = build(c, remote.state, remote); mirrors[key] = m; log("PT|hands mirror %s %s", key:match("[^.]+$"), remote.state:sub(1, 160)) end
                if remote.useAt and remote.useAt ~= m.handledUse then m.handledUse, m.swingAt = remote.useAt, remote.useAt end
                follow(c, m)
            end
        end
    end
    for key in pairs(mirrors) do if not seen[key] then dropMirror(key) end end
end

-- state reports and tool use ---------------------------------------------------------------------------------------------

local lastSent, lastAt, lastTint = nil, 0, nil
local send = net.send

local function report()
    if not safety.active() then lastSent = nil; return end
    local s = localState()
    local c=ownChar();local hand={}
    if c then c:GetActiveHandItem(false,hand) end
    local h=hand['Hand Item'];local appearance=valid(h) and valid(h.Instance) and tint.spec(h.Instance) or ""
    if appearance~=lastTint or os.time()-lastAt>=3 then
        lastTint=appearance
        send('g.hands.tint',appearance)
    end
    -- on change, else every 3 s so a late joiner and a missed message catch up
    if s ~= lastSent or os.time() - lastAt >= 3 then
        lastSent, lastAt = s, os.time()
        send("g.hands.s", s)
    end
end

net.share('g.hands.tint',function(_,data,from)
    if #data>2200 then return end
    if data~="" and not data:match('^:p[%w_/%.-]+:t[01]:c[%w_/%.-]+$') then return end
    remoteOf(from).tint=data -- update() rebuilds that player's mirror
end)
net.share("g.hands.s", function(_, data, from) local r = remoteOf(from); r.state, r.at = data, os.time() end)
net.share("g.hands.use", function(_, _, from) remoteOf(from).useAt = os.clock() end)

-- The use-press input event of the base class (_2 is the press, _3 the release; every tool's overridden PrimaryUsePress is called
-- from it). A pre hook: post hooks of Blueprint events do not fire (docs/spikes/PT1-feel.md).
local USE = "/Game/Gameplay/Inventory/BaseItems/Hand/BP_BaseHandManifestation.BP_BaseHandManifestation_C:InpActEvt_ToolPrimaryUse_K2Node_InputActionEvent_2"
local useHooked = false
local function hookUse()
    useHooked = pcall(RegisterHook, USE, function()
        if safety.active() then send("g.hands.use", "") end
    end)
end

-- a map change frees every object we hold
RegisterLoadMapPreHook(function() lastTint=nil;mirrors, others, nextScan, remotes, ids = {}, {}, 0, {}, {} end)

LoopInGameThreadWithDelay(100, function()
    local ok, err = pcall(function()
        if not useHooked then hookUse() end
        report()
        update()
    end)
    if not ok then log("PT|error hands %s", tostring(err)) end
end)

return M
