# Builds dist\PacificTogether-<mod version>-dev-<commit>.zip (GitHub): the launcher PacificTogether.exe next to the package, and
# ...-nexus.zip, the same without the launcher: VirusTotal flags the launcher (10/61 MSILHeracles, Bitdefender engines), not the rest (0/66).
# Not one exe with the package embedded: Defender flagged that as Wacatac.C!ml (0.9.0).
# Bundles the exact UE4SS build the tests run on (MIT, its LICENSE goes along) minus its debug symbols and docs.
param([string]$UE4SSZip = "$PSScriptRoot\..\..\local\cache\ue4ss\zDEV-UE4SS_v3.0.1-1181-g83330635.zip")
$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path "$PSScriptRoot\..\..").Path
if ((Get-FileHash $UE4SSZip).Hash -ne "82378CD7F679D055026286F11347355AC67C712F21EB892060C902BB0184B907") { throw "UE4SS zip hash mismatch: $UE4SSZip" }
$mod = Join-Path $Repo "mod\PacificTogether"
$native = Join-Path $Repo "mod\PacificTogetherNative"
if (-not (Test-Path "$native\dlls\main.dll")) { throw "build the native layer first (tools\build-native.cmd)" }
if (git -C $Repo status --porcelain -- mod) { throw "mod/ has uncommitted changes; commit first so the zip name matches its contents" }

$version = [regex]::Match((Get-Content "$mod\Scripts\common.lua" -Raw), 'MOD_VERSION = "([^"]+)"').Groups[1].Value
$name = "PacificTogether-$version-dev-$(git -C $Repo rev-parse --short HEAD)"
$stage = Join-Path $Repo "dist\$name"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
$game = New-Item -ItemType Directory -Force "$stage\game"

Expand-Archive $UE4SSZip $game
Remove-Item "$game\ue4ss\UE4SS.pdb", "$game\ue4ss\Docs", "$game\ue4ss\Changelog.md", "$game\ue4ss\README.md" -Recurse -Force
# players get no UE4SS console windows; the log still goes to ue4ss\UE4SS.log
$ini = "$game\ue4ss\UE4SS-settings.ini"
(Get-Content $ini) -replace '^(ConsoleEnabled|GuiConsoleEnabled|GuiConsoleVisible) = 1', '$1 = 0' | Set-Content $ini -Encoding ascii

$dst = New-Item -ItemType Directory -Force "$game\ue4ss\Mods\PacificTogether"
Copy-Item "$mod\enabled.txt", "$mod\Scripts" $dst -Recurse
$ndst = New-Item -ItemType Directory -Force "$game\ue4ss\Mods\PacificTogetherNative"
Copy-Item "$native\enabled.txt", "$native\dlls" $ndst -Recurse
Set-Content "$dst\version.txt" $name -Encoding ascii  # install.ps1 skips the copy and backup when this matches
Copy-Item "$PSScriptRoot\install.ps1", "$PSScriptRoot\install.cmd", "$PSScriptRoot\README.txt", "$PSScriptRoot\GUIDE.md", "$Repo\CHANGELOG.md" $stage

& "$PSScriptRoot\build-app.ps1" -Out "$stage\PacificTogether.exe"
# tar (bsdtar, in Windows 10+) writes '/' separators; PowerShell 5.1's zip writes backslashes, which some unzip tools mangle
$zip = "$stage.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
tar -a -c -f $zip -C (Split-Path $stage) $name
if ($LASTEXITCODE) { throw "tar failed ($LASTEXITCODE)" }
$nexus = "$stage-nexus.zip"
Remove-Item $nexus -Force -ErrorAction SilentlyContinue
tar -a -c -f $nexus --exclude "$name/PacificTogether.exe" -C (Split-Path $stage) $name
if ($LASTEXITCODE) { throw "tar failed ($LASTEXITCODE)" }
$zip, $nexus | ForEach-Object { "$((Get-FileHash $_).Hash.ToLower())  $(Split-Path $_ -Leaf)" } | Set-Content "$Repo\dist\SHA256SUMS.txt" -Encoding ascii
$zip, $nexus | ForEach-Object { Write-Host "Built $_ ($([math]::Round((Get-Item $_).Length / 1MB, 1)) MB)" }
