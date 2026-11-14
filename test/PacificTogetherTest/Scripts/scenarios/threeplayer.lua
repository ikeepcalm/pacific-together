-- 3-4 players (D1, owner 2026-11-14): a host and two guests. Each guest sees both other players, gets both other players' own state
-- through the host's relay (net.share, health reports: "PT|net shared g.health.hp from <id>" for two ids), and the two guests get
-- different seats (the first the passenger seat, the second the rear one behind the driver), then both get out.
-- Run: tools/run-test.ps1 -Scenario threeplayer -Clients 3 -Fixture garage -Headless   (tools/setup-test.ps1 -Extra 1 first)
-- Mutation norelay is not wired; a broken relay shows as shared_from_two failing on the guests.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local C = require("scenarios.carlib")(T)
    local got = {}
    local function g(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind]
    end
    local function attached(c) local p = c:GetAttachParentActor(); return p:IsValid() and T.cls(p) == "BP_PlayerCarNew_C" end
    -- distinct senders of the health relay in our own log, read on from where the last poll stopped
    local ids, n, pos = {}, 0, 0
    local function sharedFrom()
        local f = io.open("ue4ss/UE4SS.log", "rb")
        if not f then return n end
        f:seek("set", pos)
        local s = f:read("*a"); f:close()
        local cut = s:match(".*\n()") or 1 -- whole lines only; a partial last line is read again next time
        pos = pos + cut - 1
        for id in s:sub(1, cut - 1):gmatch("PT|net shared g%.health%.hp from (%-?%d+)") do
            if not ids[id] then ids[id], n = true, n + 1 end
        end
        return n
    end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function guests()
            local r = {}
            for _, pc in ipairs(L.remotePCs()) do if T.inWorld(pc.Pawn) and T.cls(pc.Pawn) == T.CHAR then r[#r + 1] = pc end end
            return r
        end
        local function tell(i, kind) PTNative_MsgToGuest(guests()[i]:GetAddress(), kind, "1") end
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_two_guests", timeout = 400, cond = function() return #guests() == 2 end })
        add({ check = "host_shared_from_two", timeout = 60, cond = function() return sharedFrom() >= 2 end })
        add({ wait = 10 })
        add({ run = function() tell(1, "t.enter") end })
        add({ check = "first_guest_seated", timeout = 60, cond = function() return attached(guests()[1].Pawn) end })
        add({ run = function() tell(2, "t.enter") end })
        add({ check = "second_guest_seated", timeout = 60, cond = function() return attached(guests()[2].Pawn) end })
        add({ check = "guests_on_different_seats", timeout = 10, cond = function()
            local car, a, b = C.car(), guests()[1].Pawn, guests()[2].Pawn
            local la, lb = C.toLocal(car, a:K2_GetActorLocation()), C.toLocal(car, b:K2_GetActorLocation())
            T.log("PT|info seats: first %.0f,%.0f,%.0f second %.0f,%.0f,%.0f", la.X, la.Y, la.Z, lb.X, lb.Y, lb.Z)
            return la.X > 0 and la.Y > 20 and lb.X < 0 and lb.Y < -20
        end })
        add({ wait = 3 })
        add({ run = function() tell(1, "t.exit"); tell(2, "t.exit") end })
        add({ check = "both_guests_out", timeout = 30, cond = function()
            local list = guests()
            return #list == 2 and not attached(list[1].Pawn) and not attached(list[2].Pawn)
        end })
        add({ run = function() tell(1, "t.done"); tell(2, "t.done") end })
        add({ wait = 3 })
        return steps
    end

    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end },
        { check = "guest_sees_two_others", timeout = 120, cond = function()
            local others, me = 0, T.myPawn()
            for _, c in ipairs(L.chars()) do if T.cls(c) == T.CHAR and c:GetAddress() ~= me:GetAddress() then others = others + 1 end end
            return others >= 2
        end },
        { check = "shared_from_two", timeout = 120, cond = function() return sharedFrom() >= 2 end },
        { check = "guest_told_enter", timeout = 300, cond = function() return g("t.enter") ~= nil end },
        { run = function() T.intent("g.car.enter", "") end },
        { check = "guest_seated", timeout = 60, cond = function() return attached(T.myPawn()) end },
        { check = "guest_told_exit", timeout = 300, cond = function() return g("t.exit") ~= nil end },
        { run = function() T.intent("g.car.exit", "") end },
        { check = "guest_out", timeout = 30, cond = function() return not attached(T.myPawn()) end },
        { check = "guest_told_done", timeout = 120, cond = function() return g("t.done") ~= nil end },
    }
end
