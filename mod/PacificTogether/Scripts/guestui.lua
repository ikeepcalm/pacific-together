-- Guest-side immersion (pt3-ui, owner's Steam playtest 2026-10-23): everything here is inert on the host and in single player.
--   pause menu   the guest's Esc did nothing: the game opens its pause menu only when UGameplayStatics::SetGamePaused succeeds,
--                and a client's SetGamePaused is always false. After "Set Pause Menu Opened" the guest shows/hides the menu widget
--                itself; the world is not paused (a guest cannot pause the host's world).
--   loading      "Joining host...", "Loading...", "Waiting for host..." in the screen centre until the guest can move
--   fade         a short fade to black and back when the guest is seated or leaves its seat
--   unstick      the End key does what F8 does (laptop keyboards need Fn for F8); the console command "ptunstick" too
local UEHelpers = require("UEHelpers")
local common = require("common")
local log = common.log

local M = {}
if os.getenv("PT_MUTATE") == "noguestui" then return M end

local MENU, Z = "RB_MainMenu", 10002
local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function guest() return common.netMode() == "client" end

-- pause menu ----------------------------------------------------------------------------------------------------------------
-- the Blueprint class is not loaded when the mod starts: hooked from the loop below once it is
local pauseHooked = false
local function hookPause()
    local ok = pcall(RegisterHook, "/Game/Systems/Managers/BP_UIManager.BP_UIManager_C:Set Pause Menu Opened", function(_, opened)
        if not guest() then return end
        local o = opened:get()
        local hud = UEHelpers.GetPlayerController():GetHUD()
        if not valid(hud) then return end
        local okc, e = pcall(function() hud:SetPauseMenuWidgetVisible(o) end)
        log("PT|guestui pause menu opened=%s ok=%s", tostring(o), tostring(okc))
    end)
    pauseHooked = ok
end

-- widget --------------------------------------------------------------------------------------------------------------------
local ui, loading = nil, nil -- { widget, msg, cache }

local function text(tree, name, size)
    local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree, FName(name))
    t:SetJustification(1) -- centre
    t:SetShadowOffset({ X = 1, Y = 1 })
    t:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.55 })
    local f = t.Font
    f.Size = size
    local fo = require("overlay").fontOf and require("overlay").fontOf("body") -- the game's HUD font
    if fo then f.FontObject = fo end
    t:SetFont(f)
    local c = require("overlay").CREAM or { R = 0.883, G = 0.915, B = 0.646 } -- the HUD's cream
    t:SetColorAndOpacity({ SpecifiedColor = { R = c.R, G = c.G, B = c.B, A = 1 }, ColorUseRule = 0 })
    t:SetVisibility(1)
    return t
end

local function build()
    local pc = UEHelpers.GetPlayerController()
    if not valid(pc) then return end
    local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, StaticFindObject("/Script/UMG.UserWidget"), pc)
    if not valid(w) or not valid(w.WidgetTree) then return end
    local tree = w.WidgetTree
    local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), tree, FName("PTGuestUiRoot"))
    tree.RootWidget = canvas
    local n = { widget = w, cache = {} }
    local function put(t, y, x)
        x = x or 0.5
        local slot = canvas:AddChildToCanvas(t)
        slot:SetAnchors({ Minimum = { X = x, Y = y }, Maximum = { X = x, Y = y } })
        slot:SetAlignment({ X = 0.5, Y = 0.5 })
        slot:SetPosition({ X = 0, Y = 0 })
        slot:SetAutoSize(true)
    end
    n.msg = text(tree, "PTGuestUiMsg", 30); put(n.msg, 0.45)
    canvas:SetVisibility(3); w:SetVisibility(3)
    w:AddToViewport(Z)
    return n
end

local function show(t, key, s)
    if ui.cache[key] == s then return end
    ui.cache[key] = s
    t:SetText(FText(s))
    t:SetVisibility(s == "" and 1 or 3)
end

-- a map change frees the widget with its world (overlay.lua: a call on the dead handle crashed the game)
RegisterLoadMapPreHook(function()
    pcall(function() if ui then ui.widget:RemoveFromParent() end end)
    ui, loading = nil, os.clock()
end)
local loadedAt = os.clock()
RegisterLoadMapPostHook(function() loading, loadedAt = nil, os.clock() end)

-- state ---------------------------------------------------------------------------------------------------------------------
local function seated(me)
    local p = me:GetAttachParentActor()
    return valid(p) and p:GetClass():GetFName():ToString() == "BP_PlayerCarNew_C"
end

local wasSeated, stillSince = nil, nil
local function message(pc, me, mapName, isSeated)
    if mapName == MENU then return "Joining host\226\128\166" end
    local char = valid(me) and me:IsA(StaticFindObject("/Script/PenDriverPro.BaseCharacter"))
    if not char then return os.clock() - loadedAt < 5 and "Loading\226\128\166" or "Waiting for host\226\128\166" end
    if isSeated then stillSince = nil; return "" end
    -- on the ground but frozen (MOVE_None) for 3 s: the host has not placed us yet
    -- only right after a load: later a frozen guest is usually at a station or in a game interaction, not waiting for the host
    local frozen = os.clock() - loadedAt < 90 and me.CharacterMovement.MovementMode == 0
    if not frozen then stillSince = nil; return "" end
    stillSince = stillSince or os.clock()
    return os.clock() - stillSince > 3 and "Waiting for host\226\128\166" or ""
end

local function fade(pc)
    local cm = pc.PlayerCameraManager
    if not valid(cm) then return end
    local black = { R = 0, G = 0, B = 0, A = 1 }
    cm:StartCameraFade(0, 1, 0.12, black, false, true)
    common.defer(200, function()
        -- the camera manager now, not the one faded: a repossess or travel in between replaces it (left black otherwise)
        pcall(function()
            local now = UEHelpers.GetPlayerController().PlayerCameraManager
            if valid(now) then now:StartCameraFade(1, 0, 0.5, black, false, false) end
            if valid(cm) and not (valid(now) and now:GetAddress() == cm:GetAddress()) then cm:StopCameraFade() end
        end)
    end)
    log("PT|guestui fade")
end

local function update()
    if not pauseHooked then hookPause() end
    if loading and os.clock() - loading < 30 then return end
    if not guest() then
        if ui then pcall(function() ui.widget:RemoveFromParent() end); ui = nil end
        wasSeated = nil
        return
    end
    if ui == nil or not valid(ui.widget) or not ui.widget:IsInViewport() then
        ui = build()
        if not ui then return end
    end
    local pc = UEHelpers.GetPlayerController()
    local world = UEHelpers.GetWorld()
    if not valid(pc) or not valid(world) then return end
    local mapName = UEHelpers.GetGameplayStatics():GetCurrentLevelName(world, true):ToString()
    local me = pc.Pawn
    local isSeated = valid(me) and seated(me) or false
    show(ui.msg, "msg", message(pc, me, mapName, isSeated))
    -- no seat hint (owner 2026-11-04): the dashboard has the game's own outlines and the passenger door is the way out
    if wasSeated ~= nil and wasSeated ~= isSeated and mapName ~= MENU then fade(pc) end
    wasSeated = isSeated
end

LoopInGameThreadWithDelay(100, function()
    local okU, e = pcall(update)
    if not okU then log("PT|error guestui %s", tostring(e)) end
end)

-- unstick -------------------------------------------------------------------------------------------------------------------
local function unstick()
    local car = package.loaded["car"]
    if guest() and car and car.unstick then car.unstick() end
end
common.onKey("End", unstick)
pcall(RegisterConsoleCommandHandler, "ptunstick", function() unstick() return true end)

return M
