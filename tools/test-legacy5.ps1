# Mix one historical author Lua/native mod with the current mod in an isolated test pair.
# -PeerProtocol 6 also checks the author 0.8.8 snapshot; protocol 5 is historical evidence only.
param(
    [Parameter(Mandatory=$true)][string]$LegacyRoot,
    [Parameter(Mandatory=$true)][string]$Root,
    [ValidateSet("host","client")][string]$Side="client",
    [int]$Port=7823,
    [ValidateSet(5,6)][int]$PeerProtocol=5
)
$ErrorActionPreference="Stop"
$Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
$LegacyRoot=(Resolve-Path -LiteralPath $LegacyRoot).Path
$which=if($Side -eq "host"){"client1"}else{"client2"}
$mods=Join-Path $Root "$which\PenDriverPro\Binaries\Win64\ue4ss\Mods"
if (-not (Test-Path -LiteralPath "$mods\PacificTogetherTest")) {throw "An isolated test pair is required"}
if (Get-Process -Name PenDriverPro-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object {$_.Path -and $_.Path.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)}) {throw "Close this test pair first"}
if ((Get-Content -LiteralPath "$LegacyRoot\PacificTogether\Scripts\common.lua" -Raw) -notmatch "PROTOCOL_VERSION = $PeerProtocol,") {throw "Historical source must use protocol $PeerProtocol"}
$oldHash=(Get-FileHash -LiteralPath "$LegacyRoot\PacificTogetherNative\dlls\main.dll" -Algorithm SHA256).Hash
if($oldHash -ne 'FCFBC4ED3E356BBA94D819498131B96883085B0296EC8B95924FAA52C39C0B54'){throw "Unexpected historical DLL"}
$staged=@()
try {
    foreach($name in @("PacificTogether","PacificTogetherNative")) {
        $path=Join-Path $mods $name
        $backup=Join-Path $Root "legacy5-$which-$name-current"
        if (Test-Path -LiteralPath $backup) {throw "Staging backup already exists: $backup"}
        if (-not ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw "Expected a mod junction: $path"}
        Move-Item -LiteralPath $path -Destination $backup
        $staged+=@{Path=$path;Backup=$backup}
        New-Item -ItemType Junction -Path $path -Target "$LegacyRoot\$name" | Out-Null
    }
    & "$PSScriptRoot\run-test.ps1" -Scenario legacy5 -Root $Root -Port $Port -Headless -Seconds 260
    $result=$LASTEXITCODE
} finally {
    foreach($entry in $staged) {
        $absolute=[IO.Path]::GetFullPath($entry.Path)
        if(-not $absolute.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe restore path"}
        if(Test-Path -LiteralPath $absolute) {
            if(-not ((Get-Item -LiteralPath $absolute).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Refusing to remove a physical directory: $absolute"}
            [IO.Directory]::Delete($absolute) # Removes only this verified junction, never its target.
        }
        Move-Item -LiteralPath $entry.Backup -Destination $absolute
    }
}
exit $result
