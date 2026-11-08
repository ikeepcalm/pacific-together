# Compiles PacificTogether.exe with the .NET Framework C# compiler every Windows has (no SDK, no runtime install).
param([Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = "Stop"
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }
& $csc /nologo /target:winexe /optimize+ /out:$Out /win32manifest:"$PSScriptRoot\app\app.manifest" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Management.dll `
    "$PSScriptRoot\app\Launcher.cs"
if ($LASTEXITCODE) { throw "csc failed ($LASTEXITCODE)" }
