-- Anomaly leftovers (W6, docs/spikes/anomrest.md). The host runs every hazard; the guest's replicated copies play their own visuals.
--   Meteorite Squall (BP_Hazard_FallingPillarChunk, the meteors): a meteor falls for about a second and lies about 7 s; the 1 s sweep of
--   world.lua gave the guest a copy up to a second late, so its fall (the copy plays the whole fall itself) came after the host's impact.
--   Replicated as it begins play (like the lightning strike and the acid glob), the copy falls within a few frames of the host's.
--   Minuteman (BP_Hazard_Movement_Prong): it rises, stands TimeActive seconds, retracts and destroys itself on the host (the guest's copy
--   "dying after 3 s" was that destroy, replicated). The copy's own rise never starts (its Cylinder stays 200 uu under ground, the
--   Minuteman was invisible to the guest): replicated as it begins play, and the guest puts the Cylinder up at once.
-- Mutation noanomrest switches the module off. Inert outside a session (Q7).
local common = require("common")
local safety = require("safety")

local M = { enabled = os.getenv("PT_MUTATE") ~= "noanomrest" }
local FP, MV = "/Game/Gameplay/Hazards/FallingPillar/", "/Game/Gameplay/Hazards/MovementHazard/"
local CLASSES = {
    { FP .. "BP_Hazard_FallingPillarChunk.BP_Hazard_FallingPillarChunk_C" },
    { MV .. "BP_Hazard_Movement_Prong.BP_Hazard_Movement_Prong_C", function(a)
        a.Cylinder:K2_SetRelativeLocation({ X = 0, Y = 0, Z = a.RandomHeight }, false, {}, false)
    end },
}
for _, c in ipairs(CLASSES) do
    local path, onGuest, hooked = c[1], c[2], false
    LoopInGameThreadWithDelay(2000, function()
        if hooked or not M.enabled then return end
        if not StaticFindObject(path):IsValid() then pcall(LoadAsset, path) end
        hooked = pcall(RegisterHook, path .. ":ReceiveBeginPlay", function(self)
            if not safety.active() then return end
            local a = self:get()
            if not safety.guest() then pcall(common.replicateActor, a)
            elseif onGuest then
                common.defer(300, function()
                    if a:IsValid() and a.Role == 1 then
                        local ok, err = pcall(onGuest, a)
                        if not ok then common.log("PT|error anomrest %s %s", path:match("([^.]+)_C$"), tostring(err)) end
                    end
                end)
            end
        end)
    end)
end
return M
