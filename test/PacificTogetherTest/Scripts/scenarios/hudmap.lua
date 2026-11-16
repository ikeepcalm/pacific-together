-- HUD map (owner request 2026-11-15, hudmap.lua): while a player sits in the car in a zone, the ARC screen's map shows in the
-- bottom-right corner (a runtime Image whose brush is the screen's widget render target); hidden on foot.
-- The host sits in its car in the coop-zone save, the guest enters through the passenger door. Read from the outside, through the
-- UMG widgets the mod builds (PTHudMapRoot / PTHudMapImage). Checks per side: shown with a valid render target brush, about 22% of
-- the screen height, and hidden again once the player left the car (host exit_car, guest g.car.exit).
-- Then the partner's pin (docs: NOTES 2026-11-15 item 10): each side places an ARC waypoint, the other side's ARC Minimap widget
-- (UMG_GobblerScreen_C.Minimap) must list an icon widget for the partner pin (checks *_minimap_pin).
-- Run: tools/run-test.ps1 -Scenario hudmap -Fixture coop-zone -Headless    Mutation: nohudmap (module off: every HUD check fails)
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind] ~= nil
    end
    local function sendGuest(kind, data) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), kind, data or "") end
    local function sendHost(kind, data) PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end
    local function theCar()
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
            local l = c:IsValid() and c:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and (T.ROLE == "host" or c.Role ~= 3) then return c end
        end
    end
    local function attached(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end
    local fixture = (os.getenv("PT_FIXTURE") or ""):match("[^,]+") or "coop-zone"

    -- what the mod's HUD map shows now: nil when it was never built
    local function hud()
        for _, i in ipairs(FindAllOf("Image") or {}) do
            if i:IsValid() and i:GetFName():ToString() == "PTHudMapImage" then
                local w = i:GetOuter():GetOuter()
                if w:IsValid() and w:IsInViewport() then
                    local root = i:GetOuter():GetOuter().WidgetTree.RootWidget
                    local b = i.Brush
                    local ro = b.ResourceObject
                    local box = i:GetParent():GetParent() -- Image > clip canvas > SizeBox (the map's frame)
                    return { visible = root:GetVisibility() == 3, rt = ro:IsValid() and ro:GetFullName() or "", h = box.HeightOverride, w = box.WidthOverride }
                end
            end
        end
    end
    local function hudShown(id)
        return { check = id, timeout = 60, cond = function()
            local h = hud()
            local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
            local vp, sc = lib:GetViewportSize(T.world()), lib:GetViewportScale(T.world())
            log("PT|info %s: hud=%s", id, h and string.format("visible=%s rt=%s %dx%d vp=%dx%d", tostring(h.visible), h.rt:match("TextureRenderTarget2D[%w_]*") or "-", h.w, h.h, vp.X, vp.Y) or "none")
            return h ~= nil and h.visible and h.rt:find("TextureRenderTarget2D", 1, true) ~= nil and math.abs(h.h * sc - vp.Y * 0.22) < 4 and h.w > 0
        end }
    end
    local function hudHidden(id)
        return { check = id, timeout = 30, cond = function() local h = hud(); return h ~= nil and not h.visible end }
    end

    -- the ARC screen's Minimap: the icon widgets it lists (it draws them) for the partner's pin
    local function pins()
        local n, drawn = 0, 0
        for _, u in ipairs(FindAllOf("UMG_GobblerScreen_C") or {}) do
            if u:IsValid() and u.Minimap:IsValid() then
                u.Minimap.Icons:ForEach(function(_, e)
                    local w = e:get()
                    local c = w:IsValid() and w.MapIconComp
                    if c and c:IsValid() and c.IconTexture:IsValid() and c.IconTexture:GetFName():ToString() == "Map-Pin" and c:GetFullName():find("BP_GobblerMapBounds", 1, true) then
                        n = n + 1
                        if w:GetVisibility() == 0 or w:GetVisibility() == 3 or w:GetVisibility() == 4 then drawn = drawn + 1 end
                    end
                end)
            end
        end
        if os.getenv("PT_HEADLESS") == "1" then -- no rendering: the Minimap never ticks, so only the tracker side can be read (rendered: the widgets above)
            n, drawn = 0, 0
            local tr = StaticFindObject("/Script/MinimapPlugin.Default__MapFunctionLibrary"):GetMapTracker(T.world())
            for _, e in ipairs(tr:IsValid() and tr:GetMapIcons() or {}) do
                local ok, c = pcall(function() return e:get() end)
                c = ok and c or e
                if c:IsValid() and c.IconTexture:IsValid() and c.IconTexture:GetFName():ToString() == "Map-Pin" and c:GetFullName():find("BP_GobblerMapBounds", 1, true) then
                    n = n + 1
                    if c:IsIconVisible() then drawn = drawn + 1 end
                end
            end
        end
        return n, drawn
    end
    local ownWp
    local WPC = "/Game/UI/CarEquipment/Internal/Gobbler/BP_WaypointActor.BP_WaypointActor_C"
    local function placeMarker() return { run = function()
        local l = T.myPawn():K2_GetActorLocation()
        local d = T.ROLE == "host" and { 3000, 0 } or { 0, 3000 }
        ownWp = { X = l.X + d[1], Y = l.Y + d[2], Z = l.Z }
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = ownWp, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local c = StaticFindObject(WPC)
        if not c:IsValid() then LoadAsset(WPC); c = StaticFindObject(WPC) end
        gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(T.myPawn(), c, xf, 1, nil), xf)
    end } end
    local function pinDrawn(id)
        return { check = id, timeout = 60, cond = function()
            local n, d = pins()
            log("PT|info %s: partner pins listed=%d drawn=%d", id, n, d)
            return n == 1 and d == 1
        end }
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local id
        for _, s in ipairs(T.loadFixture(fixture)) do add(s) end
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() and T.map() ~= "RB_Garage" end })
        add({ check = "host_guest_in_zone", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 10 })
        add({ check = "host_hud_hidden_on_foot", timeout = 5, cond = function() local h = hud(); return h == nil or not h.visible end })
        add({ run = function() id = T.act_begin("enter_car", {}) end })
        add({ check = "host_in_car", timeout = 60, cond = function() local d, _, ok = T.act_done(id); return d and ok end })
        add({ run = function()
            local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
            local c, g = theCar(), L.guestChar()
            if attached(g) then sendGuest("t.seated"); return end
            local w = KML:TransformLocation(c:GetTransform(), { X = 131, Y = -200, Z = 0 })
            g:K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = w.X, Y = w.Y, Z = c:K2_GetActorLocation().Z + 10 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
            sendGuest("t.p1")
        end })
        add({ check = "guest_seated", timeout = 120, cond = function() local g = L.guestChar(); return g ~= nil and attached(g) end })
        add(hudShown("host_hud_shown_seated"))
        add({ run = function() sendGuest("t.placed") end })
        add(placeMarker())
        add({ wait = 8 })
        add(pinDrawn("host_minimap_pin"))
        add({ wait = 3 }); add({ run = function() if os.getenv("PT_HEADLESS") ~= "1" then T.console("Shot ShowUI") end end }) -- rendered runs: the HUD map with both pins
        add({ check = "guest_out_hud_hidden", timeout = 150, cond = function() return has("t.out") end }) -- the guest leaves first, the host stays at the wheel
        add({ run = function() id = T.act_begin("exit_car", {}) end })
        add({ check = "host_left_car", timeout = 40, cond = function() return (T.act_done(id)) end })
        add(hudHidden("host_hud_hidden_after_exit"))
        add({ run = function() sendGuest("t.end") end })
        add({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local id
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() ~= "RB_Garage" and T.map() ~= "RB_MainMenu" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_hud_hidden_on_foot", timeout = 30, cond = function() local h = hud(); return h == nil or not h.visible end })
    add({ check = "guest_told_seat", timeout = 400, cond = function() return has("t.p1") or has("t.seated") end })
    add({ run = function() if got["t.p1"] then id = T.act_begin("door_press", {}) end end })
    add({ check = "guest_seated", timeout = 90, cond = function() return attached(T.myPawn()) end })
    add(hudShown("guest_hud_shown_seated"))
    add({ check = "guest_told_place", timeout = 60, cond = function() return has("t.placed") end })
    add(placeMarker())
    add({ wait = 8 })
    add(pinDrawn("guest_minimap_pin"))
    add({ wait = 3 }); add({ run = function() if os.getenv("PT_HEADLESS") ~= "1" then T.console("Shot ShowUI") end end })
    add({ wait = 3 })
    add({ run = function() sendHost("t.hud", "1") end })
    add({ wait = 2 })
    add({ run = function() id = T.act_begin("door_press", { passenger = true }) end }) -- the game's own exit through the passenger door
    add({ check = "guest_out_of_car", timeout = 40, cond = function() return not attached(T.myPawn()) end })
    add(hudHidden("guest_hud_hidden_after_exit"))
    add({ run = function() sendHost("t.out", "1") end })
    add({ check = "guest_told_end", timeout = 120, cond = function() return has("t.end") end })
    return steps
end
