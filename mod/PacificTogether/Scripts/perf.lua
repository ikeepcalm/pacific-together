-- Performance mode (owner request 2026-10-31: a weak PC fell to 12 FPS). F9 menu item 5 (rescue.lua) switches it on or off for this player only; it is
-- remembered in performance.txt next to the Scripts folder and applied again at the next start. It trades looks for frames with the
-- engine's own console variables: lower render scale, shorter view and shadow distance, thinner foliage, no volumetric fog, screen
-- space reflections, ambient occlusion, motion blur or depth of field. Works in single player too: it changes rendering only.
-- Off: the game's own Graphics settings are applied again (the Settings menu values), so nothing has to be restored by hand.
local UEHelpers = require("UEHelpers")
local common = require("common")
local log = common.log

local M = {}
local DIR = (debug.getinfo(1, "S").source:match("^@(.*[\\/])Scripts[\\/]") or "")
local FILE = DIR .. "performance.txt"

local ON = {
    "r.ScreenPercentage 70", "r.ViewDistanceScale 0.6", "foliage.DensityScale 0.4", "grass.DensityScale 0.4",
    "r.Shadow.MaxResolution 1024", "r.Shadow.DistanceScale 0.6", "r.Shadow.CSM.MaxCascades 2", "r.VolumetricFog 0",
    "r.SSR.Quality 0", "r.AmbientOcclusionLevels 0", "r.MotionBlurQuality 0", "r.DepthOfFieldQuality 0", "r.LensFlareQuality 0",
    "r.SceneColorFringeQuality 0", "r.BloomQuality 2", "r.MaxAnisotropy 4",
}

local function enabled()
    local f = io.open(FILE, "r")
    if not f then return false end
    local s = f:read("*l")
    f:close()
    return s == "on"
end

local function run(cmd)
    local pc = UEHelpers.GetPlayerController()
    if not (pc and pc:IsValid()) then return false end
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(UEHelpers.GetWorld(), cmd, pc)
    return true
end

local function apply(on)
    if on then
        for _, c in ipairs(ON) do if not run(c) then return false end end
    else
        -- the player's own settings again: GameUserSettings re-applies every scalability group and the resolution scale
        run("r.ScreenPercentage 100")
        local ok, err = pcall(function()
            StaticFindObject("/Script/Engine.Default__GameUserSettings"):GetGameUserSettings():ApplySettings(false)
        end)
        if not ok then log("PT|perf mode could not re-apply the settings %s", tostring(err)) end
    end
    return true
end

-- F10 opened the UE4SS console instead (hand test 2026-11-01): the F9 menu calls this
M.enabled = enabled
function M.toggle()
    local on = not enabled()
    local f = io.open(FILE, "w")
    if f then f:write(on and "on" or "off"); f:close() end
    apply(on)
    log("PT|perf mode %s", on and "on" or "off")
    return on and "Performance mode on" or "Performance mode off"
end

-- a map load resets nothing of these, but the first start needs a controller: try until it took, then after every map load
-- (the game re-applies its own settings when a level loads its world settings)
local pending = enabled()
RegisterLoadMapPostHook(function() pending = enabled() end)
LoopInGameThreadWithDelay(2000, function()
    if pending and apply(true) then pending = false; log("PT|perf mode applied") end
end)

return M
