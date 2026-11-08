-- M3 car (C1-C4, C7). Only the car's transform replicates, so:
--   guest: its own copy of the car (Role 3) is destroyed once the host's replicated car is there; the replicated car is
--          kinematic and moved every frame by Hermite interpolation of host-timed snapshots (legacy: ReplicatedMovement); the game's
--          door interaction (BP_CarPart_Door_Base:EnterCar) is turned into an intent, the host seats the guest in the
--          mirrored passenger seat and the guest holds the seat (X8); the host's car state (parts, health, fuel, battery,
--          ignition, gear, lights, doors, handbrake) arrives as a message and is applied to the guest's own car inventory.
--   host:  seats/unseats the guest on intent and broadcasts the state; the ARC is moved between the seats (D12).
-- Only the garage/run car BP_PlayerCarNew_C (not the intro car). Single player: nothing here runs unless this is a client, or a listening host with a guest.
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local log = common.log
local ov = require("overlay")

local M = {}
local proxyInput
function M.physicalProxyActive()
    return common.netMode() == "client" and net.hostSupports("physical-car") and proxyInput ~= nil and os.clock() - proxyInput.at < 1
end
if os.getenv("PT_MUTATE") == "nocarsync" then
    log("PT|car disabled (mutation nocarsync)")
    return M
end

local NONE = FName("None")
local PREFIX = "/Game/Gameplay/Inventory/Items/"
local COMP = "/Game/Gameplay/Inventory/GenericItemProperties/Components/"
local PASSENGER = { X = 46.2, Y = 45.8, Z = -12.3 } -- X8: the driver's seat mirrored across the car's centre line
local DRIVER = { X = 46.2, Y = -45.8, Z = -12.3 } -- a guest at the wheel (guest driving, 2026-11-08)
local ARC_SHIFT = { X = -70, Y = 0 } -- both ARC slots, car-local: behind the seats (the old X8 spot between them hid the starter key)
if os.getenv("PT_MUTATE") == "arcold" then ARC_SHIFT = { X = 0, Y = -42.5 } end -- test mutation: the old spot

-- helpers -------------------------------------------------------------------------------------------------------------

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function fname(o) return valid(o) and o:GetFullName() or "none" end
local function same(a, b) return valid(a) and valid(b) and a:GetFullName() == b:GetFullName() end
local function world() return UEHelpers.GetWorld() end
local function inWorld(o) return valid(o) and valid(o:GetWorld()) and same(o:GetWorld(), world()) end
local function now()
    local s, p = {}, {}
    UEHelpers.GetGameplayStatics():GetAccurateRealTime(s, p)
    return s.Seconds + p.PartialSeconds
end
local function vec(x, y, z) return { X = x, Y = y, Z = z } end
local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
local function kml() return StaticFindObject("/Script/Engine.Default__KismetMathLibrary") end
local function toLocal(car, p) return kml():InverseTransformLocation(car:GetTransform(), p) end
local function toWorld(car, p) return kml():TransformLocation(car:GetTransform(), p) end
local first = common.first
local function localPC()
    local c = UEHelpers.GetPlayerController() -- cached (common.lua): this ran FindAllOf per frame, 1.2 s a minute (playtest 2026-10-31)
    if inWorld(c) and c:IsLocalController() then return c end
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if inWorld(pc) and pc:IsLocalController() then return pc end
    end
end

-- a destroyed car stays IsValid until GC and then sits at exactly 0,0,0 (X7)
local function gone(c)
    if not valid(c) or not valid(c.RootComponent) then return true end
    local p = c:K2_GetActorLocation()
    return p.X == 0 and p.Y == 0 and p.Z == 0
end
-- read several times per tick by several modules (665 lookups a minute on a guest, PT|perf 2026-10-22): reused for 100 ms,
-- each car is still checked on every call
local carList, carAt = {}, -1
RegisterLoadMapPreHook(function() carList, carAt = {}, -1 end)
local function cars()
    if os.clock() - carAt > 0.1 then carList, carAt = FindAllOf("BP_PlayerCarNew_C") or {}, os.clock() end
    local r = {}
    for _, c in ipairs(carList) do
        if inWorld(c) and not gone(c) then r[#r + 1] = c end
    end
    return r
end
-- the host's car: on the host its only car; on the guest the replicated one (Role 3 = the guest's own copy)
local function theCar(isHost)
    for _, c in ipairs(cars()) do
        if isHost or c.Role ~= 3 then return c end
    end
