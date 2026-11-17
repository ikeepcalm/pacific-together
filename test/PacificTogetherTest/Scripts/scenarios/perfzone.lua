-- Perf measurement (lane perf2, 2026-11-17): both players in the zone fixture for 210 s, the host driving the car back and forth.
-- Not a correctness test: read the PT|perf lines with tools/perfsum.ps1 <results folder>.
-- Run: tools/run-test.ps1 -Scenario perfzone -Fixture zone -Headless
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local CL = require("scenarios.carlib")(T)
    local SECS = 210
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end
    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ run = function() CL.enterCar(CL.car()) end })
        add({ wait = 6 })
        add({ run = function() local car = CL.car(); if not CL.possessing(car) then CL.forcePossess(car, T.myPawn()) end end })
        add({ check = "host_in_driver_seat", timeout = 10, cond = function() return CL.possessing(CL.car()) end })
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_zone", timeout = 300, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 15 })
        add({ run = function() CL.startEngine(CL.car()); CL.drive(CL.car(), 5) end })
        add({ wait = 100 }) -- drive, then park: players spend most of an expedition at a stop
        add({ run = function() CL.driving = false; pcall(function() CL.car().VehicleController:SetParkingBrakeActive(true) end) end })
        add({ wait = SECS - 100 })
        add({ run = function() CL.driving = false; PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), "t.done", "") end })
        add({ wait = 3 })
        return steps
    end
    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.cls(T.myPawn()) == T.CHAR and L.guestSeesHost() end })
    add({ check = "host_says_done", timeout = SECS + 120, cond = function() poll(); return got["t.done"] ~= nil end })
    add({ wait = 2 })
    return steps
end
