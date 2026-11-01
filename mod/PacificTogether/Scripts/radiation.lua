-- Radiation on the guest (playtest 2026-10-23 #8). The game hurts the player from its own process: BP_ResourceDirector asks
-- BP_HazardManager (GetInfluenceValue "LocalRadiation") what the radiation is at the player. The zone's radiated areas
-- (BP_Hazard_RadiatedZone_* spawn a BP_VolCascade_Radiation_C at runtime) exist on the host only (zone: host 8 volumes,
-- guest 3, the 3 being level-placed with no radiation), so on the guest the value was always 0.
-- The host lists its radiating volumes, the guest spawns the missing ones with the same numbers. Inert outside a session (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local net = require("net")
local safety = require("safety")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "norad" } -- the test mutation switches the module off
local CLS = "/Game/Systems/VolumeCascade/BP_VolCascade_Radiation.BP_VolCascade_Radiation_C"
local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end

local function volumes()
    local r = {}
    for _, o in ipairs(FindAllOf("BP_VolCascade_Radiation_C") or {}) do
        if valid(o) and o["Max Local Radiation"] > 0 then r[#r + 1] = o end
    end
    return r
end

-- host: x y z yaw radius falloff max shape bx by bz fx fy fz, volumes joined by ";"
local function describe()
    local list = {}
    for _, o in ipairs(volumes()) do
        local l, rot, b, f = o:K2_GetActorLocation(), o:K2_GetActorRotation(), o.BoxShapeSize, o.BoxShapeFalloff
        list[#list + 1] = string.format("%.0f %.0f %.0f %.1f %.1f %.1f %.4f %d %.1f %.1f %.1f %.1f %.1f %.1f", l.X, l.Y, l.Z, rot.Yaw,
            o.Radius, o["Falloff Size"], o["Max Local Radiation"], o.Shape, b.X, b.Y, b.Z, f.X, f.Y, f.Z)
    end
    return table.concat(list, ";")
end

local mine = {} -- guest: address -> true for the volumes spawned here (a map load frees them)
RegisterLoadMapPreHook(function() mine = {} end)
local function spawn(cls, w, n)
    local a = w:SpawnActor(cls, { X = n[1], Y = n[2], Z = n[3] }, { Pitch = 0, Yaw = n[4], Roll = 0 })
    if not valid(a) then return false end
    mine[a:GetAddress()] = true
    a.Radius, a["Falloff Size"], a["Max Local Radiation"], a.Shape = n[5], n[6], n[7], n[8]
    a.BoxShapeSize, a.BoxShapeFalloff = { X = n[9], Y = n[10], Z = n[11] }, { X = n[12], Y = n[13], Z = n[14] }
    a:UpdateInfluenceZone(a.Influence_LocalRadiation)
    -- the ground decal was sized at spawn with the class default (2000): a bright glowing patch the host never saw (hand test
    -- 2026-11-01, host decal 5724 wide and faint)
    pcall(function() a:UpdateDecal(false) end)
    return true
end

net.on("g.rad.vols", function(_, data)
    if not (M.enabled and safety.guest()) then return end
    local cls, hm = StaticFindObject(CLS), FindFirstOf("BP_HazardManager_C")
    if not (cls and cls:IsValid() and valid(hm)) then return end
    local have, matched, missing = volumes(), {}, {}
    for entry in data:gmatch("[^;]+") do
        local n = {}
        for v in entry:gmatch("%S+") do n[#n + 1] = tonumber(v) end
        local known = false
        for i, o in ipairs(have) do
            local l = o:K2_GetActorLocation()
            if math.abs(l.X - n[1]) < 100 and math.abs(l.Y - n[2]) < 100 and math.abs(l.Z - n[3]) < 100 then known = true; matched[i] = true break end
        end
        if not known then missing[#missing + 1] = n end
    end
    -- a volume that moved (a carried ARC anchor's, a drifting Hot Dust cloud): our copy of the same size goes along. A new copy
    -- per update left a dust field every 15-20 m behind a host carrying an anchor (playtest 2026-10-31)
    for _, n in ipairs(missing) do
        local moved = false
        for i, o in ipairs(have) do
            if not matched[i] and mine[o:GetAddress()] and math.abs(o.Radius - n[5]) < 1 and math.abs(o["Max Local Radiation"] - n[7]) < 0.001 then
                matched[i], moved = true, pcall(function()
                    o:K2_SetActorLocation({ X = n[1], Y = n[2], Z = n[3] }, false, {}, true)
                    o:UpdateInfluenceZone(o.Influence_LocalRadiation)
                end)
                break
            end
        end
        if not moved then
            local ok, made = pcall(spawn, cls, hm:GetWorld(), n)
            if ok and made then log("PT|radiation guest volume at %.0f %.0f %.0f r=%.0f max=%.2f", n[1], n[2], n[3], n[5], n[7])
            else log("PT|error radiation spawn %s", tostring(made)) end
        end
    end
    -- what the host no longer has (Hot Dust gone or moved, the guest's own local spots) stops radiating here too
    for i, o in ipairs(have) do
        if not matched[i] then
            local l = o:K2_GetActorLocation()
            if mine[o:GetAddress()] then
                -- ours: gone with its dust (zeroed copies stayed in the world as dust fields)
                mine[o:GetAddress()] = nil
                pcall(function() o["Max Local Radiation"] = 0; o:UpdateInfluenceZone(o.Influence_LocalRadiation); o:K2_DestroyActor() end)
            else
                pcall(function() o["Max Local Radiation"] = 0; o:UpdateInfluenceZone(o.Influence_LocalRadiation) end)
            end
            log("PT|radiation guest volume off at %.0f %.0f %.0f (not on the host)", l.X, l.Y, l.Z)
        end
    end
end)

local lastSent, sentAt = nil, -99
RegisterLoadMapPostHook(function() lastSent = nil end)
-- host: the list every 1.5 s (a zone's volumes appear as it loads, a guest may join late, carried anchors and dust clouds move)
LoopInGameThreadWithDelay(1500, function()
    if not (M.enabled and safety.active() and not safety.guest()) then return end
    local ok, err = pcall(function()
        -- on change (a carried anchor's volume moves), else every 6 s: the whole list each 1.5 s was 190 KB per 30 s in a big zone
        -- (zoneexit 2026-11-01). Also when empty: the guest switches off what the host's last volume left behind.
        local d = describe()
        if d ~= lastSent or os.clock() - sentAt > 6 then
            lastSent, sentAt = d, os.clock()
            net.toGuests("g.rad.vols", d)
        end
    end)
    if not ok then log("PT|error radiation %s", tostring(err)) end
end)

return M
