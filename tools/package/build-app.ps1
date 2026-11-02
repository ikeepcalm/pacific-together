# Compiles PacificTogether.exe with the .NET Framework C# compiler every Windows has (no SDK, no runtime install).
# -Payload <zip>: the whole package embedded in the exe (resource payload.zip), unpacked by the app on first start.
param([Parameter(Mandatory)][string]$Out, [string]$Payload = "")
$ErrorActionPreference = "Stop"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }
$res = if ($Payload) { "/resource:$Payload,payload.zip" } else { $null }
& $csc /nologo /target:winexe /optimize+ /out:$Out /win32manifest:"$PSScriptRoot\app\app.manifest" $res `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Management.dll `
    "$PSScriptRoot\app\Launcher.cs"
if ($LASTEXITCODE) { throw "csc failed ($LASTEXITCODE)" }
