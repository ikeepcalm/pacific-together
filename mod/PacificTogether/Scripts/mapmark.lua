-- P8 (D17): where the other player is. Two runtime components on the other player's replicated character, each side its
-- own, nothing replicates and nothing exists outside a session (docs/spikes/PT2-map.md):
--   * a MinimapPlugin MapIconComponent: the ARC screen in the car draws it (the only spatial map the game has)
--   * the game's own HUD objective marker (SC_GenericObjective -> UMG_GenericObjective, edge-clamped on screen), shown
--     only past HANDOVER uu with "<name> <metres> m"; closer than that the name tag (nametag.lua) does the job
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local nametag = require("nametag")
local log = common.log

local M = { HANDOVER = 3000 } -- uu, 30 m: where the name tag is already half faded (nametag NEAR 1500, FAR 5000)
if os.getenv("PT_MUTATE") == "nomapmark" then return M end

local ICON = "/Script/MinimapPlugin.MapIconComponent"
local HUD = "/Game/UI/NavigationSystems/SC_GenericObjective.SC_GenericObjective_C"
local XF = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
local TYPE_BLUE = 3 -- EObjectiveMarkerDisplayType: the blue quest marker, with text

local BLUE, GREEN = { R = 0.1, G = 0.4, B = 1.0, A = 1.0 }, { R = 0.1, G = 1.0, B = 0.2, A = 1.0 }
local function colourOf(host) return host and BLUE or GREEN end
local proxyOf = {} -- full names of our own icon components the host-icon copy must leave alone
local marks = {} -- character full name -> { icon, hud, shown, text }

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end

local function class(path)
    local c = StaticFindObject(path)
    if not c:IsValid() then c = LoadAsset(path) end
    return c
end

local function carIcon()
    local wn = UEHelpers.GetWorld():GetFullName()
    for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
        if valid(c) and c:GetWorld():GetFullName() == wn and valid(c.MapIcon) then return c.MapIcon end
    end
end

-- nil until the car (and so the style to copy) exists
local function addIcon(char)
    local s = carIcon()
    if not s then return nil end
    local icon = char:AddComponentByClass(class(ICON), false, XF, false)
    icon.IconTexture, icon.IconMaterial_UMG, icon.IconMaterial_Canvas = s.IconTexture, s.IconMaterial_UMG, s.IconMaterial_Canvas
    icon:SetIconSize(s.IconSize, s.IconSizeUnit)
    icon:SetIconZOrder(s.IconZOrder + 1)
    icon:SetIconDrawColor(colourOf(safety.guest())) -- the other one: host blue, guest green
    icon:SetIconVisible(true)
    return icon
end

local function addHud(char)
    local c = char:AddComponentByClass(class(HUD), false, XF, false)
    c.UpdatePositionOnTick = true
    c:ActivateObjective() -- creates the widget (UMG_GenericObjective) and puts it on the screen
    if valid(c.MainIconWidget) then
        c:SetMarkerVisuals(TYPE_BLUE, FText(""))
        c.MainIconWidget:SetVisibility(2) -- hidden until past HANDOVER
    end
    return c
end

local function update()
    local list = safety.active() and nametag.others() or {}
    local pc = UEHelpers.GetPlayerController()
    local cam = valid(pc) and valid(pc.PlayerCameraManager) and pc.PlayerCameraManager:GetCameraLocation()
    local seen = {}
    for _, ch in ipairs(list) do
        if valid(ch) then
            local key = ch:GetFullName()
            local m = marks[key] or {}
            marks[key], seen[key] = m, true
            if not valid(m.icon) then m.icon = addIcon(ch) end
            if not valid(m.hud) then m.hud = addHud(ch) end
            local w = valid(m.hud) and m.hud.MainIconWidget
            if cam and w and valid(w) then
                local l = ch:K2_GetActorLocation()
                local d = math.sqrt((cam.X - l.X) ^ 2 + (cam.Y - l.Y) ^ 2 + (cam.Z - l.Z) ^ 2)
                local show = d > M.HANDOVER
                if show then
                    local ps = ch.PlayerState
                    local text = (valid(ps) and ps:GetPlayerName():ToString() or "") .. " " .. math.floor(d / 100 + 0.5) .. " m"
                    if text ~= m.text then m.text = text; w.TaskText:SetText(FText(text)) end
                    w.ObjectiveText:SetVisibility(0)
                end
                if show ~= m.shown then m.shown = show; w:SetVisibility(show and 0 or 2) end
            end
        end
    end
    -- the other player left (or the session ended): the markers go with them
    for key, m in pairs(marks) do
        if not seen[key] then
            if valid(m.hud) then m.hud:DeactivateObjective(false); m.hud:K2_DestroyComponent(m.hud) end
            if valid(m.icon) then m.icon:K2_DestroyComponent(m.icon) end
            marks[key] = nil
        end
    end
