-- In-game overlay (M6): bottom right (the top right holds the quest list), a version label plus a session status line, and under it a short feed of what the mod
-- syncs ("<name> entered the car", "2 items taken from the trunk x3"). A UMG widget built from Lua (UserWidget ->
-- CanvasPanel -> VerticalBox -> TextBlocks), never hit-testable. The label shows from the main menu on, also in single
-- player; the feed only takes messages during a session. overlay.post(text, kind, key): kind picks the colour
-- ("info" default, "warn", "good"); lines with the same key that are still visible merge into one with a count.
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local log = common.log

local M = {}
if os.getenv("PT_MUTATE") == "nooverlay" then
    function M.post() end
    function M.other() return "Player" end
    function M.settled() return false end
    function M.hostPaused() end
    function M.transition() end
    function M.panel() end
    return M
end

local LINES, LIFE, SETTLE = 5, 6, 6 -- visible lines, seconds a line lives, seconds into a session before loot-style chatter is allowed
local Z = 10000
local COLOR = { -- linear RGB: off-white text, a teal accent for the status, muted warn and good
    label = { R = 0.78, G = 0.78, B = 0.74 }, status = { R = 0.25, G = 0.8, B = 0.72 }, card = { R = 0.86, G = 0.84, B = 0.7 },
    info = { R = 0.78, G = 0.78, B = 0.74 }, warn = { R = 0.9, G = 0.45, B = 0.3 }, good = { R = 0.3, G = 0.75, B = 0.5 },
}

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end

-- a hot reload leaves the old widget in the viewport: take it out
for _, b in ipairs(FindAllOf("VerticalBox") or {}) do
    if b:IsValid() and b:GetFName():ToString() == "PTOverlayBox" then
        pcall(function() b:GetOuter():GetOuter():RemoveFromParent() end)
    end
end

local ui = nil -- { widget, label, status, lines = { TextBlock... }, cache = {} }
local feed = {} -- { text, kind, key, n, t0 }
local sessionSince, names, seen = nil, {}, {} -- session age; remote player names now / ever (host side)
local wasConnected, hostName, greeted = false, nil, false

-- the game's own HUD fonts (owner request 2026-10-31: the mod's text looked foreign; MediaBridgeRadio's cards use them)
local FONTS = { title = "/Game/UI/Fonts/Font_Headset_Title.Font_Headset_Title", body = "/Game/UI/Fonts/Font_Headset_Default.Font_Headset_Default",
    small = "/Game/UI/Fonts/Font_Headset_Details.Font_Headset_Details" }
local fontObjs = {}
local function fontOf(which)
    local p = FONTS[which or "body"]
    local o = fontObjs[p]
    if valid(o) then return o end
    o = StaticFindObject(p)
    if not valid(o) then pcall(LoadAsset, p); o = StaticFindObject(p) end
    fontObjs[p] = valid(o) and o or nil
    return fontObjs[p]
end
M.fontOf = fontOf

local function text(tree, name, size, kind, which, spacing, justify)
    local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree, FName(name))
    t:SetJustification(justify or 2) -- right
    t:SetShadowOffset({ X = 1.5, Y = 1.5 })
    t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 1 })
    local f = t.Font
    f.Size = size
    local fo = fontOf(which)
    if fo then f.FontObject = fo end
    if spacing then f.LetterSpacing = spacing end
    t:SetFont(f)
    t:SetColorAndOpacity({ SpecifiedColor = { R = COLOR[kind].R, G = COLOR[kind].G, B = COLOR[kind].B, A = 1 }, ColorUseRule = 0 })
    return t
end

