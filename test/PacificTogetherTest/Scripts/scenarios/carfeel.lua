-- PT1 car feel, one proving scenario. Garage fixture; the guest rides in the host's car (as carsync).
--   engine: the host turns the engine off then on; the guest's car reports the same ignition state and has its engine audio
--           component up.
--   revs:   the host drives; the guest's throttle input, engine-load/speed parameters (AC_CarAudio CurrentSpeed and
--           ThrottleAccumCurrent, what the engine and wheel sounds are fed from) follow the host's and change while it
--           drives, and the dashboard speedometer arm points where the host's does.
--   radios: garage stereo, car radio (through the radio part's own ToggleRadio), and volume, each changed by the host and
--           then by the guest (the guest's change goes to the host as an intent); the other side reports the same state.
--           Station skips and the shared track are the radio scenario (PT6).
--   car:    horn (the guest's audio component plays it), headlights, wipers.
-- Run: tools/run-test.ps1 -Scenario carfeel -Fixture garage -Headless
-- Mutation nofeel: carfeel.lua of the shipping mod does nothing.
-- Not testable headless (-nosound): that a track audibly plays; the check is the state and the music manager's skip calls.
return function(T)
    local L = require("scenarios.carlib")(T)
    local S = require("scenarios.sessionlib")(T)
    local log, ROLE = T.log, T.ROLE

    local function cm() return T.first("BP_CarManager_C") end
    local function mm() return T.first("BP_MusicManager_C") end
    local function attached(c, car)
        local p = c:GetAttachParentActor()
        return p:IsValid() and p:GetFullName() == car:GetFullName()
    end
    local function audio(car)
        for _, c in ipairs(FindAllOf("AC_CarAudio_C") or {}) do
            if c:IsValid() and c:GetOwner():GetFullName() == car:GetFullName() then return c end
        end
    end
    local function speedo(car)
        for _, c in ipairs(FindAllOf("BP_CarPart_Internal_Speedometer_C") or {}) do
            if c:IsValid() and attached(c, car) then return c end
        end
    end
    local function radioPart(car)
        for _, c in ipairs(FindAllOf("BP_CarPart_Internal_Radio_C") or {}) do
            if c:IsValid() and attached(c, car) then return c end
        end
    end
    local function stereoOn() return mm().GarageStereoOn end
    local function carRadioOn() local v = {}; cm():GetCarRadioOnOffState(v); return v.CarState_Radio == true end
    local function vol() return math.floor(mm().MusicVolume * 100 + 0.5) end
    local function head() return mm().RadioPlaylist[1]:GetFName():ToString() end
    local function near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= tol end

    -- music manager skips seen on this side (the shipping mod's SkipTrack on the receiving side, the game's own on the origin)
    local skips = 0
    pcall(RegisterHook, "/Script/PenDriverPro.BaseMusicManager:SkipTrack", function() skips = skips + 1 end)

    local inbox, heads = {}, {}
    local function drain()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then return end
            if kind == "t.pl" then heads[#heads + 1] = data; if #heads > 6 then table.remove(heads, 1) end end
            inbox[kind] = { data = data, at = os.time(), n = (inbox[kind] and inbox[kind].n or 0) + 1 }
        end
    end
    local function got(kind) drain(); return inbox[kind] end
    local function after(kind, n) local m = got(kind); return m ~= nil and m.n >= (n or 1) end

    if ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function guestPC() return S.remotePCs()[1] end
        local function send(kind, data) PTNative_MsgToGuest(guestPC():GetAddress(), kind, data or "") end
        local moved, start = 0, nil
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return S.guestChar() ~= nil end })
        add({ wait = 5 })
        -- the host takes the wheel first: the driver's door gives a guest the wheel only while nobody drives (guest driving, 0.9.2;
        -- carfeel failed host_guest_seated since then, same as carsync before 5203dff)
        add({ run = function()
            S.char = T.myPawn(); L.forcePossess(L.car(), S.char)
            pcall(function() local m = T.first("BP_CarManager_C"); m["Set PlayerCarState"](m, 1) end) -- the game's entry sets it, Possess does not
        end })
        add({ check = "host_in_car", timeout = 20, cond = function() return L.possessing(L.car()) end })
        add({ run = function() send("t.hostin") end })
        add({ check = "host_guest_seated", timeout = 240, cond = function()
            local g, car = S.guestChar(), L.car()
            if not g or not car or not attached(g, car) then return false end
            return L.d(L.toLocal(car, g:K2_GetActorLocation()), L.passengerLocal(car, S.char or T.myPawn())) < 5
        end })
        add({ wait = 3 })

        -- engine off, then on
        add({ run = function()
            local car = L.car()
            pcall(function() car:ManualSetIgnition_NoAnim(0) end)
            pcall(function() car.VehicleController:SetParkingBrakeActive(false) end)
        end })
        add({ wait = 2 })
        add({ run = function() log("PT|info host ignition %d", cm().CarIgnitionState); send("t.ign0") end })
        add({ wait = 6 })
        add({ run = function() L.startEngine(L.car()); send("t.ign2") end })
        add({ wait = 6 })

        -- revs: the host drives; it sends its own values twice a second for the guest to compare with
        add({ run = function()
            local car = L.car()
            start = car:K2_GetActorLocation()
            send("t.drive")
            L.drive(car, 4)
            local last, startRot, still = nil, car:K2_GetActorRotation(), { t = L.now(), p = start }
            local ca, sp = audio(car), speedo(car)
            LoopInGameThreadWithDelay(300, function()
                if not L.driving then return end
                pcall(function()
                    send("t.rpm", string.format("%.4f,%.4f,%.2f", ca.CurrentSpeed, ca.ThrottleAccumCurrent, sp and sp.SpeedArm.RelativeRotation.Roll or 0))
                end)
            end)
            LoopInGameThreadWithDelay(1, function()
                if not L.driving then return end
                pcall(function()
                    local p = car:K2_GetActorLocation()
                    if last then moved = moved + L.d(p, last) end
                    last = p
                    if L.d(p, still.p) > 100 then still = { t = L.now(), p = p }
                    elseif L.now() - still.t > 3 then
                        car:K2_SetActorLocationAndRotation(start, startRot, false, {}, true)
                        still = { t = L.now(), p = start }
                    end
                end)
            end)
        end })
        add({ wait = 20 })
        add({ run = function() L.driving = false; send("t.stop") end })
        add({ check = "host_drove", timeout = 1, cond = function() log("PT|info host drove %.0f uu", moved); return moved > 2000 end })
        add({ wait = 6 })

        -- garage stereo: host switches it on, the guest sees it and switches it off
        add({ run = function() mm():SetGarageStereoOn(true); send("t.gs1") end })
        add({ check = "host_stereo_off_by_guest", timeout = 60, cond = function() return after("t.gs2") and not stereoOn() end })
        -- car radio, through the part's own interaction event
        add({ run = function() radioPart(L.car()):ToggleRadio(); send("t.cr1") end })
        add({ check = "host_car_radio_off_by_guest", timeout = 60, cond = function() return after("t.cr2") and not carRadioOn() end })
        -- volume
        add({ run = function() mm():SetRadioVolume(0.33); send("t.vol1") end })
        add({ check = "host_volume_set_by_guest", timeout = 60, cond = function() return after("t.vol2") and vol() == 61 end })
        -- horn, headlights, wipers
        add({ run = function() cm():StartHornHonk(FName("ptfeel")); send("t.horn1") end })
        add({ wait = 8 })
        add({ run = function() cm():EndHornHonk(FName("ptfeel")); send("t.horn0") end })
        add({ wait = 3 })
        add({ run = function() cm():SetCarLightsOn(true); send("t.lights1") end })
        add({ wait = 4 })
        add({ run = function()
            L.car():ToggleWiperBlades()
        end })
        add({ wait = 3 })
        add({ run = function()
            log("PT|info host wipers %s", tostring(cm().WiperBladesOnOff))
            send("t.wip1", cm().WiperBladesOnOff and "1" or "0")
        end })
        add({ check = "host_guest_done", timeout = 90, cond = function() return got("t.done") ~= nil end })
        add({ wait = 3 })
        return steps
    end

    -- guest ----------------------------------------------------------------------------------------------------------------
    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local function toHost(kind, data) PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end
    local met = { n = 0, ok = 0, armOk = 0, armN = 0, csMax = 0, csMin = 9, loadMax = 0 }
    local function measure()
        local car = L.car()
        local m = got("t.rpm")
        if not car or not m or os.time() - m.at > 1 then return end
        local ca, sp = audio(car), speedo(car)
        local hcs, hacc, harm = m.data:match("([^,]+),([^,]+),([^,]+)")
        hcs, hacc, harm = tonumber(hcs), tonumber(hacc), tonumber(harm)
        local gcs, gacc = ca.CurrentSpeed, ca.ThrottleAccumCurrent
        met.csMax, met.csMin = math.max(met.csMax, gcs), math.min(met.csMin, gcs)
        met.loadMax = math.max(met.loadMax, car.VehicleController.ThrottleInput)
        if hcs > 0.05 then
            met.n = met.n + 1
            if near(gcs, hcs, 0.15) and near(gacc, hacc, 0.6) then met.ok = met.ok + 1
            elseif met.n - met.ok < 12 then log("PT|info revs miss host cs=%.3f acc=%.2f guest cs=%.3f acc=%.2f age=%d", hcs, hacc, gcs, gacc, os.time() - m.at) end
        end
        if sp and math.abs(harm) > 5 then
            met.armN = met.armN + 1
            if near(sp.SpeedArm.RelativeRotation.Roll, harm, 8) then met.armOk = met.armOk + 1 end
        end
    end

    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    add({ wait = 8 })
    add({ check = "guest_one_car", timeout = 60, cond = function() local cs = L.cars(); return #cs == 1 and #L.localCopies() == 0 end })
    add({ check = "host_sat_down", timeout = 300, cond = function() return got("t.hostin") ~= nil end })
    add({ run = function()
        local car, c = L.car(), T.myPawn()
        local l = car:K2_GetActorLocation()
        c:K2_HandleSetCharacterLocation({ Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = l.X + 250, Y = l.Y + 200, Z = l.Z + 20 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false, false)
    end })
    add({ wait = 2 })
    add({ run = function() L.car().SLOT_FrontLeftDoor:GetItemActor({}):StartEntry(false) end })
    add({ check = "guest_seated", timeout = 60, cond = function()
        local car, me = L.car(), T.myPawn()
        return car and me and attached(me, car) and L.seatErr(me, car) < 3
    end })

    -- engine
    add({ check = "guest_engine_off", timeout = 60, cond = function() return got("t.ign0") ~= nil and cm().CarIgnitionState == 0 end })
    add({ check = "guest_engine_on", timeout = 60, cond = function()
        if not got("t.ign2") then return false end
        local ca = audio(L.car())
        log("PT|info guest ignition %d engine audio valid=%s active=%s", cm().CarIgnitionState, tostring(ca.AK_Engine:IsValid()), tostring(ca.AK_Engine:IsActive()))
        return cm().CarIgnitionState == 2 and ca.AK_Engine:IsValid() and ca.AK_Engine:IsActive()
    end })

    -- revs
    add({ check = "guest_drive_started", timeout = 120, cond = function() return got("t.drive") ~= nil end })
    add({ run = function() LoopInGameThreadWithDelay(100, function() if not met.done then pcall(measure) end end) end })
    add({ check = "guest_drive_stopped", timeout = 120, cond = function() return got("t.stop") ~= nil end })
    add({ run = function() met.done = true end })
    add({ check = "guest_revs_follow_host", timeout = 1, cond = function()
        log("PT|info revs samples=%d match=%d csMin=%.3f csMax=%.3f loadMax=%.2f", met.n, met.ok, met.csMin, met.csMax, met.loadMax)
        return met.n >= 6 and met.ok >= met.n * 0.6 and met.csMax - met.csMin > 0.05 and met.loadMax > 0.3
    end })
    add({ check = "guest_dashboard_follows_host", timeout = 1, cond = function()
        log("PT|info speedometer samples=%d match=%d", met.armN, met.armOk)
        return met.armN >= 4 and met.armOk >= met.armN * 0.6
    end })

    -- radios
    add({ check = "guest_sees_stereo_on", timeout = 60, cond = function() return got("t.gs1") ~= nil and stereoOn() end })
    add({ run = function() mm():SetGarageStereoOn(false); toHost("t.gs2") end })
    add({ check = "guest_sees_car_radio_toggled", timeout = 60, cond = function() return got("t.cr1") ~= nil and carRadioOn() end })
    add({ run = function() radioPart(L.car()):ToggleRadio(); toHost("t.cr2") end })
    add({ check = "guest_sees_volume", timeout = 60, cond = function() return got("t.vol1") ~= nil and vol() == 33 end })
    add({ run = function() mm():SetRadioVolume(0.61); toHost("t.vol2") end })
    -- horn, lights, wipers
    add({ check = "guest_hears_horn", timeout = 60, cond = function() return got("t.horn1") ~= nil and audio(L.car()).HornActive == true end })
    add({ check = "guest_horn_stops", timeout = 60, cond = function() return got("t.horn0") ~= nil and audio(L.car()).HornActive == false end })
    add({ check = "guest_sees_headlights", timeout = 60, cond = function() return got("t.lights1") ~= nil and cm().CarLightsOn == true end })
    add({ check = "guest_sees_wipers", timeout = 60, cond = function()
        local m = got("t.wip1")
        return m ~= nil and (cm().WiperBladesOnOff and "1" or "0") == m.data
    end })
    add({ wait = 3 })

    -- the guest's posed car copy hits the ground and spawns the game's metal scrape sound actor (#2, 2026-10-23): the guest drops it
    local scrape
    add({ run = function()
        local P = "/Game/Sound/Blueprints/BP_CarScrapeFX.BP_CarScrapeFX_C"
        local c = StaticFindObject(P)
        if not (c and c:IsValid()) then pcall(LoadAsset, P); c = StaticFindObject(P) end
        local l = L.car():K2_GetActorLocation()
        scrape = require("UEHelpers").GetWorld():SpawnActor(c, { X = l.X, Y = l.Y, Z = l.Z + 300 }, { Pitch = 0, Yaw = 0, Roll = 0 })
        log("PT|info scrape fx spawned %s", tostring(scrape and scrape:IsValid()))
    end })
    add({ wait = 0.8 })
    add({ check = "guest_scrape_fx_dropped", timeout = 0.2, cond = function() return scrape ~= nil and (not scrape:IsValid() or scrape:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) or scrape:IsActorBeingDestroyed()) end })
    add({ run = function() toHost("t.done") end })
    add({ wait = 3 })
    return steps
end
