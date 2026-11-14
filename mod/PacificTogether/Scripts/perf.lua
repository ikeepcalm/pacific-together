-- Performance mode (owner request 2026-10-31: a weak PC fell to 12 FPS). F9 menu item 5 (rescue.lua) switches it on or off for this player only; it is
-- remembered in performance.txt next to the Scripts folder and applied again at the next start. It is aimed at a CPU-bound machine
-- (a friend's RTX 3050 laptop: 30 FPS on the lowest settings, DLSS changed nothing; 2026-11-01): the car mirror and the two rain
-- cameras draw the scene again every frame, here 10 times a second instead (54 -> 60 FPS on a CPU-bound test pair with them off),
-- and the engine's own console variables shorten view and shadow distance, thin foliage and drop volumetric fog, screen space
-- reflections, ambient occlusion, motion blur and depth of field. The render resolution stays (it does not help a CPU-bound
-- machine and looked worse). Works in single player too: it changes rendering only.
-- Off: the game's own Graphics settings are applied again (the Settings menu values), so nothing has to be restored by hand.
local UEHelpers = require("UEHelpers")
local common = require("common")
local log = common.log

local M = {}
local DIR = (debug.getinfo(1, "S").source:match("^@(.*[\\/])Scripts[\\/]") or "")
local FILE = DIR .. "performance.txt"

local ON = {
    "r.ViewDistanceScale 0.6", "foliage.DensityScale 0.4", "grass.DensityScale 0.4",
    "r.Shadow.MaxResolution 1024", "r.Shadow.DistanceScale 0.6", "r.Shadow.CSM.MaxCascades 2", "r.VolumetricFog 0",
    "r.SSR.Quality 0", "r.AmbientOcclusionLevels 0", "r.MotionBlurQuality 0", "r.DepthOfFieldQuality 0", "r.LensFlareQuality 0",
    "r.SceneColorFringeQuality 0", "r.BloomQuality 2", "r.MaxAnisotropy 4",
}

-- performance.txt: "on" or "off" = the player's own choice, which always wins; no file = automatic (owner request 2026-11-14,
-- a friend hosting ran 10-40 FPS with the mod): see autoTick below.
local function manual()
    local f = io.open(FILE, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return (s == "on" or s == "off") and s or nil
end
local autoOn = false -- the automatic mode has switched it on
local function enabled()
    local m = manual()
    if m then return m == "on" end
    return autoOn
end

local function run(cmd)
    local pc = UEHelpers.GetPlayerController()
    if not (pc and pc:IsValid()) then return false end
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(UEHelpers.GetWorld(), cmd, pc)
    return true
end

-- the scene captures that draw every frame (the mirror, the rain simulation on the car, the rain occlusion camera)
local SLOW = { ScenecaptureMirror = true, Capture_RainSim = true, rainOcclusionCamera_Blueprint_C = true }
local slowed, slowAt, slowOn = {}, -99, false
local function slowCaptures(on)
    slowOn = on
    if not on then
        for _, c in ipairs(slowed) do pcall(function() if c:IsValid() then c.bCaptureEveryFrame = true end end) end
        slowed = {}
    end
end
LoopInGameThreadWithDelay(100, function()
    if not slowOn then return end
    pcall(function()
        if os.clock() - slowAt > 5 then -- a new car or map: look again
            slowAt, slowed = os.clock(), {}
            for _, c in ipairs(FindAllOf("SceneCaptureComponent2D") or {}) do
                if c:IsValid() and c:IsActive() then
                    local o = c:GetOwner()
                    if SLOW[c:GetFName():ToString()] or (o:IsValid() and SLOW[o:GetClass():GetFName():ToString()]) then slowed[#slowed + 1] = c end
                end
            end
        end
        for _, c in ipairs(slowed) do
            if c:IsValid() then
                if c.bCaptureEveryFrame then c.bCaptureEveryFrame = false end
                c:CaptureScene()
            end
        end
    end)
end)

local function apply(on)
    slowCaptures(on)
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
M.WIN = 10 -- seconds per FPS window of the automatic mode; tests shorten it
function M.autoActive() return autoOn end
function M.label()
    local m = manual()
    return m or ("auto (" .. (autoOn and "on" or "off") .. ")")
end
-- F9 item 5 cycles automatic -> on -> off -> automatic
function M.toggle()
    local before, m = enabled(), manual()
    local nxt = (m == nil and "on") or (m == "on" and "off") or nil
    if nxt then
        local f = io.open(FILE, "w")
        if f then f:write(nxt); f:close() end
    else
        os.remove(FILE)
    end
    autoOn = false
    if enabled() ~= before then apply(enabled()) end
    log("PT|perf mode %s", M.label())
    return "Performance mode: " .. M.label()
end

-- Performance check (F9 item 6; owner request 2026-11-01: a friend's RTX 3050 laptop ran 30 FPS on low): 5 s of frames as set,
-- 5 s at half the render resolution, then the resolution back. Much faster at half: the GPU limits (DLSS, mirrors, fog help);
-- about the same: the CPU limits (resolution does not help). The result and the settings that matter go on screen and to the log.
local check
local function realNow()
    local s, p = {}, {}
    UEHelpers.GetGameplayStatics():GetAccurateRealTime(s, p)
    return s.Seconds + p.PartialSeconds
end
local function report(fps1, fps2, sp)
    local ksl, gus = UEHelpers.GetKismetSystemLibrary(), FindFirstOf("DrivingGameUserSettings")
    local s = {}
    pcall(function()
        local r = gus:GetScreenResolution()
        s[#s + 1] = string.format("%dx%d at %.0f%%", r.X, r.Y, sp)
        s[#s + 1] = "DLSS " .. tostring(gus.DLSSMode)
        s[#s + 1] = "cap " .. tostring(gus.MaxFPS) .. (gus:IsVSyncEnabled() and " vsync" or "")
        s[#s + 1] = "quality " .. tostring(gus:GetOverallScalabilityLevel())
        s[#s + 1] = string.format("mirrors %.2f/%d", gus.MirrorResolutionScale, gus.MirrorDrawDistance)
    end)
    local gpu = fps2 > fps1 * 1.25
    local verdict = gpu and "GPU-limited: DLSS or a lower render scale will help" or "CPU-limited: resolution will not help"
    local text = string.format("Performance check: %.0f FPS, %.0f at half resolution. %s. %s", fps1, fps2, verdict, table.concat(s, ", "))
    log("PT|perf check %s", text)
    return text
end
function M.check(done)
    if check then return "Performance check already running" end
    check = { phase = 1, frames = 0, t0 = realNow(), done = done }
    log("PT|perf check started")
    return "Performance check: 10 s, keep playing as usual"
end
-- Automatic mode: 3 windows in a row under LOW FPS (not within 6 windows of a map load) switch performance mode on. Two settled
-- windows later the FPS must be GAIN times the FPS before; if not, it did not help (CPU or game thread limits, not what it
-- changes): back off and do not try again for 10 minutes. Mutations: noautoperf (never), autoignoresmanual (ignores the player's choice).
local GAIN = 1.15
M.LOW = 25 -- FPS; tests raise it (a headless game ignores t.MaxFPS)
local wf, wAt, loadedAt = 0, os.clock(), os.clock()
local low, base, trial, acc, blockedUntil = 0, 0, 0, 0, 0
local function autoTick(fps)
    local mut = os.getenv("PT_MUTATE")
    if mut == "noautoperf" then return end
    if manual() and mut ~= "autoignoresmanual" then low, autoOn = 0, false; return end
    if os.clock() - loadedAt < 6 * M.WIN then low = 0; return end
    if not autoOn then
        low = fps < M.LOW and low + 1 or 0
        if low >= 3 and os.clock() >= blockedUntil then
            base, low, trial, acc, autoOn = fps, 0, 0, 0, true
            apply(true)
            log("PT|perf auto on (%.1f FPS)", fps)
            pcall(function() require("overlay").post(string.format("Performance mode switched on automatically (%.0f FPS)", fps), "info", "perfauto") end)
        end
        return
    end
    if trial == nil then return end -- kept
    trial = trial + 1
    if trial == 1 then return end -- the settings take a moment
    acc = acc + fps
    if trial < 3 then return end
    trial = nil
    if acc / 2 >= base * GAIN then log("PT|perf auto kept (%.1f -> %.1f FPS)", base, acc / 2); return end
    autoOn, blockedUntil = false, os.clock() + 600
    apply(false)
    log("PT|perf auto off, no gain (%.1f -> %.1f FPS)", base, acc / 2)
end
-- FPS every minute next to the PT|perf rows (friend host 10 FPS vs 30 alone, 2026-11-11: no number to compare); this loop runs once a frame
local frames, fpsAt = 0, os.clock()
LoopInGameThreadWithDelay(1, function()
    frames = frames + 1
    local dt = os.clock() - fpsAt
    if dt >= 60 then
        log("PT|perf fps %.1f peers=%d", frames / dt, #(FindAllOf("PlayerController") or {}))
        frames, fpsAt = 0, os.clock()
    end
    wf = wf + 1
    local wdt = os.clock() - wAt
    if wdt >= M.WIN then
        local fps = wf / wdt
        wf, wAt = 0, os.clock()
        local ok, err = pcall(autoTick, fps)
        if not ok then log("PT|error perf auto %s", tostring(err)) end
    end
    local c = check
    if not c then return end
    c.frames = c.frames + 1
    local t = realNow() - c.t0
    if t < 5 then return end
    local ok, err = pcall(function()
        if c.phase == 1 then
            c.fps1 = c.frames / t
            c.sp = UEHelpers.GetKismetSystemLibrary():GetConsoleVariableFloatValue("r.ScreenPercentage")
            if not c.sp or c.sp <= 0 then c.sp = 100 end
            run("r.ScreenPercentage 50")
            c.phase, c.frames, c.t0 = 2, 0, realNow()
            return
        end
        check = nil
        run("r.ScreenPercentage " .. string.format("%.0f", c.sp))
        local text = report(c.fps1, c.frames / t, c.sp)
        if c.done then c.done(text) end
    end)
    if not ok then check = nil; log("PT|error perf check %s", tostring(err)) end
end)
pcall(RegisterConsoleCommandHandler, "ptperfcheck", function() M.check(); return true end)
-- tests: performance mode on and off without the F9 menu (a single game has no session)
pcall(RegisterConsoleCommandHandler, "ptperfmode", function() M.toggle(); return true end)
pcall(RegisterConsoleCommandHandler, "ptperfwin", function(full) M.WIN = tonumber(tostring(full):match("(%d+)")) or 10; return true end)
pcall(RegisterConsoleCommandHandler, "ptperflow", function(full) M.LOW = tonumber(tostring(full):match("(%d+)")) or 25; return true end)

-- a map load resets nothing of these, but the first start needs a controller: try until it took, then after every map load
-- (the game re-applies its own settings when a level loads its world settings)
local pending = enabled()
RegisterLoadMapPostHook(function() pending = enabled(); loadedAt = os.clock(); low = 0 end)
LoopInGameThreadWithDelay(2000, function()
    if pending and apply(true) then pending = false; log("PT|perf mode applied") end
end)

return M