end

-- The ARC map's terrain and roads are a capture the map bounds take at level start; on the guest it came out blank (only
-- icons, hand playtest 2026-10-23), a RecaptureMinimap once the world is there drew it like the host's (seen live).
-- s after the guest first sees this map's bounds: one capture, once the world has streamed in (each capture held a rendered
-- guest's frame 0.8-1.9 s; two of them, at 10 and 40 s, rendered profile 2026-10-24)
local RECAPTURE = { 30 }
local captureSeen, captureDone = nil, 0

-- The ARC waypoint (owner requests 2026-10-30, 2026-11-12): each side's ARC screen places its own BP_WaypointActor (map pin +
-- in-world marker, gone by itself within 10 m of the local camera). Each player keeps their OWN pin and sees the partner's as a
-- second pin: the partner's is a MapIconComponent on the map bounds actor (not a second BP_WaypointActor: the ARC screen's
-- FindExistingWaypoint takes the first actor of the class and would move the partner's). Colours: host blue, guest green, on the
-- pins and on the partner-position icons. Both sides send their waypoint ("x y z" or "none") when it changes.
-- Mutation nowaypoint: off. Mutation onemark: the old single shared marker (the partner's spawns/moves our own actor).
local net = require("net")
local WP = "/Game/UI/CarEquipment/Internal/Gobbler/BP_WaypointActor.BP_WaypointActor_C"
local wp = { sent = nil, got = nil, pending = {} }
local pins, pinTex = {}, nil -- PlayerState.PlayerId -> that player's waypoint pin (3-4 players)
local function waypoint()
    for _, a in ipairs(FindAllOf("BP_WaypointActor_C") or {}) do
        if valid(a) and a:GetWorld():IsValid() and a:GetWorld():GetFullName() == UEHelpers.GetWorld():GetFullName() then return a end
    end
end
local function wpState(a)
    if not a then return "none" end
    local l = a:K2_GetActorLocation()
    return string.format("%.0f %.0f %.0f", l.X, l.Y, l.Z)
end
local function pinTexture()
    if valid(pinTex) then return pinTex end
    for _, t in ipairs(FindAllOf("Texture2D") or {}) do
        if valid(t) and t:GetFName():ToString() == "Map-Pin" then pinTex = t; return t end
    end
end
-- the partner's pin: a map icon like the game's own pin, in the partner's colour; nil when the map bounds actor is not there
local function showPartnerPin(id, x, y, z)
    local s, tex, h = carIcon(), pinTexture(), FindFirstOf("BP_GobblerMapBounds_C")
    if not (s and tex and valid(h)) then return false end
    local partnerPin = pins[id]
    if not valid(partnerPin) then
        partnerPin = h:AddComponentByClass(class(ICON), true, XF, false)
        proxyOf[partnerPin:GetFullName()] = true
        pins[id] = partnerPin
    end
    partnerPin:SetIconTexture(tex)
    partnerPin:ResetIconMaterialForUMG(); partnerPin:ResetIconMaterialForCanvas()
    partnerPin:K2_SetWorldLocationAndRotation({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, true)
    partnerPin:SetIconSize(s.IconSize, s.IconSizeUnit)
    partnerPin:SetIconZOrder(s.IconZOrder + 2)
    partnerPin:SetIconDrawColor(colourOf(safety.guest())) -- the partner of a guest is the host (shortcut: another guest's pin is blue too)
    partnerPin:SetIconVisible(true)
    return true
end
local function applyPartner(id, s)
    if s == "none" then
        if valid(pins[id]) then pins[id]:SetIconVisible(false) end
        return true
    end
    local x, y, z = s:match("^(%S+) (%S+) (%S+)$")
    if not z then return true end
    return showPartnerPin(id, tonumber(x), tonumber(y), tonumber(z))
end
net.share("g.map.wp", function(_, s, from)
    if not safety.active() then return end
    if os.getenv("PT_MUTATE") == "onemark" then wp.got, wp.sent = s, s end -- the old single marker: the partner's state is ours
    if os.getenv("PT_MUTATE") == "onemark" then
        local a = waypoint()
        if s == "none" then if a then a:K2_DestroyActor() end return end
        local x, y, z = s:match("^(%S+) (%S+) (%S+)$")
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        if a then a:K2_SetActorTransform(xf, false, {}, true)
        else
            local gs = UEHelpers.GetGameplayStatics()
            gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(UEHelpers.GetWorldContextObject(), class(WP), xf, 1, nil), xf)
        end
        return
    end
    wp.pending[from] = s
    if applyPartner(from, s) then wp.pending[from] = nil end
    log("PT|mapmark partner waypoint %s", s)
end)
local function waypointTick()
    if not safety.active() then wp.sent, wp.got, wp.pending = nil, nil, {}; return end
    for id, p in pairs(wp.pending) do if applyPartner(id, p) then wp.pending[id] = nil end end
    local own = waypoint()
    if own and valid(own.MapIcon) and os.getenv("PT_MUTATE") ~= "onemark" then own.MapIcon:SetIconDrawColor(colourOf(not safety.guest())) end
    local s = wpState(own)
    if s ~= wp.sent then -- a player who joins later gets it from the host (net.share keeps the last one)
        wp.sent = s
        if s ~= wp.got then net.send("g.map.wp", s); log("PT|mapmark waypoint sent %s", s) end
        wp.got = nil
    end
end
if os.getenv("PT_MUTATE") ~= "nowaypoint" then
    LoopInGameThreadWithDelay(500, function()
        local ok, err = pcall(waypointTick)
        if not ok then log("PT|error mapmark waypoint %s", tostring(err)) end
    end)
end

-- The guest's ARC map is the host's (live 2026-11-04). Its own game kept every junction open (Icon_Entrance/Exit/Closed on one
-- spot, the host shows one), its clumps spawned other buildings than the host's (runtime icon components, other names on each
-- side), and the gateway's icons stay off on a portal copy the host's game did not activate. So the host sends each visible icon
-- (texture, materials, place, size, color) and the guest hides all of its own and draws the host's on components of its own.
-- Players, the car and the waypoint (car texture, pin) stay each side's own. No GetOwner: an icon whose actor was gone crashed
-- the host in it (access violation, live 2026-11-04).
-- shortcut: no tooltips, layer offsets or per-layer rotation on the copies; send them if hover text or odd icons turn out to matter.
local SKIP = { ["Car_-_Key"] = true, ["Map-Pin"] = true }
local hostIcons, applied, sentIcons, sentAt, proxies, holder = nil, nil, nil, nil, {}, nil
local hid, missing = {}, {} -- guest: its own icons it turned off (full name -> component); asset paths that did not load
local DEFAULT_MAT = { ["/MinimapPlugin/Materials/Icons/M_UMG_MapIcon.M_UMG_MapIcon"] = true, ["/MinimapPlugin/Materials/Icons/M_Canvas_MapIcon.M_Canvas_MapIcon"] = true }
local function path(o) return valid(o) and (o:GetFullName():gsub("^%S+ ", "")) or "" end
local function mat(o) local p = path(o); return DEFAULT_MAT[p] and "" or p end -- the default (nearly every icon) is not sent
local function eachIcon(fn)
    for _, c in ipairs(FindAllOf("MapIconComponent") or {}) do
        if valid(c) and not proxyOf[c:GetFullName()] then
            local t = c.IconTexture
            if not SKIP[valid(t) and t:GetFName():ToString() or "?"] then fn(c) end
        end
    end
end
local function hostList()
    local L = {}
    eachIcon(function(c)
        -- an orphan in /Engine/Transient (its actor gone) sits at 0,0 and the host's map does not draw it: the guest drew it mid-map
        if c:IsIconVisible() and not c:GetFullName():find("/Engine/Transient", 1, true) then
            local l = c:K2_GetComponentLocation()
            local function add(tex, col, size, z)
                L[#L + 1] = table.concat({ path(tex), mat(c.IconMaterial_UMG), mat(c.IconMaterial_Canvas),
                    string.format("%.0f|%.0f|%.0f|%.0f|%d|%d|%.2f|%.2f|%.2f|%.2f|%s|%.0f|%d", l.X, l.Y, l.Z, size, c.IconSizeUnit,
                        z, col.R, col.G, col.B, col.A, tostring(c.bIconRotates), c:K2_GetComponentRotation().Yaw, c.IconFogInteraction) }, "|")
            end
            add(c.IconTexture, c.IconDrawColor, c.IconSize, c.IconZOrder)
            -- each layer draws over the base (a junction: grey square, black glyph at 0.67; a house: black, white glyph)
            for i = 0, c:GetIconLayerCount() - 1 do
                local t = c:GetIconTextureForLayer(i)
                if c:IsIconVisibleForLayer(i) and valid(t) then
                    add(t, c:GetIconDrawColorForLayer(i), c.IconSize * c:GetIconScaleForLayer(i).X, c.IconZOrder + i + 1)
                end
            end
        end
    end)
    table.sort(L)
    return table.concat(L, "\n")
