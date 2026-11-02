# Runs one test scenario on the test copies (client1 = host, client2 = client) and judges the PT| lines in UE4SS.log.
# Exit code 0 = every check passed. Results go to local\test-results\<stamp>-<scenario>.
param(
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string]$Root = "C:\PacificTogetherTest",
    [ValidateSet(0, 1, 2)][int]$Clients = 0,
    [int]$Seconds = 0,
    [string]$Mutate = "",
    [switch]$KeepOpen,
    [switch]$Headless,
    # parallel lanes must not share a port: a guest would join another lane's host
    [int]$Port = 7777,
    # lanes run from worktrees that get deleted, so they point this at the main repo's local\test-results
    [string]$ResultsDir = "",
    # copy local/fixtures/<name>/*.sav into the host copy's Saved/SaveGames for the run (its own saves are restored after) and set PT_FIXTURE
    [string]$Fixture = "",
    [string]$FixturesDir = "",
    # X5: "udp [lag=ms] [loss=pct] [hold=s]" runs the scenario through the native tunnel (test Scripts/tunnel.lua)
    [string]$Tunnel = ""
)
$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path "$PSScriptRoot\..").Path
$BinRel = "PenDriverPro\Binaries\Win64"
$Defaults = @{ boot = @(2, 150); listen = @(2, 330); dump = @(1, 600); travel = @(2, 1500); zonejoin = @(2, 420); guestsave = @(2, 1200); body = @(2, 420); fixtureload = @(1, 300); session = @(2, 1500); sessionmismatch = @(2, 420); sessionsolo = @(1, 600); sessionrejoin = @(2, 900); safety = @(2, 600); x2garage = @(2, 420); x2zone = @(2, 420); sessionabrupt = @(2, 900); sessionabruptzone = @(2, 900); sessiontravel = @(2, 1500); safetysaves = @(2, 900); carenter = @(2, 1200); reload = @(2, 900); channel = @(2, 600); playerhealth = @(2, 900); worldsync = @(2, 600); weathersync = @(2, 600); anchordup = @(2, 600); carsync = @(2, 900); lootsync = @(2, 900); backpacksync = @(2, 1500); guestact = @(2, 900); lootsync2 = @(2, 900); storysync = @(2, 900); anomalies = @(2, 900); progsync = @(2, 900); overlay = @(2, 900); playpath = @(2, 1500); anomalies2 = @(2, 1200); pausemenu = @(2, 1200); garagesync = @(2, 900); lootcar = @(2, 1200); dropfall = @(2, 900); guestdeath = @(2, 900); guestcraft = @(2, 1500); carexit = @(2, 1200); carsit = @(2, 1200); arckey = @(2, 1200); runloop = @(2, 1800); guestparts = @(2, 1800); carfeel = @(2, 1200); guestswap = @(2, 900); anomalies3 = @(2, 1500); storyprog = @(2, 1200); mapmark = @(2, 1200); ping = @(2, 900); steamsession = @(2, 900); steamplayhost = @(1, 1800); steamplayguest = @(1, 1800); upgrades = @(2, 1500); stations = @(2, 1500); hands = @(2, 900); visual = @(2, 1200); visualgarage = @(2, 900); carrelevant = @(2, 900); netflow = @(2, 900); zoneexit = @(2, 1200); zonespawn = @(2, 1200); guestui = @(2, 1200); worlddoors = @(2, 900); worldzone = @(2, 1200); radiation = @(2, 900); wheelflat = @(2, 900); portals = @(2, 900); pausehost = @(2, 1200); anomtesla = @(2, 1200); survivor = @(2, 600); transition = @(2, 1200); arcui = @(2, 900); radio = @(2, 900); bigjoin = @(2, 600); frames = @(2, 600); desync = @(2, 600); netspeed = @(2, 600); cutscene = @(2, 1200); carcrash = @(2, 900); carseat = @(2, 900); storagelayout = @(2, 900); doubledoor = @(2, 900); guestctl = @(2, 900); q01anchor = @(2, 900); sharedworld = @(2, 900); rescue = @(2, 900); keypad = @(2, 900) }
# M2: in these scenarios the shipping mod's guest joins by itself (PT_JOIN), the test mod never runs `open`
$AutoJoin = @("repl", "session", "sessionlook", "sessionprobe", "sessionrejoin", "sessionabrupt", "sessionabruptzone", "sessiontravel", "carenter", "reload", "channel", "playerhealth", "worldsync", "weathersync", "anchordup", "carsync", "lootsync", "backpacksync", "guestact", "lootsync2", "storysync", "anomalies", "progsync", "overlay", "playpath", "anomalies2", "pausemenu", "garagesync", "guestparts", "lootcar", "dropfall", "guestdeath", "guestcraft", "carexit", "carsit", "arckey", "runloop", "carfeel", "guestswap", "anomalies3", "storyprog", "mapmark", "ping", "upgrades", "stations", "hands", "visual", "visualgarage", "carrelevant", "netflow", "zoneexit", "zonespawn", "guestui", "worlddoors", "worldzone", "radiation", "wheelflat", "portals", "pausehost", "anomtesla", "transition", "arcui", "radio", "bigjoin", "frames", "desync", "netspeed", "cutscene", "carcrash", "carseat", "storagelayout", "doubledoor", "guestctl", "q01anchor", "sharedworld", "rescue", "keypad")
$Defaults.boons = @(2, 600)
$AutoJoin += "boons"
$Defaults.itemphysics = @(2, 600)
$AutoJoin += "itemphysics"
$Defaults.damagefeedback = @(2, 600)
$Defaults.progressquiet = @(2, 600)
$AutoJoin += "damagefeedback", "progressquiet"
$Defaults.mail = @(2, 300)
$AutoJoin += "mail"
$Defaults.keyedges = @(1, 180)
$Defaults.messageepoch = @(1, 180)
$Defaults.worldactions = @(1, 180)
$Defaults.seatepoch = @(2, 300)
$AutoJoin += "seatepoch"
# per-run Engine.ini additions, restored after the run; the mutations in skip run without them
$IniEdits = @{ zonejoin = @{ client = "[/Script/OnlineSubsystemUtils.IpNetDriver]`r`nResolutionConnectionTimeout=120`r`n"; skip = @("noconfig", "cdo") } }
# M6: the shipping mod's Steam lobby/join runs in these scenarios only (test runs keep it off so they never touch the owner's Steam presence);
# the guest's join request comes through a file instead of Steam's command line (steam.lua inbox)
$SteamMod = @("steamsession", "steamplayhost", "steamplayguest")
$Root = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
# Q9: a side crashes on purpose, so the run needs that crash instead of "no crash" and keeps waiting after it
$CrashExpected = @("safety_crash", "crashfw")
# S5: a scenario asks the runner to kill a side (PT|runner kill side=<role> n=<k>) and start it again later
# (PT|runner relaunch side=<role> n=<k>; the new process gets PT_LIFE=2, 3, ...); an exit after a kill is no failure
$KillExpected = @("sessionabrupt", "sessionabruptzone")
$d = if ($Defaults.ContainsKey($Scenario)) { $Defaults[$Scenario] } else { @(2, 300) }
if (-not $Clients) { $Clients = $d[0] }
if (-not $Seconds) { $Seconds = $d[1] }
$DumpOutputs = "UHTHeaderDump", "CXXHeaderDump", "*.usmap", "Mods\shared\types"

