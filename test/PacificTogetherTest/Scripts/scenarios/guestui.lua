-- pt3-ui (guestui.lua of the shipping mod), the guest's side of the first Steam playtest:
--   joining      before the guest is placed its screen says "Joining host..", "Loading.." or "Waiting for host.."; gone once it can move
--   pause menu   Esc on the guest (the controller's PauseMenu input event, as pausemenu.lua does) opens the game's pause menu; the
--                host's world is not paused and keeps ticking; the menu closes again through its own action
--   F8 path      the console command "ptunstick" runs the same request as F8/End: the overlay says "Controls reset"
--   seat         seated by a real door press: a camera fade ran; after the exit a second fade ran (no seat hint since 2026-11-04)
-- Run: tools/run-test.ps1 -Scenario guestui -Fixture garage -Headless      Mutation noguestui: guestui.lua does nothing: the checks FAIL.
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

    if T.ROLE == "host" then
        local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        local GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function theCar()
            for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
                local l = c:IsValid() and c:K2_GetActorLocation()
                if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) then return c end
            end
        end
        local function attached(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end
        local t0
        add(T.onMap("RB_MainMenu", 90))
        for _, s in ipairs(T.loadFixture("garage", false)) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        -- pause menu on the guest: the host's world keeps running
        add({ run = function() sendGuest("t.esc") end })
        add({ check = "guest_menu_open_told", timeout = 60, cond = function() return has("t.menuopen") end })
        add({ run = function() t0 = GS:GetTimeSeconds(T.world()) end })
        add({ wait = 3 })
        add({ check = "host_world_runs_while_guest_menu_open", timeout = 2, cond = function()
            local dt = GS:GetTimeSeconds(T.world()) - t0
            log("PT|info guestui host world advanced %.1f s paused=%s", dt, tostring(GS:IsGamePaused(T.world())))
            return dt > 2.5 and not GS:IsGamePaused(T.world())
        end })
        add({ run = function() sendGuest("t.closemenu") end })
        add({ check = "guest_menu_closed_told", timeout = 60, cond = function() return has("t.menuclosed") end })
        add({ run = function() sendGuest("t.f8") end })
        add({ check = "guest_f8_told", timeout = 60, cond = function() return has("t.f8done") end })
        -- the guest takes its seat by the door press (the way carexit.lua does it)
        add({ run = function()
            local c = theCar()
            local w = KML:TransformLocation(c:GetTransform(), { X = 131, Y = -200, Z = 0 })
            L.guestChar():K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = w.X, Y = w.Y, Z = c:K2_GetActorLocation().Z + 10 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
            sendGuest("t.p1")
        end })
        add({ check = "host_guest_seated", timeout = 120, cond = function() local g = L.guestChar(); return g ~= nil and attached(g) end })
        add({ check = "guest_seat_checked_told", timeout = 60, cond = function() return has("t.seatok") end })
        add({ run = function() sendGuest("t.exit") end })
        add({ check = "host_guest_detached", timeout = 30, cond = function() local g = L.guestChar(); return g ~= nil and not attached(g) end })
        add({ check = "guest_exit_checked_told", timeout = 60, cond = function() return has("t.exitok") end })
        add({ wait = 2 })
        return steps
    end

    -- guest ---------------------------------------------------------------------------------------------------------------
    local function text(name)
        for _, t in ipairs(FindAllOf("TextBlock") or {}) do
            if t:IsValid() and t:GetFName():ToString() == name then
                local w = t:GetOuter():GetOuter()
                if w:IsValid() and w:IsInViewport() then return t:GetVisibility() ~= 1 and t:GetText():ToString() or "" end
            end
        end
    end
    local seen = {}
    LoopInGameThreadWithDelay(100, function()
        pcall(function()
            local m = text("PTGuestUiMsg")
            if m and m ~= "" then seen[m] = true end
        end)
    end)
    local function menu()
        local w = T.localPC():GetHUD().PauseMenuWidget
        if w:IsValid() and w:IsInViewport() and w.PDP_PauseMenu:GetVisibility() == 0 then return w.PDP_PauseMenu end
    end
    local function overlayLines()
        local r = {}
        for _, b in ipairs(FindAllOf("VerticalBox") or {}) do
            if b:IsValid() and b:GetFName():ToString() == "PTOverlayBox" and b:GetOuter():GetOuter():IsInViewport() then
                for i = 2, b:GetChildrenCount() - 1 do
                    local t = b:GetChildAt(i)
                    if t:GetVisibility() ~= 1 then r[#r + 1] = t:GetText():ToString() end
                end
            end
        end
        return r
    end
    local fades = 0
    pcall(RegisterHook, "/Script/Engine.PlayerCameraManager:StartCameraFade", function() fades = fades + 1 end)
    local function attached(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end
    local function theCar()
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
            local l = c:IsValid() and c:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and c.Role ~= 3 then return c end
        end
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local id, fadesBefore
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_loading_text_was_shown", timeout = 5, cond = function()
        local all = {}
        for k in pairs(seen) do all[#all + 1] = k end
        log("PT|info guestui texts seen: %s", table.concat(all, " | "))
        return #all > 0
    end })
    add({ check = "guest_loading_text_gone_when_placed", timeout = 60, cond = function() return text("PTGuestUiMsg") == "" end })
    add({ check = "guest_one_car", timeout = 90, cond = function() return theCar() ~= nil end })
    add({ check = "guest_told_esc", timeout = 120, cond = function() return has("t.esc") end })
    add({ run = function()
        local ok, err = pcall(function() T.localPC():InpActEvt_PauseMenu_K2Node_InputActionEvent_35({ KeyName = FName("Escape") }) end)
        log("PT|info guestui esc ok=%s %s", tostring(ok), tostring(err or ""))
    end })
    add({ check = "guest_pause_menu_open", timeout = 10, cond = function() return menu() ~= nil end })
    add({ run = function() sendHost("t.menuopen") end })
    add({ check = "guest_told_closemenu", timeout = 60, cond = function() return has("t.closemenu") end })
    add({ run = function() pcall(function() menu():ActionPauseMenu(true) end) end })
    add({ check = "guest_pause_menu_closed", timeout = 10, cond = function() return menu() == nil end })
    add({ run = function() sendHost("t.menuclosed") end })
    add({ check = "guest_told_f8", timeout = 60, cond = function() return has("t.f8") end })
    add({ run = function() T.console("ptunstick") end })
    add({ check = "guest_f8_path_ran", timeout = 10, cond = function()
        for _, l in ipairs(overlayLines()) do if l:find("Controls reset", 1, true) then return true end end
        return false
    end })
    add({ run = function() sendHost("t.f8done") end })
    add({ check = "guest_told_p1", timeout = 240, cond = function() return has("t.p1") end })
    add({ wait = 2 })
    add({ run = function() fadesBefore = fades; id = T.act_begin("door_press", {}) end })
    add({ check = "guest_door_press", timeout = 90, cond = function() local d, _, ok = T.act_done(id); return d and ok end })
    add({ check = "guest_seated", timeout = 60, cond = function() return attached(T.myPawn()) end })
    add({ check = "guest_fade_on_seating", timeout = 10, cond = function() log("PT|info guestui fades %d -> %d", fadesBefore, fades); return fades > fadesBefore end })
    add({ run = function() sendHost("t.seatok") end })
    add({ check = "guest_told_exit", timeout = 120, cond = function() return has("t.exit") end })
    -- g.car.exit is a protected kind: since the intent queue (protocol 7) it only counts as an intent
    add({ run = function() fadesBefore = fades; T.intent("g.car.exit", "") end })
    add({ check = "guest_left_seat", timeout = 30, cond = function() return not attached(T.myPawn()) end })
    add({ check = "guest_fade_on_leaving", timeout = 10, cond = function() return fades > fadesBefore end })
    add({ run = function() sendHost("t.exitok") end })
    add({ wait = 3 })
    return steps
end
