<#
Fast build of PacificTogetherNative (main.dll) for any checkout/worktree, reusing the MAIN checkout's
fully built UE4SS (native/build). Compiles this checkout's .cpp files with the template flags and relinks.
Usage: powershell -File tools/build-mod-fast.ps1 [-MainBuild <dir>] [-Out <main.dll path>] [-Root <checkout>] [-Public]
-Public: defines PT_PUBLIC (no test-only natives, T08) in its own build-fast-public folder; tools/package builds this one.
#>
param(
    [string]$MainBuild = 'C:\Users\ikeepcalm\Documents\PacificTogether\native\build',
    [string]$Out,
    [string]$Root,
    [switch]$Public
)
$ErrorActionPreference = 'Stop'
$sw = [Diagnostics.Stopwatch]::StartNew()
function Die($m) { Write-Host "build-mod-fast: $m" -ForegroundColor Red; exit 1 }

$root = if ($Root) { (Resolve-Path $Root).Path } else { (Resolve-Path "$PSScriptRoot/..").Path }
$src = "$root\native\PacificTogetherNative"
if (-not $Out) { $Out = "$root\mod\PacificTogetherNative\dlls\main.dll" }
$Out = [IO.Path]::GetFullPath($Out)
$tgt = 'PacificTogetherNative'
$mainRoot = (Resolve-Path "$MainBuild\..\..").Path

if (-not (Test-Path "$MainBuild\build.ninja") -or -not (Test-Path "$MainBuild\Game__Shipping__Win64\lib\UE4SS.lib")) {
    Die "main build missing or incomplete at $MainBuild. Run tools\build-native.cmd in the main checkout, or use it here."
}

# same UE4SS commit as the main build
$want = (git -C $mainRoot ls-tree HEAD native/RE-UE4SS).Split()[2]
$have = (git -C $root ls-tree HEAD native/RE-UE4SS).Split()[2]
if ($want -ne $have) { Die "RE-UE4SS pin differs (main $want, here $have). Use tools\build-native.cmd." }
if (Test-Path "$root\native\RE-UE4SS\.git") {
    $init = git -C "$root\native\RE-UE4SS" rev-parse HEAD
    if ($init -ne $want) { Die "initialised native\RE-UE4SS is at $init, main is $want. Use tools\build-native.cmd." }
}

# our CMakeLists must not add anything the template link/compile lacks
$cm = Get-Content "$src\CMakeLists.txt" -Raw
$libs = [regex]::Matches($cm, 'target_link_libraries\s*\(([^)]*)\)') | ForEach-Object { $_.Groups[1].Value -split '\s+' } |
    Where-Object { $_ -and $_ -notin @($tgt, '${TARGET}', 'PUBLIC', 'PRIVATE', 'INTERFACE', 'UE4SS') }
if ($libs) { Die "CMakeLists links extra libraries ($($libs -join ', ')). Use tools\build-native.cmd." }
if ($cm -match 'target_compile_(definitions|options)|add_definitions|find_package|FetchContent') {
    Die "CMakeLists adds compile settings or dependencies the template lacks. Use tools\build-native.cmd."
}
$inc = [regex]::Matches($cm, 'target_include_directories\s*\(([^)]*)\)') | ForEach-Object { $_.Groups[1].Value -split '\s+' } |
    Where-Object { $_ -and $_ -notin @($tgt, '${TARGET}', 'PUBLIC', 'PRIVATE', 'INTERFACE', '.') }
if ($inc) { Die "CMakeLists adds include dirs ($($inc -join ', ')). Use tools\build-native.cmd." }

# toolchain
$vsw = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vsw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { Die 'Visual Studio Build Tools not found' }
$ninja = "$vs\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"

