# Focused file/network tests without starting games or touching the real music folder.
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/..").Path
$out = Join-Path $repo 'local/music-tests'
New-Item -ItemType Directory -Force $out | Out-Null
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $vs) { throw 'An installed Visual C++ toolchain is required' }
$lua = Join-Path $repo 'native/RE-UE4SS/deps/first/LuaRaw'
$sources = (Get-ChildItem "$lua/src/*.c" | Where-Object Name -ne 'luac.c' | ForEach-Object { '"' + $_.FullName + '"' }) -join ' '
$batch = @"
@echo off
call "$vs/VC/Auxiliary/Build/vcvars64.bat" >nul || exit /b 1
cd /d "$out"
cl /nologo /std:c++20 /EHsc /O2 /DPT_MUSIC_SELF_TEST /Fe:music-test.exe "$repo/native/PacificTogetherNative/music.cpp" || exit /b 1
music-test.exe || exit /b 1
"@
# shortcut: reuse the test interpreter; delete local/music-tests/lua.exe after changing the pinned Lua source.
if (-not (Test-Path "$out/lua.exe")) {
    $batch += "`r`ncl /nologo /TC /O2 /I`"$lua/include`" /Fe:lua.exe $sources || exit /b 1`r`n"
}
$batch += "`r`nlua.exe `"$PSScriptRoot/tests/radio-music.lua`" `"$repo`"`r`nexit /b %errorlevel%`r`n"
[IO.File]::WriteAllText("$out/run.cmd", $batch, [Text.Encoding]::ASCII)
& cmd /c "`"$out/run.cmd`""
if ($LASTEXITCODE) { throw "Radio music checks failed ($LASTEXITCODE)" }
