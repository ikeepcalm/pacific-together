-- S7 guest saves blocked, G5 no Chrono Dilator in co-op (pause allowed, see below), Q7 inert outside a session, Q9 no crash upload.
-- Nothing here changes a setting in place: GameUserSettings.ini is rewritten on every map load and would keep it.
local UEHelpers = require("UEHelpers")
local common = require("common")
local log = common.log

local M = {}

-- guest = connected or connecting to a host (the pending connect already reports client)
function M.guest() return common.netMode() == "client" end

-- a session = we are the guest, or the host with a guest connected; a host listening alone is still single player
function M.active()
    local mode = common.netMode()
    if mode == "client" then return true end
    if mode ~= "listen" then return false end
    local d = UEHelpers.GetWorld().NetDriver
    return d:IsValid() and #d.ClientConnections > 0
end

local function hook(path, pre, post)
    local ok, err = pcall(RegisterHook, path, pre, post)
    if not ok then log("PT|error safety hook %s %s", path, tostring(err)) end
end

-- S7: the save manager's native writers. A pre-hook cannot cancel a call, so the slot is pointed at nothing (-1).
for _, fn in ipairs({ "SaveGame", "WriteGameplaySettingsToSlot", "DeleteGame", "Rinse" }) do
    hook("/Script/PenDriverPro.BaseSaveGameManager:" .. fn, function(self, slot)
        if not M.guest() then return end
        log("PT|safety blocked %s slot=%s", fn, tostring(slot:get()))
        slot:set(-1)
    end)
end
-- SaveCheckpoint, MakeBookmark, WriteUserSettings have no slot; the native file guard refuses what they write under
-- Saved/SaveGames and Content/Bookmarks, on while we are a guest (set around every map load: joining and leaving are map loads)
local function guard(on)
    if PTNative_SetSaveGuard then PTNative_SetSaveGuard(on) end
    common.crashBase = string.format("mod=%s guest=%s", common.MOD_VERSION, tostring(on))
    common.crumb("map load")
end
RegisterLoadMapPreHook(function(engine, world, url, pending)
    if pending:get():IsValid() then guard(true) end
end)
RegisterLoadMapPostHook(function() guard(M.guest()) end)

-- G5 pause: not blocked any more. Rewriting the pause to false let the host's pause menu run over an unpaused world, which
-- crashed the host (AV PenDriverPro+0x3160a56 reading 0x178, playtest 2026-10-21) and kept the guest's menu from opening.
-- The host's menu now pauses both players; a guest's pause cannot pause the host's world.

-- G5: the Chrono Dilator (BP_Attach_Util_Ability_TimeWarper_C) ramps global time dilation to 0.35 for everyone
hook("/Script/Engine.GameplayStatics:SetGlobalTimeDilation", function(self, ctx, dilation)
    local o = ctx:get()
    if o:IsValid() and o:GetClass():GetFName():ToString() == "BP_Attach_Util_Ability_TimeWarper_C" and M.active() then dilation:set(1.0) end
end)

-- Q9 (D16): while the mod is installed, crashes are never uploaded. The native layer refuses sentry_init and never
-- starts CrashReportClient; the empty DSN (in memory only, the settings object is never saved) covers a missing DLL.
local sentry = StaticFindObject("/Script/Sentry.Default__SentrySettings")
if sentry:IsValid() then sentry.DsnUrl = "" end

return M