end
local function asset(p)
    if p == "" or missing[p] then return nil end
    local o = StaticFindObject(p)
    if not o:IsValid() then pcall(LoadAsset, p); o = StaticFindObject(p) end
    if not o:IsValid() then missing[p] = true; return nil end -- a runtime material (/Engine/Transient): no retry per apply
    return o
end
local function proxy(i)
    if valid(proxies[i]) then return proxies[i] end
    if not valid(holder) then holder = FindFirstOf("BP_GobblerMapBounds_C") end -- lives as long as the map; none, no map to draw on
    if not valid(holder) then return nil end
    local c = holder:AddComponentByClass(class(ICON), true, XF, false) -- manual attachment: its transform is the world's
    proxies[i], proxyOf[c:GetFullName()] = c, true
    return c
end
local function applyIcons()
    local i = 0
    for line in (hostIcons .. "\n"):gmatch("(.-)\n") do
        local f = {}
        for x in (line .. "|"):gmatch("(.-)|") do f[#f + 1] = x end
        if #f >= 16 then
            local c = proxy(i + 1)
            if not c then return false end
            i = i + 1
            local tex, mu, mc = asset(f[1]), asset(f[2]), asset(f[3])
            if tex then c:SetIconTexture(tex) end
            if mu then c:SetIconMaterialForUMG(mu) else c:ResetIconMaterialForUMG() end
            if mc then c:SetIconMaterialForCanvas(mc) else c:ResetIconMaterialForCanvas() end
            c:K2_SetWorldLocationAndRotation({ X = tonumber(f[4]), Y = tonumber(f[5]), Z = tonumber(f[6]) }, { Pitch = 0, Yaw = tonumber(f[15]), Roll = 0 }, false, {}, true)
            c:SetIconSize(tonumber(f[7]), tonumber(f[8]))
            c:SetIconZOrder(tonumber(f[9]))
            c:SetIconDrawColor({ R = tonumber(f[10]), G = tonumber(f[11]), B = tonumber(f[12]), A = tonumber(f[13]) })
            c:SetIconRotates(f[14] == "true")
            c:SetIconFogInteraction(tonumber(f[16]))
            c:SetIconVisible(true)
        end
    end
    for j = i + 1, #proxies do if valid(proxies[j]) then proxies[j]:SetIconVisible(false) end end
    log("PT|mapmark guest map draws %d host icons", i)
    return true
end
-- the session ended with the guest still in the map: its own icons back, the host's copies off
local function restoreIcons()
    for _, c in pairs(hid) do if valid(c) then c:SetIconVisible(true) end end
    for _, c in ipairs(proxies) do if valid(c) then c:SetIconVisible(false) end end
    hid = {}
end
local function iconTick()
    if not safety.active() then
        if next(hid) then restoreIcons() end
        hostIcons, applied, sentIcons = nil, nil, nil
        return
    end
    if not safety.guest() then
        local msg = hostList()
        -- again every 10 s: one sent before the guest was ready is gone (seen: none arrived after a join)
        if msg ~= sentIcons or os.clock() - (sentAt or 0) >= 10 then sentIcons, sentAt = msg, os.clock(); net.toGuests("g.map.icons", msg) end
        return
    end
    if not hostIcons then return end
    eachIcon(function(c) if c:IsIconVisible() then c:SetIconVisible(false); hid[c:GetFullName()] = c end end)
    if hostIcons ~= applied and applyIcons() then applied = hostIcons end
end
net.on("g.map.icons", function(_, msg) if safety.guest() then hostIcons = msg end end)
if os.getenv("PT_MUTATE") ~= "noicons" then
    LoopInGameThreadWithDelay(2000, function()
        local ok, err = pcall(iconTick)
        if not ok then log("PT|error mapmark icons %s", tostring(err)) end
    end)
end

-- a map change frees every object we hold: forget them before it happens
RegisterLoadMapPreHook(function() marks, captureSeen, captureDone = {}, nil, 0; wp.sent, wp.got, wp.pending, pins = nil, nil, {}, {}; hostIcons, applied, sentIcons, proxies, holder, hid = nil, nil, nil, {}, nil, {}; proxyOf = {} end)

LoopInGameThreadWithDelay(250, function()
    local ok, err = pcall(update)
    if not ok then log("PT|error mapmark %s", tostring(err)) end
end)
LoopInGameThreadWithDelay(1000, function()
    if not safety.guest() or captureDone >= #RECAPTURE then return end
    local ok, err = pcall(function()
        local b = FindFirstOf("BP_GobblerMapBounds_C")
        if not (b and b:IsValid()) then return end
        captureSeen = captureSeen or os.clock()
        if os.clock() - captureSeen >= RECAPTURE[captureDone + 1] then
            captureDone = captureDone + 1
            b:RecaptureMinimap()
            log("PT|mapmark guest map recaptured n=%d", captureDone)
        end
    end)
    if not ok then log("PT|error mapmark recapture %s", tostring(err)) end
end)

return M
