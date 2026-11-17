-- P4/D6: player health in a co-op session (zone). Each player's health lives in its own process (BP_ResourceManager_C.PlayerHealth,
-- one per process), so the guest's damage and healing are its own sim's; the mod shares the numbers (name tag) and handles the
-- guest's death: no KillPlayer / return to garage, a respawn at the host's car with health restored, the host's run untouched.
-- Run: tools/run-test.ps1 -Scenario playerhealth -Fixture zone -Headless
-- Mutation nohealth: health.lua is inert (no shared health, no guest death handling): the tag, respawn and run checks FAIL.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local SAFE = require("scenarios.safety_lib")
    local mapName = "Rural_Forest_Radio_Scylla_02"

    local function health()
        local rm = T.first("BP_ResourceManager_C")
        local h = rm and rm.PlayerHealth
        if not (h and h:IsValid()) then return nil end
        return h.Current, h.Maximum, h
    end
    local function pct() local c, m = health(); return c and c / m * 100 or -1 end
    local function adjust(frac) -- the game's own sink for every damage and heal message
        local c, m, h = health()
        h:Adjust(T.first("BP_ResourceManager_C"), frac * m)
        T.log("PT|info health adjust %.2f -> %.0f%%", frac, pct())
    end
    -- what the other player's name tag shows over their head (name, newline, percent)
    local function otherPct()
        local o = T.otherChar()
        local tag = o and SAFE.tagsOn(T, o)[1]
        local t = tag and SAFE.tagState(T, tag).text or ""
        -- the quiet tag (nametag.lua) shows health only when hurt: a name without a percent line is a full-health partner
        return tonumber(t:match("\n(%d+)%%")) or (t ~= "" and 100 or -1)
    end
    local function near(a, b) return math.abs(a - b) <= 6 end
    local function manager() return T.first("BP_MainCharacterManager_C") end

    if T.ROLE == "host" then
        local steps = {}
        local function add(s) steps[#steps + 1] = s end
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ check = "host_sees_guest_full", timeout = 15, cond = function() return near(otherPct(), 100) end })
        add({ check = "host_sees_guest_damaged", timeout = 40, cond = function() return near(otherPct(), 70) end })
        -- the host's own damage: the guest must see it over our head
        add({ run = function() adjust(-0.5) end })
        add({ check = "host_sees_guest_healed", timeout = 60, cond = function() return near(otherPct(), 100) end })
        -- put the guest far from us and the car, so a respawn next to the car shows
        add({ run = function()
            local g, me = L.guestChar(), T.myPawn() or manager().CharacterActor
            local l = me:K2_GetActorLocation()
            for i = 0, 3 do
                local a = math.rad(90 * i)
                if g:K2_TeleportTo({ X = l.X + math.cos(a) * 2500, Y = l.Y + math.sin(a) * 2500, Z = l.Z + 600 }, { Pitch = 0, Yaw = 0, Roll = 0 }) then break end
            end
            T.log("PT|info guest moved away d=%.0f", T.dist(me, g))
        end })
        add({ check = "host_guest_respawned_near", timeout = 60, cond = function()
            local g, me = L.guestChar(), T.myPawn() or manager().CharacterActor
            local d = g and T.dist(me, g) or -1
            T.log("PT|info guest dist=%.0f health seen=%d", d, otherPct())
            return g ~= nil and d >= 0 and d < 1500 and near(otherPct(), 100)
        end })
        -- the guest's death must not touch our run: same map, still listening, alive, health as we left it
        add({ check = "host_run_intact", timeout = 40, cond = L.holds(15, function()
            local cm = manager()
            return T.netMode() == "listen" and T.listening() and T.map() == mapName and cm and cm:IsPlayerAlive() and pct() > 40 and pct() < 90
        end) })
        add({ check = "host_guest_still_there", timeout = 5, cond = function() return L.guestChar() ~= nil end })
        return steps
    end

    local steps = { T.onMap("RB_MainMenu", 90) }
    local function add(s) steps[#steps + 1] = s end
    local mark
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end })
    add({ run = function() mark = L.mark() end })
    add({ wait = 12 })
    add({ run = function()
        adjust(-0.3)
    end })
    add({ check = "guest_health_lowered", timeout = 5, cond = function() return near(pct(), 70) end })
    add({ check = "guest_sees_host_damaged", timeout = 90, cond = function() return near(otherPct(), 50) end })
    add({ run = function() adjust(0.3) end })
    add({ check = "guest_health_healed", timeout = 5, cond = function() return near(pct(), 100) end })
    -- health.lua: no death within 8 s of the arrival transition (a level loads at the minimum), and the game regenerates after ~4 s
    add({ check = "guest_arrival_settled", timeout = 90, cond = function() local tr = package.loaded["transition"]; return not (tr and tr.state().phase) end })
    add({ wait = 10 })
    add({ run = function() adjust(-1.0) end }) -- dead
    -- respawn: health back, no travel, still connected, the host's car/character near
    add({ check = "guest_respawned", timeout = 30, cond = function()
        local o = T.otherChar()
        local d = (o and T.myPawn()) and T.dist(T.myPawn(), o) or -1
        T.log("PT|info guest respawn health=%.0f%% dist=%.0f", pct(), d)
        return pct() > 90 and T.netMode() == "client" and T.map() == mapName and d >= 0 and d < 1500
    end })
    add({ check = "guest_no_reload", timeout = 12, cond = L.holds(8, function() return T.netMode() == "client" and T.map() == mapName and not L.reloadedNoMenu(mark) end) })
    add({ wait = 20 })
    return steps
end
