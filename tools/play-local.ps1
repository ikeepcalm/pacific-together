# Two games on this PC, played by hand (no test bots): client1 = host, client2 = guest, both windowed side by side.
# The guest joins by itself (PT_JOIN, like a real player) and keeps retrying until the host listens.
# Without -Fixture both stop at the main menu: load or start a game on the host yourself (the host mod listens by itself).
# With -Fixture the test mod's `repl` scenario only loads that save on the host (standalone, then the shipping mod listens); no checks run.
# Waits until both games are closed, then restores the host copy's saves; Ctrl+C does the same and closes the games.
param(
    [string]$Root = "C:\PacificTogetherTest",
    [string]$Fixture = "",
    [string]$FixturesDir = "",
    [int]$Port = 7777,
    [int]$ResX = 0,
    [int]$ResY = 0
)
$ErrorActionPreference = "Stop"
# two windows side by side on the main screen: half its working width each (desktop units: the game is not DPI-aware, so Windows
# scales its window, and 960 px on a 125% 1536-wide desktop covered most of the screen), minus the window border
Add-Type -AssemblyName System.Windows.Forms
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if (-not $ResX) { $ResX = [int]($wa.Width / 2) - 16 }
if (-not $ResY) { $ResY = [int]($ResX * 9 / 16) }
$Repo = (Resolve-Path "$PSScriptRoot\..").Path
$BinRel = "PenDriverPro\Binaries\Win64"
$sides = @(@{ Role = "host"; Dir = Join-Path $Root "client1" }, @{ Role = "client"; Dir = Join-Path $Root "client2" })
foreach ($s in $sides) {
    $s.Bin = Join-Path $s.Dir $BinRel
    $s.Log = Join-Path $s.Bin "ue4ss\UE4SS.log"
    foreach ($file in @('PacificTogether\enabled.txt', 'PacificTogether\Scripts\main.lua', 'PacificTogetherNative\enabled.txt', 'PacificTogetherNative\dlls\main.dll')) {
        $required = Join-Path "$($s.Bin)\ue4ss\Mods" $file
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Missing mod file: $required. Check the mod junction targets: their source worktree may have been removed."
        }
    }
}
$running = @(Get-Process -Name "PenDriverPro-Win64-Shipping", "PenDriverPro" -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith("$Root\", "OrdinalIgnoreCase") })
if ($running) { Write-Host "A game from $Root is already running (PID $($running.Id -join ', ')). Close it first."; exit 2 }

$saveDir = Join-Path $sides[0].Dir "PenDriverPro\Saved\SaveGames"
$procs = @()
try {
    # same save swap as run-test.ps1: a leftover .ptbak from a killed run is restored first
    if (Test-Path "$saveDir.ptbak") { Remove-Item $saveDir -Recurse -Force -ErrorAction SilentlyContinue; Rename-Item "$saveDir.ptbak" (Split-Path $saveDir -Leaf) }
    if ($Fixture) {
        if (-not $FixturesDir) { $FixturesDir = Join-Path $Repo "local\fixtures" }
        $fx = Join-Path $FixturesDir $Fixture
        if (-not (Get-ChildItem $fx -Filter *.sav -ErrorAction SilentlyContinue)) { throw "no fixture saves in $fx" }
        if (Test-Path $saveDir) { Rename-Item $saveDir "$(Split-Path $saveDir -Leaf).ptbak" }
        New-Item -ItemType Directory $saveDir | Out-Null
        Copy-Item "$fx\*.sav" $saveDir
        if (Test-Path "$fx\fixture.json") { $j = Get-Content "$fx\fixture.json" -Raw | ConvertFrom-Json; $env:PT_FIXTURE_SPEC = "$Fixture=$($j.slot):$($j.map)" }
        Write-Host "fixture $Fixture -> $saveDir (restored on exit)"
    }
    foreach ($s in $sides) {
        Remove-Item $s.Log -ErrorAction SilentlyContinue
        if ($procs) { Start-Sleep 8 }
        $host_ = $s.Role -eq "host"
        # no PT_SCENARIO = the test mod stays inert (main.lua returns at once)
        if ($host_ -and $Fixture) { $env:PT_SCENARIO = "repl"; $env:PT_ROLE = "host"; $env:PT_FIXTURE = $Fixture }
        $env:PT_JOIN = if ($host_) { "" } else { "127.0.0.1:$Port" }
        try {
            $winX = if ($host_) { 0 } else { [int]($wa.Width / 2) }
            $gameArgs = "-NotInstalled", "-windowed", "-ResX=$ResX", "-ResY=$ResY", "-WinX=$winX", "-WinY=0", "-log", "-port=$Port"
            $p = Start-Process (Join-Path $s.Bin "PenDriverPro-Win64-Shipping.exe") -ArgumentList $gameArgs -WorkingDirectory $s.Bin -PassThru
        } finally { Remove-Item Env:PT_SCENARIO, Env:PT_ROLE, Env:PT_FIXTURE, Env:PT_JOIN -ErrorAction SilentlyContinue }
        $procs += $p
        Write-Host "started $($s.Role) PID $($p.Id)  log: $($s.Log)"
    }
    Write-Host "Playing. Close both game windows (or Ctrl+C here) to finish."
    while ($procs | Where-Object { -not $_.HasExited }) { Start-Sleep 3 }
} finally {
    $procs | Where-Object { -not $_.HasExited } | Stop-Process -Force
    $procs | ForEach-Object { $_.WaitForExit(15000) | Out-Null }
    Remove-Item Env:PT_FIXTURE_SPEC -ErrorAction SilentlyContinue
    if ($Fixture) {
        if (Test-Path $saveDir) { Remove-Item $saveDir -Recurse -Force }
        if (Test-Path "$saveDir.ptbak") { Rename-Item "$saveDir.ptbak" (Split-Path $saveDir -Leaf) }
    }
    Write-Host "closed; host saves restored."
}
