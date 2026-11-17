# Sums the PT|perf per-site times (ms) of a test results folder, for host and guest (client).
# Usage: powershell -File tools/perfsum.ps1 <results folder> [-Top 12] [-Skip 1]
# -Skip: minutes (PT|perf blocks) ignored at the start of each log (join/load noise). Sites under 10 ms/min are not logged by the mod.
param([Parameter(Mandatory)][string]$Dir, [int]$Top = 12, [int]$Skip = 1)
foreach ($role in "host", "client") {
    $f = Join-Path $Dir "$role-UE4SS.log"
    if (-not (Test-Path $f)) { continue }
    $sites = @{}; $blocks = 0; $last = ""; $fps = @()
    foreach ($l in Get-Content $f) {
        if ($l -match 'PT\|perf fps (.*)$') { $fps += $Matches[1]; continue }
        if ($l -notmatch 'PT\|perf (\S+\.lua:\d+) total=(\d+) ms max=(\d+) ms n=(\d+)') { continue }
        $s = $Matches[1]; $ms = [int]$Matches[2]; $mx = [int]$Matches[3]; $cnt = [int]$Matches[4]
        if ($l -match '^\[(\S+ \S{8})') { if ($Matches[1] -ne $last) { $last = $Matches[1]; $blocks++ } } # a new block per second stamp
        if ($blocks -le $Skip) { continue }
        if (-not $sites[$s]) { $sites[$s] = @{ t = 0; m = 0; n = 0 } }
        $sites[$s].t += $ms; $sites[$s].n += $cnt
        if ($mx -gt $sites[$s].m) { $sites[$s].m = $mx }
    }
    $tot = ($sites.Values | ForEach-Object { $_.t } | Measure-Object -Sum).Sum
    "== $role  (sum of logged sites: $tot ms, blocks seen: $blocks, skipped $Skip)"
    $sites.GetEnumerator() | Sort-Object { $_.Value.t } -Descending | Select-Object -First $Top |
        ForEach-Object { "{0,-26} total={1,7} ms  max={2,4} ms  n={3}" -f $_.Key, $_.Value.t, $_.Value.m, $_.Value.n }
    if ($fps) { "fps: " + ($fps -join " | ") }
}
