# L9/Q3 soak: repeats run-loop scenarios back to back for -Minutes (default 120) on one pair and logs each summary.
# Pass = every run passes with no crash. Usage: powershell -File tools/soak.ps1 -Root C:\PTLanes\soak -Port 7860 [-Minutes 120] [-Tunnel "udp lag=150 loss=2"]
param([string]$Root = "C:\PTLanes\soak", [int]$Port = 7860, [int]$Minutes = 120, [string]$Tunnel = "",
      [string[]]$Scenarios = @("runloop:garage", "playpath:zone", "lootsync:zone", "sessiontravel:garage"),
      [string]$Data = "") # folder with fixtures\ and test-results\ (default: this checkout's local; a pinned worktree passes the main one)
$Repo = (Resolve-Path "$PSScriptRoot\..").Path
if (-not $Data) { $Data = "$Repo\local" }
$out = Join-Path $Data "test-results\soak-$(Get-Date -f yyyyMMdd-HHmmss).txt"
$end = (Get-Date).AddMinutes($Minutes); $i = 0; $fail = 0
while ((Get-Date) -lt $end) {
    $s, $fx = $Scenarios[$i % $Scenarios.Count] -split ":"; $i++
    $a = @("-File", "$Repo\tools\run-test.ps1", "-Scenario", $s, "-Root", $Root, "-Port", $Port, "-Headless",
           "-ResultsDir", "$Data\test-results", "-FixturesDir", "$Data\fixtures")
    if ($fx) { $a += @("-Fixture", $fx) }
    if ($Tunnel) { $a += @("-Tunnel", $Tunnel) }
    $log = & powershell @a 2>&1 | Out-String
    $sum = ($log -split "`n" | Where-Object { $_ -match "^SUMMARY|^results:" }) -join " "
    if ($log -notmatch "SUMMARY: (\d+)/\1 passed") { $fail++ }
    "$(Get-Date -f HH:mm:ss) run $i $s $sum" | Tee-Object -FilePath $out -Append
}
"$(Get-Date -f HH:mm:ss) soak done: $i runs, $fail failed" | Tee-Object -FilePath $out -Append
