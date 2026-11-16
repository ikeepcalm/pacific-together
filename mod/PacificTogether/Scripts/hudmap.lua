-- HUD map (owner request 2026-11-15): the ARC screen sits between the front seats, behind a passenger, so while the local player
-- is seated in the car in an expedition zone its map is mirrored into the bottom-right corner: the screen's widget render target
-- drawn by a runtime UMG Image (view only, HitTestInvisible), small dark frame, behind the mod's other UI. Session only (Q7).
-- Mutation nohudmap: off.
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local log = common.log

local M = {}
if os.getenv("PT_MUTATE") == "nohudmap" then return M end

local Z, FRACTION, MARGIN = 5000, 0.22, 18 -- z-order (overlay 10000, guestui 10002), share of the screen height, px from the edges
local ui, loading, ticked = nil, os.clock(), nil
local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end

local function build()
    local pc = UEHelpers.GetPlayerController()
    if not valid(pc) then return end
    local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(pc, StaticFindObject("/Script/UMG.UserWidget"), pc)
    if not valid(w) or not valid(w.WidgetTree) then return end
    local tree = w.WidgetTree
    local canvas = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), tree, FName("PTHudMapRoot"))
    tree.RootWidget = canvas
    local frame = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), tree, FName("PTHudMapFrame"))
    frame:SetBrushColor({ R = 0.012, G = 0.012, B = 0.01, A = 0.9 })
    frame:SetPadding({ Left = 3, Top = 3, Right = 3, Bottom = 3 })
    -- the screen's widget is much bigger than its map (map top left, legend and text around it): a clipped box shows the map part
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), tree, FName("PTHudMapBox"))
    local inner = StaticConstructObject(StaticFindObject("/Script/UMG.CanvasPanel"), tree, FName("PTHudMapClip"))
    local img = StaticConstructObject(StaticFindObject("/Script/UMG.Image"), tree, FName("PTHudMapImage"))
    inner:SetClipping(1) -- ClipToBounds
    frame:SetContent(box); box:SetContent(inner)
    local islot = inner:AddChildToCanvas(img)
    islot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    islot:SetPosition({ X = 0, Y = 0 })
    islot:SetAutoSize(false)
    local slot = canvas:AddChildToCanvas(frame)
    slot:SetAnchors({ Minimum = { X = 1, Y = 1 }, Maximum = { X = 1, Y = 1 } })
    slot:SetAlignment({ X = 1, Y = 1 })
    slot:SetPosition({ X = -MARGIN, Y = -MARGIN })
    slot:SetAutoSize(true)
    canvas:SetVisibility(1); frame:SetVisibility(3); box:SetVisibility(3); inner:SetVisibility(3); img:SetVisibility(3); w:SetVisibility(3) -- canvas hidden until seated
    w:AddToViewport(Z)
    return { widget = w, canvas = canvas, img = img, box = box, islot = islot, shown = false, key = nil }
end

local function screen()
    local wn = UEHelpers.GetWorld():GetFullName()
    for _, s in ipairs(FindAllOf("BP_Carpart_Internal_GobblerScreen_C") or {}) do
        if valid(s) and s:GetWorld():GetFullName() == wn then return s end
    end
end

-- in the car: the guest's pawn rides attached to it; the host is in it while the car manager's PlayerCarState is not 0
local function seated(pawn)
    local p = pawn:GetAttachParentActor()
    if valid(p) and p:GetClass():GetFName():ToString() == "BP_PlayerCarNew_C" then return true end
    local cm = FindFirstOf("BP_CarManager_C")
    return valid(cm) and cm.PlayerCarState ~= 0
end

local function want()
    if loading and os.clock() - loading < 15 or not safety.active() then return nil end
    local pc = UEHelpers.GetPlayerController()
    local world = UEHelpers.GetWorld()
    if not (valid(pc) and valid(world) and valid(pc.Pawn)) then return nil end
    if UEHelpers.GetGameplayStatics():IsGamePaused(world) then return nil end
    local map = UEHelpers.GetGameplayStatics():GetCurrentLevelName(world, true):ToString()
    if map == "RB_MainMenu" or map:find("Garage", 1, true) then return nil end
    if not seated(pc.Pawn) then return nil end
    local s = screen()
    if not valid(s) then return nil end
    local w = s.BP_InteractCameraComponent
    if not valid(w) then return nil end
    -- BP_InteractCameraComponent (not a WidgetComponent) redraws its widget only while the screen was rendered recently (tick mode 1);
    -- mode 2 draws every Frame Interval frames anyway, so the mirror keeps moving with the screen behind a seat
    if not ticked then ticked = { w, w["Widget Tick Mode"], w["Frame Interval"] }; w["Widget Tick Mode"] = 2; w["Frame Interval"] = 3 end
    local rt = w:GetWidgetRenderTarget()
    return valid(rt) and rt or nil
end

local function restoreTick()
    if ticked and valid(ticked[1]) then ticked[1]["Widget Tick Mode"], ticked[1]["Frame Interval"] = ticked[2], ticked[3] end
    ticked = nil
end

local function update()
    local rt = want()
    if not rt then restoreTick() end
    if not rt then
        if ui and ui.shown then
            if valid(ui.widget) then ui.canvas:SetVisibility(1) end
            ui.shown = false
        end
        return
    end
    if ui == nil or not valid(ui.widget) or not ui.widget:IsInViewport() then
        ui = build()
        if not ui then return end
    end
    local lib, wd = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"), UEHelpers.GetWorld()
    local vp, scale = lib:GetViewportSize(wd), lib:GetViewportScale(wd) -- slate units are pixels / the DPI scale
    local h = math.floor(vp.Y * FRACTION / scale)
    local sc = FindFirstOf("UMG_GobblerScreen_C")
    local ms = valid(sc) and valid(sc.Minimap) and sc.Minimap.InitialMapSize or { X = 0, Y = 0 } -- the map's part of the widget, 0 before its first tick
    local mw, mh = ms.X > 0 and ms.X or rt.SizeX, ms.Y > 0 and ms.Y or rt.SizeY
    local key = rt:GetFullName() .. h .. "/" .. mw .. "/" .. mh
    if ui.key ~= key then
        ui.key = key
        local w = math.floor(h * mw / mh)
        ui.img:SetBrushResourceObject(rt)
        ui.box:SetWidthOverride(w); ui.box:SetHeightOverride(h)
        ui.islot:SetSize({ X = w * rt.SizeX / mw, Y = h * rt.SizeY / mh })
    end
    if not ui.shown then ui.canvas:SetVisibility(3); ui.shown = true; log("PT|hudmap shown") end
end

-- a map change frees the widget with its world (overlay.lua: a call on the dead handle crashed the game)
RegisterLoadMapPreHook(function()
    pcall(function() if ui then ui.widget:RemoveFromParent() end end)
    ui, loading, ticked = nil, os.clock(), nil
end)

LoopInGameThreadWithDelay(250, function()
    local ok, err = pcall(update)
    if not ok then log("PT|error hudmap %s", tostring(err)) end
end)

return M
