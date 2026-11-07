# Installs (or removes) Pacific Together into the Steam copy of Pacific Drive. Run from the unpacked zip:
#   install.cmd                      host: you start the game and your friend joins you
#   install.cmd -Join 100.64.1.2     guest: joins that host when the game reaches the main menu
#   install.cmd -Uninstall           removes UE4SS and the mod; saves are left alone
#   install.ps1 -Find                prints the game folder it would use (for launcher.ps1)
param(
    [string]$Join = "",
    [string]$GameDir = "",
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$Find
)
$ErrorActionPreference = "Stop"
trap { Write-Host "ERROR: $($_.Exception.Message)"; exit 1 }  # one clean line for the launcher app and install.cmd
$ExeSha = "568BB63476C6DE5FC2B1878572A655DD631DD25BB44FE304E3D96A51F6B98F7E"  # Steam build 21896301 (v1.15.0)

if (-not $GameDir) {
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    $libs = @()
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) { $libs += [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } }
    }
    $GameDir = $libs | ForEach-Object { Join-Path $_ "steamapps\common\Pacific Drive" } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($Find) { return $GameDir }
    if (-not $GameDir) { throw "Pacific Drive not found in your Steam libraries. Run again with -GameDir `"<folder with PenDriverPro>`"" }
}
$bin = Join-Path $GameDir "PenDriverPro\Binaries\Win64"
$exe = Join-Path $bin "PenDriverPro-Win64-Shipping.exe"
if (-not (Test-Path $exe)) { throw "not a Pacific Drive folder: $GameDir" }
if (Get-Process PenDriverPro* -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$GameDir*" }) { throw "close Pacific Drive first" }
Write-Host "Game: $GameDir"

# the startup movies (Ironwood, Kepler, Unreal, Wwise, disclaimer) play for a while at every start. The engine plays only the ones
# it finds in Content\Movies itself (MoviePlayerSettings.StartupMovies, matched by name), so they wait in a subfolder while the mod is in
$movies = Join-Path $GameDir "PenDriverPro\Content\Movies"
$skipped = Join-Path $movies "PacificTogether-skipped"

if ($Uninstall) {
    if (Test-Path $skipped) { Move-Item (Join-Path $skipped "*") $movies -Force; Remove-Item $skipped -Force }
    Remove-Item (Join-Path $bin "dwmapi.dll") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin "steam_appid.txt") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $bin "ue4ss") -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Removed. Your saves were not touched."
    exit 0
}

if ((Get-FileHash $exe).Hash -ne $ExeSha -and -not $Force) {
    throw "your game build differs from the one this mod was tested on (Steam probably updated it). Wait for a new mod build, or run with -Force at your own risk."
}

$stamp = "ue4ss\Mods\PacificTogether\version.txt"
$installed = Get-Content (Join-Path $bin $stamp) -ErrorAction SilentlyContinue
$source = Join-Path $PSScriptRoot "game"
$required = @('dwmapi.dll', 'ue4ss\UE4SS.dll')
foreach ($mod in @('PacificTogether', 'PacificTogetherNative')) {
    $required += Get-ChildItem (Join-Path $source "ue4ss\Mods\$mod") -Recurse -File | ForEach-Object { $_.FullName.Substring($source.Length + 1) }
}
$missing = @($required | Where-Object {
    $target = Join-Path $bin $_
    -not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-Item -LiteralPath $target).Length -ne (Get-Item -LiteralPath (Join-Path $source $_)).Length
})
if ($installed -ne (Get-Content (Join-Path $PSScriptRoot "game\$stamp")) -or $missing.Count -gt 0) {
    # one backup per install of a new build, before the modded game ever runs
    $saved = Join-Path $env:LOCALAPPDATA "PenDriverPro\Saved"
    if (Test-Path $saved) {
        $backup = Join-Path ([Environment]::GetFolderPath("MyDocuments")) ("PacificDrive-saves-backup-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".zip")
        Compress-Archive -Path $saved -DestinationPath $backup
        Write-Host "Saves backed up to $backup"
    }
    # older builds kept main.dll in the Lua mod's folder; left there it would load twice
    Remove-Item (Join-Path $bin "ue4ss\Mods\PacificTogether\dlls") -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $PSScriptRoot "game\*") $bin -Recurse -Force
}
if (Test-Path $movies) {
    $intro = Get-ChildItem $movies -File -Filter "Intro_Segment_*"
    if ($intro) { New-Item -ItemType Directory $skipped -Force | Out-Null; $intro | Move-Item -Destination $skipped -Force; Write-Host "Intro movies skipped." }
}
# lets the exe start directly (launcher, shortcut) instead of restarting itself through Steam, as in the test copies
[IO.File]::WriteAllText((Join-Path $bin "steam_appid.txt"), "1458140")
$joinFile = Join-Path $bin "ue4ss\Mods\PacificTogether\join.txt"
if ($Join) {
    [IO.File]::WriteAllText($joinFile, $Join)
    Write-Host "Installed as GUEST: the game joins $Join from the main menu."
} else {
    Remove-Item $joinFile -Force -ErrorAction SilentlyContinue
    Write-Host "Installed as HOST: load your save, your friend joins you."
}
