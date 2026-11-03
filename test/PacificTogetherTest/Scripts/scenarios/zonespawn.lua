-- Steam playtest 2026-10-23 #3, #17: the guest joins a ZONE: the game puts its character in the driver's seat (stuck, X dropped it
-- through the ground, once launched the car). Expected: not in the driver seat (passenger seat or on foot), X puts it on the ground at
-- a sane height, and the host's car barely moves during the join, a rejoin and the exit.
-- Run: tools/run-test.ps1 -Scenario zonespawn -Fixture zone -Headless    Mutation: nozonefix (the zone seat fix is off)
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local CL = require("scenarios.carlib")(T)
    local log = T.log
    local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local MAXDRIFT = 60 -- uu the host's car may move
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end
    local function theCar()
        for _, c in ipairs(FindAllOf("BP_PlayerCarNew_C") or {}) do
            local l = c:IsValid() and c:K2_GetActorLocation()
            if l and not (l.X == 0 and l.Y == 0 and l.Z == 0) and (T.ROLE == "host" or c.Role ~= 3) then return c end
        end
    end
    local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
    local function attachedToCar(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end
    local function pos(o) local l = o:K2_GetActorLocation(); return string.format("%.0f|%.0f|%.0f", l.X, l.Y, l.Z) end
    local function unpos(s) local x, y, z = s:match("^([^|]*)|([^|]*)|(.*)$"); return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end
    local N = 2 -- joins: the first and one rejoin

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        local base, maxd
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        -- the playtest host arrives in the zone driving: its pawn is the car, the guest spawns next to it
        add({ run = function() CL.enterCar(CL.car()) end })
        add({ wait = 6 })
        add({ run = function() local car = CL.car(); if not CL.possessing(car) then CL.forcePossess(car, T.myPawn()) end end })
        add({ check = "host_in_driver_seat", timeout = 10, cond = function() return CL.possessing(CL.car()) end })
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ run = function() local c = theCar(); base = c:K2_GetActorLocation(); maxd = 0; log("PT|info car base %.0f,%.0f,%.0f", base.X, base.Y, base.Z) end })
        for i = 1, N do
            add({ check = "host_guest_in_zone_" .. i, timeout = 300, cond = function() return L.guestChar() ~= nil end })
            add({ check = "join" .. i .. "_watch", timeout = 60, cond = (function()
                local t0
                return function()
                    t0 = t0 or os.clock()
                    local g, c = L.guestChar(), theCar()
                    if g and c then
                        maxd = math.max(maxd, d3(c:K2_GetActorLocation(), base))
                        local lp = KML:InverseTransformLocation(c:GetTransform(), g:K2_GetActorLocation())
                        log("PT|info join%d t=%.1f attached=%s carlocal=%.0f,%.0f,%.0f carDrift=%.0f", i, os.clock() - t0, tostring(attachedToCar(g)), lp.X, lp.Y, lp.Z, maxd)
                    end
                    return os.clock() - t0 > 25
                end
            end)() })
            add({ check = "join" .. i .. "_guest_not_in_driver_seat", timeout = 1, cond = function()
                local g, c = L.guestChar(), theCar()
                local lp = KML:InverseTransformLocation(c:GetTransform(), g:K2_GetActorLocation())
                -- the driver seat is car-local Y about -45.8 (the passenger's is +45.8)
                return not (math.abs(lp.X - 46) < 60 and lp.Y < -10 and lp.Y > -90 and math.abs(lp.Z) < 80)
            end })
            add({ check = "join" .. i .. "_car_stays", timeout = 1, cond = function() return maxd < MAXDRIFT end })
            add({ run = function() toGuest("t.go" .. i) end })
            add({ check = "guest" .. i .. "_x_done", timeout = 90, cond = function() poll(); return got["t.x" .. i] ~= nil end })
            add({ wait = 4 })
            add({ check = "exit" .. i .. "_guest_on_ground", timeout = 1, cond = function()
                local g, c = L.guestChar(), theCar()
                local own = unpos(got["t.x" .. i])
                log("PT|info exit%d host sees guest %s own=%s car z=%.0f", i, pos(g), got["t.x" .. i], c:K2_GetActorLocation().Z)
                return not attachedToCar(g) and math.abs(g:K2_GetActorLocation().Z - c:K2_GetActorLocation().Z) < 150 and math.abs(own.Z - c:K2_GetActorLocation().Z) < 150
            end })
            add({ check = "exit" .. i .. "_car_stays", timeout = 1, cond = function()
                maxd = math.max(maxd, d3(theCar():K2_GetActorLocation(), base))
                log("PT|info car drift after exit %d: %.0f", i, maxd)
                return maxd < MAXDRIFT
            end })
            if i < N then
                add({ run = function()
                    for _, pc in ipairs(L.remotePCs()) do pc:ClientReturnToMainMenuWithTextReason(FText("Pacific Together test: dropped " .. i)) end
                end })
                add({ check = "host_guest_gone_" .. i, timeout = 60, cond = function() return T.pcs() == 1 and #L.chars() == 1 and T.listening() end })
            end
        end
        add({ wait = 3 })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local mark
    for i = 1, N do
        add({ check = "client_in_zone_" .. i, timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "Rural_Forest_Radio_Scylla_02" and T.cls(T.myPawn()) == T.CHAR and L.guestSeesHost() end })
        add({ check = "guest_told_go" .. i, timeout = 240, cond = function() poll(); return got["t.go" .. i] ~= nil end })
        add({ run = function()
            local me = T.myPawn()
            log("PT|info guest%d before X: attached=%s pos=%s", i, tostring(attachedToCar(me)), pos(me))
            T.intent("g.car.exit", "") -- what X sends
        end })
        add({ wait = 5 })
        add({ run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.x" .. i, pos(T.myPawn())) end })
        if i < N then
            add({ run = function() mark = L.mark() end })
            add({ check = "client_dropped_" .. i, timeout = 90, cond = function() return L.reloadedNoMenu(mark) end })
        end
    end
    add({ wait = 3 })
    return steps
end
