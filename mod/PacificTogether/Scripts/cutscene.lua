-- The new-game opening (the story title cards) is skipped with E, for both players at once (from PDCoopNet's cutscene.lua, MIT,
-- BroZYTnikkkk). The intro map's level script skips it itself on Interact while its CanSkip is set (it moves the opening sequence to
-- its end), but the player controller binds Interact too, consumes the key and comes first in the input stack: in co-op nobody could
-- skip it (PDCoopNet owner's playtest; calling the level's Interact event directly skipped at once, their exp232).
--   E while a level can skip: skip here, and "g.cut.skip" to the other side; the host passes a guest's skip on to every guest.
-- Inert outside a session (Q7).
local common = require("common")
local net = require("net")
local safety = require("safety")
local log = common.log

local M = { enabled = os.getenv("PT_MUTATE") ~= "nocutscene" }
local INTERACT = "InpActEvt_Interact_K2Node_InputActionEvent_0"

-- the intro's level scripts that can skip now; a stale copy in /Engine/Transient keeps CanSkip true for good (seen on a host,
-- 2026-10-28): pressing it does nothing, and the live one in the PersistentLevel stayed unskipped
-- garage level scripts have a CanSkip too but no Interact event: every E logged an error (hand test 2026-11-01); skipped after one try
local bad = {}
local function levels()
    local r = {}
    for _, l in ipairs(FindAllOf("LevelScriptActor") or {}) do
        local ok, can = pcall(function() return l:IsValid() and l.CanSkip == true and not l:GetFullName():find("/Engine/Transient", 1, true)
            and not bad[l:GetFullName()] end)
        if ok and can == true then r[#r + 1] = l end
    end
    return r
end
local function skippable() return levels()[1] end

local function skipHere(why)
    local any = false
    for _, l in ipairs(levels()) do
        local ok, err = pcall(function() l[INTERACT](l, { KeyName = FName("E") }) end)
        log("PT|cutscene opening skipped (%s) ok=%s %s", why, tostring(ok), ok and "" or tostring(err))
        if not ok then pcall(function() bad[l:GetFullName()] = true end) end
        any = any or ok
    end
    return any
end

local function skip(why)
    if not (M.enabled and safety.active()) or not skippable() then return end
    skipHere(why)
    if safety.guest() then net.toHost("g.cut.skip", "") else net.toGuests("g.cut.skip", "") end
end
common.onKey("E", function() skip("E") end)
-- the test mod is another Lua state: its scenario presses E through the console ("ptskip"), same handler, on the game thread
local wanted = false
pcall(RegisterConsoleCommandHandler, "ptskip", function() wanted = true return true end)
LoopInGameThreadWithDelay(100, function() if wanted then wanted = false; skip("ptskip") end end)

net.on("g.cut.skip", function(pc)
    if not (M.enabled and safety.active()) then return end
    skipHere(safety.guest() and "the host's skip" or "the guest's E")
    if not safety.guest() then
        for _, g in ipairs(net.guests()) do if g:GetAddress() ~= pc:GetAddress() then net.toGuest(g, "g.cut.skip", "") end end
    end
end)

return M
