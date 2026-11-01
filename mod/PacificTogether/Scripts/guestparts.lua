-- PT1 guest tool damage on car parts (player car and wrecks). The guest's tools (scrapper and electric scrapper, hammer and magnetic
-- hammer, prybar, explosive cutter) damage the guest's own copy of a part through the game's damage messages; the copy never breaks
-- locally (no ghost drops) and the damage goes to the host as an intent. The host applies it to its real part with the same message
-- class, so HP, breaking, the part's removal and the drops all happen there and come back through car.lua (state) and loot.lua (D, items).
--   g.parts.dmg   kind id class damage harvesterType intensity   kind C = car slot name, P = wreck part id (loot.lua)
--   g.parts.heal  id amount                                       a repair tool on a wreck part (car parts: g.act.heal in guestact.lua)
-- The settings struct a hammer or cutter message carries (retained scrap rates) is not copied: Lua cannot write array fields of a
-- struct, so the host's message has the default settings. Inert outside a session (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local car = require("car")
local loot = require("loot")
local ga = require("guestact")
local log = common.log

local M = {}
if os.getenv("PT_MUTATE") == "noguestparts" then
    log("PT|guestparts disabled")
    return M
end

local COMP = "/Game/Gameplay/Inventory/GenericItemProperties/Components/"
local TOOL = "/Game/Gameplay/Inventory/Items/Tools/Scrapper/BP_Tool_Target_ItemHarvest_Scrapper.BP_Tool_Target_ItemHarvest_Scrapper_C"
local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local function guest() return common.netMode() == "client" and safety.active() end

-- host --------------------------------------------------------------------------------------------------------------------

local dummy -- a scrapper actor far away: the message's source (the game reads the harvest settings from it)
local function source()
    if valid(dummy) then return dummy end
    local gs, cls = UEHelpers.GetGameplayStatics(), StaticFindObject(TOOL)
    if not valid(cls) then pcall(LoadAsset, TOOL); cls = StaticFindObject(TOOL) end
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = -50000 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local a = gs:BeginDeferredActorSpawnFromClass(UEHelpers.GetWorld(), cls, xf, 1, nil)
    dummy = gs:FinishSpawningActor(a, xf)
    -- a first-person tool: it went to the host's view and stayed on the host's screen (hand test 2026-11-01)
    pcall(function() dummy:SetActorHiddenInGame(true); dummy:SetActorTickEnabled(false) end)
    return dummy
end

-- the tool damage messages (short names), each forwarded as its own class
local CLASSES = { Piercing_Scrapper = true, Impact_Hammer = true, Impact_HammerT2 = true, Prybar = true, Explosive_Cutter = true }
local function msgClass(short)
    local p = "/Game/Systems/Messages/MSG_Damage_Physical_" .. short .. ".MSG_Damage_Physical_" .. short .. "_C"
    local c = StaticFindObject(p)
    if not valid(c) then pcall(LoadAsset, p); c = StaticFindObject(p) end
    return valid(c) and c or nil
end

net.on("g.parts.heal", function(_, data)
    if common.netMode() ~= "listen" or not safety.active() then return end
    local id, amount = data:match("^([^\t]*)\t(.*)$")
    amount = tonumber(amount)
    local a = loot.actorOf(id)
    if valid(a) and amount and amount > 0 and amount < 1000 then
        local hc = a:K2_GetComponentsByClass(StaticFindObject(COMP .. "BP_HealthComponent.BP_HealthComponent_C"))[1]
        if hc then hc:get():HealDamage(amount, false, {}, {}, {}); log("PT|parts heal P %s %.2f", id, amount) end
    end
end)