$sides = @(@(
    @{ Role = "host"; Dir = Join-Path $Root "client1" },
    @{ Role = "client"; Dir = Join-Path $Root "client2" }
) | Select-Object -First $Clients)
foreach ($s in $sides) {
    $s.Bin = Join-Path $s.Dir $BinRel
    $s.Log = Join-Path $s.Bin "ue4ss\UE4SS.log"
    $s.Crashes = Join-Path $s.Dir "PenDriverPro\Saved\Crashes"
    $s.Ini = Join-Path $s.Dir "PenDriverPro\Saved\Config\WindowsNoEditor\Engine.ini"
    $s.Snaps = [ordered]@{}
    $s.Prefix = ""; $s.Life = 1
    if (-not (Test-Path "$($s.Bin)\ue4ss\Mods\PacificTogetherTest")) { throw "$($s.Dir) is not set up; run tools\setup-test.ps1" }
    if (-not (Test-Path "$($s.Bin)\ue4ss\Mods\PacificTogetherNative")) { throw "$($s.Dir) has no PacificTogetherNative mod (main.dll moved there); run tools\setup-test.ps1 again" }
}

function Get-TestProcesses($names) {
    Get-Process -Name $names -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith("$Root\", "OrdinalIgnoreCase") }
}
# UE4SS keeps its log open while the game runs
function Read-Shared($path) {
    if (-not (Test-Path $path)) { return "" }
    $r = New-Object IO.StreamReader([IO.File]::Open($path, "Open", "Read", "ReadWrite, Delete"))
    try { $r.ReadToEnd() } finally { $r.Close() }
}

# the log of every life of a side: a relaunch moves the old log into $s.Prefix before the new process truncates it
function Get-Log($s) { $s.Prefix + (Read-Shared $s.Log) }

# X10: names, sizes, times and hashes of everything under Saved\SaveGames and Saved\Config
function Get-Snapshot($s) {
    $base = Join-Path $s.Dir "PenDriverPro\Saved"
    foreach ($sub in "SaveGames", "Config") {
        Get-ChildItem (Join-Path $base $sub) -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $stream = [IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $h = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
            finally { $sha.Dispose(); $stream.Dispose() }
            "{0}`t{1}`t{2:o}`t{3}" -f $_.FullName.Substring($base.Length + 1), $_.Length, $_.LastWriteTimeUtc, $h
        }
    }
}
# a side prints PT|snap side=<role> tag=<tag>; the runner snapshots that side within one poll (3 s)
function Update-Snapshots {
    foreach ($s in $sides) {
        foreach ($m in [regex]::Matches((Get-Log $s), "PT\|snap side=$($s.Role) tag=(\S+)")) {
            $tag = $m.Groups[1].Value
            if (-not $s.Snaps.Contains($tag)) { $s.Snaps[$tag] = @(Get-Snapshot $s) }
        }
    }
}

$running = @(Get-TestProcesses "PenDriverPro-Win64-Shipping", "PenDriverPro")
if ($running) {
    Write-Host "A game from $Root is already running (PID $($running.Id -join ', ')). Close it first; this script only stops games it started."
    exit 2
}

# at most $env:PT_SLOTS (default 4) runs at once across all lanes on this machine; a dead runner's mutex is abandoned and reusable
$maxSlots = if ($env:PT_SLOTS) { [int]$env:PT_SLOTS } else { 4 }
$slot = $null
while (-not $slot) {
    foreach ($i in 1..$maxSlots) {
        $m = New-Object Threading.Mutex($false, "Local\PacificTogetherGameSlot$i")
        try { if ($m.WaitOne(0)) { $slot = $m; break } } catch [Threading.AbandonedMutexException] { $slot = $m; break }
        $m.Dispose()
    }
    if (-not $slot) { Write-Host "all $maxSlots game slots busy, waiting"; Start-Sleep 10 }
}

$oldCrashes = @{}
foreach ($s in $sides) {
    Remove-Item $s.Log -ErrorAction SilentlyContinue
    $oldCrashes[$s.Role] = @(Get-ChildItem $s.Crashes -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    if ($Scenario -eq "dump") { foreach ($o in $DumpOutputs) { Remove-Item "$($s.Bin)\ue4ss\$o" -Recurse -Force -ErrorAction SilentlyContinue } }
}

$edit = $IniEdits[$Scenario]
foreach ($s in $sides) {
    if ($edit -and $edit[$s.Role] -and $edit.skip -notcontains $Mutate) {
        # each copy has its own Saved\Config (not hardlinked), so this only changes this copy
        $s.IniBackup = [IO.File]::ReadAllBytes($s.Ini)
        [IO.File]::AppendAllText($s.Ini, "`r`n" + $edit[$s.Role])
        Write-Host "$($s.Role): appended to $($s.Ini)"
    }
}

# fixture saves: the host copy's SaveGames is moved aside and restored in the end (a leftover .ptbak from a killed run is restored first)
$saveDir = Join-Path $sides[0].Dir "PenDriverPro\Saved\SaveGames"
if (Test-Path "$saveDir.ptbak") { Remove-Item $saveDir -Recurse -Force -ErrorAction SilentlyContinue; Rename-Item "$saveDir.ptbak" (Split-Path $saveDir -Leaf) }
if ($Fixture) {
    if (-not $FixturesDir) { $FixturesDir = Join-Path $Repo "local\fixtures" }
    # a comma list loads several fixtures (each uses its own slot)
    $fxDirs = @($Fixture -split "," | ForEach-Object { Join-Path $FixturesDir $_.Trim() })
    foreach ($fx in $fxDirs) { if (-not (Get-ChildItem $fx -Filter *.sav -ErrorAction SilentlyContinue)) { throw "no fixture saves in $fx" } }
    if (Test-Path $saveDir) { Rename-Item $saveDir "$(Split-Path $saveDir -Leaf).ptbak" }
    New-Item -ItemType Directory $saveDir | Out-Null
    foreach ($fx in $fxDirs) { Copy-Item "$fx\*.sav" $saveDir }
    # fixtures made by the game MCP (fixture_save) carry fixture.json {slot,map}; the test mod reads PT_FIXTURE_SPEC for them
    $env:PT_FIXTURE_SPEC = ($fxDirs | Where-Object { Test-Path "$_\fixture.json" } | ForEach-Object { $j = Get-Content "$_\fixture.json" -Raw | ConvertFrom-Json; "$(Split-Path $_ -Leaf)=$($j.slot):$($j.map)" }) -join ","
    Write-Host "fixture $Fixture -> $saveDir"
}

$started = Get-Date
$procs = @()
function Start-Side($s, $life) {
    $env:PT_SCENARIO = $Scenario; $env:PT_STATUS = "2000"; $env:PT_HOST = "127.0.0.1:$Port"; $env:PT_MUTATE = $Mutate; $env:PT_FIXTURE = $Fixture
    if ($Tunnel) { $env:PT_TUNNEL = $Tunnel }
    $env:PT_LIFE = "$life"
    $env:PT_HEADLESS = if ($Headless) { "1" } else { $null }  # -nullrhi makes no particle effects: checks on them skip
    if ($SteamMod -contains $Scenario) { $env:PT_STEAM = "1"; $env:PT_STEAM_INBOX = Join-Path $Root "steam-inbox.txt" }
    # one account cannot message itself across processes (X6): the two-client test carries the tunnel over loopback UDP, the real two-account scenarios over Steam
    if ($Scenario -eq "steamsession") { $env:PT_STEAM_UDP = "$($Port + 1000)" }
    $env:PT_CRASH_GARAGE = if ($Scenario -eq "carcrash") { "1" } else { $null }  # anomalies.lua: crash damage reaches a seated guest in the garage too (test only)
    $env:PT_VISUAL_ZONE = if ($Scenario -eq "visual") { "1" } else { $null }  # the zone props mirror is on by default (visual.lua); null keeps it on, "0" would turn it off
    try {
        $env:PT_ROLE = $s.Role
        $env:PT_JOIN = if ($s.Role -eq "client" -and $AutoJoin -contains $Scenario) {
            if ($Tunnel -and $Mutate -ne "tunnelbypass") { "10.77.0.1:$Port" } else { "127.0.0.1:$Port" }
        } else { "" }
        $exe = Join-Path $s.Bin "PenDriverPro-Win64-Shipping.exe"
        # -nullrhi: no rendering, ~1 GB RAM and no GPU per instance, so many lanes can test at once; screenshots need a normal run
        $gameArgs = if ($Headless) { "-NotInstalled", "-nullrhi", "-nosound", "-log", "-port=$Port" } else {
            Add-Type -AssemblyName System.Windows.Forms
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea  # side by side, half the screen each (see play-local.ps1)
            $rx = [int]($wa.Width / 2) - 16
            "-NotInstalled", "-windowed", "-ResX=$rx", "-ResY=$([int]($rx * 9 / 16))", "-WinX=$(if ($s.Role -eq 'host') { 0 } else { [int]($wa.Width / 2) })", "-WinY=0", "-log", "-port=$Port"
        }
        $s.Proc = Start-Process $exe -ArgumentList $gameArgs -WorkingDirectory $s.Bin -PassThru
        $s.Started = Get-Date
        $script:procs += $s.Proc
        Write-Host "started $($s.Role) life $life PID $($s.Proc.Id)"
    } finally {
        Remove-Item Env:PT_ROLE, Env:PT_SCENARIO, Env:PT_STATUS, Env:PT_HOST, Env:PT_MUTATE, Env:PT_FIXTURE, Env:PT_JOIN, Env:PT_TUNNEL, Env:PT_LIFE, Env:PT_STEAM, Env:PT_STEAM_INBOX, Env:PT_STEAM_UDP -ErrorAction SilentlyContinue
    }
}
foreach ($s in $sides) {
    if ($procs) { Start-Sleep 8 }
    Start-Side $s 1
}
# scenario directives (each handled once): kill a side's process, or start it again with the next life number
$handled = @{}
$killed = @()
function Invoke-Directives {
    foreach ($s in $sides) {
        foreach ($m in [regex]::Matches((Get-Log $s), "PT\|runner (kill|relaunch) side=(\S+) n=(\d+)")) {
            $target = $sides | Where-Object Role -eq $m.Groups[2].Value
            if ($handled.ContainsKey($m.Value) -or -not $target) { continue }
            $handled[$m.Value] = $true
            if ($m.Groups[1].Value -eq "kill") {
                Write-Host "runner: killing $($target.Role) PID $($target.Proc.Id)"
                $script:killed += $target.Proc.Id
                Stop-Process -Id $target.Proc.Id -Force -ErrorAction SilentlyContinue
                $target.Proc.WaitForExit(15000) | Out-Null
            } else {
                $target.Prefix = (Get-Log $target) + "`n"
                Remove-Item $target.Log -ErrorAction SilentlyContinue
                $target.Life++
                Start-Side $target $target.Life
            }
        }
    }
}

function Get-NewCrashes {
    foreach ($s in $sides) {
        Get-ChildItem $s.Crashes -Directory -ErrorAction SilentlyContinue | Where-Object { $oldCrashes[$s.Role] -notcontains $_.Name } |
            ForEach-Object { [pscustomobject]@{ Role = $s.Role; Dir = $_ } }
    }
}

$deadline = (Get-Date).AddSeconds($Seconds)
$stop = "timeout after $Seconds s"
while ((Get-Date) -lt $deadline) {
    Start-Sleep 3
    Update-Snapshots
    if ($KillExpected -contains $Scenario) { Invoke-Directives }
    # the engine sometimes hangs in start-up before any mod loads (X7 notes, seen again 2026-10-21): start that side again
    foreach ($s in $sides) {
        if ($s.Proc.HasExited -or $s.BootRetries -ge 2 -or ((Get-Date) - $s.Started).TotalSeconds -lt 120) { continue }
        if ((Read-Shared $s.Log) -match "PT\|boot ") { continue }
        $s.BootRetries++
        Write-Host "runner: $($s.Role) never booted, restarting it (retry $($s.BootRetries))"
        $script:killed += $s.Proc.Id
        Stop-Process -Id $s.Proc.Id -Force -ErrorAction SilentlyContinue
        $s.Proc.WaitForExit(15000) | Out-Null
        Remove-Item $s.Log -ErrorAction SilentlyContinue
        Start-Side $s $s.Life
        $deadline = $deadline.AddSeconds(120)
    }
    # a scenario that does not load (a Lua syntax error) left both games idling at the menu until the timeout, 18 min (2026-10-24):
    # stop at once, and when a booted side shows no test plan after 3 min
    $bad = @($sides | Where-Object { (Get-Log $_) -match "PT\|error unknown scenario" })
    if ($bad) { $stop = "scenario did not load on $($bad.Role -join ', ') (PT|error unknown scenario: see its UE4SS.log)"; break }
    $noPlan = @($sides | Where-Object { ((Get-Date) - $_.Started).TotalSeconds -gt 180 -and (Get-Log $_) -match "PT\|boot " -and (Get-Log $_) -notmatch "PT\|plan side=" })
    if ($noPlan) { $stop = "no test plan 3 min after boot on $($noPlan.Role -join ', ')"; break }
    $done = @($sides | Where-Object { (Get-Log $_) -match "\[PacificTogetherTest\] PT\|done side=" })
    if ($done.Count -eq $sides.Count) { $stop = "all sides done"; break }
    if ((Get-NewCrashes) -and $CrashExpected -notcontains $Scenario) { $stop = "crash"; break }
    $exited = @($procs | Where-Object { $_.HasExited -and $killed -notcontains $_.Id })
    if ($exited -and $CrashExpected -notcontains $Scenario) { $stop = "process exited (PID $($exited.Id -join ', '))"; break }
}
$elapsed = [int]((Get-Date) - $deadline.AddSeconds(-$Seconds)).TotalSeconds
Write-Host "stopped waiting: $stop ($elapsed s)"

if (-not $ResultsDir) { $ResultsDir = Join-Path $Repo "local\test-results" }
$lane = if ($Root.TrimEnd('\') -ne "C:\PacificTogetherTest") { "-" + (Split-Path $Root -Leaf) } else { "" }
if ($Tunnel) { $lane += "-tunnel" }
$results = Join-Path $ResultsDir ("{0}{1}-{2}{3}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $lane, $Scenario, $(if ($Mutate) { "-$Mutate" }))
New-Item -ItemType Directory -Force $results | Out-Null
if (-not $KeepOpen) {
    $procs | Where-Object { -not $_.HasExited } | Stop-Process -Force
    $procs | ForEach-Object { $_.WaitForExit(15000) | Out-Null }
}
Update-Snapshots
foreach ($s in $sides) {
    if ($s.Snaps.Count) { $s.Snaps["end"] = @(Get-Snapshot $s) }
    if ($null -ne $s.IniBackup) { [IO.File]::WriteAllBytes($s.Ini, $s.IniBackup) }
}
if ($Fixture) {
    $fixtureSaves = Join-Path $results "fixture-saves-after"
    if (Test-Path $saveDir) { Copy-Item $saveDir $fixtureSaves -Recurse; Remove-Item $saveDir -Recurse -Force }
    if (Test-Path "$saveDir.ptbak") { Rename-Item "$saveDir.ptbak" (Split-Path $saveDir -Leaf) }
}
# a crashed game opens CrashReportClient a moment later; close it without sending anything
Start-Sleep 3
Get-TestProcesses "CrashReportClient" | Stop-Process -Force

$crashes = @(Get-NewCrashes | ForEach-Object {
    $ctx = Join-Path $_.Dir.FullName "CrashContext.runtime-xml"
    $msg = if (Test-Path $ctx) { ([regex]::Match((Get-Content $ctx -Raw), "<ErrorMessage>([^<]*)")).Groups[1].Value } else { "no CrashContext" }
    Copy-Item $_.Dir.FullName (Join-Path $results "crash-$($_.Role)-$($_.Dir.Name)") -Recurse
    "$($_.Role): $msg"
})

$checks = New-Object System.Collections.Generic.List[object]
function Add-Check($name, $pass, $detail) { $checks.Add([pscustomobject]@{ Name = $name; Pass = [bool]$pass; Detail = $detail }) }
foreach ($s in $sides) {
    $r = $s.Role
    $text = Get-Log $s
    [IO.File]::WriteAllText((Join-Path $results "$r-UE4SS.log"), $text)
    Copy-Item (Join-Path $s.Dir "PenDriverPro\Saved\Logs\PenDriverPro.log") (Join-Path $results "$r-PenDriverPro.log") -ErrorAction SilentlyContinue
    # X13: HighResShot writes under Saved\Screenshots; copy this run's shots in the order they were taken
    Get-ChildItem (Join-Path $s.Dir "PenDriverPro\Saved\Screenshots") -Recurse -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $started |
        Sort-Object LastWriteTime | ForEach-Object { Copy-Item $_.FullName (Join-Path $results "$r-$($_.Name)") }

    $boot = [regex]::Match($text, "\[PacificTogether\] PT\|boot (.*)")
    Add-Check "$r main mod booted" $boot.Success $boot.Groups[1].Value.Trim()
    # one plan line per life of the process (a relaunched side plans again; the killed life must have reported all its checks)
    $plans = @([regex]::Matches($text, "\[PacificTogetherTest\] PT\|plan side=$r checks=(\d+)"))
    $planned = if ($plans.Count) { ($plans | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Sum).Sum } else { -1 }
    Add-Check "$r test plan" ($plans.Count -gt 0) "checks=$planned lives=$($plans.Count)"
    $reported = [regex]::Matches($text, "\[PacificTogetherTest\] PT\|check side=$r name=(\S+) result=(PASS|FAIL) detail=(.*)")
    foreach ($m in $reported) { Add-Check "$r $($m.Groups[1].Value)" ($m.Groups[2].Value -eq "PASS") $m.Groups[3].Value.Trim() }
    if ($planned -ge 0 -and $reported.Count -ne $planned) { Add-Check "$r all planned checks reported" $false "$($reported.Count) of $planned" }
    Add-Check "$r done" ($text -match "\[PacificTogetherTest\] PT\|done side=$r") ""
    $errors = [regex]::Matches($text, "PT\|error .*")
    Add-Check "$r no PT|error" ($errors.Count -eq 0) $(if ($errors.Count) { "$($errors.Count): $($errors[0].Value.Trim())" })
    if ($s.Snaps.Count) {
        $tags = @($s.Snaps.Keys)
        $s.Snaps.GetEnumerator() | ForEach-Object { "## $($_.Key)"; $_.Value } | Set-Content -Encoding utf8 (Join-Path $results "snapshots-$r.txt")
        foreach ($tag in $tags[1..($tags.Count - 1)]) {
            # content = name, size, hash; a rewrite with the same bytes (the game rewrites GameUserSettings.ini on every map load) is listed, not failed
            $content = { param($lines) @($lines | ForEach-Object { $f = $_ -split "`t"; "$($f[0])`t$($f[1])`t$($f[3])" }) }
            $diff = @(Compare-Object (& $content $s.Snaps[$tags[0]]) (& $content $s.Snaps[$tag]) | ForEach-Object { "$($_.SideIndicator)$(($_.InputObject -split "`t")[0])" })
            $touched = @(Compare-Object @($s.Snaps[$tags[0]]) @($s.Snaps[$tag]) | Where-Object SideIndicator -eq "=>" | ForEach-Object { ($_.InputObject -split "`t")[0] })
            Add-Check "$r saves unchanged $($tags[0])->$tag" ($diff.Count -eq 0) (($diff -join " ") + $(if ($touched) { " rewritten: $($touched -join ' ')" }))
        }
    }
}
# X3: host and client actor counts side by side, one csv per survey tag
$actors = foreach ($s in $sides) {
    foreach ($m in [regex]::Matches((Get-Log $s), "PT\|actors side=(\S+) tag=(\S+) class=(\S+) role=(\S+) rep=(\d) loaded=(\d) owner=(\S+) n=(\d+)")) {
        $g = $m.Groups
        [pscustomobject]@{ Side = $g[1].Value; Tag = $g[2].Value; Class = $g[3].Value; Role = $g[4].Value; Rep = $g[5].Value; Loaded = $g[6].Value; Owner = $g[7].Value; N = [int]$g[8].Value }
    }
}
foreach ($t in @($actors | Group-Object Tag)) {
    $t.Group | Group-Object Class, Role, Rep, Loaded, Owner | ForEach-Object {
        $f = $_.Group[0]
        [pscustomobject]@{ Class = $f.Class; Role = $f.Role; Rep = $f.Rep; Loaded = $f.Loaded; Owner = $f.Owner
            Host = [int]($_.Group | Where-Object Side -eq "host" | Measure-Object N -Sum).Sum
            Client = [int]($_.Group | Where-Object Side -eq "client" | Measure-Object N -Sum).Sum }
    } | Sort-Object Class, Role | Export-Csv -NoTypeInformation (Join-Path $results "actors-$($t.Name).csv")
}
if ($CrashExpected -contains $Scenario) { Add-Check "expected crash" ($crashes.Count -gt 0) ($crashes -join "; ") }
else { Add-Check "no crash" ($crashes.Count -eq 0) ($crashes -join "; ") }

if ($Scenario -eq "dump") {
    $dumps = Join-Path $Repo "local\dumps"
    New-Item -ItemType Directory -Force $dumps | Out-Null
    foreach ($o in $DumpOutputs) {
        $src = @(Get-Item "$($sides[0].Bin)\ue4ss\$o" -ErrorAction SilentlyContinue)
        Add-Check "dump output $o" $src.Count (Join-Path $dumps ($src.Name -join ", "))
        foreach ($i in $src) {
            Remove-Item (Join-Path $dumps $i.Name) -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item $i.FullName (Join-Path $dumps $i.Name) -Recurse
        }
    }
}

$passed = @($checks | Where-Object Pass).Count
$lines = @($checks | ForEach-Object { "{0}  {1}  {2}" -f $(if ($_.Pass) { "PASS" } else { "FAIL" }), $_.Name, $_.Detail })
$lines += "SUMMARY: $passed/$($checks.Count) passed ($Scenario$(if ($Mutate) { ", mutate=$Mutate" }); $stop)"
$lines | Set-Content -Encoding utf8 (Join-Path $results "summary.txt")
$lines | Write-Host
Write-Host "results: $results"
if ($passed -eq $checks.Count) { exit 0 } else { exit 1 }
