-- Anomaly leftovers (W6, docs/spikes/anomrest.md). The host runs every hazard; the guest's replicated copies play their own visuals.
--   Meteorite Squall (BP_Hazard_FallingPillarChunk, the meteors): a meteor falls for about a second and lies about 7 s; the 1 s sweep of
--   world.lua gave the guest a copy up to a second late, so its fall (the copy plays the whole fall itself) came after the host's impact.
--   Replicated as it begins play (like the lightning strike and the acid glob), the copy falls within a few frames of the host's.
--   Mutation noanomrest switches the module off. Inert outside a session (Q7).
local common = require("common")
local safety = require("safety")

local M = { enabled = os.getenv("PT_MUTATE") ~= "noanomrest" }
local CHUNK = "/Game/Gameplay/Hazards/FallingPillar/BP_Hazard_FallingPillarChunk.BP_Hazard_FallingPillarChunk_C"
local hooked = false
LoopInGameThreadWithDelay(2000, function()
    if hooked or not M.enabled then return end
    if not StaticFindObject(CHUNK):IsValid() then pcall(LoadAsset, CHUNK) end
    hooked = pcall(RegisterHook, CHUNK .. ":ReceiveBeginPlay", function(self)
        if safety.active() and not safety.guest() then pcall(common.replicateActor, self:get()) end
    end)
end)
return M
