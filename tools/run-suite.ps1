# Full regression, one scenario at a time on one test pair (docs/LANES.md: run once on main after the lanes merge).
# tools\run-suite.ps1 [-Only a,b] [-Root ...] [-Port ...]; writes local\test-results\suite-<stamp>.txt, exit 1 if any failed.
param([string[]]$Only = @(), [string]$Root = "C:\PacificTogetherTest", [int]$Port = 7700, [string]$Shard = "")  # -Shard 1/2: every 2nd scenario from the 1st, for two pairs in parallel
$Repo = (Resolve-Path "$PSScriptRoot\..").Path
$Only = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ })  # -File passes "a,b" as one string
# scenario = fixture ("" = none); the fixture each one needs comes from its lane's report
$Suite = [ordered]@{ # most affected by recent merges first, so a cut-short run still covers them
    session = ""; playpath = "zone"; carsync = "garage"; carenter = "garage"; lootsync = "zone"; lootsync2 = "zone"
    guestact = "gateway"; progsync = "zone"; playerhealth = "zone"; backpacksync = "zone"; garagesync = "garage"; guestparts = "gateway"
    guestcraft = "garage"; guestdeath = "zone"; lootcar = "zone"; dropfall = "zone"; carexit = "garage"; arckey = "garage"
    carfeel = "garage"; guestswap = "gateway"; pausemenu = "garage"; runloop = "garage"; worldsync = "gateway"; storysync = "garage"; storyprog = "garage"; overlay = "garage"; mapmark = "zone"; ping = "garage"; upgrades = "garage"; stations = "garage"; hands = "garage"; visual = "zone"; visualgarage = "garage"
    anomalies = "zone"; anomalies2 = "zone"; anomalies3 = "zone"; boons = "garage"; safety = ""; nametag = ""; sessiontravel = "garage"; sessionrejoin = ""
    zonejoin = ""; steamsession = ""
    zonespawn = "zone"; guestui = "garage"; worlddoors = "garage"; worldzone = "zone"; weathersync = "zone"; anchordup = "zone"; radiation = "zone"; wheelflat = "zone"; portals = "gateway"; pausehost = "garage"; anomtesla = "zone"; carsit = "garage"; survivor = "garage"; carrelevant = "garage"; netflow = "garage"; zoneexit = "coop-zone"; transition = "coop-zone"; arcui = "gateway"
}
$out = Join-Path $Repo "local\test-results\suite-$(Get-Date -f yyyyMMdd-HHmmss)$(if ($Shard) { '-' + ($Shard -replace '/', 'of') }).txt"
$Suite.itemphysics = "garage"
$Suite.damagefeedback = "garage"
$Suite.progressquiet = "garage"
$Suite.keyedges = ""
$Suite.mail = "garage"
$Suite.guestctl = "garage"
$Suite.travel = ""
$Suite.body = ""
$failed = @(); $ran = 0
$i = -1
foreach ($s in $Suite.Keys) {
    $i++
    if ($Only.Count -and $Only -notcontains $s) { continue }
    if ($Shard -match "^(\d+)/(\d+)$" -and ($i % [int]$Matches[2]) -ne ([int]$Matches[1] - 1)) { continue }
    $ran++
    $a = @("-Scenario", $s, "-Root", $Root, "-Port", $Port, "-Headless")
    if ($Suite[$s]) { $a += @("-Fixture", $Suite[$s]) }
    $lines = & powershell -NoProfile -File "$Repo\tools\run-test.ps1" @a 2>&1 | Select-String "SUMMARY|results:" | ForEach-Object { $_.Line }
    $ok = $LASTEXITCODE -eq 0
    if (-not $ok) { $failed += $s }
    $line = "{0} {1,-14} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $s, ($lines -join " | ")
    Add-Content -Encoding utf8 $out $line
    $line
}
"suite: $($ran - $failed.Count)/$ran passed; failed: $($failed -join ' ')" | Tee-Object -FilePath $out -Append
if ($failed) { exit 1 }
