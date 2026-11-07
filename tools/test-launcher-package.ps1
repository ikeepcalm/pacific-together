# Run with Windows PowerShell: validates the actual embedded installer without touching an installed game or real saves.
param([Parameter(Mandatory)][string]$Installer, [Parameter(Mandatory)][string]$GameExe)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$Repo = (Resolve-Path "$PSScriptRoot\..").Path
$root = Join-Path $Repo ('local\launcher-package-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$env:LOCALAPPDATA = Join-Path $root 'localappdata'
$env:APPDATA = Join-Path $root 'appdata'
function Check($ok, $name) { if (-not $ok) { throw "FAIL $name" }; Write-Output "PASS $name" }
$asm = [Reflection.Assembly]::LoadFile((Resolve-Path $Installer).Path)
$app = $asm.GetType('App', $true)
$flags = [Reflection.BindingFlags]'Static,NonPublic'
function Call($name, $params) {
    $values = @($params | ForEach-Object { $_.PSObject.BaseObject })
    $app.GetMethod($name, $flags).Invoke($null, [object[]]$values)
}
$stream = $asm.GetManifestResourceStream('payload.zip')
$zip = [IO.Compression.ZipArchive]::new($stream)
try {
    $stampEntry = $zip.Entries | Where-Object { $_.FullName.Replace('\','/') -eq 'game/ue4ss/Mods/PacificTogether/version.txt' }
    $reader = [IO.StreamReader]::new($stampEntry.Open())
    try { $version = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
    $cache = Join-Path "$env:LOCALAPPDATA\PacificTogether\app" $version
    $stamp = Join-Path $cache 'game\ue4ss\Mods\PacificTogether\version.txt'
    New-Item -ItemType Directory -Force (Split-Path $stamp) | Out-Null
    [IO.File]::WriteAllText($stamp, $version)
    Call 'Unpack' @()
    Check (Test-Path "$cache\install.ps1") 'partial cache with a valid stamp is repaired'
    Remove-Item -LiteralPath "$cache\install.ps1"
    Call 'Unpack' @()
    Check (Test-Path "$cache\install.ps1") 'deleted installer is restored'
    $dll = Join-Path $cache 'game\ue4ss\Mods\PacificTogetherNative\dlls\main.dll'
    $length = (Get-Item $dll).Length
    [IO.File]::WriteAllBytes($dll, [byte[]]@(0))
    Call 'Unpack' @()
    Check ((Get-Item $dll).Length -eq $length) 'truncated DLL is restored'
    $time = (Get-Item "$cache\install.ps1").LastWriteTimeUtc
    Call 'Unpack' @()
    Check ((Get-Item "$cache\install.ps1").LastWriteTimeUtc -eq $time) 'complete cache is reused'
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName.EndsWith('/')) { continue }
        $file = Join-Path $cache $entry.FullName
        if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -ne $entry.Length) { throw "payload differs: $($entry.FullName)" }
    }
    Write-Output 'PASS all embedded files extracted'
} finally { $zip.Dispose(); $stream.Dispose() }

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
