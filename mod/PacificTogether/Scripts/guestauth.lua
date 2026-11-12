-- Guest authority over the car it drives (owner 2026-11-12: "when guest is in the driver's seat, HIS game decides the physics").
-- Before, the guest's keys went to the host, the host simulated and the guest saw it through the follower: ping + 100-250 ms late
-- ("rather alien to control"). Now the guest at the wheel simulates its own car copy from its own keys and streams the result;
-- the host's car follows that stream with car.lua's follower (the one the guest uses when the host drives). Only the transform
-- and physics change hands: ignition, gear, lights, parts, fuel and the trunk stay the host's (docs/spikes/guestauth.md).
--   g.guestauth.car  guest -> host  "<world token>|<guest clock>|x|y|z|pitch|yaw|roll|vx|vy|vz" (g.motion.car's fields), 20 Hz
-- Back to the host when the guest leaves the wheel, the host takes it, or no sample came for 1 s: physics on where the car is,
-- with the last sample's velocity. Mutation noguestauth: not offered, the host simulates the guest's driving as before.
local common = require("common")
local net = require("net")
local car = require("car")
local log = common.log

local ga = car.ga
if not ga then return {} end -- car.lua disabled (mutation nocarsync)
local OFF = os.getenv("PT_MUTATE") == "noguestauth"
local NONE = FName("None")
local TIMEOUT = 1 -- s without a sample: the host takes the car back
local function valid(o) return o ~= nil and o:IsValid() end
local function same(a, b) return valid(a) and valid(b) and a:GetFullName() == b:GetFullName() end
local function kml() return StaticFindObject("/Script/Engine.Default__KismetMathLibrary") end
local function localPC()
    local pc = require("UEHelpers").GetPlayerController()
    return valid(pc) and pc:IsLocalController() and pc or nil
end
-- this character sits at the wheel of that car (car-local Y < 0: the driver's side, as car.lua's key poll checks)
local function atWheel(char, c)
    return valid(char) and c and same(char:GetAttachParentActor(), c)
        and kml():InverseTransformLocation(c:GetTransform(), char:K2_GetActorLocation()).Y < 0
end
RegisterLoadMapPreHook(function() ga.mine, ga.host, ga.axis, ga.pc = false, false, nil, nil end)

-- guest -------------------------------------------------------------------------------------------------------------------
local KEYS = {}
for _, k in ipairs({ "W", "S", "A", "D", "SpaceBar" }) do KEYS[k] = { KeyName = FName(k) } end
local test -- { keys, at }: the test bot's g.car.drive intents (it cannot press keys in a headless game)
if os.getenv("PT_SCENARIO") then
    net.testTap = function(kind, payload) if kind == "g.car.drive" then test = { payload, os.clock() } end end
end
local yaw, hooked = nil, false
-- the first second: the guest's car must stay put before the host follows it. In the garage it was thrown on its side the moment
-- its physics came on (carsync 2026-11-12, cause not found): then the host keeps simulating until the guest leaves the wheel.
local probe, blocked = nil, false
local function keys(pc)
    local function down(k) return pc:IsInputKeyDown(KEYS[k]) and 1 or 0 end
    local th, br, st, hb = down("W"), down("S"), down("D") - down("A"), down("SpaceBar")
    if th + br + math.abs(st) + hb == 0 and test and os.clock() - test[2] < 0.5 then
        local a, b, c, d = test[1]:match("^(%d) (%d) (%-?%d) (%d)$")
        if a then th, br, st, hb = tonumber(a), tonumber(b), tonumber(c), tonumber(d) end
    end
    return th, br, st, hb
end
LoopInGameThreadWithDelay(16, function()
    if common.netMode() ~= "client" then ga.mine = false; return end
    local ok, err = pcall(function()
        local c, pc = car.theCar(false), localPC()
        local me = pc and pc.Pawn
        local seated = c ~= nil and atWheel(me, c)
        if not seated then blocked = false end
        local want = not OFF and not blocked and net.hostSupports("guest-auth") and seated
        if want and not ga.mine then
            local m = ga.motion()
            ga.mine, yaw = true, c:K2_GetActorRotation().Yaw
            probe = { at = os.clock(), p = c:K2_GetActorLocation(), r = c:K2_GetActorRotation() }
            car.unfollow(c, m and m.v, true)
            log("PT|guestauth guest simulates the car it drives")
        elseif not want and ga.mine then
            ga.mine, ga.axis = false, nil
            if c then car.follow(c) end
            log("PT|guestauth guest left the wheel: following the host's car again")
        end
        if not ga.mine then return end
        if not hooked then
            -- the guest's own controller tick resets the car's throttle with its (on foot) axes, as on the host (car.lua thr)
            hooked = pcall(RegisterHook, "/Game/Systems/Controller/BP_Controller_PlayerCar.BP_Controller_PlayerCar_C:Input Car Throttle Brake", function()
                local cc = ga.mine and ga.axis and car.theCar(false)
                if cc then pcall(function() cc:AccelerateBrake(ga.axis) end) end
            end)
        end
        -- the car's own input events, as a seated player's axes call them every frame (car.lua: they smooth throttle and steering)
        local th, br, st, hb = keys(pc)
        ga.axis = th - br
        c:AccelerateBrake(th - br)
        c:SteerLeftRight(st)
        c:Handbrake(hb)
        -- the guest looks where it looked, turned with the car (car.lua's follower does this for a passenger)
        local y = c:K2_GetActorRotation().Yaw
        local turn = (y - yaw + 180) % 360 - 180
        yaw = y
        if math.abs(turn) > 0.0001 then
            local view = pc:GetControlRotation()
            pc:SetControlRotation({ Pitch = view.Pitch, Yaw = view.Yaw + turn, Roll = view.Roll })
        end
    end)
    if not ok then log("PT|error guestauth guest %s", tostring(err)) end
end)
-- A door or panel the host's door stream poses (kinematic) keeps its hinge to the chassis: the guest's car drove 2 m and stood
-- still at full throttle (guestdrive 2026-11-12). The hinge goes, as the game's own shut does (BreakConstraint, kinematic mesh).
local hingeAt = 0
local function freeHinges(c)
    if os.clock() - hingeAt < 0.25 then return end
    hingeAt = os.clock()
    for _, cls in ipairs({ "BP_CarPart_Door_Base_C", "BP_Panel_Base_C" }) do
        for _, part in ipairs(FindAllOf(cls) or {}) do
            pcall(function()
                if same(part:GetAttachParentActor(), c) and not part.MainMesh:IsSimulatingPhysics(NONE) then part.PhysicsConstraint:BreakConstraint() end
            end)
        end
    end
end
LoopInGameThreadWithDelay(50, function()
    if not ga.mine or common.netMode() ~= "client" then return end
    local c = car.theCar(false)
    if not c then return end
    if os.getenv("PT_MUTATE") ~= "guestauthhinge" then freeHinges(c) end
    local p, r, v = c:K2_GetActorLocation(), c:K2_GetActorRotation(), c:GetVelocity()
    if probe then
        local moved = math.sqrt((p.X - probe.p.X) ^ 2 + (p.Y - probe.p.Y) ^ 2 + (p.Z - probe.p.Z) ^ 2)
        local tilt = math.max(math.abs(r.Pitch - probe.r.Pitch), math.abs((r.Roll - probe.r.Roll + 180) % 360 - 180))
        if moved > 50 or tilt > 10 or os.getenv("PT_MUTATE") == "guestauthunstable" then
            probe, blocked, ga.mine, ga.axis = nil, true, false, nil
            car.follow(c)
            log("PT|guestauth unstable start (moved %.0f uu, tilt %.0f deg): the host keeps simulating", moved, tilt)
            return
        end
        if os.clock() - probe.at < 1 then return end
        probe = nil
        log("PT|guestauth guest car steady: streaming to the host")
    end
    net.toHost("g.guestauth.car", string.format("%s|%.6f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f", net.worldToken(), os.clock(),
        p.X, p.Y, p.Z, r.Pitch, r.Yaw, r.Roll, v.X, v.Y, v.Z))
end)

-- host --------------------------------------------------------------------------------------------------------------------
local cm = function() return common.first("BP_CarManager_C") end
net.on("g.guestauth.car", function(pc, data)
    if OFF or common.netMode() ~= "listen" or not net.peerSupports(pc, "guest-auth") then return end
    local c, m = car.theCar(true), cm()
    -- only the guest at the wheel while the host is not driving (car.lua seats the host's driver-door entry at the wheel)
    if not (c and m and m.PlayerCarState == 0 and atWheel(pc.Pawn, c)) then return end
    if ga.host and ga.pc ~= pc:GetAddress() then return end
    if not ga.take(data) then return end
    ga.host, ga.at, ga.pc = true, os.clock(), pc:GetAddress() -- host: the follower reads the guest's samples
    car.follow(c)
end)
local followedLogged = false
LoopInGameThreadWithDelay(16, function()
    if not ga.host then followedLogged = false; return end
    local ok, err = pcall(function()
        local c, m = car.theCar(true), cm()
        local driver
        for _, g in ipairs(net.guests()) do if g:GetAddress() == ga.pc then driver = g end end
        if not followedLogged then followedLogged = true; log("PT|guestauth host follows the guest's car") end
        local why = common.netMode() ~= "listen" and "not hosting" or not c and "no car" or not driver and "guest gone"
            or os.clock() - ga.at > TIMEOUT and "no sample for 1 s" or (m and m.PlayerCarState ~= 0) and "host drives"
            or not atWheel(driver.Pawn, c) and "guest left the wheel"
        if not why then return end
        local s = ga.motion()
        ga.host, ga.pc = false, nil
        ga.reset()
        if c then car.unfollow(c, s and s.v) end
        log("PT|guestauth host simulates the car again (%s) v=%s", why, s and string.format("%.0f,%.0f,%.0f", s.v.X, s.v.Y, s.v.Z) or "-")
    end)
    if not ok then ga.host = false; log("PT|error guestauth host %s", tostring(err)) end
end)

return {}