net.on("g.parts.dmg", function(_, data)
    if common.netMode() ~= "listen" or not safety.active() then return end
    local kind, id, class, dmg, ht, ni = data:match("^(%a)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    dmg = tonumber(dmg)
    if not (kind and CLASSES[class] and dmg and dmg > 0 and dmg < 5000) then return end
    local target
    if kind == "P" then target = loot.actorOf(id)
    else
        local cm = car.carManager()
        target = cm and car.manifestation(cm, id)
    end
    if not valid(target) then return end
    local src = source()
    local cls = msgClass(class)
    if not cls then return end
    local msg = StaticConstructObject(cls, src)
    msg.Damage, msg.ToolDispatched = dmg, true
    local function set(k, v) pcall(function() msg[k] = v end) end
    if class == "Piercing_Scrapper" then set("IsDamageOverTime", true) end
    if tonumber(ht) then set("HarvesterType", tonumber(ht)) end
    if tonumber(ni) then set("Normalized Intensity", tonumber(ni)) end
    StaticFindObject("/Script/PenDriverPro.Default__BlueprintGameUtilities"):GetMessageSystem(src):DispatchMessage(msg, target)
    log("PT|parts damage %s %s %s %.2f", kind, id, class, dmg)
end)
-- guest -------------------------------------------------------------------------------------------------------------------

local acc, held = {}, {} -- "kind\tid\tclass" -> { dmg, ht, ni }; hc address -> { hc, hp } health before the hit
local function healthOf(hc)
    local t = { {}, {}, {}, {}, {}, {}, {}, {} }
    hc:GetHealth(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8])
    return t[1].Health, t[2].MaxHealth
end
local function targetOf(owner)
    local id = loot.idOf(owner)
    if id then return "P", id end
    local slot = ga.slotOf and ga.slotOf(owner)
    if slot then return "C", slot end
end
local function mine(msg)
    local short = msg:GetClass():GetFName():ToString():match("^MSG_Damage_Physical_(.+)_C$")
    return short and CLASSES[short] and short
end

-- zero the message's damage before the copy takes it (no local damage, no break, no ghost drops), keep the damage for the host
local function pre(self, msg)
    if not guest() then return end
    local hc, m = self:get(), msg:get()
    local short = mine(m)
    if not short then return end
    local kind, id = targetOf(hc:GetOwner())
    if not kind then return end
    local dmg = m.Damage
    if not dmg or dmg <= 0 then return end
    local ht, ni = "-", "-"
    pcall(function() ht = tostring(m.HarvesterType) end)
    pcall(function() ni = tostring(m["Normalized Intensity"]) end)
    local k = table.concat({ kind, id, short }, "\t")
    local e = acc[k] or { dmg = 0 }
    e.dmg, e.ht, e.ni = e.dmg + dmg, ht, ni
    acc[k] = e
    m.Damage = 0
    -- a car part still took a hit with the damage zeroed (a modifier ran before): lift it to full health too, the loop puts it back
    local hp, max = healthOf(hc)
    local key = hc:GetAddress()
    if not held[key] then held[key] = { hc = hc, hp = hp, max = max } end
    hc:SetHealth(max)
end

local hooked = false
LoopInGameThreadWithDelay(200, function()
    if not guest() then acc, held = {}, {}; return end
    -- only once a health component of the run map exists (a hook set while the menu is up did not survive the map load)
    if not hooked and valid(FindFirstOf("BP_HealthComponent_C")) and valid(car.theCar(false)) then
        hooked = pcall(RegisterHook, COMP .. "BP_HealthComponent.BP_HealthComponent_C:Process Damage Message", function(...)
            local ok, err = pcall(pre, ...)
            if not ok then log("PT|error guestparts pre %s", tostring(err)) end
        end, function() end)
        if hooked then log("PT|guestparts hooked") end
    end
    -- only undo our lift: a host-synced health that arrived meanwhile stays
    for _, h in pairs(held) do if valid(h.hc) and math.abs(healthOf(h.hc) - h.max) < 0.5 then h.hc:SetHealth(h.hp) end end
    held = {}
    for key, e in pairs(acc) do
        log("PT|parts send %s %.2f", (key:gsub("\t", " ")), e.dmg)
        net.toHost("g.parts.dmg", key .. "\t" .. e.dmg .. "\t" .. e.ht .. "\t" .. e.ni)
    end
    acc = {}
end)

return M
