# Run with Windows PowerShell: validates the release zip (-Installer) without touching an installed game or real saves.
param([Parameter(Mandatory)][string]$Installer, [Parameter(Mandatory)][string]$GameExe)
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path "$PSScriptRoot\..").Path
$root = Join-Path $Repo ('local\launcher-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$env:LOCALAPPDATA = Join-Path $root 'localappdata'
$env:APPDATA = Join-Path $root 'appdata'
function Check($ok, $name) { if (-not $ok) { throw "FAIL $name" }; Write-Output "PASS $name" }
# the release zip unpacks to one folder: the launcher next to install.ps1, the docs and game/
$unzipped = Join-Path $root 'unzipped'
New-Item -ItemType Directory -Path $unzipped | Out-Null
tar -x -f (Resolve-Path $Installer).Path -C $unzipped
if ($LASTEXITCODE) { throw 'unzip failed' }
$cache = (Get-ChildItem -Directory $unzipped | Select-Object -First 1).FullName
Check (-not ((tar -t -f (Resolve-Path $Installer).Path) -like '*\*')) 'zip paths use forward slashes'
foreach ($f in 'PacificTogether.exe', 'install.ps1', 'README.txt', 'GUIDE.md', 'CHANGELOG.md', 'game\ue4ss\Mods\PacificTogether\version.txt', 'game\ue4ss\Mods\PacificTogetherNative\dlls\main.dll') {
    Check (Test-Path "$cache\$f") "package has $f"
}
$asm = [Reflection.Assembly]::LoadFile("$cache\PacificTogether.exe")
Check ($null -eq $asm.GetManifestResourceStream('payload.zip')) 'launcher carries no embedded payload'
$app = $asm.GetType('App', $true)
$flags = [Reflection.BindingFlags]'Static,NonPublic'
function Call($name, $params) {
    $values = @($params | ForEach-Object { $_.PSObject.BaseObject })
    $app.GetMethod($name, $flags).Invoke($null, [object[]]$values)
}

$bin = Join-Path $root 'launch-probe'
New-Item -ItemType Directory -Path $bin | Out-Null
$source = Join-Path $root 'Probe.cs'
[IO.File]::WriteAllText($source, 'class Probe { static void Main() { System.IO.File.WriteAllText("launch.txt", System.Environment.CurrentDirectory); } }')
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe "/out:$bin\PenDriverPro-Win64-Shipping.exe" $source
if ($LASTEXITCODE) { throw 'probe compiler failed' }
$info = Call 'GameStartInfo' @($bin, $false)
Check ($info.FileName -eq "$bin\PenDriverPro-Win64-Shipping.exe") 'direct launch selects the chosen copy'
Check ($info.WorkingDirectory -eq $bin) 'direct launch uses the game binary directory'
[Diagnostics.Process]::Start($info).WaitForExit()
Check ((Get-Content "$bin\launch.txt" -Raw) -eq $bin) 'selected executable actually runs in that directory'
$steam = Call 'SteamExe' @()
if ($steam) {
    $info = Call 'GameStartInfo' @($bin, $true)
    Check ($info.FileName -eq $steam -and $info.Arguments -eq '-applaunch 1458140') 'Steam mode builds the explicit app launch command'
}

Check ((Get-FileHash $GameExe).Hash -eq '568BB63476C6DE5FC2B1878572A655DD631DD25BB44FE304E3D96A51F6B98F7E') 'supported game executable'
$game = Join-Path $root 'isolated-game'
$gameBin = Join-Path $game 'PenDriverPro\Binaries\Win64'
New-Item -ItemType Directory -Force $gameBin | Out-Null
Copy-Item -LiteralPath $GameExe -Destination "$gameBin\PenDriverPro-Win64-Shipping.exe"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$cache\install.ps1" -GameDir $game
if ($LASTEXITCODE) { throw 'isolated installation failed' }
$module = Join-Path $gameBin 'ue4ss\Mods\PacificTogether\Scripts\worldclock.lua'
Check (Test-Path $module) 'mod installs into the isolated copy'
Remove-Item -LiteralPath $module
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$cache\install.ps1" -GameDir $game -Join '127.0.0.1:7777'
if ($LASTEXITCODE) { throw 'isolated repair failed' }
Check (Test-Path $module) 'same-version install repairs missing feature files'
Check ((Get-Content "$gameBin\ue4ss\Mods\PacificTogether\join.txt" -Raw) -eq '127.0.0.1:7777') 'direct-IP configuration is written to the selected copy'
Write-Output "Results: $root"
