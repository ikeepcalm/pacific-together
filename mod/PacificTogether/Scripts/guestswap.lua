-- The guest swaps car parts (C5, C6, W1). The guest's own game runs the game's CarManager "Swap Equipment" (remove a part into
-- hands/pack, install one from hands); what it did to the slot is turned into an intent and the HOST applies it to its car, so the
-- part exists once: on the guest as the item it carries, in the car as the host's equipment. car.lua's state message shows it back.
--   g.swap.set  slot spec   the slot now holds the part "spec" (ids.lua item string), or "-" for an empty slot
-- Fuel and battery work (guestact.lua) and the trunk (loot.lua) were already proven; this is the missing part install/remove.
-- Inert outside a session (Q7).
local UEHelpers = require("UEHelpers")
local common = require("common")
local safety = require("safety")
local net = require("net")
local car = require("car")
local ids = require("ids")
local ov = require("overlay")
local log = common.log

local M = {}
if os.getenv("PT_MUTATE") == "noswap" or not car.theCar then
    log("PT|guestswap disabled")
    return M
end

local function valid(o) return o ~= nil and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end
local HOLD = 4 -- s: the host's state message may still show the old part for a moment
local held = {} -- guest: slot name -> until (os.clock)

-- car.lua asks before it overwrites a slot with the host's state
function M.held(slot) return held[slot] ~= nil and held[slot] > os.clock() end
car.holdSlot = M.held

local function slotItem(slot)
    local cont = car.equipped()
    local found = false
    if cont then
        cont.Slots:ForEach(function(_, e)
            local s = e:get()
            if not found and car.slotName(s) == slot then found = { slot = s, item = car.itemOf(s) } end
        end)
    end
    return found
end

-- host: apply the guest's swap to the real car ---------------------------------------------------------------------------

net.on("g.swap.set", function(pc, data)
    if common.netMode() ~= "listen" or not safety.active() then return end
    local name, spec = data:match("^([^\t]+)\t(.*)$")
    local s = name and slotItem(name)
    if not s then log("PT|swap no slot %s", tostring(name)); return end
    if spec == "-" then
        if s.item then s.slot:RemoveAllItems({}) end
    else
        local p = spec:match("^[^:]+")
        if s.item and ids.path(s.item.Archetype) == p then
            ids.setProps(s.item, spec)
        else
            local arch = ids.archetype(p)
            if not arch then log("PT|error swap archetype %s", p); return end
            if s.item then s.slot:RemoveAllItems({}) end
            local inst = StaticFindObject("/Script/PenDriverInventory.Default__InventoryBlueprintLibrary"):CreateItemInstance(UEHelpers.GetWorld(), arch, 0)
            ids.setProps(inst, spec)
            s.slot:SetItem(inst, {})
        end
    end
    log("PT|swap applied %s %s", name, spec)
    ov.post(ov.nameOf(pc) .. (spec == "-" and " removed " or " installed ") .. name:match("[^%.]+$"), "good", "swap")
end)

-- guest: the game's own swap ----------------------------------------------------------------------------------------------

local function swapHook(self, _, interact, success)
    if common.netMode() ~= "client" or not safety.active() or not success:get() then return end
    local sl, nm = {}, {}
    interact:get():GetSlot(sl, nm)
    local name = nm.TagName:ToString():gsub("^Car%.Equip%.", "")
    local s = slotItem(name)
    if not s then return end
    local spec = s.item and ids.spec(s.item) or "-"
    held[name] = os.clock() + HOLD
    log("PT|swap send %s %s", name, spec)
    net.toHost("g.swap.set", name .. "\t" .. spec)
end

local done = false
LoopInGameThreadWithDelay(1000, function()
    if done or common.netMode() ~= "client" then return end
    local ok = pcall(RegisterHook, "/Game/Systems/Managers/BP_CarManager.BP_CarManager_C:Swap Equipment", function(...)
        local ok2, err = pcall(swapHook, ...)
        if not ok2 then log("PT|error guestswap hook %s", tostring(err)) end
    end)
    if ok then done = true; log("PT|guestswap hooked") end
end)

return M
