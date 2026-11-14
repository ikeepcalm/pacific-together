-- Automatic performance mode (perf.lua, owner request 2026-11-14): sustained low FPS (perf.LOW raised above the FPS (a headless game ignores t.MaxFPS)) switches it on by itself,
-- it goes back off when the FPS did not improve (a frame cap is not something it can fix), and the player's own choice (F9 5 set to
-- "off") always wins. Window shortened to 2 s (console ptperfwin). The state is read from the mod's own log lines (the engine's
-- scalability cvars do not come back headless, so they say nothing about "off").
-- Run: tools/run-test.ps1 -Scenario perfauto -Fixture garage -Clients 1 -Headless
-- Mutations: noautoperf (never switches on: auto_on fails), autoignoresmanual (switches on against the player's "off": manual_off_wins fails).
return function(T)
    if T.ROLE ~= "host" then return { T.onMap("RB_MainMenu", 90) } end
    local function count(what)
        local f = io.open("ue4ss/UE4SS.log", "rb"); if not f then return 0 end
        local s = f:read("*a"); f:close()
        local n = 0
        for _ in s:gmatch(what) do n = n + 1 end
        return n
    end
    local steps = {}
    local function add(s) steps[#steps + 1] = s end
    for _, s in ipairs(T.loadFixture("garage")) do add(s) end
    -- auto -> on -> off (the player's choice)
    add({ run = function() T.console("ptperfwin 2"); T.console("ptperflow 100000"); T.console("ptperfmode"); T.console("ptperfmode") end })
    local t0
    add({ run = function() t0 = os.clock() end })
    add({ check = "manual_off_wins", timeout = 40, cond = function()
        if count("PT|perf auto on") > 0 then return false end
        return os.clock() - t0 > 15
    end })
    add({ run = function() T.console("ptperfmode") end }) -- off -> auto
    add({ check = "auto_on", timeout = 60, cond = function() return count("PT|perf auto on") >= 1 end })
    add({ check = "auto_reverts_no_gain", timeout = 60, cond = function() return count("PT|perf auto off, no gain") >= 1 end })
    add({ run = function() T.console("ptperflow 25") end })
    return steps
end