# template commands from the main build
$objRel = "$tgt\CMakeFiles\$tgt.dir\dllmain.cpp.obj"
$cc = & $ninja -C $MainBuild -t commands $objRel | Select-Object -Last 1
$ld = & $ninja -C $MainBuild -t commands "$tgt\$tgt.dll" | Select-Object -Last 1
# tool paths come quoted when they hold spaces ("C:\Program Files (x86)\...")
if ($cc -notmatch '^"?(?<cl>[^" ]*(?: [^" ]+)*?cl\.exe)"? (?<args>.*?) /showIncludes /Fo\S+ /Fd\S+ /FS -c \S+$') { Die 'unexpected compile template' }
$cl = $Matches.cl; $ccArgs = $Matches.args
$mainSrc = "$mainRoot\native\PacificTogetherNative"
if (-not $ccArgs.Contains("-I$mainSrc\.")) { Die 'main include path not found in template' }
$ccArgs = $ccArgs.Replace("-I$mainSrc\.", "-I$src\.")
if ($Public) { $ccArgs += " /DPT_PUBLIC" }
if ($ld -notmatch '(?<wrap>"[^"]*cmake\.exe" -E vs_link_dll .*?) -- "?(?<link>[^" ]*(?: [^" ]+)*?link\.exe)"? /nologo (?<args>.*?) && C:.WINDOWS') {
    Die 'unexpected link template'
}
$wrap = $Matches.wrap; $linkExe = $Matches.link; $ldArgs = $Matches.args

$fast = "$root\native\build-fast$(if ($Public) { '-public' })"
$objDir = "$fast\obj"
New-Item -ItemType Directory -Force $objDir | Out-Null

# incremental: recompile .cpp newer than its obj, or all if a header changed
$cpps = Get-ChildItem "$src\*.cpp"
$hdrNewest = (Get-ChildItem "$src\*.h*" -ErrorAction SilentlyContinue | Measure-Object LastWriteTime -Maximum).Maximum
$stale = $cpps | Where-Object {
    $o = "$objDir\$($_.BaseName).obj"
    -not (Test-Path $o) -or (Get-Item $o).LastWriteTime -lt $_.LastWriteTime -or ($hdrNewest -and (Get-Item $o).LastWriteTime -lt $hdrNewest)
}
# drop objs of deleted sources
Get-ChildItem "$objDir\*.obj" -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -notin $cpps.BaseName } | Remove-Item

$cmd = "@echo off`r`nset `"PATH=$(Split-Path $vsw);%PATH%`"`r`ncall `"$vs/VC/Auxiliary/Build/vcvars64.bat`" >nul || exit /b 1`r`n"
if ($stale) {
    $bs = [string][char]92; $q = [string][char]34
    $files = ($stale | ForEach-Object { $q + $_.FullName + $q }) -join " "
    Set-Content (Join-Path $fast "cc.rsp") -Encoding ASCII -Value "/nologo /TP $ccArgs /MP /Fo$q$objDir$bs$bs$q /Fd$q$fast$bs$bs$q /FS -c $files"
    $cmd += "`"$cl`" @`"$fast\cc.rsp`" || exit /b 1`r`n"
}
$objs = ($cpps | ForEach-Object { '"' + "$objDir\$($_.BaseName).obj" + '"' }) -join ' '
$ldArgs = $ldArgs.Replace("$tgt\CMakeFiles\$tgt.dir\dllmain.cpp.obj", $objs)
# the template may list more of our objects (trace.cpp.obj, ...): ours are all in $objs already
$ldArgs = [regex]::Replace($ldArgs, '\s' + [regex]::Escape("$tgt\CMakeFiles\$tgt.dir\") + '\S+\.cpp\.obj', '')
$ldArgs = $ldArgs.Replace("/out:$tgt\$tgt.dll", "/out:`"$fast\main.dll`"").Replace("/implib:$tgt\$tgt.lib", "/implib:`"$fast\main.lib`"").Replace("/pdb:$tgt\$tgt.pdb", "/pdb:`"$fast\main.pdb`"")
Set-Content "$fast\link.rsp" -Encoding ASCII -Value $ldArgs
$wrap = $wrap.Replace("--intdir=$tgt\CMakeFiles\$tgt.dir", "--intdir=`"$fast`"")
$cmd += "cd /d `"$MainBuild`"`r`n$wrap -- `"$linkExe`" /nologo @`"$fast\link.rsp`" || exit /b 1`r`n"
Set-Content "$fast\build.cmd" -Encoding ASCII -Value $cmd

Write-Host "compiling $(@($stale).Count) of $($cpps.Count) file(s), linking..."
& cmd /c "`"$fast\build.cmd`""
if ($LASTEXITCODE -ne 0) { Die "build failed (exit $LASTEXITCODE)" }

New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
try { Copy-Item "$fast\main.dll" $Out -Force } catch { Die "cannot overwrite $Out (loaded by a running game?): $($_.Exception.Message)" }
Write-Host ("OK {0} ({1:N0} KB) in {2:N1}s" -f $Out, ((Get-Item $Out).Length / 1KB), $sw.Elapsed.TotalSeconds)