end
local function localCopies()
    local r = {}
    for _, c in ipairs(cars()) do if c.Role == 3 then r[#r + 1] = c end end
    return r
end
local function carManager() return first("BP_CarManager_C") end

-- the car's equipped container: one slot per car slot tag, one ItemInstance per installed part
local function equipped()
    local im = first("BP_InventoryManager_C")
    if not im then return end
    local box = {}
    im:GetCarEquippedContainer(box)
    local c = box.Inventory_CarEquipped
    return valid(c) and c or nil
end
local function itemOf(slot)
    local it
    slot.Items:ForEach(function(_, e) it = e:get() end)
    return valid(it) and it or nil
end
local function slotName(slot) return (slot.SlotName:ToString():gsub("^Car%.Equip%.", "")) end
local function archPath(it)
    local p = it.Archetype:GetFullName():match("^%S+ ([^%.]+)")
    return p and (p:sub(1, #PREFIX) == PREFIX and p:sub(#PREFIX + 1) or p) or "?"
end
local function archObject(p)
    if p:sub(1, 1) ~= "/" then p = PREFIX .. p end
    local full = p .. "." .. p:match("([^/]+)$")
    local o = StaticFindObject(full)
    if not valid(o) then o = LoadAsset(full) end
    return valid(o) and o or nil
end
local function manifestation(cm, name)
    local r, r2 = {}, {}
    cm:GetItemManifestationEquippedInSlot({ TagName = FName("Car.Equip." .. name) }, r, r2)
    local m = r.Manifestation
    return valid(m) and m or nil
end

-- property components of a part (health, fuel, battery), cached per manifestation
local classes, compCache = nil, {}
RegisterLoadMapPreHook(function() classes, compCache = nil, {} end)
local function propComps(m)
    classes = classes or {
        h = StaticFindObject(COMP .. "BP_HealthComponent.BP_HealthComponent_C"),
        f = StaticFindObject(COMP .. "BP_FuelableComponent.BP_FuelableComponent_C"),
        b = StaticFindObject(COMP .. "BP_BatteryComponent.BP_BatteryComponent_C"),
    }
    local key = m:GetAddress()
    local c = compCache[key]
    if c and common.resolve(c.lease) then
        local live = true
        for _, lease in pairs(c.components) do if not common.resolve(lease) then live = false; break end end
        if live then return c end
    end
    c = { owner = m:GetFullName(), lease = common.lease(m), components = {} }
    for k, cls in pairs(classes) do
        for _, x in ipairs(m:K2_GetComponentsByClass(cls)) do
            local comp = x:get()
            -- the gas cap and the charge port pass fuel and charge through; the tanks and batteries own it
            local n = comp:GetClass():GetFName():ToString()
            if not n:find("GasCap", 1, true) and not n:find("ChargePort", 1, true) then c[k], c.components[k] = comp, common.lease(comp); break end
        end
    end
    compCache[key] = c
    return c
end
local function readPart(c)
    local h, f, b
    if c.h and valid(c.h) then
        local t = { {}, {}, {}, {}, {}, {}, {}, {} }
        c.h:GetHealth(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8])
        h = t[1].Health
    end
    if c.f and valid(c.f) then
        local t = { {}, {}, {}, {}, {}, {}, {} }
        c.f:GetFuelStatus(t[1], t[2], t[3], t[4], t[5], t[6], t[7])
        f = t[1].Fuel
    end
    if c.b and valid(c.b) then
        local t = { {}, {}, {}, {}, {} }
        c.b:GetBatteryStatus(t[1], t[2], t[3], t[4], t[5])
        b = t[1].BATTERY
    end
    return h, f, b
end
local function num(v) return v and string.format("%.1f", v) or "-" end

-- ARC (D12): both of its slots slide between the seats; nothing about it replicates, each side moves its own pair
local arcDone = {}
local arcAt = {} -- car address -> os.clock() of the next look (two FindAllOf scans every 250 ms before, on both sides)
local function moveArc(car)
    local k = car:GetAddress()
    if (arcAt[k] or 0) > os.clock() then return end
    arcAt[k] = os.clock() + 5 -- a re-installed ARC part is moved within 5 s
    for _, class in ipairs({ "BP_Carpart_Internal_Gobbler_C", "BP_Carpart_Internal_GobblerScreen_C" }) do
        for _, a in ipairs(FindAllOf(class) or {}) do
            if inWorld(a) and same(a:GetAttachParentActor(), car) then
                local slot = a.RootComponent:GetAttachParent()
                if valid(slot) and not arcDone[slot:GetFullName()] then
                    local r = slot.RelativeLocation
                    -- not yet moved: the slot is still on the near side of the half-way point along the shift
                    if r.X * ARC_SHIFT.X + r.Y * ARC_SHIFT.Y < (ARC_SHIFT.X ^ 2 + ARC_SHIFT.Y ^ 2) / 2 then
                        slot:K2_SetRelativeLocation(vec(r.X + ARC_SHIFT.X, r.Y + ARC_SHIFT.Y, r.Z), false, {}, true)
                        log("PT|car arc slot moved %s", slot:GetFullName())
                    end
                    arcDone[slot:GetFullName()] = true
                end
            end
        end
    end
end

-- doors and the rear hatch (BP_CarPart_Door_Base on SLOT_*Door / Slot_Trunk): slot name -> part
-- Opening only unlatches one; its mesh then swings on physics. The guest's copy stayed shut (no physics there), and the
-- host's door-state sync closed the guest's own opening 1-2 s later (hand playtest 2026-10-23).
local DOOR = "BP_CarPart_Door_Base_C"
local HOOD = "BP_Panel_Base_C"
local function doorParts(car)
    local r, list = {}, {}
    pcall(function() car:GetAttachedActors(list, true) end)
    for _, e in ipairs(list) do
        local a = e:get()
        if valid(a) and (a:GetClass():GetFName():ToString() == DOOR or a:GetClass():GetFName():ToString() == HOOD) then
            local ok, slot = pcall(function() return a.RootComponent.AttachParent:GetFName():ToString() end)
            if ok and (a:GetClass():GetFName():ToString() == DOOR or slot == "SLOT_Hood") then r[slot] = a end
        end
    end
    return r
end
local doorHold = 0 -- guest: until then its own door move (sent to the host) is not overridden
local entryDoor -- host: the door a guest opened last { part, at }; shut once they are seated (the game's entry does it itself)
local doorHeld -- guest: the host's last state during the hold, applied when it ends (else a shut showed only 3 s later)
local doorRest, doorSwung = {}, {} -- guest: part address -> the mesh's shut pose on its part; parts we posed open
local doorTargets = {}
RegisterLoadMapPreHook(function() doorTargets = {} end)

-- host -------------------------------------------------------------------------------------------------------------------

-- the car's door parts, kept 2 s (the 50 ms swing loop and every 250 ms sample walked its attached actors)
local doorCache, doorCacheAt, doorCacheCar = {}, -10, nil
local function doorsOf(car)
    local addr = car:GetAddress()
    local ok = doorCacheCar == addr and os.clock() - doorCacheAt < 2
    if ok then for _, d in pairs(doorCache) do if not valid(d) then ok = false; break end end end
    if not ok then doorCache, doorCacheAt, doorCacheCar = doorParts(car), os.clock(), addr end
    return doorCache
end
-- host: the parts lines of the last sample (see sample); the list of doors shut or open last time starts the swing watcher
local partLines, partCount, partsAt, partsCar = {}, 0, -1, nil
local swingUntil, lastDoorBits = 0, nil
local function swingFor(s) swingUntil = os.clock() + (s or 6) end
RegisterLoadMapPreHook(function() doorCache, doorCacheCar, partsAt, partsCar = {}, nil, -1, nil end)
-- a guest's part work (heal, damage, swap, fuel ...) is applied on the host first: a cached line would send the old state back
-- for up to 1 s and the guest's repair flickered away (guestparts "door stays repaired" broke)
net.tap = function(kind) if kind:find("^g%.parts%.") or kind:find("^g%.act%.") or kind:find("^g%.swap%.") then partsAt = -1 end end

local function sample(car, cm)
    local cont = equipped()
    if not cont then return end
    local ign = cm.CarIgnitionState
    local doors = 0
    for d = 0, 5 do
        local o = {}
        cm:GetDoorState(d, o)
        if o.Open then doors = doors | (1 << d) end
    end
    if doors ~= lastDoorBits then lastDoorBits = doors; swingFor() end
    local hb = false
    pcall(function() hb = car.VehicleController:GetParkingBrakeActive() end)
    local lines = { string.format("H\t%d\t%d\t%d\t%d\t%d", ign, cm.MyCarGearBox, cm.CarLightsOn and 1 or 0, hb and 1 or 0, doors) }
    lines[#lines + 1] = "C\t" .. car:GetFName():ToString()
    -- the part lines (about 30 slots, ~100 UE calls) are rebuilt at 1 Hz, or at once after a UpdatedCarEquip; the H and R lines
    -- stay at the tick's rate (health, fuel and battery drift slowly: the guest sees them 1 s late at most)
    if partsAt < 0 or os.clock() - partsAt > 1 or partsCar ~= car:GetAddress() then
        local n = 0
        local pl = {}
        cont.Slots:ForEach(function(_, e)
            local slot = e:get()
            local it = itemOf(slot)
            if it then
                local name = slotName(slot)
                local h, f, b
                local m = manifestation(cm, name)
                if m then h, f, b = readPart(propComps(m)) end
                n = n + 1
                pl[#pl + 1] = string.format("P\t%s\t%s\t%s\t%s\t%s", name, archPath(it), num(h), num(f), num(b))
            end
        end)
        partLines, partCount, partsAt, partsCar = pl, n, os.clock(), car:GetAddress()
    end
    for _, l in ipairs(partLines) do lines[#lines + 1] = l end
    local n = partCount
    -- an open door's mesh simulates physics, which detaches it (its "relative" transform is then the world's): its pose
    -- goes in the car's own space
    local ct = car:GetTransform()
    for slot, d in pairs(doorsOf(car)) do
        pcall(function()
            local m = d.MainMesh
            if not m:IsSimulatingPhysics(FName("None")) then return end
            local l = kml():InverseTransformLocation(ct, m:K2_GetComponentLocation())
            local r = kml():InverseTransformRotation(ct, m:K2_GetComponentRotation())
            lines[#lines + 1] = string.format("R\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f", slot, l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll)
        end)
    end
    lines[#lines + 1] = "E\t" .. n
    return table.concat(lines, "\n")
end

-- host hooks (listen only): a door verb or knock starts the swing watcher, a changed car loadout rebuilds the part lines.
-- Each keeps its slow timer fallback (the 2 s swing pass, the 1 s part lines); first fires are logged as PT|probe.
local DOORBP = "/Game/Gameplay/Inventory/Items/Car/Doors/BP_CarPart_Door_Base.BP_CarPart_Door_Base_C:"
local HOODBP = "/Game/Gameplay/Inventory/Items/Car/Panels/BP_Panel_Base.BP_Panel_Base_C:"
local hostHooked, probeN = false, {}
local healthDirty=false
local probeOk, probeLogged = {}, {} -- hook name -> registered; -> failure logged once
local function probe(name, fn)
    if probeOk[name] then return true end
    local ok, err = pcall(RegisterHook, name, function()
        if common.netMode() ~= "listen" then return end
        probeN[name] = (probeN[name] or 0) + 1
        if probeN[name] <= 3 then log("PT|probe car hook %s n=%d", name:match("[^:/%.]+$"), probeN[name]) end
        fn()
    end)
    if not ok and not probeLogged[name] then
        probeLogged[name] = true
        log("PT|probe car hook %s not registered: %s", name:match("[^:/%.]+$"), tostring(err))
    end
    probeOk[name] = ok
    return ok
end
local function hostHooks()
    if hostHooked then return end
    -- retried until all register: on the first listen tick the Blueprint classes may not be loaded yet
    local all = true
    for _, fn in ipairs({ "AttemptOpen", "AttemptShut", "ObjectKicked", "OnConstraintBroken_Event_0" }) do
        all = probe(DOORBP .. fn, function() swingFor() end) and all
    end
    for _, fn in ipairs({ "AttemptOpen", "AttemptShut", "OnConstraintBroken_Event_0" }) do
        all = probe(HOODBP .. fn, function() swingFor() end) and all
    end
    all = probe("/Game/Systems/Managers/BP_CarManager.BP_CarManager_C:UpdatedCarEquip", function() partsAt = -1 end) and all
    for _,fn in ipairs({'SetHealth','ModifyHealth'})do
        all=probe(COMP..'BP_HealthComponent.BP_HealthComponent_C:'..fn,function(self)
            if common.netMode()~='listen' then return end
            local owner=self:get():GetOwner()
            if valid(owner) and same(owner:GetAttachParentActor(),theCar(true))then partsAt=-1;healthDirty=true end
        end) and all
    end
    hostHooked = all
end

local lastSent, lastAt, lastGuests, lastH = nil, 0, 0, nil
local arcAt = -10
local function hostTick()
    hostHooks()
    local guests = net.guests()
    if #guests == 0 then lastSent, lastGuests = nil, 0; return end
    local car, cm = theCar(true), carManager()
    if not car or not cm then return end
    -- past the default 150 m net cull (from the guest's camera, which rides the guest's copy) the car stopped replicating: frozen in
    -- the garage while the host drove off, and in a zone the guest's world never streamed in around the real car (fell through)
    if os.getenv("PT_MUTATE") ~= "norelevant" and not car.bAlwaysRelevant then
        car.bAlwaysRelevant = true
        log("PT|car always relevant for the guest")
    end
    if os.clock() - arcAt > 5 then arcAt = os.clock(); moveArc(car) end -- a slot is moved once
    local s = sample(car, cm)
    if not s then return end
    local t = now()
    -- the whole state (~5 KB: every part with its asset path) went out whenever a number drifted: 52 KB/s of the guest's 100 KB/s
    -- while driving, and the guest's own pawn waited minutes for room (hand play 2026-10-24). Ignition, gear, lights, handbrake and
    -- doors (the H line) still go at once; the rest at most twice a second.
    local h = s:match("^[^\n]*")
    if #guests ~= lastGuests or h ~= lastH or (s ~= lastSent and (healthDirty or t - lastAt >= 0.5)) or t - lastAt > 3 then
        net.toGuests("g.car.s", s)
        lastSent, lastAt, lastGuests, lastH = s, t, #guests, h
        healthDirty=false
    end
end

-- Native wheel phase and steering travel separately, on MultiVoid's independent snapshot clock.
local wheelMotion = require("wheelmotion")
local wheelCar, wheelMeshes, wheelBodies, wheelBuffer = nil, {}, {}, {}
local wheelLast, wheelSentAt, wheelHostKey, wheelCarLease = nil, 0, nil, nil
local WHEEL_NAMES = { "FrontLeftWheel", "FrontRightWheel", "RearLeftWheel", "RearRightWheel" }
local function wheelMeshesOf(car)
    if not common.resolve(wheelCarLease) or not same(wheelCar, car) then
        wheelCarLease = common.lease(car)
        wheelCar, wheelMeshes, wheelBodies, wheelBuffer, wheelLast = car, {}, {}, {}, nil
        for _, wrapped in ipairs(car:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.SceneComponent"))) do
            local c = wrapped:get()
            for i, name in ipairs(WHEEL_NAMES) do
                if c:GetFName():ToString() == name .. "_Mesh" then wheelMeshes[i] = c
                elseif c:GetFName():ToString() == name then wheelBodies[i] = c end
            end
        end
    end
    return wheelMeshes
end
RegisterLoadMapPreHook(function() wheelCar, wheelMeshes, wheelBodies, wheelBuffer, wheelHostKey = nil, {}, {}, {}, nil end)
net.on("g.motion.wheels", function(_, data)
    if common.netMode() ~= "client" then return end
    local car = theCar(false)
    if not car then return end
    wheelMeshesOf(car)
    local key, timestamp, rows = data:match("^([%w_]+)|([^\n]+)\n(.*)$")
    if not wheelHostKey or key ~= wheelHostKey then return end
    timestamp = tonumber(timestamp)
    if not timestamp or timestamp ~= timestamp or math.abs(timestamp) > 1e12 then return end
    local snapshot = { t = timestamp, at = os.clock(), wheels = {} }
    for line in rows:gmatch("[^\n]+") do
        local f = {}
        for token in (line .. ","):gmatch("([^,]*),") do
            local v = tonumber(token)
            if not v or v ~= v or math.abs(v) > 1e7 then return end
            f[#f + 1] = v
        end
        if #f ~= 9 or not wheelMeshes[f[1]] then return end
        snapshot.wheels[f[1]] = { p = vec(f[2], f[3], f[4]), r = { Pitch = f[5], Yaw = f[6], Roll = f[7] }, phase = f[8], omega = f[9] }
    end
    if not (snapshot.wheels[1] and snapshot.wheels[2] and snapshot.wheels[3] and snapshot.wheels[4]) then return end
    wheelMotion.push(wheelBuffer, snapshot)
end)
LoopInGameThreadWithDelay(50, function()
    if common.netMode() ~= "listen" or #net.guests() == 0 then return end
    local car = theCar(true)
    if not car then return end
    local lines, ct = {}, car:GetTransform()
    for i, mesh in ipairs(wheelMeshesOf(car)) do
        local wheel = wheelBodies[i]
        if not (valid(mesh) and valid(wheel)) then return end
        local p = toLocal(car, mesh:K2_GetComponentLocation())
        local r = kml():InverseTransformRotation(ct, mesh:K2_GetComponentRotation())
        local phase, omega = wheel:GetAngularPosition(), wheel:GetAngularVelocity()
        local steering = kml():ComposeRotators({ Pitch = math.deg(phase), Yaw = 0, Roll = 0 }, r)
        lines[#lines + 1] = string.format("%d,%.2f,%.2f,%.2f,%.3f,%.3f,%.3f,%.6f,%.6f", i, p.X, p.Y, p.Z, steering.Pitch, steering.Yaw, steering.Roll, phase, omega)
    end
    local rows = table.concat(lines, "\n")
    if rows ~= wheelLast or os.clock() - wheelSentAt > 1 then
        local data = string.format("%s|%.6f\n%s", car:GetFName():ToString(), os.clock(), rows)
        net.toGuests("g.motion.wheels", data)
        wheelLast, wheelSentAt = rows, os.clock()
    end
end)
LoopInGameThreadWithDelay(16, function()
    if common.netMode() ~= "client" or not valid(wheelCar) then return end
    if M.physicalProxyActive() then return end
    local a, b, u, extrapolate = wheelMotion.sample(wheelBuffer, os.clock())
    if not a then return end
    local ct = wheelCar:GetTransform()
    for i, target in pairs(b.wheels) do
        local from, mesh = a.wheels[i] or target, wheelMeshes[i]
        if valid(mesh) then
            local function lerp(x, y) return x + (y - x) * u end
            local p = vec(lerp(from.p.X, target.p.X), lerp(from.p.Y, target.p.Y), lerp(from.p.Z, target.p.Z))
            local steering = kml():RLerp(from.r, target.r, u, true)
            local rolling = { Pitch = -math.deg(wheelMotion.phase(from, target, u, extrapolate)), Yaw = 0, Roll = 0 }
            mesh:K2_SetWorldLocation(kml():TransformLocation(ct, p), false, {}, true)
            mesh:K2_SetWorldRotation(kml():TransformRotation(ct, kml():ComposeRotators(rolling, steering)), false, {}, true)
        end
    end
end)

-- C1: seat the guest at the mirrored seat and attach it (movement and collision off on both sides)
-- Steam playtest #12: a seated guest body stands at seat height, its legs hang under the car. The game has no sitting pose (its own
-- driver's body is never shown; ALS_MovementMode 5 changes nothing visible), so the legs are hidden while the guest sits.
local LEG_BONES = { "thigh_l", "thigh_r" }
local function sitPose(char, on)
    if os.getenv("PT_MUTATE") == "nosit" then return end
    local ok, sv = pcall(require, "survivor")
    if ok then sv.sit(char, on) end
    pcall(function()
        for _, b in ipairs(LEG_BONES) do
            if on then char.Mesh:HideBoneByName(FName(b), 0) else char.Mesh:UnHideBoneByName(FName(b)) end
        end
    end)
end
local seated = {} -- host: guest character full name -> true while our seat() holds it (the game attaches a new character as DRIVER, playtest 2026-10-23)
-- what is under a spot on this side: "z=<impact z>" or "none" (diagnostic for the guest falling through the map after leaving the car)
local function groundAt(who, p)
    local ok, r = pcall(function()
        local hit = {}
        local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local got = KSL:LineTraceSingle(who, vec(p.X, p.Y, p.Z + 50), vec(p.X, p.Y, p.Z - 3000), 0, false, { who }, 0, hit, true, {}, {}, 0)
        local h = hit.OutHit or hit
        return got and string.format("z=%.0f", h.ImpactPoint.Z) or "none"
    end)
    return ok and r or ("err " .. tostring(r))
end

local hostRiding = false -- host: the host sits in the passenger seat, seated by us (guest driving)
local driverGuest = nil -- host: full name of the guest character seated at the wheel (it drives while the host does not)
local function seat(char, car, driver)
    seated[char:GetFullName()] = true
    if driver then driverGuest = char:GetFullName() elseif driverGuest == char:GetFullName() then driverGuest = nil end
    local want = driver and DRIVER or PASSENGER
    local lp = want
    pcall(function()
        local t = {}
        local f = StaticFindObject(char:GetClass():GetFullName():match("^%S+ (.+)$") .. ":GetCarAttachTransformForCharacter")
        f(char, t)
        local d = toLocal(car, t.Translation) -- the driver's seat
        lp = driver and vec(d.X, d.Y, d.Z) or vec(d.X, -d.Y, d.Z)
    end)
    -- the game's transform once came out 18 uu high (head in the roof, garage play 2026-10-24): only small corrections are kept
    if dist(lp, want) > 8 then lp = want end
    pcall(function() char:K2_DetachFromActor(1, 1, 1) end) -- a re-seat (the host took the wheel) attaches anew at the new spot
    pcall(function() char.CharacterMovement:DisableMovement() end)
    char:SetActorEnableCollision(false)
    local r = car:K2_GetActorRotation()
    char:K2_SetActorLocationAndRotation(toWorld(car, lp), { Pitch = 0, Yaw = r.Yaw, Roll = 0 }, false, {}, true)
    char:K2_AttachToActor(car, NONE, 1, 1, 1, false)
    sitPose(char, true)
    -- tell the guest at once: the engine's attachment replication reached it 4-14 s later (it stood frozen by the shut door)
    if os.getenv("PT_MUTATE") ~= "noseatmsg" then pcall(function() net.toGuest(char.Controller, "g.car.seat", string.format("%.1f,%.1f,%.1f", lp.X, lp.Y, lp.Z)) end) end
    log("PT|car seated %s at %.1f,%.1f,%.1f", char:GetFullName(), lp.X, lp.Y, lp.Z)
end

local function guestChar(pc)
    local c = pc.Pawn
    return valid(c) and c:IsA(StaticFindObject("/Script/PenDriverPro.BaseCharacter")) and c or nil
end

-- Getting in and out looks like a player doing it (after PDCoopNet's seatanim.lua, MIT, BroZYTnikkkk): the guest's body moves from
-- where it stands past the front door's entry point onto the seat in ~1.9 s, and on the way out from the seat past the door to
-- the exit spot in ~1.1 s, on both sides; before, it jumped onto the seat and back. The game's own entry and exit stay muted on
-- the guest (a local exit crashed AC_CarAudio's tick, 2026-10-23). Points are car-local, so a moving car carries the path.
--   in   the actor itself moves (movement and collision off; the host ignores the guest's moves meanwhile), then seat() attaches it
--   out  on the host the actor stands at the spot at once and only its mesh moves there (moving the actor threw the car aside in
--        PDCoopNet, exp257-260); the guest moves its own actor, then walks
local GLIDE_IN, GLIDE_OUT = { 0.8, 1.9 }, { 0.4, 1.1 } -- s: at the door's entry point, at the end
local glides = {} -- actor full name -> { a, car, pts, times, t0, mesh, rel0, yaw0, yaw1, after }
local function noGlide() return os.getenv("PT_MUTATE") == "noglide" end
local function gliding(a) return valid(a) and glides[a:GetFullName()] ~= nil end
M.gliding = gliding -- desync.lua leaves a gliding body alone (its "repair" turned walking and collision back on mid-glide, carsync)
local function stopGlide(a) if valid(a) then glides[a:GetFullName()] = nil end end
LoopInGameThreadWithDelay(16, function()
    if not next(glides) then return end
    for key, g in pairs(glides) do
        local ok = pcall(function()
            if not (common.resolve(g.actorLease) and common.resolve(g.carLease)) then glides[key] = nil; return end
            local t = os.clock() - g.t0
            local a, b, u
            if t < g.times[1] then a, b, u = g.pts[1], g.pts[2], t / g.times[1]
            elseif t < g.times[2] then a, b, u = g.pts[2], g.pts[3], (t - g.times[1]) / (g.times[2] - g.times[1])
            else a, b, u = g.pts[3], g.pts[3], 1 end
            u = u * u * (3 - 2 * u) -- ease in and out
            local w = toWorld(g.car, vec(a.X + (b.X - a.X) * u, a.Y + (b.Y - a.Y) * u, a.Z + (b.Z - a.Z) * u))
            if g.mesh then -- the mesh where the actor would be, keeping its own offset to the actor
                g.mesh:K2_SetRelativeLocation(g.rel0, false, {}, true)
                local m, l = g.mesh:K2_GetComponentLocation(), g.a:K2_GetActorLocation()
                g.mesh:K2_SetWorldLocation(vec(m.X + w.X - l.X, m.Y + w.Y - l.Y, m.Z + w.Z - l.Z), false, {}, true)
            else
                g.a:K2_SetActorLocation(w, false, {}, true)
                local k, d = math.min(1, t / g.times[2]), ((g.yaw1 - g.yaw0 + 180) % 360) - 180
                g.a:K2_SetActorRotation({ Pitch = 0, Yaw = g.yaw0 + d * k, Roll = 0 }, true)
            end
            if t >= g.times[2] then
                glides[key] = nil
                if g.mesh then g.mesh:K2_SetRelativeLocation(g.rel0, false, {}, true) end
                if g.after then g.after() end
            end
        end)
        if not ok then glides[key] = nil end
    end
end)
RegisterLoadMapPreHook(function() glides = {} end)
local function glideFlags(char, on)
    pcall(function() char.CharacterMovement.bIgnoreClientMovementErrorChecksAndCorrection = on end)
    if on then
        pcall(function() char.CharacterMovement:StopMovementImmediately(); char.CharacterMovement:DisableMovement() end)
        pcall(function() char:SetActorEnableCollision(false) end)
    end
end
-- the front doors' entry points (EntranceLogicPoint arrows on the door part), car-local: the one nearest to p
local function doorPoint(car, p)
    local best, bd
    local arrow = StaticFindObject("/Script/Engine.ArrowComponent")
    for slot, d in pairs(doorParts(car)) do
        if slot == "SLOT_FrontRightDoor" or slot == "SLOT_FrontLeftDoor" then
            for _, c in ipairs(d:K2_GetComponentsByClass(arrow) or {}) do
                local o = c.get and c:get() or c
                if valid(o) and o:GetFName():ToString():find("EntranceLogicPoint", 1, true) then
                    local l = toLocal(car, o:K2_GetComponentLocation())
                    local dd = (l.X - p.X) ^ 2 + (l.Y - p.Y) ^ 2
                    if not bd or dd < bd then best, bd = l, dd end
                end
            end
        end
    end
    return best
end
-- host: the body (actor) moves onto the seat; then(...) when it is there
local function glideIn(char, car, seatLocal, after)
    local from = toLocal(car, char:K2_GetActorLocation())
    local mid = doorPoint(car, from) or from
    glideFlags(char, true)
    glides[char:GetFullName()] = { a = char, car = car, actorLease = common.lease(char), carLease = common.lease(car), t0 = os.clock(), times = GLIDE_IN, yaw0 = char:K2_GetActorRotation().Yaw,
        yaw1 = car:K2_GetActorRotation().Yaw, pts = { from, vec(mid.X, mid.Y, from.Z), seatLocal }, after = after }
end
-- the exit spot on the passenger side: the game's own safe exit point is the driver's, mirrored across the car's centre line
-- when there is ground under the mirrored spot (ponytail: no wall check; the driver's spot is the fallback)
local function passengerSide(car, out)
    if os.getenv("PT_MUTATE") == "driverexit" then return out, "driver" end
    local l = toLocal(car, out)
    if l.Y >= 0 then return out, "passenger" end -- already on the passenger side
    local m = toWorld(car, vec(l.X, -l.Y, l.Z))
    local hit = false
    pcall(function()
        local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local h = {}
        hit = KSL:LineTraceSingle(car, vec(m.X, m.Y, m.Z + 50), vec(m.X, m.Y, m.Z - 300), 0, false, { car }, 0, h, true, {}, {}, 0)
    end)
    if hit then return m, "passenger" end
    return out, "driver (no ground on the passenger side)"
end

net.on("g.car.enter", function(pc, data)
    if not safety.active() or common.netMode() ~= "listen" then return end
    local char, car, cm = guestChar(pc), theCar(true), carManager()
    if not char or not car then return end
    if same(char:GetAttachParentActor(), car) or gliding(char) then return end
    -- the seat is the free one nearest the door used: the driver's door gets the wheel unless the host drives (or is getting in)
    local driver = data == "D" and os.getenv("PT_MUTATE") ~= "noguestdrive"
    if cm and cm.PlayerCarState ~= 0 then driver = false end
    if hostRiding and os.getenv("PT_MUTATE") ~= "noguestdrive" then driver = true end
    -- shortcut: no reach check (a client-side teleport did not move the guest on the host); add one when doors are real input
    log("PT|car enter from %.0f uu", dist(char:K2_GetActorLocation(), car:K2_GetActorLocation()))
    local function sit()
        if not (valid(char) and valid(car)) then return end
        glideFlags(char, false)
        seat(char, car, driver)
        -- the guest's door stayed open and swung while driving (hand playtest 2026-10-23): no entry animation shuts it here
        local door = entryDoor and now() - entryDoor.at < 8 and entryDoor.part
        entryDoor = nil
        if door then
            common.defer(800, function() pcall(function() if valid(door) then door:AttemptShut() end end) end)
        end
        ov.post(ov.other() .. " entered the car")
    end
    -- far from the car (the host has the guest elsewhere: a client-side move, carsync's 87 m) there is no door to walk past
    if noGlide() or dist(char:K2_GetActorLocation(), car:K2_GetActorLocation()) > 600 then sit() else glideIn(char, car, driver and DRIVER or PASSENGER, sit) end
end)

-- the car radio (its power button is the driver's highlight too) and the shifter: the parts attached to the car, looked up every 2 s
local parts, partsAt = {}, -99
local function carPart(car, class)
    if os.clock() - partsAt > 2 then parts, partsAt = {}, os.clock() end
    if parts[class] == nil then
        parts[class] = false
        for _, r in ipairs(FindAllOf(class) or {}) do
            if valid(r) and same(r:GetAttachParentActor(), car) then parts[class] = common.lease(r); break end
        end
    end
    local part = common.resolve(parts[class] or nil)
    return part and same(part:GetAttachParentActor(), car) and part or nil
end
local function carRadio(car) return carPart(car, "BP_CarPart_Internal_Radio_C") end

-- the seated guest turned the key or moved the shifter (P <-> D; P holds the parking brake): the host's own setters, then
-- the H line shows it on both sides. No key animation or failed-start chance (ManualSetIgnition_NoAnim: 0 off, 2 running).
net.on("g.car.ctl", function(pc, what)
    if common.netMode() ~= "listen" or os.getenv("PT_MUTATE") == "noguestctl" then return end
    local char, car, cm = guestChar(pc), theCar(true), carManager()
    if not (char and car and cm and same(char:GetAttachParentActor(), car)) then return end
    if what == "ign" then
        local to = cm.CarIgnitionState == 0 and 2 or 0
        pcall(function() car:ManualSetIgnition_NoAnim(to) end)
        log("PT|car ctl ign -> %d now %d", to, cm.CarIgnitionState)
    elseif what == "radio" then
        local r = carRadio(car)
        pcall(function() r.BP_RadioComponent:TogglePlayback() end)
        log("PT|car ctl radio toggled")
    elseif what == "radio_next" or what == "radio_prev" or what == "radio_louder" or what == "radio_quieter" then
        local r = carRadio(car)
        if not r then return end
        local rc = r.BP_RadioComponent
        if what == "radio_next" then rc:ChangeChannel(1)
        elseif what == "radio_prev" then rc:ChangeChannel(-1)
        elseif what == "radio_louder" then rc:VolUp()
        else rc:VolDown() end
    elseif what == "gear" then
        local to = cm.MyCarGearBox == 1 and 0 or 1
        pcall(function() car:ManualActivate_Gearbox(to, true) end)
        log("PT|car ctl gear -> %d now %d", to, cm.MyCarGearBox)
    end
end)

net.on("g.car.exit", function(pc)
    if common.netMode() ~= "listen" then return end
    local char, car = guestChar(pc), theCar(true)
    if not char or not car or not same(char:GetAttachParentActor(), car) then return end
    local wasDriver = driverGuest == char:GetFullName()
    local door = doorParts(car)[wasDriver and "SLOT_FrontLeftDoor" or "SLOT_FrontRightDoor"]
    if valid(door) then
        door:AttemptOpen()
        common.defer(1500, function() if valid(door) then door:AttemptShut() end end)
    end
    seated[char:GetFullName()] = nil
    if wasDriver then driverGuest = nil end
    char:K2_DetachFromActor(1, 1, 1)
    sitPose(char, false)
    -- the game's own exit spot for the driver (traces for a free, grounded place): a fixed 2.5 m to the left put the guest inside the
    -- ground or a rail on a highway (hand play 2026-10-24, stuck under the road); beside the driver's door when it finds none
    local out
    if os.getenv("PT_MUTATE") ~= "noexitspot" then
        local okE, e = pcall(function()
            local o, f = {}, {}
            car:LocateSafeExitPoint(o, f)
            local t = o.Translation -- a struct out parameter's table gets the struct's fields
            local c = car:K2_GetActorLocation()
            if t and not f.Failed_UsingSafetyTrace and (t.X - c.X) ^ 2 + (t.Y - c.Y) ^ 2 < 600 ^ 2 then out = vec(t.X, t.Y, t.Z + 20) end
        end)
        if not okE then log("PT|car safe exit point error %s", tostring(e)) end
    end
    local from = out and "game" or "offset"
    if not out then
        local p = car:K2_GetActorLocation()
        local r = car:GetActorRightVector()
        out = vec(p.X - r.X * 250, p.Y - r.Y * 250, p.Z + 80)
    end
    local side = "driver"
    if not wasDriver then out, side = passengerSide(car, out) end
    log("PT|car exit spot %.0f,%.0f,%.0f (%s, %s side)", out.X, out.Y, out.Z, from, side)
    local seatAt = toLocal(car, char:K2_GetActorLocation())
    char:K2_SetActorLocation(out, false, {}, true)
    -- the actor stands outside at once; its mesh walks there from the seat past the door
    if not noGlide() and valid(char.Mesh) then
        local spot = toLocal(car, out)
        local mid = doorPoint(car, spot) or spot
        local r = char.Mesh.RelativeLocation
        glides[char:GetFullName()] = { a = char, car = car, actorLease = common.lease(char), carLease = common.lease(car), t0 = os.clock(), times = GLIDE_OUT, mesh = char.Mesh, rel0 = vec(r.X, r.Y, r.Z),
            pts = { seatAt, vec(mid.X, mid.Y, (seatAt.Z + spot.Z) / 2), spot } }
    end
    -- the guest's own pawn is autonomous: the host's move is not replicated to it, so it places itself
    log("PT|car exit ground here %s", groundAt(char, out))
    net.toGuest(pc, "g.car.out", string.format("%.2f|%.2f|%.2f", out.X, out.Y, out.Z))
    char:SetActorEnableCollision(true)
    pcall(function() char.CharacterMovement:SetMovementMode(1, 0) end)
    -- The guest sends no moves while seated, so the server's forced updates move its clock for the guest on and every move
    -- after the exit was dropped for about as long as the ride (frozen on the host, 2026-10-23). Unpossess resets the
    -- server's prediction data, Possess makes the client reset its own (proven live: moves accepted at once).
    -- The possess runs the game's single-player possession, which sees "the player is in the car" (the HOST, driving) and freezes
    -- the guest again: movement off, collision off; on the guest's side it fell through the road on its first jump (hand play
    -- 2026-10-24, host showed MOVE_None and no collision). Walking and collision go back on right after, and once more later.
    local function walk()
        if os.getenv("PT_MUTATE") == "noexitwalk" then return end
        if valid(char) and not valid(char:GetAttachParentActor()) then
            char:SetActorEnableCollision(true)
            -- the game puts a guest who joins while the host drives in the car with its capsule's own collision off (NoCollision,
            -- profile Custom): with the actor's collision back on it still fell through the ground on the host (zoneexit)
            if char.CapsuleComponent:GetCollisionEnabled() == 0 then char.CapsuleComponent:SetCollisionEnabled(3) end -- QueryAndPhysics
            char.CharacterMovement:SetMovementMode(1, 0)
        end
    end
    common.defer(150, function()
        if os.getenv("PT_MUTATE") ~= "nostaleactions" and not (valid(pc) and same(pc.Pawn, char)) then return end
        local ok, e = pcall(function() if valid(pc) and valid(char) then pc:UnPossess(); pc:Possess(char); walk() end end)
        if not ok then log("PT|error car repossess %s", tostring(e)) end
        common.defer(500, function()
            if os.getenv("PT_MUTATE") ~= "nostaleactions" and not (valid(pc) and same(pc.Pawn, char)) then return end
            pcall(walk)
            pcall(function()
                local cap = char.CapsuleComponent
                log("PT|car guest after exit: mode=%d collision=%s capsule=%d static=%d dynamic=%d profile=%s", char.CharacterMovement.MovementMode,
                    tostring(char:GetActorEnableCollision()), cap:GetCollisionEnabled(), cap:GetCollisionResponseToChannel(0), cap:GetCollisionResponseToChannel(1),
                    cap:GetCollisionProfileName():ToString())
            end)
        end)
    end)
    log("PT|car guest left the car")
    ov.post(ov.other() .. " left the car")
end)

net.on("g.car.hello", function() lastSent = nil end)

-- A character spawned while the host drives is attached by the game to the DRIVER's seat (stuck there, X dropped it through the
-- ground, once launched the car; Steam playtest 2026-10-23 #3, #17). Not seated by us: move it to the passenger seat. Checked every
-- frame: within the old 250 ms a guest respawned into the car body tore off doors, a panel and a wheel (hand play 2026-10-24).
LoopInGameThreadWithDelay(16, function()
    if not safety.active() or common.netMode() ~= "listen" or os.getenv("PT_MUTATE") == "nozonefix" then return end
    pcall(function()
        local car = theCar(true)
        if not car then return end
        for _, pc in ipairs(net.guests()) do
            local char = guestChar(pc)
            local on = char and same(char:GetAttachParentActor(), car)
            if char and not on then
                seated[char:GetFullName()] = nil -- left by any path (death, unstick, the game's exit)
                if driverGuest == char:GetFullName() then driverGuest = nil end
            end
            -- the host got in by the driver's door: it takes the wheel, the guest moves over
            if on and driverGuest == char:GetFullName() and carManager().PlayerCarState ~= 0 then
                log("PT|car host takes the wheel, guest to the passenger seat")
                seat(char, car, false)
            end
            if on and not seated[char:GetFullName()] then
                log("PT|car guest attached by the game, moved to the passenger seat")
                seat(char, car)
            end
        end
    end)
end)

-- guest ------------------------------------------------------------------------------------------------------------------

-- X7: chassis kinematic, vehicle controller off, placed every frame by motion-time Hermite interpolation of the replicated
-- transform (ported from the carride scenario's carlib.lua, mode "motion")
local function wrap(a) return (a + 180) % 360 - 180 end
local function hermite(a, b, s, k)
    local h = b[k] - a[k]
    local s2, s3 = s * s, s * s * s
    local h00, h10, h01, h11 = 2 * s3 - 3 * s2 + 1, s3 - 2 * s2 + s, -2 * s3 + 3 * s2, s3 - s2
    local function ax(c, vk) return h00 * a[c] + h10 * h * a[vk] + h01 * b[c] + h11 * h * b[vk] end
    local function ang(c) return a[c] + wrap(b[c] - a[c]) * s end
    return vec(ax("x", "vx"), ax("y", "vy"), ax("z", "vz")), { Pitch = ang("pitch"), Yaw = ang("yaw"), Roll = ang("roll") }
end
local function sample_at(buf, r, k)
    local n = #buf
    if n == 0 then return end
    for i = n - 1, 1, -1 do
        local a, b = buf[i], buf[i + 1]
        if a[k] <= r and r < b[k] then return hermite(a, b, (r - a[k]) / (b[k] - a[k]), k) end
    end
    local z = buf[n]
    if r < buf[1][k] then z = buf[1] end
    local dt = math.max(0, math.min(r - z[k], 0.25))
    return vec(z.x + z.vx * dt, z.y + z.vy * dt, z.z + z.vz * dt), { Pitch = z.pitch, Yaw = z.yaw, Roll = z.roll }
end
-- a motion time is the previous one plus the time the car needed for the distance at its replicated speed, pulled 10 %
-- per snapshot towards the arrival time so it cannot drift
local function motionTime(prev, t, p, v)
    if not prev then return t end
    local h = t - prev.t
    local sp = (math.sqrt(v.X ^ 2 + v.Y ^ 2 + v.Z ^ 2) + math.sqrt(prev.vx ^ 2 + prev.vy ^ 2 + prev.vz ^ 2)) / 2
    if sp > 50 then
        local d = math.sqrt((p.X - prev.x) ^ 2 + (p.Y - prev.y) ^ 2 + (p.Z - prev.z) ^ 2)
        h = math.max(0.3 * h, math.min(3 * h, d / sp))
    end
    local tm = prev.tm + h
    return tm + 0.1 * (t - tm)
end

-- Keep the host's sample times: packet arrival gaps are not the car's travel time.
local carMotion,carClock
RegisterLoadMapPreHook(function()carMotion,carClock=nil,nil end)
net.on("g.motion.car",function(_,data)
    if common.netMode()~="client" or not net.hostSupports("car-motion") or #data>1024 then return end
    local fields={}
    for f in data:gmatch('[^|]+')do fields[#fields+1]=f end
    if #fields~=11 or fields[1]~=net.worldToken() then return end
    for i=2,11 do
        fields[i]=tonumber(fields[i])
        if not fields[i] or fields[i]~=fields[i] or math.abs(fields[i])>1e9 then return end
    end
    if carMotion and fields[2]<=carMotion.source then return end
    local t=os.clock();local offset=t-fields[2]
    if not carClock then log('PT|car host-timed motion active') end
    -- Follow clock drift slowly; a delayed packet must not move the presentation clock abruptly.
    carClock=carClock and carClock+math.max(-0.0005,math.min(0.0005,(offset-carClock)*0.01)) or offset
    carMotion={source=fields[2],tm=fields[2]+carClock,t=t,
        p=vec(fields[3],fields[4],fields[5]),r={Pitch=fields[6],Yaw=fields[7],Roll=fields[8]},v=vec(fields[9],fields[10],fields[11])}
end)
LoopInGameThreadWithDelay(50,function()
    if common.netMode()~="listen" then return end
    local guests=net.guests();local wanted=false
    for _,pc in ipairs(guests)do if net.peerSupports(pc,"car-motion")then wanted=true;break end end
    if not wanted then return end
    local car=theCar(true);if not car then return end
    local p,r,v=car:K2_GetActorLocation(),car:K2_GetActorRotation(),car:GetVelocity()
    local data=string.format('%s|%.6f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f',net.worldToken(),os.clock(),p.X,p.Y,p.Z,r.Pitch,r.Yaw,r.Roll,v.X,v.Y,v.Z)
    for _,pc in ipairs(guests)do if net.peerSupports(pc,"car-motion")then net.toGuest(pc,"g.motion.car",data)end end
end)

-- The guest's camera is set after the actors tick; a car placed from the UE4SS loop came after it, so the view lagged the car one
-- frame and the interior shook against it at speed (POV in car space p5-p95 ~8 uu, 2026-10-30). The car's own ReceiveTick runs in
-- the actor ticks, before the camera: the step runs there, the loop only stands in when the tick stops (mutation nocartick: loop only).
local TICK = os.getenv("PT_MUTATE") ~= "nocartick"
local LOOK = os.getenv("PT_MUTATE") ~= "nocarlook"
local followed, followLoop, followUnmute = nil, nil, nil
local tickStep, tickAt, tickHooked = nil, 0, false
local function hookTick(car)
    if tickHooked or not TICK then return end
    tickHooked = pcall(RegisterHook, car:GetClass():GetFullName():gsub("^%S+ ", "") .. ":ReceiveTick", function(self)
        if tickStep and self:get():GetFullName() == followed then tickAt = os.clock(); tickStep() end
    end)
    log("PT|car follow on the car's tick: %s", tostring(tickHooked))
end

-- Cosmetic constraints are created before the guest's local car is replaced by the host replica.
local cosmeticBindings,cosmeticBodies={},{}
RegisterLoadMapPreHook(function()cosmeticBindings,cosmeticBodies={},{} end)
LoopInGameThreadWithDelay(500,function()
    local mode=common.netMode();if mode~='client'and mode~='listen'then return end
    local car=theCar(mode=='listen');if not car or not valid(car.Chassis)then return end
    local keyBody=car.SM_Wagon_01_KeyPhysics
    if valid(keyBody)then
        local key=common.identity(car)..':key'
        cosmeticBodies[key]={body=common.lease(keyBody),car=common.lease(car),part=common.lease(car),kind='SM_Wagon_01_KeyPhysics',class=car:GetClass():GetFName():ToString()}
    end
    for _,entry in ipairs({{'BP_CarPart_Cosmetic_Bobble_Base_C','PhysicsConstraint','BobbleTop'},
                          {'BP_CarPart_Hanging_Base_C','PhysicsConstraint_Tree','HangingMesh'}})do
        for _,part in ipairs(FindAllOf(entry[1])or{})do
            if valid(part)and same(part:GetAttachParentActor(),car)then
                local key=common.identity(part)
                if key and cosmeticBindings[key]~=common.identity(car)then
                    local constraint,body=part[entry[2]],part[entry[3]]
                    if valid(constraint)and valid(body)then
                        if mode=="client"then constraint:SetConstrainedComponents(body,NONE,car.Chassis,NONE)end
                        cosmeticBindings[key]=common.identity(car)
                        cosmeticBodies[key]={body=common.lease(body),car=common.lease(car),part=common.lease(part),kind=entry[3],class=part:GetClass():GetFName():ToString()}
                    end
                end
            end
        end
    end
end)
local cosmeticMotion=require('itemmotion')
local cosmeticBuffers,cosmeticSerial={},0
local cosmeticStream={BobbleTop='b',HangingMesh='h',SM_Wagon_01_KeyPhysics='k'}
RegisterLoadMapPreHook(function()cosmeticBuffers,cosmeticSerial={},0 end)
LoopInGameThreadWithDelay(50,function()
    if common.netMode()~='listen'then return end
    local guests=net.guests();if #guests==0 then return end
    for _,entry in pairs(cosmeticBodies)do
        local body,part=common.resolve(entry.body),common.resolve(entry.part)
        if body and part then
            local xf=part:GetTransform()
            local p=kml():InverseTransformLocation(xf,body:K2_GetComponentLocation())
            local r=kml():InverseTransformRotation(xf,body:K2_GetComponentRotation())
            cosmeticSerial=cosmeticSerial+1
            local data=string.format('%s|%d|%s|%s|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f',net.worldToken(),cosmeticSerial,entry.kind,entry.class,p.X,p.Y,p.Z,r.Pitch,r.Yaw,r.Roll)
            for _,pc in ipairs(guests)do if net.peerSupports(pc,'cosmetic-motion')then net.toGuest(pc,'g.motion.cosmetic.'..cosmeticStream[entry.kind],data)end end
        end
    end
end)
local function receiveCosmetic(_,data)
    if common.netMode()~='client'or not net.hostSupports('cosmetic-motion')or #data>512 then return end
    local f={};for v in data:gmatch('[^|]+')do f[#f+1]=v end
    if #f~=10 or f[1]~=net.worldToken()or(f[3]~='BobbleTop'and f[3]~='HangingMesh'and f[3]~='SM_Wagon_01_KeyPhysics')or not f[4]:match('^[%w_]+$')then return end
    for i=5,10 do f[i]=tonumber(f[i]);if not f[i]or f[i]~=f[i]or math.abs(f[i])>500 then return end end
    local serial=tonumber(f[2]);if not serial or serial%1~=0 or serial<0 or serial>1e9 then return end
    local b=cosmeticBuffers[f[3]]
    if b and (serial<=b.serial or b.class~=f[4])then if serial<=b.serial then return end;b=nil end
    if not b then b={class=f[4]};cosmeticBuffers[f[3]]=b end
    b.serial,b.at=serial,os.clock()
    local p,r=vec(f[5],f[6],f[7]),{Pitch=f[8],Yaw=f[9],Roll=f[10]}
    local last=b[#b];cosmeticMotion.push(b,p,r,b.at,last and last.p or p,last and last.r or r)
end
for _,suffix in pairs(cosmeticStream)do net.on('g.motion.cosmetic.'..suffix,receiveCosmetic)end
local function renderCosmetics()
    for _,entry in pairs(cosmeticBodies)do
        local b=cosmeticBuffers[entry.kind]
        local body,part=common.resolve(entry.body),common.resolve(entry.part)
        if b and b.class==entry.class and body and part then
            local a,z,u=cosmeticMotion.sample(b,os.clock())
            if a then
                if body:IsSimulatingPhysics(NONE)then body:SetSimulatePhysics(false)end
                local p=vec(a.p.X+(z.p.X-a.p.X)*u,a.p.Y+(z.p.Y-a.p.Y)*u,a.p.Z+(z.p.Z-a.p.Z)*u)
                local r={};for _,k in ipairs({'Pitch','Yaw','Roll'})do r[k]=a.r[k]+wrap(z.r[k]-a.r[k])*u end
                body:K2_SetWorldLocationAndRotation(kml():TransformLocation(part:GetTransform(),p),kml():TransformRotation(part:GetTransform(),r),false,{},true)
            end
        end
    end
end
-- Passenger head sway: the seated guest's camera moves against the car's acceleration on a damped spring (back on
-- throttle, forward on braking, out in turns, down over bumps). The host feels the car through its controls and physics;
-- Retained as a regression control: this synthetic camera offset visibly shifts the cabin relative to the guest.
local SWAY = os.getenv("PT_MUTATE") == "oldpassengersway"
local GAIN, MAXOFF, K, C = 0.012, 10, 247, 22 -- 0.5 g -> ~6 uu; spring 2.5 Hz, damping 0.7
local sw = {}
local function swayCam(me)
    if sw.camOf ~= me:GetFullName() then
        sw.cam, sw.camOf = nil, me:GetFullName()
        for _, c in ipairs(FindAllOf("CameraComponent") or {}) do
            if c:GetFName():ToString() == "FP_Camera" and same(c:GetOwner(), me) then sw.cam = c end
        end
    end
    return sw.cam
end
local function swayReset()
    if valid(sw.cam) and sw.off then pcall(function() sw.cam:K2_SetRelativeLocation(vec(0, 0, 0), false, {}, false) end) end
    sw.off, sw.ov, sw.p, sw.vs, sw.as, sw.t = nil, nil, nil, nil, nil, nil
end
local function sway(car, t)
    if not SWAY then return end
    local pc = localPC()
    local me = pc and pc.Pawn
    if not (valid(me) and same(me:GetAttachParentActor(), car)) then if sw.off then swayReset() end return end
    local cam = swayCam(me)
    if not valid(cam) then return end
    local p, dt = car:K2_GetActorLocation(), sw.t and (t - sw.t) or 0
    sw.t = t
    if not sw.p or dt <= 0 or dt > 0.1 then sw.p, sw.vs, sw.as = p, vec(0, 0, 0), vec(0, 0, 0); sw.off, sw.ov = sw.off or vec(0, 0, 0), sw.ov or vec(0, 0, 0); return end
    local v = vec((p.X - sw.p.X) / dt, (p.Y - sw.p.Y) / dt, (p.Z - sw.p.Z) / dt)
    sw.p = p
    -- velocity and acceleration low-passed (80 ms): finite differences of frame times are noisy
    local f = math.min(1, dt / 0.08)
    local vs = vec(sw.vs.X + (v.X - sw.vs.X) * f, sw.vs.Y + (v.Y - sw.vs.Y) * f, sw.vs.Z + (v.Z - sw.vs.Z) * f)
    local a = vec((vs.X - sw.vs.X) / dt, (vs.Y - sw.vs.Y) / dt, (vs.Z - sw.vs.Z) / dt)
    sw.vs = vs
    sw.as = vec(sw.as.X + (a.X - sw.as.X) * f, sw.as.Y + (a.Y - sw.as.Y) * f, sw.as.Z + (a.Z - sw.as.Z) * f)
    local aL = kml():InverseTransformDirection(car:GetTransform(), sw.as)
    local off, ov = sw.off, sw.ov
    -- A whole frame destabilizes this spring below ~15 FPS, even after the parked car stops moving.
    local steps = math.ceil(dt * 120)
    local h = dt / steps
    for _ = 1, steps do
        for _, k in ipairs({ "X", "Y", "Z" }) do
            local target = math.max(-MAXOFF, math.min(MAXOFF, -aL[k] * GAIN))
            ov[k] = ov[k] + (K * (target - off[k]) - C * ov[k]) * h
            off[k] = math.max(-MAXOFF, math.min(MAXOFF, off[k] + ov[k] * h))
        end
    end
    local w = kml():TransformDirection(car:GetTransform(), off)
    cam:K2_SetRelativeLocation(kml():InverseTransformDirection(cam:GetAttachParent():K2_GetComponentToWorld(), w), false, {}, false)
end

-- Experimental proxy: the host remains authoritative; controls are presentation input on the guest.
RegisterLoadMapPreHook(function() proxyInput = nil end)
net.on("g.motion.physicalcar", function(_, data)
    if common.netMode() ~= "client" or not net.hostSupports("physical-car") then return end
    local epoch, th, brake, steer = data:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    th, brake, steer = tonumber(th), tonumber(brake), tonumber(steer)
    if epoch ~= net.worldToken() or not th or not brake or not steer or th ~= th or brake ~= brake or steer ~= steer
        or math.abs(th) > 1 or math.abs(brake) > 1 or math.abs(steer) > 1 then return end
    proxyInput = {th=th, brake=brake, steer=steer, at=os.clock()}
end)
LoopInGameThreadWithDelay(50, function()
    if common.netMode() ~= "listen" then return end
    local guests, car = net.guests(), theCar(true)
    if #guests == 0 or not car then return end
    local ok, data = pcall(function()
        local v = car.VehicleController
        return string.format("%s|%.3f|%.3f|%.3f", net.worldToken(), v.ThrottleInput, v.BrakeInput, v.SteerInput)
    end)
    if ok then for _, pc in ipairs(guests) do if net.peerSupports(pc, "physical-car") then net.toGuest(pc, "g.motion.physicalcar", data) end end end
end)

local function follow(car)
    if followLoop then CancelDelayedAction(followLoop) end
    if followUnmute then followUnmute() end
    pcall(function() car.Chassis:SetSimulatePhysics(false) end)
    pcall(function() car.VehicleController:SetComponentTickEnabled(false) end)
    local buf, gaps, last, delay, target = {}, {}, nil, 0.1, 0.1
    -- placed on the last sample's end point: nothing to do until the host's car moves again (a parked car cost the guest this
    -- loop's full price every frame, ~0.5 ms; part of 1-4 s a minute in the rendered profile, 2026-10-24)
    local settled = false
    local lookYaw = car:K2_GetActorRotation().Yaw
    local name = car:GetFullName()
    log("PT|car follow %s", name)
    followed = name
    local physical, previousAt, stoppedAt, poseMuted = false, os.clock(), nil, false
    local carAddress=car:GetAddress()
    followUnmute=function() if poseMuted then PTNative_Unmute(carAddress);poseMuted=false end end
    local function step()
        local ok, err = pcall(function()
            local t, rm = os.clock(), car.ReplicatedMovement -- os.clock: wall time on Windows, no engine call each frame
            local dt = math.min(0.1, math.max(0, t - previousAt)); previousAt = t
            local enabled = M.physicalProxyActive()
            if enabled ~= physical then
                physical = enabled
                car.Chassis:SetSimulatePhysics(physical)
                car.VehicleController:SetComponentTickEnabled(physical)
                log("PT|car experimental physical proxy=%s", tostring(physical))
            end
            if physical then
                local vc = car.VehicleController
                vc.ThrottleInput, vc.BrakeInput, vc.SteerInput = proxyInput.th, proxyInput.brake, proxyInput.steer
                local v = rm.LinearVelocity
                if math.abs(proxyInput.th) < 0.01 and v.X^2 + v.Y^2 + v.Z^2 < 25 then
                    stoppedAt = stoppedAt or t
                    if t - stoppedAt >= 1 and os.getenv("PT_MUTATE") ~= "nostationaryguard" then
                        car.Chassis:SetPhysicsLinearVelocity(vec(0, 0, 0), false, NONE)
                        car.Chassis:SetPhysicsAngularVelocityInDegrees(vec(0, 0, 0), false, NONE)
                    end
                else stoppedAt = nil end
            else
                stoppedAt = nil
            end
            local motion=net.hostSupports("car-motion") and carMotion or nil
            -- Only the negotiated visual follower owns this car's pose; raw OnRep writes bypass its buffer.
            if motion and not physical and not poseMuted and PTNative_Mute and os.getenv('PT_MUTATE')~='nativecarpose' then
                poseMuted=PTNative_Mute(carAddress,'OnRep_ReplicatedMovement')
            elseif physical and poseMuted then
                PTNative_Unmute(car:GetAddress());poseMuted=false
            end
            if motion and last and not last.source then buf,gaps,last={},{},nil end
            local p = motion and motion.p or rm.Location
            local fresh = not last or (motion and motion.source~=last.source) or (not motion and (p.X ~= last.x or p.Y ~= last.y or p.Z ~= last.z))
            if not fresh and settled and not physical then return end
            if fresh then
                settled = false
                local r, v = motion and motion.r or rm.Rotation, motion and motion.v or rm.LinearVelocity
                local tm = motion and motion.tm or motionTime(last, t, p, v)
                if last then
                    table.insert(gaps, t - last.t)
                    if #gaps > 60 then table.remove(gaps, 1) end
                    local s = {}
                    for i, g in ipairs(gaps) do s[i] = g end
                    table.sort(s)
                    target = math.max(0.1, math.min(0.25, 1.5 * s[math.ceil(#s * 0.95)] + 0.02))
                else
                    delay = target
                end
                last = { t = t, tm = tm, source=motion and motion.source, x = p.X, y = p.Y, z = p.Z, vx = v.X, vy = v.Y, vz = v.Z, pitch = r.Pitch, yaw = r.Yaw, roll = r.Roll }
                table.insert(buf, last)
                if #buf > 64 then table.remove(buf, 1) end
            end
            delay = delay + (target - delay) * 0.01
            local to, rot = sample_at(buf, t - delay, "tm")
            if to then
                if physical then
                    to = kml():VInterpTo(car:K2_GetActorLocation(), to, dt, 10)
                    rot = kml():RInterpTo(car:K2_GetActorRotation(), rot, dt, 10)
                end
                local cosmeticPose={}
                if not physical and os.getenv('PT_MUTATE')~='nocosmeticcarry'then
                    local before=car:GetTransform()
                    for key,entry in pairs(cosmeticBodies)do
                        local body=common.resolve(entry.body)
                        if not body or not common.resolve(entry.car)then cosmeticBodies[key]=nil
                        elseif same(common.resolve(entry.car),car) and not cosmeticBuffers[entry.kind]then
                            cosmeticPose[#cosmeticPose+1]={body=body,relative=kml():MakeRelativeTransform(body:K2_GetComponentToWorld(),before)}
                        end
                    end
                end
                car:K2_SetActorLocationAndRotation(to, rot, false, {}, true)
                local after=#cosmeticPose>0 and car:GetTransform()
                for _,entry in ipairs(cosmeticPose)do
                    entry.body:K2_SetWorldTransform(kml():ComposeTransforms(entry.relative,after),false,{},true)
                end
                local turn = wrap(rot.Yaw - lookYaw)
                lookYaw = rot.Yaw
                local pc = localPC()
                if LOOK and math.abs(turn) > 0.0001 and pc
                    and valid(pc.Pawn) and same(pc.Pawn:GetAttachParentActor(), car) then
                    -- ControlRotation is world-space; carry the passenger's current look through the car's turn.
                    local view = pc:GetControlRotation()
                    pc:SetControlRotation({ Pitch = view.Pitch, Yaw = view.Yaw + turn, Roll = view.Roll })
                end
            end
            -- past the last sample by more than sample_at's 0.25 s of extrapolation: the pose no longer changes
            if last and t - delay > last.tm + 0.3 then settled = true end
        end)
        if not ok then log("PT|error car follow %s", tostring(err)) end
        local okc,errc=pcall(renderCosmetics);if not okc then log("PT|error cosmetic render %s",tostring(errc))end
        local oks, errs = pcall(sway, car, os.clock())
        if not oks and not sw.err then sw.err = true; log("PT|error car sway %s", tostring(errs)) end
    end
    tickStep = step
    hookTick(car)
    followLoop = LoopInGameThreadWithDelay(1, function()
        if not valid(car) then followUnmute();followUnmute=nil;CancelDelayedAction(followLoop); followLoop, followed, tickStep = nil, nil, nil; pcall(swayReset); return end
        if os.clock() - tickAt > 0.2 then step() end
    end)
end

-- the guest's own copy of the car and its part actors
local function dedupe(car)
    for _, c in ipairs(localCopies()) do
        local n = 0
        for _, a in ipairs(FindAllOf("Actor") or {}) do
            if valid(a) and same(a:GetAttachParentActor(), c) then a:K2_DestroyActor(); n = n + 1 end
        end
        log("PT|car destroying local copy %s (%d parts)", c:GetFullName(), n)
        c:K2_DestroyActor()
    end
    local cm = carManager()
    if cm and not same(cm.NewCarActor, car) then cm.NewCarActor = car end
end

-- X8: once the host attached us, hold the replicated offset; the pawn arrives attached but far off its seat
local riding = nil
if os.getenv("PT_MUTATE") ~= "noridefree" then RegisterLoadMapPreHook(function() if riding then CancelDelayedAction(riding.loop); riding = nil end end) end
local function seatErr(char, car, off)
    local o = char.AttachmentReplication.LocationOffset
    if off and not same(char.AttachmentReplication.AttachParent, car) then o = off end
    return dist(toLocal(car, char:K2_GetActorLocation()), vec(o.X, o.Y, o.Z))
end
local function stopRide(char)
    if riding then CancelDelayedAction(riding.loop) end
    riding = nil
    if valid(char) then
        sitPose(char, false)
        pcall(function() char:SetActorEnableCollision(true) end)
        pcall(function() char.CharacterMovement:SetComponentTickEnabled(true); char.CharacterMovement:SetMovementMode(1, 0) end)
    end
end
net.on("g.car.out", function(_, data)
    if common.netMode() ~= "client" or os.getenv("PT_MUTATE") == "noexitfix" then return end
    local me = localPC() and localPC().Pawn
    local x, y, z = data:match("^([^|]*)|([^|]*)|(.*)$")
    if not valid(me) or not x then return end
    local spot, car = vec(tonumber(x), tonumber(y), tonumber(z)), theCar(false)
    local seatAt = car and toLocal(car, me:K2_GetActorLocation())
    pcall(function() me:K2_DetachFromActor(1, 1, 1) end)
    stopRide(me)
    local function placed()
        if not valid(me) then return end
        me:K2_SetActorLocation(spot, false, {}, true)
        pcall(function() me:SetActorEnableCollision(true); me.CharacterMovement:SetMovementMode(1, 0) end)
        log("PT|car exit ground on the guest %s", groundAt(me, spot))
    end
    if car and not noGlide() then
        -- out past the door to the spot the host has us at (1.1 s), then walking (stopRide put movement back on: off again meanwhile)
        local l = toLocal(car, spot)
        local mid = doorPoint(car, l) or l
        glideFlags(me, true)
        glides[me:GetFullName()] = { a = me, car = car, actorLease = common.lease(me), carLease = common.lease(car), t0 = os.clock(), times = GLIDE_OUT, yaw0 = me:K2_GetActorRotation().Yaw,
            yaw1 = car:K2_GetActorRotation().Yaw + 90, pts = { seatAt, vec(mid.X, mid.Y, (seatAt.Z + l.Z) / 2), l }, after = placed }
    else
        placed()
    end
    -- the camera and the controls stayed with the car: camera frozen, no walking (local playtest 2026-10-22)
    local pc = localPC()
    pcall(function() pc:ResetIgnoreInputFlags() end)
    pcall(function() pc:SetIgnoreLookInput(false); pc:SetIgnoreMoveInput(false) end)
    pcall(function() pc:SetViewTargetWithBlend(me, 0, 0, 0, false) end)
    pcall(function() me:EnableInput(pc) end)
    pcall(function() StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(pc) end)
    local okv, view = pcall(function() return pc:GetViewTarget():GetFName():ToString() end)
    log("PT|car guest placed outside at %s,%s,%s view=%s", x, y, z, okv and view or "?")
end)

local function ride(char, car, off)
    local cm = char.CharacterMovement
    pcall(function() cm:StopMovementImmediately(); cm:DisableMovement(); cm:SetComponentTickEnabled(false) end)
    pcall(function() char:SetActorEnableCollision(false) end)
    local function place()
        local o = char.AttachmentReplication.LocationOffset
        -- the host's seat message comes before the replicated offset: its offset until the replicated one arrives
        if off and not same(char.AttachmentReplication.AttachParent, car) then o = off end
        char:K2_SetActorRelativeLocation(vec(o.X, o.Y, o.Z), false, {}, true)
    end
    place()
    sitPose(char, true)
    local fixes = 0
    local loop
    loop = LoopInGameThreadWithDelay(1, function()
        -- the pawn and car of a world that was freed: reading them is an access violation pcall cannot catch (guest rejoin crash)
        if os.getenv("PT_MUTATE") ~= "noridefree" and not (valid(char) and valid(car)) then CancelDelayedAction(loop); riding = nil; return end
        local ok = pcall(function()
            if not same(char:GetAttachParentActor(), car) then
                log("PT|car left the seat (fixes=%d)", fixes)
                stopRide(char)
                return
            end
            if seatErr(char, car, off) > 1 then
                fixes = fixes + 1
                if fixes <= 3 then log("PT|car seat guard n=%d", fixes) end
                place()
            end
        end)
        if not ok then CancelDelayedAction(loop); riding = nil end
    end)
    riding = { loop = loop, car = car:GetFullName() }
    log("PT|car riding %s offset=%.1f,%.1f,%.1f", car:GetFullName(), char.AttachmentReplication.LocationOffset.X,
        char.AttachmentReplication.LocationOffset.Y, char.AttachmentReplication.LocationOffset.Z)
end
-- the host seated us (g.car.seat, sent with its attach): attach here at once instead of waiting seconds for the replicated attachment
local function seatMe(me, car, off)
    stopGlide(me) -- our own entry glide ends here at the latest
    local r = car:K2_GetActorRotation()
    me:K2_SetActorRotation({ Pitch = 0, Yaw = r.Yaw, Roll = 0 }, true) -- facing forward, as the host seats the body
    me:K2_AttachToActor(car, NONE, 1, 1, 1, false)
    ride(me, car, off)
end
local seatConfirmedAt = -math.huge -- guest: now() of the host's last g.car.seat
net.on("g.car.seat", function(_, data)
    if common.netMode() ~= "client" then return end
    seatConfirmedAt = now()
    local x, y, z = data:match("^([^,]*),([^,]*),(.*)$")
    local me, car = localPC() and localPC().Pawn, theCar(false)
    if not (x and valid(me) and car) then return end
    local off = vec(tonumber(x), tonumber(y), tonumber(z))
    if same(me:GetAttachParentActor(), car) then -- seated by our own prediction: moved only if the host chose the other seat
        if riding and dist(toLocal(car, me:K2_GetActorLocation()), off) > 20 then
            CancelDelayedAction(riding.loop); riding = nil
            ride(me, car, off)
            log("PT|car moved to the other seat by the host at %.1f,%.1f,%.1f", off.X, off.Y, off.Z)
        end
        return
    end
    seatMe(me, car, off)
    log("PT|car seated by the host message at %.1f,%.1f,%.1f", off.X, off.Y, off.Z)
end)

-- Prediction: the guest walks in and sits down at once, as the host does the same; the host's g.car.seat confirms it. Waiting for the
-- host's walk-in to end first made every entry take 2.1-2.3 s on the guest's screen (friend session 2026-11-01). No confirmation
-- 4 s after we sat (the host refused: car gone, guest elsewhere on the host): stand up by the door again.
local function wheelTaken(car, me) -- guest: another body sits on the driver's side of the car (the host driving)
    for _, c in ipairs(FindAllOf("BaseCharacter") or {}) do
        if valid(c) and not same(c, me) and same(c:GetAttachParentActor(), car) and toLocal(car, c:K2_GetActorLocation()).Y < 0 then return true end
    end
    return false
end
local function predictEnter(me, car, driverDoor)
    if noGlide() or os.getenv("PT_MUTATE") == "nopredict" or not (valid(me) and car) or riding or gliding(me) or valid(me:GetAttachParentActor()) then return end
    local t0 = now()
    local meLease, carLease = common.lease(me), common.lease(car)
    local spot = driverDoor and os.getenv("PT_MUTATE") ~= "noguestdrive" and not wheelTaken(car, me) and DRIVER or PASSENGER
    glideIn(me, car, spot, function()
        if not (common.resolve(meLease) and common.resolve(carLease)) then return end
        if os.getenv("PT_MUTATE") ~= "nopredictseat" and seatConfirmedAt < t0 and not valid(me:GetAttachParentActor()) then
            seatMe(me, car, spot)
            log("PT|car seated by prediction")
        end
        common.defer(4000, function() pcall(function()
            if seatConfirmedAt >= t0 or not (common.resolve(meLease) and common.resolve(carLease))
                or not same(localPC() and localPC().Pawn, me) or same(me.AttachmentReplication.AttachParent, car) then return end
            if same(me:GetAttachParentActor(), car) then pcall(function() me:K2_DetachFromActor(1, 1, 1) end) end
            stopRide(me)
            local d = doorPoint(car, PASSENGER)
            if d then me:K2_SetActorLocation(toWorld(car, vec(d.X, d.Y, d.Z + 20)), false, {}, true) end
            me:SetActorEnableCollision(true); me.CharacterMovement:SetMovementMode(1, 0)
            log("PT|car seat not confirmed by the host: standing up again")
        end) end)
    end)
end

-- Keep a short-lived target while the installed part's component is being created.
local healthTargets = {}
RegisterLoadMapPreHook(function() healthTargets = {} end)
local function retryHealth(name, arch, value)
    local target = { arch = arch, value = value, tries = 0 }
    healthTargets[name] = target
    local function retry()
        if healthTargets[name] ~= target or common.netMode() ~= "client" then return end
        target.tries = target.tries + 1
        local cm, cont = carManager(), equipped()
        local item
        if cont then cont.Slots:ForEach(function(_, e)
            local slot = e:get()
            if slotName(slot) == name then item = itemOf(slot) end
        end) end
        if item and archPath(item) ~= arch then healthTargets[name] = nil; return end
        if not (M.holdSlot and M.holdSlot(name)) and item and cm then
            local m = manifestation(cm, name)
            local c = m and propComps(m)
            local h = c and readPart(c)
            if h and math.abs(h - value) <= 0.05 then healthTargets[name] = nil; return end
            if h and valid(c.h) then c.h:SetHealth(value) end
        end
        if target.tries < 12 then common.defer(250, retry) else healthTargets[name] = nil end
    end
    common.defer(250, retry)
end

-- apply the host's state to our own car inventory (the manifestations on the replicated car follow it)
local function applyState(data)
    local cm, cont = carManager(), equipped()
    if not cm or not cont then return end
    local car = theCar(false)
    local head, parts, count, n, swing, hostKey = nil, {}, 0, nil, {}, nil
    for line in data:gmatch("[^\n]+") do
        local f = {}
        for x in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
        if f[1] == "H" then head = f
        elseif f[1] == "C" then hostKey = f[2]
        elseif f[1] == "P" then parts[f[2]] = { arch = f[3], h = tonumber(f[4]), f = tonumber(f[5]), b = tonumber(f[6]) }; count = count + 1
        elseif f[1] == "R" then swing[f[2]] = { vec(tonumber(f[3]), tonumber(f[4]), tonumber(f[5])), { Pitch = tonumber(f[6]), Yaw = tonumber(f[7]), Roll = tonumber(f[8]) } }
        elseif f[1] == "E" then n = tonumber(f[2]) end
    end
    -- a truncated message must never look like "the host has no parts"
    if not head or n ~= count then log("PT|error car state message incomplete"); return end
    if hostKey and hostKey ~= wheelHostKey then wheelHostKey, wheelBuffer = hostKey, {} end
    local changed = 0
    cont.Slots:ForEach(function(_, e)
        local slot = e:get()
        local name = slotName(slot)
        local want, it = parts[name], itemOf(slot)
        if M.holdSlot and M.holdSlot(name) then return end -- the guest just swapped this part itself (guestswap.lua)
        if not want then
            healthTargets[name] = nil
            if it then slot:RemoveAllItems({}); changed = changed + 1; log("PT|car part removed %s", name); if ov.settled() then ov.post("%d car part{s} changed by the host", "info", "carpart") end end
            return
        end
        if not it or archPath(it) ~= want.arch then
            local arch = archObject(want.arch)
            if not arch then log("PT|error car archetype not found %s", want.arch); return end
            if it then slot:RemoveAllItems({}) end
            slot:SetItem(arch:CreateInstance(UEHelpers.GetWorldContextObject(), 0), {})
            changed = changed + 1
            log("PT|car part installed %s %s", name, want.arch)
            if ov.settled() then ov.post("%d car part{s} changed by the host", "info", "carpart") end
        end
        if want.h or want.f or want.b then
            local m = manifestation(cm, name)
            if m then
                local c = propComps(m)
                local h, f, b = readPart(c)
                if want.h and (not h or math.abs(h - want.h) > 0.05) then
                    if h and os.getenv("PT_MUTATE") ~= "healthretryonly" then c.h:SetHealth(want.h); changed = changed + 1 end
                    retryHealth(name, want.arch, want.h)
                else healthTargets[name] = nil end
                if want.f and f and math.abs(f - want.f) > 0.05 then c.f["Set Fuel"](c.f, want.f); changed = changed + 1 end
                if want.b and b and math.abs(b - want.b) > 0.05 then c.b["Set Battery"](c.b, want.b); changed = changed + 1 end
            elseif want.h then retryHealth(name, want.arch, want.h) end
        else healthTargets[name] = nil end
    end)
    if changed > 0 then
        pcall(function() cm:UpdateAggregateFuel() end)
        pcall(function() cm:UpdateAggregateBattery() end)
    end
    -- car-level state
    local ign, gear, lights, hb, doors = tonumber(head[2]), tonumber(head[3]), head[4] == "1", head[5] == "1", tonumber(head[6])
    if car then
        if cm.CarIgnitionState ~= ign then pcall(function() car:ManualSetIgnition_NoAnim(ign) end) end
        if cm.MyCarGearBox ~= gear then pcall(function() car:ManualActivate_Gearbox(gear, true) end) end
        pcall(function()
            if car.VehicleController:GetParkingBrakeActive() ~= hb then car.VehicleController:SetParkingBrakeActive(hb) end
        end)
    end
    if cm.CarLightsOn ~= lights then pcall(function() cm:SetCarLightsOn(lights) end) end
    if now() < doorHold then doorHeld = data; return end
    doorHeld = nil
    for d = 0, 5 do
        local o = {}
        cm:GetDoorState(d, o)
        local want = (doors >> d) & 1 == 1
        if o.Open ~= want then pcall(function() cm:SetDoorState(d, want) end) end
    end
    if not car then return end
    local ct = car:GetTransform()
    for slot, part in pairs(doorParts(car)) do
        pcall(function()
            local m = part.MainMesh
            local key = part:GetAddress()
            -- the shut pose: where the mesh sits on its part before anything swung it
            if not doorRest[key] and not swing[slot] and not m:IsSimulatingPhysics(FName("None")) then
                local l, r = m.RelativeLocation, m.RelativeRotation
                doorRest[key] = { parent = m.AttachParent, loc = vec(l.X, l.Y, l.Z), rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
            end
            local want = swing[slot]
            if want then
                if net.hostSupports("door-motion") then return end
                if m:IsSimulatingPhysics(FName("None")) then m:SetSimulatePhysics(false) end
                m:K2_SetWorldLocationAndRotation(kml():TransformLocation(ct, want[1]), kml():TransformRotation(ct, want[2]), false, {}, true)
                doorSwung[key] = true
            elseif doorSwung[key] and doorRest[key] then
                local rest = doorRest[key]
                if m:IsSimulatingPhysics(FName("None")) then m:SetSimulatePhysics(false) end
                if valid(rest.parent) then m:K2_AttachToComponent(rest.parent, FName("None"), 0, 0, 0, false) end
                m:K2_SetRelativeLocationAndRotation(rest.loc, rest.rot, false, {}, true)
                doorSwung[key] = nil
            end
        end)
    end
    net.baselineComplete("car")
end

-- guest: its own open/close of the host's car door goes to the host, which runs the same AttemptOpen on its part;
-- the result comes back with the car state
net.on("g.car.door", function(pc, data)
    if common.netMode() ~= "listen" then return end
    local slot, verb = data:match("^([^|]*)|?(.*)$")
    local pawn = valid(pc) and pc.Pawn
    if slot == "SLOT_Hood" and valid(pawn) and same(pawn:GetAttachParentActor(), theCar(true)) then return end
    local shut = verb == "shut"
    local car = theCar(true)
    local part = car and doorParts(car)[slot]
    if not valid(part) then log("PT|car door intent: no door at %s", tostring(slot)); return end
    pcall(function() if shut then part:AttemptShut() else part:AttemptOpen() end end)
    entryDoor = not shut and slot == "SLOT_FrontRightDoor" and { part = part, at = now() } or nil
    log("PT|car door intent %s %s applied", slot, shut and "shut" or "open")
end)

net.on("g.car.s", function(_, data)
    if common.netMode() ~= "client" then return end
    local ok, err = pcall(applyState, data)
    if not ok then log("PT|error car apply %s", tostring(err)) end
end)

-- C1: the game's door interaction ends in the door's EnterCar, then a broadcast of CommandEnterCar to every character of
-- this process, ours included (muted below). The intent goes to the host.
local function sendEnter(seat)
    local char = localPC() and localPC().Pawn
    log("PT|car enter intent %s sent=%s", seat or "P", tostring(net.toHost("g.car.enter", seat)))
    return char
end
local function sendExit()
    log("PT|car exit intent sent=%s", tostring(net.toHost("g.car.exit")))
end

local hooked, ctlWanted, aimed = false, false, nil
local function hookAll()
    if hooked then return end
    local ok, err = pcall(RegisterHook, "/Game/Gameplay/Inventory/Items/Car/Doors/BP_CarPart_Door_Base.BP_CarPart_Door_Base_C:EnterCar", function(self)
        local okc, e = pcall(function()
            if common.netMode() ~= "client" then return end
            local me = sendEnter("D")
            pcall(predictEnter, me, theCar(false), true)
            -- the door flow set this and waits for the (muted) enter to end it
            local door = self:get() -- a hook parameter must not outlive the callback
            common.defer(500, function() pcall(function() if valid(door) then door.PlayerStartedEnteringCar = false end end) end)
        end)
        if not okc then log("PT|error car door hook %s", tostring(e)) end
    end)
    if not ok then log("PT|error car hook EnterCar %s", tostring(err)); return end
    -- shutting too: a door the host opened is posed on the guest with its physics off, so a local shut did nothing (2026-10-23)
    for fn, suffix in pairs({ AttemptOpen = "", AttemptShut = "|shut" }) do
        for _, path in ipairs({DOORBP, HOODBP}) do
        local okd, errd = pcall(RegisterHook, path .. fn, function(self)
            pcall(function()
                if common.netMode() ~= "client" then return end
                local part, car = self:get(), theCar(false)
                if not (valid(part) and car and same(part:GetAttachParentActor(), car)) then return end
                local slot = part.RootComponent.AttachParent:GetFName():ToString()
                if path == HOODBP and slot ~= "SLOT_Hood" then return end
                if slot == "SLOT_Hood" and riding then return end
                -- only our own physics swing needs protecting; a door the host opened is posed here, its shut animates from the host
                if suffix == "" or part.MainMesh:IsSimulatingPhysics(FName("None")) then doorHold = now() + 1.5 end
                log("PT|car door intent %s%s sent=%s", slot, suffix, tostring(net.toHost("g.car.door", slot .. suffix)))
                -- E opening the passenger's door from outside gets the guest in, as the driver's door does for the driver (the game
                -- itself only enters through the driver's door: the guest walked round to it and sat down on the other side)
                local me = localPC() and localPC().Pawn
                if (slot == "SLOT_FrontRightDoor" or slot == "SLOT_FrontLeftDoor") and riding and os.getenv("PT_MUTATE") ~= "nopassdoorexit" then
                    sendExit()
                    return
                end
                if suffix == "" and slot == "SLOT_FrontRightDoor" and not riding and valid(me) and not gliding(me)
                    and not valid(me:GetAttachParentActor()) and os.getenv("PT_MUTATE") ~= "nopassdoor" then
                    sendEnter()
                    predictEnter(me, car)
                end
            end)
        end)
        if not okd then log("PT|error car hook %s %s", fn, tostring(errd)) end
        end
    end
    hooked = true
    -- leaving: the passenger door (owner 2026-11-04: X went, it is also the radio's next track). E only raises a flag (an
    -- ExecuteInGameThread per press crashed UE4SS when spammed, ping.lua)
    common.onKey("E", function() ctlWanted = true end)
end

-- Use the game's current action mappings for passenger radio controls, including controller bindings.
local radioActions = { ToggleRadio = "radio", Radio_ChannelUp = "radio_next", Radio_ChannelDown = "radio_prev", Radio_VolumeUp = "radio_louder", Radio_VolumeDown = "radio_quieter" }
StaticFindObject("/Script/Engine.Default__InputSettings").ActionMappings:ForEach(function(_, wrapped)
    local binding = wrapped:get()
    local action, key = radioActions[binding.ActionName:ToString()], binding.Key.KeyName:ToString()
    if action then
        common.onKey(key, function()
            if common.netMode() ~= "client" or not riding then return end
            local hm = first("BP_HighlightManager_C")
            if not (hm and hm.Enabled) then return end
            net.toHost("g.car.ctl", action)
        end)
    end
end)

-- Guest driving (owner 2026-11-08): whoever sits at the wheel drives. A guest who got in by the driver's door (car.enter "D")
-- while the host is not driving sits there, and its W/S/A/D/Space drive the host's car through the car's own input handlers
-- (what the test bot's drive does); the host still simulates it, so the guest sees it through the usual follow. The guest turns
-- the key and shifts with E. The host rides by E on the passenger door, or takes the wheel by the driver's door.
-- shortcut: keyboard only, physics stay on the host (guest input lag = ping + follow delay); gamepad axes or guest-side physics next
local DRIVE_KEYS = { W = true, S = true, A = true, D = true, SpaceBar = true }
local keyStructs = {}
for k in pairs(DRIVE_KEYS) do keyStructs[k] = { KeyName = FName(k) } end
local sentDrive, sentDriveAt = "0 0 0 0", 0
LoopInGameThreadWithDelay(50, function()
    if common.netMode() ~= "client" or not riding or os.getenv("PT_MUTATE") == "noguestdrive" then return end
    local pc = localPC()
    if not pc then return end
    local ok, d = pcall(function()
        local function down(k) return pc:IsInputKeyDown(keyStructs[k]) and 1 or 0 end
        return string.format("%d %d %d %d", down("W"), down("S"), down("D") - down("A"), down("SpaceBar"))
    end)
    if not ok then return end
    -- on change, and every 200 ms while held (the host lets go of inputs it has not heard for 500 ms)
    if d ~= sentDrive or (d ~= "0 0 0 0" and os.clock() - sentDriveAt > 0.2) then
        sentDrive, sentDriveAt = d, os.clock()
        net.toHost("g.car.drive", d)
    end
end)

local guestDrive = nil -- host: { th, br, st, hb, at }
net.on("g.car.drive", function(pc, data)
    if common.netMode() ~= "listen" or os.getenv("PT_MUTATE") == "noguestdrive" then return end
    local char, car, cm = guestChar(pc), theCar(true), carManager()
    if not (char and car and cm and same(char:GetAttachParentActor(), car)) then return end
    if cm.PlayerCarState ~= 0 or driverGuest ~= char:GetFullName() then return end -- the one at the wheel drives
    local th, br, st, hb = data:match("^(%d) (%d) (%-?%d) (%d)$")
    if not th then return end
    if not guestDrive then log("PT|car guest drives") end
    guestDrive = { th = tonumber(th), br = tonumber(br), st = tonumber(st), hb = tonumber(hb) == 1, at = os.clock() }
end)
LoopInGameThreadWithDelay(16, function()
    if not guestDrive then return end
    local car, cm = theCar(true), carManager()
    local stale = os.clock() - guestDrive.at > 0.5 or not (car and cm) or cm.PlayerCarState ~= 0 or common.netMode() ~= "listen" or not driverGuest
    local g = stale and { th = 0, br = 0, st = 0, hb = false } or guestDrive
    if car then
        pcall(function()
            car:AccelerateBrake(g.th - g.br)
            car:SteerLeftRight(g.st)
            local vc = car.VehicleController
            vc.ThrottleInput, vc.BrakeInput, vc.SteerInput = g.th, g.br, g.st
            vc:SetHandbrakeInput(g.hb)
        end)
    end
    if stale then guestDrive = nil; log("PT|car guest stops driving") end
end)

-- The host as passenger: E on the passenger door (from outside: sit down; inside: get out, also E with nothing highlighted).
-- The game only enters through the driver's door, so the host is seated like a guest: attached, movement and collision off,
-- in-car share 1 (the radiation shield, see carfeel.lua). E only raises a flag (onKey runs off the game thread).
local hostE = false
common.onKey("E", function() if common.netMode() == "listen" then hostE = true end end)
local function onCar(a, car) -- a door, or its handle on the door, of this car
    for _ = 1, 3 do
        if not valid(a) then return false end
        if same(a, car) then return true end
        a = a:GetAttachParentActor()
    end
    return false
end
local function shutPassengerDoor(car)
    local door = doorParts(car).SLOT_FrontRightDoor
    common.defer(1200, function() pcall(function() if valid(door) then door:AttemptShut() end end) end)
end
local function hostSitPct(me, v) pcall(function() me.PercentInCar = v end) end
local function hostStand(me, car)
    hostRiding = false
    pcall(function() me:K2_DetachFromActor(1, 1, 1) end)
    sitPose(me, false)
    local l = toLocal(car, me:K2_GetActorLocation())
    local d = doorPoint(car, l) or l
    me:K2_SetActorLocation(toWorld(car, vec(d.X, d.Y + 60, d.Z + 40)), false, {}, true)
    me:SetActorEnableCollision(true)
    pcall(function() me.CharacterMovement:SetMovementMode(1, 0) end)
    hostSitPct(me, 0)
    log("PT|car host left the passenger seat")
end
local function hostSit(me, car)
    hostRiding = true
    glideIn(me, car, PASSENGER, function()
        if not (valid(me) and valid(car)) then hostRiding = false return end
        glideFlags(me, false)
        local r = car:K2_GetActorRotation()
        me:K2_SetActorLocationAndRotation(toWorld(car, PASSENGER), { Pitch = 0, Yaw = r.Yaw, Roll = 0 }, false, {}, true)
        me:K2_AttachToActor(car, NONE, 1, 1, 1, false)
        sitPose(me, true)
        hostSitPct(me, 1)
        log("PT|car host seated as passenger")
    end)
end
LoopInGameThreadWithDelay(16, function()
    if common.netMode() ~= "listen" then hostE = false; return end
    local pressed = hostE
    hostE = false
    if os.getenv("PT_MUTATE") == "noguestdrive" then return end
    local ok, err = pcall(function()
        local pc, car, cm = localPC(), theCar(true), carManager()
        local me = pc and pc.Pawn
        if not (valid(me) and car and cm) then return end
        local attached = same(me:GetAttachParentActor(), car)
        if hostRiding and not attached and not gliding(me) then hostRiding = false; hostSitPct(me, 0) end -- died, respawned, map
        if hostRiding and attached and car.Chassis then
            -- held at the seat: a moving car must not leave the body behind its own attachment
            if dist(toLocal(car, me:K2_GetActorLocation()), PASSENGER) > 5 then me:K2_SetActorRelativeLocation(PASSENGER, false, {}, true) end
        end
        if not pressed or gliding(me) then return end
        local hm = first("BP_HighlightManager_C")
        local h = hm and hm.CurrentHighlight
        local owner = valid(h) and h:GetOwner() or nil
        -- the passenger's front door (or its handle): car-local right side, ahead of the rear doors
        local side = owner and not same(owner, car) and onCar(owner, car) and toLocal(car, owner:K2_GetActorLocation()) or nil
        if hostRiding and attached and (not valid(h) or (side and side.Y > 30)) then
            hostStand(me, car)
            shutPassengerDoor(car)
        elseif not hostRiding and not attached and cm.PlayerCarState == 0 and side and side.Y > 30 and side.X > -80
            and dist(me:K2_GetActorLocation(), car:K2_GetActorLocation()) < 400 then
            for _, gpc in ipairs(net.guests()) do -- the seat is taken: a guest passenger moves to the wheel
                local g = guestChar(gpc)
                if g and same(g:GetAttachParentActor(), car) and driverGuest ~= g:GetFullName() then seat(g, car, true) end
            end
            hostSit(me, car)
            shutPassengerDoor(car)
        end
    end)
    if not ok then log("PT|error car host passenger %s", tostring(err)) end
end)

-- The guest remains a character, so enable the dashboard's native highlights for that state; E is applied by the host.
local AIM_DEG, AIM_REACH = 12, 200
local controlHighlights = {}
local function aimAt(pc)
    local cam = pc.PlayerCameraManager
    local from, fwd = cam:GetCameraLocation(), kml():GetForwardVector(cam:GetCameraRotation())
    local best, bestCos = nil, math.cos(math.rad(AIM_DEG))
    for what, h in pairs(controlHighlights) do
        local comp = valid(h) and h.HighlightCollision:GetArrayNum() > 0 and h.HighlightCollision[1]
        if valid(comp) then
            local p = comp:K2_GetComponentLocation()
            local d = { X = p.X - from.X, Y = p.Y - from.Y, Z = p.Z - from.Z }
            local len = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
            local c = len > 1 and (d.X * fwd.X + d.Y * fwd.Y + d.Z * fwd.Z) / len or -1
            if len < AIM_REACH and c > bestCos then best, bestCos = what, c end
        end
    end
    return best
end

-- F8 on the guest: log what holds the controls, then give them back (camera and walking stayed locked after an exit,
-- local playtest 2026-10-22, cause not found yet)
local unstickWanted = false
common.onKey("F8", function() unstickWanted = true end)
local function unstick()
    local pc = localPC()
    local me = pc and pc.Pawn
    if not valid(me) then return end
    local s = {}
    local function probe(k, f) local ok, v = pcall(f); s[#s + 1] = k .. "=" .. (ok and tostring(v) or "?") end
    probe("look", function() return pc:IsLookInputIgnored() end)
    probe("move", function() return pc:IsMoveInputIgnored() end)
    probe("view", function() return pc:GetViewTarget():GetFName():ToString() end)
    probe("mode", function() return me.CharacterMovement.MovementMode end)
    probe("tick", function() return me.CharacterMovement:IsComponentTickEnabled() end)
    probe("parent", function() local p = me:GetAttachParentActor(); return p:IsValid() and p:GetFName():ToString() or "none" end)
    probe("riding", function() return riding ~= nil end)
    log("PT|car unstick %s", table.concat(s, " "))
    -- seated, it also gets out: the passenger door is the only other way since X went, and a door can be removed or broken off
    if riding and common.netMode() == "client" then sendExit() end
    -- the controller looked normal when stuck (2026-10-22): dump the game's own car/seat/input state on the character and its manager
    local function dump(tag, o)
        if not valid(o) then return end
        local out = {}
        pcall(function()
            local cls = o:GetClass()
            while cls and cls:IsValid() do
                cls:ForEachProperty(function(p)
                    local n = p:GetFName():ToString()
                    if n:find("Car") or n:find("Seat") or n:find("Driv") or n:find("Input") or n:find("Camera") or n:find("State") or n:find("Mode") or n:find("Lock") then
                        local ok, v = pcall(function() return o[n] end)
                        if ok and type(v) ~= "userdata" then out[#out + 1] = n .. "=" .. tostring(v)
                        elseif ok and v and v.IsValid and v:IsValid() and v.GetFName then out[#out + 1] = n .. "=" .. v:GetFName():ToString() end
                    end
                end)
                cls = cls:GetSuperStruct()
            end
        end)
        log("PT|car unstick %s %s", tag, table.concat(out, " "))
    end
    dump("char", me)
    dump("manager", FindFirstOf("BP_MainCharacterManager_C"))
    if riding and not same(me:GetAttachParentActor(), theCar(false)) then stopRide(me) end
    if not riding then
        pcall(function() me:K2_DetachFromActor(1, 1, 1) end)
        stopRide(me)
    end
    pcall(function() pc:ResetIgnoreInputFlags() end)
    pcall(function() pc:SetViewTargetWithBlend(me, 0, 0, 0, false) end)
    pcall(function() me:EnableInput(pc) end)
    pcall(function() StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_GameOnly(pc) end)
end

local helloFor = nil
local function guestTick()
    if doorHeld and now() >= doorHold then
        local held = doorHeld
        doorHeld = nil
        local ok, err = pcall(applyState, held)
        if not ok then log("PT|error car apply %s", tostring(err)) end
    end
    if unstickWanted then
        unstickWanted = false
        local ok, err = pcall(unstick)
        if not ok then log("PT|error car unstick %s", tostring(err)) end
        if ok then ov.post("Controls reset", "info", "unstick") end
    end
    local car = theCar(false)
    if not car then return end
    hookAll()
    local c0 = #localCopies()
    if c0 > 0 then dedupe(car) end
    if followed ~= car:GetFullName() then follow(car) end
    moveArc(car)
    local pc = localPC()
    local me = pc and pc.Pawn
    if valid(me) then
        -- our own enter and exit must not run locally; they are the host's job (a local exit crashed AC_CarAudio's tick, 2026-10-23)
        if PTNative_Mute then PTNative_Mute(me:GetAddress(), "CommandEnterCar|Exit Car") end
        if same(me:GetAttachParentActor(), car) then
            if not riding or riding.car ~= car:GetFullName() then ride(me, car) end
        elseif riding then
            stopRide(me)
        end
    end
    if helloFor ~= car:GetFullName() then
        helloFor = car:GetFullName()
        net.toHost("g.car.hello")
    end
end

local controlCar, controlData, controlRetryAt = nil, {}, 0
local function restoreControls()
    for h, saved in pairs(controlData) do
        if valid(h) then
            if saved.inside ~= nil and valid(h.ExtraData) then h.ExtraData.IsInside = saved.inside end
            if PTNative_Unmute then PTNative_Unmute(h:GetAddress()) end
        end
    end
    controlCar, controlData, controlHighlights = nil, {}, {}
end
RegisterLoadMapPreHook(function() controlCar, controlData, controlHighlights, aimed, ctlWanted = nil, {}, {}, nil, false end)
RegisterHook("/Script/PenDriverPro.BaseHighlightManager:PassesFilter", function(_, highlight)
    if common.netMode() ~= "client" or not riding then return end
    local h = highlight:get()
    if not valid(h) then return end
    local owner = h:GetOwner()
    if not valid(owner) then return end
    local cls=owner:GetClass():GetFName():ToString()
    if cls ~= "BP_CarPart_Interactive_C" and cls ~= HOOD then return end
    if cls == "BP_CarPart_Interactive_C" then
        local slot = {}; owner:GetSlotComponent(slot)
        if valid(slot.SlotSceneComponent) then
            local name = slot.SlotSceneComponent:GetFName():ToString()
            if name == "SLOT_Windshield" or name == "SLOT_Hood" then return false end
        end
    end
    local parent=valid(owner.RootComponent)and owner.RootComponent.AttachParent
    if valid(parent) then
        local name=parent:GetFName():ToString()
        if name=="SLOT_Windshield" or name=="SLOT_Hood" then return false end
    end
end)
local function highlightControl(hm)
    if not aimed or not controlCar or os.getenv("PT_MUTATE") == "nopasshighlight" then return end
    local h = controlHighlights[aimed]
    if valid(h) and not same(hm.CurrentHighlight, h) then
        hm:SetHighlight(h)
    end
end
LoopInGameThreadWithDelay(16, function()
    if common.netMode() ~= "client" or not riding then
        aimed, ctlWanted = nil, false
        if controlCar then restoreControls() end
        return
    end
    local car, pc, hm = theCar(false), localPC(), first("BP_HighlightManager_C")
    if not (car and pc and hm) then return end
    if not same(controlCar, car) or (not valid(controlHighlights.gear) and os.clock() >= controlRetryAt) then
        restoreControls()
        controlCar = car
        controlRetryAt = os.clock() + 1
        controlHighlights.ign = car.Highlight_Key
        -- Cosmetic shifters own their collision and mesh; the old car.Highlight_GearBox contains null references.
        for _, a in ipairs(FindAllOf("BP_Carpart_Shifter_Base_C") or {}) do
            if valid(a) and same(a:GetAttachParentActor(), car) then
                controlHighlights.gear = a.Highlight
                break
            end
        end
        local radio = carRadio(car)
        controlHighlights.radio = radio and radio.Highlight1 or nil -- a car without a radio (DLC zone, 2026-11-04): not false
        for what, h in pairs(controlHighlights) do
            if valid(h) then
                local saved = {}
                -- the radio too: left inside, the guest got no outline and no radio panel (live 2026-11-04)
                if valid(h.ExtraData) and os.getenv("PT_MUTATE") ~= "nopasshighlight" then
                    saved.inside = h.ExtraData.IsInside
                    h.ExtraData.IsInside = false -- the passenger remains a character, outside the native driver state
                end
                controlData[h] = saved
                if PTNative_Mute then PTNative_Mute(h:GetAddress(), "InteractPressed|InteractReleased") end
            end
        end
    end
    aimed = hm.Enabled and aimAt(pc) or nil
    highlightControl(hm) -- dashboard controls win over the ARC's broad selection volume
    if ctlWanted and aimed then log("PT|car ctl %s sent=%s", aimed, tostring(net.toHost("g.car.ctl", aimed))) end
    ctlWanted = false
end)

LoopInGameThreadWithDelay(250, function()
    local mode = common.netMode()
    local ok, err
    if mode == "client" then ok, err = pcall(guestTick)
    elseif mode == "listen" then ok, err = pcall(hostTick)
    else
        riding, helloFor, followed = nil, nil, nil
        return
    end
    if not ok then log("PT|error car tick %s", tostring(err)) end
end)
-- host: while a door swings the state goes out at 20 Hz, at 4 Hz the guest saw its swing "like 3 fps" (hand playtest 2026-10-23).
-- The loop read every door's physics 20 times a second; it now works while swingUntil is ahead (set by the door hooks and by
-- a door bit change in the 4 Hz sample) and, in case a hook did not fire, once every 2 s.
local swingFallbackAt = 0
net.on("g.motion.doors", function(_, data)
    if common.netMode() ~= "client" or not net.hostSupports("door-motion") then return end
    local epoch, identity, rows = data:match("^([^\n]+)\n([^\n]+)\n(.*)$")
    if epoch ~= net.worldToken() or identity ~= wheelHostKey then return end
    local targets = {}
    for row in rows:gmatch("[^\n]+") do
        local f={};for v in row:gmatch("[^|]+") do f[#f+1]=v end
        if #f~=7 then return end
        for i=2,7 do local n=tonumber(f[i]);if not n or n~=n or math.abs(n)>1e7 then return end;f[i]=n end
        targets[f[1]]={p=vec(f[2],f[3],f[4]),r={Pitch=f[5],Yaw=f[6],Roll=f[7]}}
    end
    local t=os.clock()
    for slot, target in pairs(targets) do
        local old=doorTargets[slot]
        target.fromP,target.fromR,target.at=old and old.shownP or target.p,old and old.shownR or target.r,t
    end
    doorTargets=targets
end)
LoopInGameThreadWithDelay(16,function()
    if common.netMode()~="client" or os.clock()<doorHold then return end
    local car=theCar(false);if not car then return end
    local ct=car:GetTransform()
    for slot,part in pairs(doorsOf(car)) do
        local m=doorTargets[slot]
        if m and valid(part.MainMesh) then
            local u=math.min(1,(os.clock()-m.at)/0.075)
            m.shownP=kml():VLerp(m.fromP,m.p,u);m.shownR=kml():RLerp(m.fromR,m.r,u,true)
            local mesh=part.MainMesh
            mesh:SetSimulatePhysics(false)
            mesh:K2_SetWorldLocationAndRotation(kml():TransformLocation(ct,m.shownP),kml():TransformRotation(ct,m.shownR),false,{},true)
            doorSwung[part:GetAddress()]=true
        end
    end
end)
M.swingWork = 0 -- debug counter for scenarios: passes that read door physics
LoopInGameThreadWithDelay(50, function()
    if os.clock() >= swingUntil then
        if os.clock() - swingFallbackAt < 2 then return end
        swingFallbackAt = os.clock()
    end
    if common.netMode() ~= "listen" or #net.guests() == 0 then return end
    local ok, err = pcall(function()
        local car = theCar(true)
        if not car then return end
        M.swingWork = M.swingWork + 1
        local rows,ct={},car:GetTransform()
        for slot,d in pairs(doorsOf(car)) do
            local mesh=d.MainMesh
            if valid(mesh) and mesh:IsSimulatingPhysics(FName("None")) then
                local p=kml():InverseTransformLocation(ct,mesh:K2_GetComponentLocation())
                local r=kml():InverseTransformRotation(ct,mesh:K2_GetComponentRotation())
                rows[#rows+1]=string.format("%s|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f",slot,p.X,p.Y,p.Z,r.Pitch,r.Yaw,r.Roll)
            end
        end
        for _,pc in ipairs(net.guests()) do
            if net.peerSupports(pc,"door-motion") then net.toGuest(pc,"g.motion.doors",net.worldToken().."\n"..car:GetFName():ToString().."\n"..table.concat(rows,"\n")) end
        end
        for _, d in pairs(doorsOf(car)) do
            local m = valid(d) and d.MainMesh
            if m and m:IsSimulatingPhysics(FName("None")) then
                local a = m:GetPhysicsAngularVelocityInDegrees(FName("None"))
                if a.X * a.X + a.Y * a.Y + a.Z * a.Z > 25 then swingFor(2); return hostTick() end
            end
        end
    end)
    if not ok then log("PT|error car door tick %s", tostring(err)) end
end)

M.exit = sendExit
M.unstick = function() unstickWanted = true end -- guestui.lua: second key and console command
-- for guestact.lua (the guest's car work and ARC)
M.theCar, M.carManager, M.equipped, M.itemOf, M.slotName = theCar, carManager, equipped, itemOf, slotName
M.manifestation, M.propComps, M.readPart = manifestation, propComps, readPart
return M
