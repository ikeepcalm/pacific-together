-- ARC anchor structures are pulled once (owner hand play 2026-10-24: an anchor the guest pulled stayed on the host, deposited twice).
--   guest_sees_both_anchors       the host's two anchor structures exist on the guest as copies
--   host_anchor_taken_by_guest    the guest pulls its copy of A (the game's own Long Grab Complete): the host's A is taken within 20 s, B is not
--   host_pull_hazards_for_guest   the guest's pull runs the host's anchor-pull hazards once (AnchorTaken broadcasts CauseHazardDisturbance;
--                                 the guest's game has no BP_HazardAnchorPull) and removes the anchor's Hot Dust (RadActor) on the host
--   guest_anchor_gone_when_host_pulls   the host pulls B (its own Long Grab Complete): the guest's copy of B is taken in place (sound, fade)
-- Run: tools/run-test.ps1 -Scenario anchordup -Fixture zone -Headless [-Root .. -Port ..]   Mutations: noanchorsync (the guest's pull is not sent), noanchorfx (the host's pull is not sent).
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local function to(s) return s end
    local takenWait = (T.MUTATE == "noanchorsync") and 12 or 20 -- a mutation must fail the intended check, not wait out a long timeout
    local ANCHOR = "/Game/Gameplay/Resources/AnchorBase/BP_Spawn_Anchor_Stable_S.BP_Spawn_Anchor_Stable_S_C"
    local function alive(o) return o ~= nil and o:IsValid() end
    local function d3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
    local function spawn(p)
        if not StaticFindObject(ANCHOR):IsValid() then pcall(LoadAsset, ANCHOR) end
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = p, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local a = gs:BeginDeferredActorSpawnFromClass(T.myPawn(), StaticFindObject(ANCHOR), xf, 1, nil)
        return gs:FinishSpawningActor(a, xf)
    end
    local function near(p, r)
        for _, o in ipairs(FindAllOf("BP_Spawn_Anchor_Stable_S_C") or {}) do
            if alive(o) and not o:GetFullName():find("/Engine/Transient", 1, true) and d3(o:K2_GetActorLocation(), p) < r then return o end
        end
    end
    local got = {}
    local function poll()
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then return end
            got[k] = d
        end
    end
    local function pt(s) local x, y, z = s:match("^([^,]+),([^,]+),([^,]+)$"); return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end
    local function str(p) return string.format("%.1f,%.1f,%.1f", p.X, p.Y, p.Z) end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        local function toGuest(k, v) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), k, v or "") end
        local A, B
        for _, s in ipairs(T.loadFixture(os.getenv("PT_FIXTURE") or "zone")) do add(s) end
        add({ check = "host_listen_zone", timeout = 60, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_zone", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ check = "guest_ready", timeout = 400, cond = function() poll(); return got["t.ready"] ~= nil end })
        local disturbed = 0
        add({ run = function()
            RegisterHook("/Game/Gameplay/Hazards/HazardPullEvents/BP_HazardAnchorPull.BP_HazardAnchorPull_C:HazardDisturbance", function(_, _, _, nonAnchor)
                local na = nonAnchor:get()
                T.log("PT|info host HazardDisturbance nonAnchor=%s", tostring(na))
                if na == false then disturbed = disturbed + 1 end
            end)
            local l = T.myPawn():K2_GetActorLocation()
            A = spawn({ X = l.X, Y = l.Y + 700, Z = l.Z + 20 })
            B = spawn({ X = l.X + 600, Y = l.Y + 700, Z = l.Z + 20 })
            T.log("PT|info host spawned anchors %s %s", A:GetFName():ToString(), B:GetFName():ToString())
            toGuest("t.spawned", str(A:K2_GetActorLocation()) .. ";" .. str(B:K2_GetActorLocation()))
        end })
        add({ check = "guest_sees_both_anchors", timeout = to(120), cond = function() poll(); return got["t.seen"] ~= nil end })
        add({ check = "host_anchor_taken_by_guest", timeout = takenWait, cond = function()
            poll()
            if not got["t.pulled"] then return false end
            T.log("PT|info host A taken=%s B taken=%s", tostring(A.SuccessfullyGrabbed), tostring(B.SuccessfullyGrabbed))
            return A.SuccessfullyGrabbed == true and B.SuccessfullyGrabbed ~= true
        end })
        add({ check = "host_pull_hazards_for_guest", timeout = 10, cond = function() return disturbed == 1 end })
        add({ run = function() B["Long Grab Complete"](B); T.log("PT|info host pulled B: %s", tostring(B.SuccessfullyGrabbed)); toGuest("t.hostpulled", "1") end })
        add({ check = "guest_anchor_gone_when_host_pulls", timeout = to(60), cond = function() poll(); return got["t.bgone"] ~= nil end })
        add({ wait = 2 })
        return steps
    end

    local ap, bp
    return {
        T.onMap("RB_MainMenu", 90),
        { check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.cls(T.myPawn()) == T.CHAR end },
        { wait = 20 },
        { run = function() PTNative_MsgToHost(T.localPC():GetAddress(), "t.ready", "1") end },
        { check = "got_spawned", timeout = 60, cond = function() poll(); if got["t.spawned"] then local a, b = got["t.spawned"]:match("^(.-);(.*)$"); ap, bp = pt(a), pt(b); return true end end },
        { check = "guest_sees_both_anchors", timeout = to(120), cond = function()
            if near(ap, 60) and near(bp, 60) then PTNative_MsgToHost(T.localPC():GetAddress(), "t.seen", "1"); return true end
        end },
        { run = function()
            local a = near(ap, 60)
            a["Long Grab Complete"](a)
            T.log("PT|info guest pulled its copy of A: grabbed=%s", tostring(a.SuccessfullyGrabbed))
            PTNative_MsgToHost(T.localPC():GetAddress(), "t.pulled", "1")
        end },
        { check = "guest_anchor_gone_when_host_pulls", timeout = to(60), cond = function()
            poll()
            if not got["t.hostpulled"] then return false end
            -- the copy plays the game's take (g.vis.anchortaken) and stays as a pulled anchor; removed by the slow prop sweep instead = FAIL
            local b = near(bp, 60)
            if b and b.SuccessfullyGrabbed == true then PTNative_MsgToHost(T.localPC():GetAddress(), "t.bgone", "1"); return true end
        end },
        { wait = 3 },
    }
end