local function build()
    local pc = UEHelpers.GetPlayerController()
    if not valid(pc) then return end
    local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, StaticFindObject("/Script/UMG.UserWidget"), pc)
    if not valid(w) or not valid(w.WidgetTree) then return end
    local tree = w.WidgetTree
    local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), tree, FName("PTOverlayRoot"))
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.VerticalBox"), tree, FName("PTOverlayBox"))
    tree.RootWidget = canvas
    local slot = canvas:AddChildToCanvas(box)
    -- bottom right, above the game's own key hints there (the top right holds the quest list)
    slot:SetAnchors({ Minimum = { X = 1, Y = 1 }, Maximum = { X = 1, Y = 1 } })
    slot:SetAlignment({ X = 1, Y = 1 })
    slot:SetPosition({ X = -18, Y = -240 }) -- playtest: -90 still overlapped the HUD there
    slot:SetAutoSize(true)
    local n = { widget = w, cache = {}, lines = {} }
    local function add(t) box:AddChildToVerticalBox(t):SetHorizontalAlignment(3) end -- right
    n.label = text(tree, "PTVersion", 18, "label"); add(n.label)
    n.status = text(tree, "PTStatus", 16, "status"); add(n.status)
    n.arc = text(tree, "PTArc", 16, "status"); n.arc:SetVisibility(1); add(n.arc) -- "ARC 3.0 / 7.0": the device sits behind the seats in co-op (D12)
    -- rescue.lua's menu: a card on the left like the game's own (cream frame, dark panel, spaced caps kicker, big title)
    local B = StaticFindObject("/Script/UMG.Border")
    local frame = StaticConstructObject(B, tree, FName("PTCardFrame"))
    local inner = StaticConstructObject(B, tree, FName("PTCardInner"))
    frame:SetBrushColor({ R = COLOR.card.R, G = COLOR.card.G, B = COLOR.card.B, A = 0.8 })
    frame:SetPadding({ Left = 2, Top = 2, Right = 2, Bottom = 2 })
    inner:SetBrushColor({ R = 0.012, G = 0.012, B = 0.01, A = 0.88 })
    inner:SetPadding({ Left = 26, Top = 18, Right = 30, Bottom = 22 })
    local col = StaticConstructObject(StaticFindObject("/Script/UMG.VerticalBox"), tree, FName("PTCardBox"))
    frame:SetContent(inner); inner:SetContent(col)
    n.kicker = text(tree, "PTCardKicker", 13, "card", "small", 600, 0); col:AddChildToVerticalBox(n.kicker)
    n.kicker:SetText(FText("PACIFIC TOGETHER " .. common.MOD_VERSION))
    n.title = text(tree, "PTCardTitle", 44, "card", "title", 60, 0)
    col:AddChildToVerticalBox(n.title):SetPadding({ Left = 0, Top = 6, Right = 0, Bottom = 8 })
    n.panel = text(tree, "PTPanel", 18, "card", "body", nil, 0); col:AddChildToVerticalBox(n.panel)
    local cs = canvas:AddChildToCanvas(frame)
    cs:SetAnchors({ Minimum = { X = 0, Y = 0.3 }, Maximum = { X = 0, Y = 0.3 } })
    cs:SetAlignment({ X = 0, Y = 0 })
    cs:SetPosition({ X = 42, Y = 0 })
    cs:SetAutoSize(true)
    frame:SetVisibility(1)
    n.card = frame
    for i = 1, LINES do
        n.lines[i] = text(tree, "PTFeed" .. i, 16, "info")
        n.lines[i]:SetVisibility(1)
        add(n.lines[i])
    end
    n.banner = text(tree, "PTBanner", 30, "warn"); n.banner:SetVisibility(1); add(n.banner) -- last child: "Paused by host"
    n.label:SetText(FText("Pacific Together " .. common.MOD_VERSION))
    -- nothing of it takes input or hit tests: the whole tree is HitTestInvisible
    box:SetVisibility(3); canvas:SetVisibility(3); w:SetVisibility(3)
    w:AddToViewport(Z)
    return n
end

local pausedAt, transitionOn = nil, false -- when the host last said it is paused (see M.hostPaused); a map transition hides the banner
local function set(t, key, value) -- only touch the widget when something changed
    if ui.cache[key] ~= value then ui.cache[key] = value; t:SetText(FText(value)) end
end

-- "%d" in the text is the running count of a coalesced burst, "{s}" its plural; without "%d" a repeat shows as "x3"
local function label(l)
    local t = l.fmt:gsub("{s}", l.n == 1 and "" or "s")
    local c, hit = t:gsub("%%d", tostring(l.n))
    if hit > 0 then return c end
    return l.n > 1 and (t .. "  x" .. l.n) or t
end

-- rescue.lua's menu, a few lines above the feed; nil hides it
local panelText
function M.panel(t) panelText = t end

