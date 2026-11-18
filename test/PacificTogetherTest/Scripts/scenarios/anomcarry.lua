-- W6: the Abductor (BP_Hazard_PhysicsGrabber) really grabs the car on the host and the guest sees it carried. Fixture `zone`, the guest joins by itself.
--   The host makes the game's own hunt: the Cone's overlap handler with the car's chassis (state 1), then anommove's driver makes the machine's calls
--   (the Logic Driver machine does not run in a listen session): fly to the car, hook on, drag. Checks:
--   host_grabber_grabs_car    the host's grabber reaches state 3 (car hooked) and the car is moved by it
--   guest_car_follows_carry   the guest's car is where the host's is, away from where it started
--   guest_grabber_follows     the guest's copy of the grabber (found by the host's current root) has its core and magnet within 400 uu of the host's, 3 samples in a row
-- Run: tools/run-test.ps1 -Scenario anomcarry -Fixture zone -Headless ; mutations noanommove (no driver, no sync), anomrootkey (the old root-position match).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local UEHelpers = require("UEHelpers")
    local GRAB = "/Game/Gameplay/Hazards/PhysicsGrabber/BP_Hazard_PhysicsGrabber.BP_Hazard_PhysicsGrabber_C"
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local function xf(x, y, z) return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x, Y = y, Z = z }, Scale3D = { X = 1, Y = 1, Z = 1 } } end
    local function spawn(path, x, y, z)
        local cls = StaticFindObject(path)
        if not cls:IsValid() then LoadAsset(path); cls = StaticFindObject(path) end
        local gs = UEHelpers.GetGameplayStatics()
        return gs:FinishSpawningActor(gs:BeginDeferredActorSpawnFromClass(T.world(), cls, xf(x, y, z), 0, nil), xf(x, y, z))
    end
    local function dead(o) return not o:IsValid() or o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function car() return T.first("BP_PlayerCarNew_C") end
    local function dist(ax, ay, az, bx, by, bz) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2) end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local gpc, gr, c0 = nil, nil, nil
        local g = {} -- the guest's last report
        local function poll()
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then return end
                if kind == "t.carry" then
                    local v = {}
                    for n in data:gmatch("%-?[%d%.]+") do v[#v + 1] = tonumber(n) end
                    if #v == 9 then g = { car = { v[1], v[2], v[3] }, core = { v[4], v[5], v[6] }, mag = { v[7], v[8], v[9] } } else g = { car = { v[1], v[2], v[3] } } end
                end
            end
        end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function()
            gpc = L.remotePCs()[1]
            local l = car():K2_GetActorLocation()
            c0 = { l.X, l.Y, l.Z }
            gr = spawn(GRAB, l.X + 300, l.Y, l.Z + 900)
            T.log("PT|info spawned grabber %s over the car at %.0f %.0f %.0f", T.name(gr), l.X, l.Y, l.Z)
            -- keep the guest told where the host's grabber is now (it travels; the guest finds its copy by that)
            LoopInGameThreadWithDelay(200, function()
                if dead(gr) then return true end
                pcall(function()
                    local r = gr:K2_GetActorLocation()
                    PTNative_MsgToGuest(gpc:GetAddress(), "t.watch", string.format("%.0f\t%.0f\t%.0f", r.X, r.Y, r.Z))
                end)
                return false
            end)
        end })
        add({ wait = 4 })
        add({ run = function() -- the game's own trigger: the Cone overlaps the car's body
            local c = car()
            gr.CanGrabOn = true
            gr:BndEvt__Cone_K2Node_ComponentBoundEvent_0_ComponentBeginOverlapSignature__DelegateSignature(gr.Cone, c, c:K2_GetRootComponent(), 0, false, {})
            T.log("PT|info cone overlap with the car sent, grabber state %s", tostring(gr.CurrentPatStealerState))
        end })
        add({ check = "host_grabber_grabs_car", timeout = 120, cond = function()
            local l, st = car():K2_GetActorLocation(), gr.CurrentPatStealerState
            local c = gr.CoreFloatingMesh:K2_GetComponentLocation()
            T.log("PT|info grabber state=%s core=(%.0f,%.0f,%.0f) car moved %.0f", tostring(st), c.X, c.Y, c.Z, dist(l.X, l.Y, l.Z, c0[1], c0[2], c0[3]))
            return st == 3 and dist(l.X, l.Y, l.Z, c0[1], c0[2], c0[3]) > 300
        end })
        local okRun = 0
        add({ check = "guest_car_follows_carry", timeout = 60, cond = function()
            poll()
            if not g.car then return false end
            local l = car():K2_GetActorLocation()
            local d = dist(l.X, l.Y, l.Z, g.car[1], g.car[2], g.car[3])
            T.log("PT|info car host=(%.0f,%.0f,%.0f) guest=(%.0f,%.0f,%.0f) apart=%.0f", l.X, l.Y, l.Z, g.car[1], g.car[2], g.car[3], d)
            return d < 250 and dist(l.X, l.Y, l.Z, c0[1], c0[2], c0[3]) > 300
        end })
        add({ check = "guest_grabber_follows", timeout = 60, cond = function()
            poll()
            if dead(gr) or not g.core then okRun = 0; return false end
            local c, m = gr.CoreFloatingMesh:K2_GetComponentLocation(), gr.SM_PG_Magnet:K2_GetComponentLocation()
            local dc = dist(c.X, c.Y, c.Z, g.core[1], g.core[2], g.core[3])
            local dm = dist(m.X, m.Y, m.Z, g.mag[1], g.mag[2], g.mag[3])
            T.log("PT|info grabber state=%s core apart=%.0f magnet apart=%.0f", tostring(gr.CurrentPatStealerState), dc, dm)
            okRun = (dc < 400 and dm < 400) and okRun + 1 or 0
            return okRun >= 3
        end })
        local zmax, n = -1e9, 0
        add({ check = "carry_height_info", timeout = 30, cond = function() -- information only: how high the game's carry takes the car in its 10 s pull
            n = n + 1
            local l, st = car():K2_GetActorLocation(), gr.CurrentPatStealerState
            zmax = math.max(zmax, l.Z)
            T.log("PT|info carry t=%d state=%s car z=%.0f (start %.0f, max %.0f) guest car z=%s", n, tostring(st), l.Z, c0[3], zmax, tostring(g.car and g.car[3]))
            poll()
            return n >= 14 or st == 0
        end })
        add({ run = function() PTNative_MsgToGuest(gpc:GetAddress(), "t.end", "1") end })
        add({ wait = 3 })
        return steps
    end

    local finished, watch = false, nil
    LoopInGameThreadWithDelay(500, function()
        pcall(function()
            if T.netMode() ~= "client" then return end
            local c = car():K2_GetActorLocation()
            local best, bd = nil, 600 ^ 2 -- the copy nearest to the host's grabber root
            if watch then
                for _, o in ipairs(FindAllOf("BP_Hazard_PhysicsGrabber_C") or {}) do
                    if T.inWorld(o) and not dead(o) and not o:GetFullName():find("Default__", 1, true) then
                        local l = o:K2_GetActorLocation()
                        local d = (l.X - watch[1]) ^ 2 + (l.Y - watch[2]) ^ 2 + (l.Z - watch[3]) ^ 2
                        if d < bd then best, bd = o, d end
                    end
                end
            end
            local msg = string.format("%.0f\t%.0f\t%.0f", c.X, c.Y, c.Z)
            if best then
                local a, b = best.CoreFloatingMesh:K2_GetComponentLocation(), best.SM_PG_Magnet:K2_GetComponentLocation()
                msg = msg .. string.format("\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f", a.X, a.Y, a.Z, b.X, b.Y, b.Z)
            end
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.carry", msg)
            while true do
                local kind, data = PTNative_MsgPoll("t.")
                if not kind then break end
                if kind == "t.end" then finished = true end
                if kind == "t.watch" then
                    local x, y, z = data:match("^(%-?[%d%.]+)\t(%-?[%d%.]+)\t(%-?[%d%.]+)$")
                    if x then watch = { tonumber(x), tonumber(y), tonumber(z) } end
                end
            end
        end)
    end)
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end },
        { check = "client_stays_until_host_done", timeout = 900, cond = function() return finished end },
    }
end
