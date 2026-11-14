# Makes two isolated test copies of the game with UE4SS and our mods, never touching the real install.
# client1 = full copy, client2 = hardlinks to client1 except its own PenDriverPro/Binaries/Win64 (own UE4SS, logs, mods).
# -LinkFrom <existing client1> builds client1 from hardlinks too (an extra pair, e.g. one per workflow lane, costs ~700 MB).
# -Extra 1|2 adds client3 (and client4) the same way as client2, for 3-4 player runs (run-test.ps1 -Clients 3|4).
# Mod junctions point at the repo this script lives in, so run it from the worktree whose mods the pair should load.
param(
    [string]$Root = "C:\PacificTogetherTest",
    [string]$LinkFrom = "",
    [ValidateSet(0, 1, 2)][int]$Extra = 0,
    [string]$Game = "C:\Program Files (x86)\Steam\steamapps\common\Pacific Drive",
    [string]$UE4SSZip = "$PSScriptRoot\..\local\cache\ue4ss\zDEV-UE4SS_v3.0.1-1181-g83330635.zip"
)
$ErrorActionPreference = "Stop"
$ExeRel = "PenDriverPro\Binaries\Win64\PenDriverPro-Win64-Shipping.exe"
$BinRel = "PenDriverPro\Binaries\Win64"
$PinnedExe = "568BB63476C6DE5FC2B1878572A655DD631DD25BB44FE304E3D96A51F6B98F7E"
$PinnedUE4SS = @{
    "zDEV-UE4SS_v3.0.1-1181-g83330635.zip" = "82378CD7F679D055026286F11347355AC67C712F21EB892060C902BB0184B907"
    "UE4SS_v3.0.1-1181-g83330635.zip"      = "B9A166A756605B21058A64CDE93BCAAB1A855DBA3553E5C7E6CE0FA8FDFAD7B9"
}
$Repo = (Resolve-Path "$PSScriptRoot\..").Path

if ((Get-FileHash "$Game\$ExeRel").Hash -ne $PinnedExe) { throw "Game exe hash differs from the pinned build; stop (see CLAUDE.md)." }
$zipName = Split-Path $UE4SSZip -Leaf
if ((Get-FileHash $UE4SSZip).Hash -ne $PinnedUE4SS[$zipName]) { throw "UE4SS zip hash mismatch: $UE4SSZip" }
if ((Resolve-Path $Game).Path.TrimEnd('\') -eq $Root.TrimEnd('\')) { throw "Root must not be the real install." }

$c1 = Join-Path $Root "client1"

# hardlinks every game file except Binaries (each copy needs its own UE4SS, logs, mods) and Saved (per-copy state)
function Link-Game($src, $dst) {
    Get-ChildItem $src -Recurse -File | Where-Object {
        $_.FullName -notlike "$src\$BinRel\*" -and $_.FullName -notlike "$src\PenDriverPro\Saved\*"
    } | ForEach-Object {
        $target = $dst + $_.FullName.Substring($src.Length)
        if (-not (Test-Path $target)) {
            New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
            New-Item -ItemType HardLink -Path $target -Target $_.FullName | Out-Null
        }
    }
    robocopy "$Game\$BinRel" "$dst\$BinRel" /E /NFL /NDL /NJH /NP /R:1 /W:1 /XD "$Game\$BinRel\ue4ss" /XF dwmapi.dll | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy Binaries failed with $LASTEXITCODE" }
}

if ($LinkFrom) {
    Write-Host "client1: hardlinking game data from $LinkFrom"
    Link-Game (Resolve-Path $LinkFrom).Path $c1
} else {
    Write-Host "client1: copying the game (first run takes a while, later runs only copy changes)"
    # never the real install's UE4SS or mod: copied through the mod junctions it would overwrite the repo
    robocopy $Game $c1 /E /NFL /NDL /NJH /NP /R:1 /W:1 /XD "$Game\PenDriverPro\Saved" "$Game\$BinRel\ue4ss" /XF dwmapi.dll | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with $LASTEXITCODE" }
}
if ((Get-FileHash "$c1\$ExeRel").Hash -ne $PinnedExe) { throw "client1 exe hash mismatch" }

$copies = @($c1)
for ($i = 2; $i -le 2 + $Extra; $i++) {
    $cx = Join-Path $Root "client$i"
    Write-Host "client${i}: hardlinking game data, copying Binaries"
    Link-Game $c1 $cx
    $copies += $cx
}

foreach ($c in $copies) {
    # the stock crash reporter can upload to Ironwood without a click; modded test crashes must never reach them
    Remove-Item (Join-Path $c "Engine\Binaries\Win64\CrashReportClient.exe") -Force -ErrorAction SilentlyContinue
    $bin = Join-Path $c $BinRel
    # without it the copy restarts through Steam into the real install
    Set-Content -Path "$bin\steam_appid.txt" -Value "1458140" -Encoding ascii -NoNewline
    if (-not (Test-Path "$bin\ue4ss\UE4SS.dll")) { Expand-Archive -Path $UE4SSZip -DestinationPath $bin -Force }
    # no UE4SS console windows popping over the owner's work; everything is in UE4SS.log anyway
    $ini = "$bin\ue4ss\UE4SS-settings.ini"
    (Get-Content $ini) -replace '^(ConsoleEnabled|GuiConsoleEnabled|GuiConsoleVisible) = 1', '$1 = 0' | Set-Content $ini -Encoding ascii
    # junctions, so edits in the repo apply on the next game launch
    foreach ($m in @(@{n = "PacificTogether"; s = "$Repo\mod\PacificTogether"}, @{n = "PacificTogetherNative"; s = "$Repo\mod\PacificTogetherNative"}, @{n = "PacificTogetherTest"; s = "$Repo\test\PacificTogetherTest"})) {
        $link = "$bin\ue4ss\Mods\$($m.n)"
        if ((Test-Path $m.s) -and -not (Test-Path $link)) { New-Item -ItemType Junction -Path $link -Target $m.s | Out-Null }
    }
}
Write-Host "Done: $($copies -join ', ')"
exit 0  # robocopy leaves $LASTEXITCODE at 1 ("files copied")
