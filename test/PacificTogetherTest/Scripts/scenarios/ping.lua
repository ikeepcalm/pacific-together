-- PT2 ping (ping.lua of the shipping mod): a player looks at something and pings; both players get a marker there for ~8 s.
--   host ping on the floor   the host looks down and pings (the console "ptping" runs the key's handler on the real camera trace): its own marker sits
--                            on its view ray; the guest has a marker named after the host within 1 m of the same point, with a distance line
--   host ping at an item     the host drops a steel item and looks at it: the new ping REPLACES the first (one marker per player, moved), and the
--                            marker, on both sides, names the item (its archetype title)
--   guest ping               the guest looks down and pings: the host gets a marker named after the guest within 1 m; one marker per player
--   colours                  the host's marker is blue and the guest's green on both sides (checks above)
--   expiry                   with no further ping both sides end with no markers, about 8 s after the last ping (not earlier)
-- Run: tools/run-test.ps1 -Scenario ping -Fixture garage -Headless      Mutation noping: ping.lua inert (no marker anywhere): every check FAILS.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local STEEL = "/Game/Gameplay/Inventory/Items/Resources/Basic/RawSteel/IA_Resource_Raw_Scrap_Steel.IA_Resource_Raw_Scrap_Steel"
    local function alive(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
    local function im() return T.first("BP_InventoryManager_C") end
    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind] ~= nil
    end
    local function sendGuest(kind, data) PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), kind, data or "") end
    local function sendHost(kind, data) PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end
    local function nums(s) local r = {}; for v in s:gmatch("[^|]+") do r[#r + 1] = tonumber(v) end; return r end
    local function myName() return T.localPC().PlayerState:GetPlayerName():ToString() end

    -- ping markers now up: the game's objective marker (SC_GenericObjective) on a StaticMeshActor beam, its text ending "<n> m":
    -- { text, x, y, z, colour } (x,y,z: the ping point, the beam is 10 m tall around it)
    local function marks()
        local r = {}
        for _, c in ipairs(FindAllOf("SC_GenericObjective_C") or {}) do
            local okc, err = pcall(function() -- the game's own markers have other owners; stale ones answer nullptr
                if not (alive(c) and T.inWorld(c)) then return end
                local o = c:GetOwner()
                if not (alive(o) and o:GetClass():GetFName():ToString() == "StaticMeshActor" and alive(c.MainIconWidget)) then return end
                local t = c.MainIconWidget.TaskText:GetText():ToString()
                if t:match("\n%d+ m$") then
                    local l = o:K2_GetActorLocation()
                    r[#r + 1] = { text = t, x = l.X, y = l.Y, z = l.Z - 1000, colour = c.MainIconWidget.MainImage.ColorAndOpacity }
                end
            end)
            if not okc then T.log("PT|info ping hud comp error %s", tostring(err)) end
        end
        return r
    end
    local function isBlue(c) return c.B > 0.8 and c.G < 0.6 and c.R < 0.4 end -- the host's colour (as the map pins)
    local function isGreen(c) return c.G > 0.8 and c.B < 0.5 and c.R < 0.4 end -- the guest's
    local function markOf(name, list)
        for _, m in ipairs(list or marks()) do if m.text:sub(1, #name + 1) == name .. "\n" then return m end end
    end
    local function d3(m, x, y, z) return math.sqrt((m.x - x) ^ 2 + (m.y - y) ^ 2 + (m.z - z) ^ 2) end
    local function lookAt(x, y, z)
        local pc = T.localPC()
        local c = pc.PlayerCameraManager:GetCameraLocation()
        local dx, dy, dz = x - c.X, y - c.Y, z - c.Z
        pc:SetControlRotation({ Pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 })
    end
    local function lookDown(pitch)
        local pc = T.localPC()
        pc:SetControlRotation({ Pitch = pitch, Yaw = pc.PlayerCameraManager:GetCameraRotation().Yaw, Roll = 0 })
    end
    -- is the marker on the camera's view ray (within 3 degrees)? the independent check of the trace
    local function onViewRay(m)
        local pcm = T.localPC().PlayerCameraManager
        local c, r = pcm:GetCameraLocation(), pcm:GetCameraRotation()
        local dx, dy, dz = m.x - c.X, m.y - c.Y, m.z - c.Z
        local len = math.sqrt(dx * dx + dy * dy + dz * dz)
        local cp = math.cos(math.rad(r.Pitch))
        local dot = (dx * cp * math.cos(math.rad(r.Yaw)) + dy * cp * math.sin(math.rad(r.Yaw)) + dz * math.sin(math.rad(r.Pitch))) / len
        T.log("PT|info ping view ray dist=%.0f cos=%.4f", len, dot)
        return len > 50 and dot > math.cos(math.rad(3))
    end
    local function ping() T.console("ptping") end

    local steps = {}
    local function add(s) steps[#steps + 1] = s end

    if T.ROLE == "host" then
        local hit1, item, title
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 12 })
        -- 1. a ping on the floor
        add({ run = function() lookDown(-55) end })
        add({ wait = 1.5 })
        add({ run = function() ping() end })
        add({ check = "host_own_marker_on_view_ray", timeout = 3, cond = function()
            local m = markOf(myName())
            if not m or not isBlue(m.colour) or not onViewRay(m) then return false end
            hit1 = m
            sendGuest("t.hit1", string.format("%.0f|%.0f|%.0f|%s", m.x, m.y, m.z, myName()))
            return true
        end })
        add({ check = "guest_got_marker_1", timeout = 10, cond = function() return has("t.ok1") end })
        -- 2. a ping at an item replaces it and names the item
        add({ run = function()
            local x, y, z = (function() im():GiveItemToPlayer(StaticFindObject(STEEL))
                local s
                for i = 0, im().Inventory_Player:GetNumSlots() - 1 do
                    local sl = im().Inventory_Player:GetSlot(i)
                    if sl:IsValid() and sl:GetNumItems() > 0 and sl:GetCurrentArchetype():GetFName():ToString() == STEEL:match("[^/%.]+$") then s = sl; break end
                end
                assert(s, "the item is not in the backpack")
                s:TransferSingleIntoContainer(im().Inventory_PlayerHand)
                local o1, o2 = {}, {}
                im():PlayerDropHandItem(o1, o2)
                assert(o1["Drop Success"], "drop failed")
                local l = o2["World Actor"]:K2_GetActorLocation()
                return l.X, l.Y, l.Z
            end)()
            T.log("PT|info ping item dropped at %.0f %.0f %.0f", x, y, z)
        end })
        add({ wait = 4 })
        add({ run = function()
            local c = T.localPC().PlayerCameraManager:GetCameraLocation()
            local best = 1e12
            for _, a in ipairs(FindAllOf("BP_WorldItem_C") or {}) do
                if alive(a) and alive(a.Instance) and not a:GetAttachParentActor():IsValid()
                    and a.Instance.Archetype:GetFName():ToString() == STEEL:match("[^/%.]+$") then
                    local l = a:K2_GetActorLocation()
                    local d = (l.X - c.X) ^ 2 + (l.Y - c.Y) ^ 2 + (l.Z - c.Z) ^ 2
                    if d < best then best, item = d, a end
                end
            end
            assert(item, "no dropped steel in the world")
            title = item.Instance.Archetype.Title:ToString()
            local l = item:K2_GetActorLocation()
            T.log("PT|info ping item '%s' at %.0f %.0f %.0f", title, l.X, l.Y, l.Z)
            lookAt(l.X, l.Y, l.Z)
        end })
        add({ wait = 1.5 })
        add({ run = function() ping() end })
        add({ check = "host_marker_names_item_replaced_first", timeout = 3, cond = function()
            local all = marks()
            local m = markOf(myName(), all)
            if not (m and isBlue(m.colour) and title ~= "" and #all == 1 and m.text:find(title, 1, true) and d3(m, hit1.x, hit1.y, hit1.z) > 30) then return false end
            sendGuest("t.hit2", string.format("%.0f|%.0f|%.0f|%s", m.x, m.y, m.z, title))
            return true
        end })
        add({ check = "guest_got_marker_2", timeout = 10, cond = function() return has("t.ok2") end })
        -- 3. the guest pings: the host gets its marker too (one per player, two in all)
        add({ run = function() sendGuest("t.gstart") end })
        add({ check = "host_marker_from_guest", timeout = 15, cond = function()
            if not has("t.hit3") then return false end
            local v = got["t.hit3"]
            local x, y, z, name = v:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
            local all = marks()
            local m = markOf(name, all)
            T.log("PT|info ping host sees %d markers, guest's at %s", #all, m and string.format("%.0f %.0f %.0f", m.x, m.y, m.z) or "-")
            -- the host's own ping (step 2) may have run out by now (8 s): one or two markers, one per player
            return m ~= nil and isGreen(m.colour) and #all <= 2 and d3(m, tonumber(x), tonumber(y), tonumber(z)) < 100 and m.text:find("%d+ m") ~= nil
        end })
        -- 4. nothing more is pinged: the markers go
        local t0
        add({ check = "host_markers_expire", timeout = 25, cond = function()
            if not has("t.gping") then return false end
            t0 = t0 or os.clock()
            local n = #marks()
            if n > 0 then return false end
            local age = os.clock() - t0
            T.log("PT|info ping host: markers gone %.1f s after the guest's ping report", age)
            return true
        end })
        add({ wait = 2 })
        return steps
    end

    add({ run = function() end })
    add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
    local hostName
    add({ check = "guest_marker_1_at_host_hit", timeout = 120, cond = function()
        if not has("t.hit1") then return false end
        local x, y, z, name = got["t.hit1"]:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
        hostName = name
        local all = marks()
        local m = markOf(name, all)
        T.log("PT|info ping guest sees %d markers, host's at %s", #all, m and string.format("%.0f %.0f %.0f", m.x, m.y, m.z) or "-")
        return m ~= nil and isBlue(m.colour) and #all == 1 and d3(m, tonumber(x), tonumber(y), tonumber(z)) < 100 and m.text:find("%d+ m") ~= nil
    end })
    add({ run = function() sendHost("t.ok1") end })
    local hit2
    add({ check = "guest_marker_2_names_item_and_replaced", timeout = 120, cond = function()
        if not has("t.hit2") then return false end
        local x, y, z, title = got["t.hit2"]:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
        local all = marks()
        local m = markOf(hostName, all)
        local o = nums(got["t.hit1"])
        T.log("PT|info ping guest sees %d markers: '%s'", #all, m and m.text:gsub("\n", "/") or "-")
        return m ~= nil and #all == 1 and title ~= "" and m.text:find(title, 1, true) ~= nil and d3(m, tonumber(x), tonumber(y), tonumber(z)) < 100 and d3(m, o[1], o[2], o[3]) > 30
    end })
    add({ run = function() sendHost("t.ok2") end })
    add({ check = "guest_told_gstart", timeout = 120, cond = function() return has("t.gstart") end })
    add({ run = function() lookDown(-45) end })
    add({ wait = 1.5 })
    local tping
    add({ run = function() ping(); tping = os.clock() end })
    add({ check = "guest_own_marker_on_view_ray", timeout = 3, cond = function()
        local m = markOf(myName())
        if not m or not isGreen(m.colour) or not onViewRay(m) then return false end
        sendHost("t.hit3", string.format("%.0f|%.0f|%.0f|%s", m.x, m.y, m.z, myName()))
        return true
    end })
    add({ run = function() sendHost("t.gping") end })
    add({ check = "guest_markers_expire_after_lifetime", timeout = 25, cond = function()
        if #marks() > 0 then return false end
        local age = os.clock() - tping
        T.log("PT|info ping guest: markers gone %.1f s after the guest's ping", age)
        return age > 6.5 -- ping.lua LIFE is 8 s
    end })
    add({ wait = 4 })
    return steps
end
