-- Playtest 1 bug B: an item a player drops lies on the ground for the other player too (it used to hang in the air at its drop height).
-- Each side drops an item the way the game does (item to the hand, PlayerDropHandItem); after a few seconds the item's Z on the other
-- side is within 20 cm of the dropper's resting Z, and below the dropper's own height.
-- Run: tools/run-test.ps1 -Scenario dropfall -Fixture zone -Headless
-- guest_drop_kept_single: the guest's dropped actor itself stays and is the only copy (mutation nodropadopt fails it).
-- Mutation nofall: loot.lua does not send item positions after the first line (the copy stays where it appeared) -> FAILS.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log = T.log
    local mapName = "Rural_Forest_Radio_Scylla_02"
    local STEEL = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
    local TAPE = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawTape/IA_Resource_Raw_Tape.IA_Resource_Raw_Tape"
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function im() return T.first("BP_InventoryManager_C") end
    -- the nearest loose world item of an archetype to x,y (any height), its Z
    local function zOf(path, x, y)
        local name, best, bz = path:match("[^/%.]+$"), 1e12, nil
        for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
            if alive(a) and alive(a.Instance) and a.Instance.Archetype:GetFName():ToString() == name and not a:GetAttachParentActor():IsValid() then
                local l = a:K2_GetActorLocation()
                local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
                if d < best and d < 300 ^ 2 then best, bz = d, l.Z end
            end
        end
        return bz
    end
    local function drop(path) -- what the drop key does: the item into the hand, then the game's drop
        local m = im()
        m:GiveItemToPlayer(StaticFindObject(path))
        local s
        for i = 0, m.Inventory_Player:GetNumSlots() - 1 do
            local sl = m.Inventory_Player:GetSlot(i)
            if sl:IsValid() and sl:GetNumItems() > 0 and sl:GetCurrentArchetype():GetFName():ToString() == path:match("[^/%.]+$") then s = sl; break end
        end
        assert(s, "the item is not in the backpack")
        s:TransferSingleIntoContainer(m.Inventory_PlayerHand)
        local o1, o2 = {}, {}
        m:PlayerDropHandItem(o1, o2)
        assert(o1["Drop Success"], "drop failed")
        local l = o2["World Actor"]:K2_GetActorLocation()
        return l.X, l.Y, l.Z, o2["World Actor"]
    end
    local got = {}
    local function drain()
        while true do
            local kind, data = PTNative_MsgPoll("t.")
            if not kind then return end
            got[kind] = data
        end
    end
    local function has(kind) drain(); return got[kind] ~= nil end
    local function sendGuest(kind, data) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), kind, data or "") end
    local function sendHost(kind, data) PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end
    local function nums(s) local r = {}; for v in s:gmatch("[^|]+") do r[#r + 1] = tonumber(v) end; return r end

    local steps = {}
    local function add(s) steps[#steps + 1] = s end
    local function agree(label, zOther, zMine, pawnZ)
        log("PT|info dropfall %s: dropper rests at %.0f, other side at %.0f, dropper pawn z %.0f", label, zMine, zOther, pawnZ)
    end

    if T.ROLE == "host" then
        local hx, hy, hz, hp
        for _, s in ipairs(T.loadFixture("zone")) do add(s) end
        add({ check = "host_listen", timeout = 120, cond = function() return T.netMode() == "listen" and T.listening() and T.map() == mapName end })
        add({ check = "host_guest_in", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 12 })
        -- 1. the host drops
        add({ run = function()
            hp = T.myPawn():K2_GetActorLocation().Z
            hx, hy, hz = drop(STEEL)
            log("PT|info dropfall host dropped at %.0f,%.0f,%.0f (pawn z %.0f)", hx, hy, hz, hp)
        end })
        add({ wait = 10 })
        add({ run = function()
            local z = zOf(STEEL, hx, hy)
            assert(z, "the host's dropped item is gone")
            agree("host drop", z, z, hp)
            sendGuest("t.hz", string.format("%.0f|%.0f|%.0f|%.0f", hx, hy, z, hp))
        end })
        add({ check = "host_drop_guest_agrees", timeout = 60, cond = function() return has("t.hok") end })
        -- 2. the guest drops: its item lies on the host's ground too
        add({ run = function() sendGuest("t.gstart") end })
        add({ check = "guest_dropped", timeout = 60, cond = function() return has("t.gz") end })
        add({ wait = 6 })
        add({ check = "guest_drop_on_host_ground", timeout = 30, cond = function()
            local v = nums(got["t.gz"])
            local z = zOf(TAPE, v[1], v[2])
            log("PT|info dropfall host sees the guest's drop at z=%s (guest rests at %.0f, guest pawn z %.0f)", tostring(z), v[3], v[4])
            return z ~= nil and math.abs(z - v[3]) < 20 and z < v[4] - 40
        end })
        add({ wait = 2 })
        return steps
    end

    local gx, gy, gz, gp, gActor
    local function count(path, x, y)
        local name, n = path:match("[^/%.]+$"), 0
        for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
            if alive(a) and alive(a.Instance) and a.Instance.Archetype:GetFName():ToString() == name then
                local l = a:K2_GetActorLocation()
                if (l.X - x) ^ 2 + (l.Y - y) ^ 2 < 300 ^ 2 then n = n + 1 end
            end
        end
        return n
    end
    add({ check = "client_in_zone", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == mapName and T.cls(T.myPawn()) == T.CHAR end })
    add({ check = "guest_told_hz", timeout = 240, cond = function() return has("t.hz") end })
    add({ check = "host_drop_on_guest_ground", timeout = 30, cond = function()
        local v = nums(got["t.hz"])
        local z = zOf(STEEL, v[1], v[2])
        log("PT|info dropfall guest sees the host's drop at z=%s (host rests at %.0f)", tostring(z), v[3])
        return z ~= nil and math.abs(z - v[3]) < 20 and z < v[4] - 40
    end })
    add({ run = function() sendHost("t.hok") end })
    add({ check = "guest_told_gstart", timeout = 120, cond = function() return has("t.gstart") end })
    add({ run = function()
        gp = T.myPawn():K2_GetActorLocation().Z
        gx, gy, gz, gActor = drop(TAPE)
        log("PT|info dropfall guest dropped at %.0f,%.0f,%.0f (pawn z %.0f)", gx, gy, gz, gp)
    end })
    add({ wait = 8 })
    -- the guest's own item stays (the host adopts it, loot.lua "K"): not deleted and replaced by the host's copy seconds later
    -- (scrapped resources vanished and came back, friend session 2026-11-01). Mutation nodropadopt fails it.
    add({ check = "guest_drop_kept_single", timeout = 1, cond = function()
        local n = count(TAPE, gx, gy)
        log("PT|info dropfall guest's own drop alive=%s copies near=%d", tostring(alive(gActor)), n)
        return alive(gActor) and n == 1
    end })
    add({ run = function()
        local z = zOf(TAPE, gx, gy)
        assert(z, "the guest's dropped item is gone")
        log("PT|info dropfall guest drop rests at %.0f", z)
        sendHost("t.gz", string.format("%.0f|%.0f|%.0f|%.0f", gx, gy, z, gp))
    end })
    add({ wait = 12 })
    return steps
end