local function render()
    local now = os.clock()
    local pnv = panelText and 3 or 1
    if ui.cache.pnv ~= pnv then ui.cache.pnv = pnv; ui.card:SetVisibility(pnv) end
    if panelText then
        -- first line the title (caps, the game's card style), the rest the body
        local head, body = panelText:match("^([^\n]*)\n?(.*)$")
        set(ui.title, "title", head:upper())
        set(ui.panel, "panel", body)
    end
    local pv = (pausedAt and now - pausedAt < 3 and not transitionOn) and 3 or 1
    if ui.cache.pv ~= pv then
        ui.cache.pv = pv
        ui.banner:SetVisibility(pv)
        if pv == 3 then ui.banner:SetText(FText("Paused by host")) end
    end
    for i = #feed, 1, -1 do if now - feed[i].t0 > LIFE then table.remove(feed, i) end end
    for i, t in ipairs(ui.lines) do
        local l = feed[math.max(1, #feed - LINES + 1) + i - 1] -- newest at the bottom, the last LINES shown
        local vis = l and 3 or 1
        if ui.cache["v" .. i] ~= vis then ui.cache["v" .. i] = vis; t:SetVisibility(vis) end
        if l then
            set(t, "t" .. i, label(l))
            if ui.cache["k" .. i] ~= l.kind then
                ui.cache["k" .. i] = l.kind
                local c = COLOR[l.kind] or COLOR.info
                t:SetColorAndOpacity({ SpecifiedColor = { R = c.R, G = c.G, B = c.B, A = 1 }, ColorUseRule = 0 })
            end
            -- no fade: the per-tick SetRenderOpacity crashed the host right after a guest joined (playtest 2026-10-21,
            -- AV in PenDriverPro+0x3160a56 reading 0x178, the same crash as the hands-on bot's)
        end
    end
end

-- feed ------------------------------------------------------------------------------------------------------------

local function push(fmt, kind, key, n)
    local now = os.clock()
    for _, l in ipairs(feed) do
        if now - l.t0 <= LIFE and ((key and l.key == key) or (not key and l.fmt == fmt and now - l.t0 < 3)) then
            if key then l.n = l.n + (n or 1); l.fmt = fmt end
            l.t0 = now
            return
        end
    end
    feed[#feed + 1] = { fmt = fmt, kind = kind or "info", key = key, n = n or 1, t0 = now }
    if #feed > LINES * 2 then table.remove(feed, 1) end
end

-- messages only during a session: post("Rex took %d item{s} from the trunk", "info", "loot.trunk", 2)
-- Quiet feed (owner request 2026-10-30): the game never narrates, so the feed keeps only what a player cannot see and needs
-- (the partner's loading, their own backpack and items, a resync); the rest (entered the car, picked up, repaired, anomaly hits,
-- objectives the game's own HUD shows) goes to the log. Session lines (joined, left, connection) are pushed directly and stay.
-- Mutation loudfeed: everything shows.
local KEEP = { "to load", "did not load", "death crate", "Backpack", "were lost", "resynced", "Controls reset", "Host is " }
local LOUD = os.getenv("PT_MUTATE") == "loudfeed"
function M.post(fmt, kind, key, n)
    if not safety.active() then return end
    if not LOUD then
        local keep = false
        for _, k in ipairs(KEEP) do if fmt:find(k, 1, true) then keep = true break end end
        if not keep then log("PT|feed (quiet) %s", fmt); return end
    end
    push(fmt, kind, key, n)
end

-- the host's world is paused (Esc menu): pause.lua tells us every second; the label lapses 3 s after the last word
function M.hostPaused(on) pausedAt = on and os.clock() or nil end
-- transition.lua: the guest is on the host's loading screen or faded out (the host's world is paused while it spawns: no banner)
function M.transition(on) transitionOn = on end

-- the other player's name as this side knows it
function M.other() return hostName or next(names) or "Player" end

-- false until a few seconds into a session: the first full state sync is not news
function M.settled() return sessionSince ~= nil and os.clock() - sessionSince > SETTLE end

function M.state() -- for tests: what the widget should hold
    return { label = "Pacific Together " .. common.MOD_VERSION, status = ui and ui.cache.status or "", lines = #feed }
end

-- status ----------------------------------------------------------------------------------------------------------

local function playerStates(w)
    local out = {}
    local gs = w.GameState
    if valid(gs) then
        local a = gs.PlayerArray
        for i = 1, #a do if valid(a[i]) then out[#out + 1] = a[i] end end
    end
    return out
end

local function realName(ps)
    local n = ps:GetPlayerName():ToString()
    return not n:find("PT|", 1, true) and n ~= "" and n or nil
end

-- ARC energy, in run maps during a session: the guest's values are the host's (guestact.lua g.act.arc)
local function arcText()
    local screen = common.first("BP_Carpart_Internal_GobblerScreen_C")
    if not screen then return "" end
    local c, m = {}, {}
    screen:GetAnchorCharge(c, m)
    return string.format("ARC %.1f / %.1f", c.CurrentCharge, m.MaxCharge)
end
local function arc(show)
    local ok, str = pcall(arcText)
    str = (show and ok) and str or ""
    set(ui.arc, "arc", str)
    local v = str == "" and 1 or 3
    if ui.cache.av ~= v then ui.cache.av = v; ui.arc:SetVisibility(v) end
end
local function status()
    local mode = common.netMode()
    local w = UEHelpers.GetWorld()
    local s = package.loaded["session"]
    local join = s and s.join
    local connected, str = false, ""
    if mode == "listen" and valid(w) then
        local cur, kept, ping = {}, {}, 0
        for _, ps in ipairs(playerStates(w)) do
            local pc = ps:GetOwner()
            if valid(pc) and not pc:IsLocalController() then
                local n = realName(ps)
                if n then
                    cur[n] = true; ping = math.max(ping, ps.Ping * 4)
                    -- announced once its character exists: the PlayerState shows up while the guest still loads the map, and the line expired unseen
                    if names[n] or valid(pc.Pawn) then kept[n] = true end
                end
            end
        end
        local count = 0
        for n in pairs(cur) do count = count + 1 end
        for n in pairs(kept) do
            if not names[n] then
                push(n .. (seen[n] and " rejoined" or " joined"), "good")
                seen[n] = true
            end
        end
        for n in pairs(names) do if not cur[n] then push(n .. " left", "warn") end end
        names = kept
        if count > 0 then connected, str = true, string.format("Host \194\183 %d guest%s \194\183 %d ms", count, count == 1 and "" or "s", ping) end
    elseif mode == "client" or (join and s.wanted()) then
        local mine = valid(w) and UEHelpers.GetPlayerController()
        local host
        if mode == "client" and valid(w) and valid(mine) and valid(mine.PlayerState) then
            for _, ps in ipairs(playerStates(w)) do
                if ps:GetFullName() ~= mine.PlayerState:GetFullName() and realName(ps) then host = ps end
            end
            if host then
                hostName = realName(host)
                connected, str = true, string.format("Guest \194\183 %s \194\183 %d ms", hostName, mine.PlayerState.Ping * 4)
            end
        end
        if not connected then str = "Joining " .. tostring(join or "the host") .. "\226\128\166" end
        -- once this side has a character: during the map load the line expired unseen
        if connected and not greeted and valid(mine.Pawn) then push("Connected to " .. hostName, "good"); greeted = true end
        if not connected then greeted = false end
        if not connected and wasConnected then push("Connection lost, rejoining", "warn") end
    end
    if connected then sessionSince = sessionSince or os.clock() else sessionSince, hostName = nil, nil end
    wasConnected = connected
    set(ui.status, "status", str)
    local v = str == "" and 1 or 3
    if ui.cache.sv ~= v then ui.cache.sv = v; ui.status:SetVisibility(v) end
    arc(connected and valid(w) and not UEHelpers.GetGameplayStatics():GetCurrentLevelName(w, true):ToString():find("Garage", 1, true))
end

-- A map change frees the widget with its world, and a call on the dead handle crashed the game (AV in a guest's zone load):
-- let go of it before the load and build a fresh one once the new world is up.
local tick, loading = 0, nil
RegisterLoadMapPreHook(function()
    pcall(function() if ui then ui.widget:RemoveFromParent() end end)
    ui, loading = nil, os.clock()
end)
RegisterLoadMapPostHook(function() loading = nil end)

local function update()
    if loading and os.clock() - loading < 30 then return end
    if ui == nil or not valid(ui.widget) or not ui.widget:IsInViewport() then
        ui = build()
        log("PT|overlay built=%s", tostring(ui ~= nil))
        if not ui then return end
        tick = 0
    end
    tick = tick + 1
    if tick % 5 == 1 then status() end
    render()
end

LoopInGameThreadWithDelay(100, function()
    local ok, err = pcall(update)
    if not ok then log("PT|error overlay %s", tostring(err)) end
end)

return M
