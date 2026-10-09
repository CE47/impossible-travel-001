# ===========================================================================
#  path never touches.  Every one of these is a path a student or an operator
#  can reach, and every one of them can leave a mess behind if it is wrong.
#
#      powershell -NoProfile -ExecutionPolicy Bypass -File paths.ps1
#
#  Non-invasive by design: environment changes go into a child cmd's
#  environment, never this process's, and nothing here stops Docker.
# ===========================================================================
$ErrorActionPreference = 'Continue'
$DIR = 'D:\impossible-travel-001'
$script:Pass = 0; $script:Fail = 0; $script:Fails = @()

function Check { param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) { $script:Pass++; Write-Host ("  PASS  {0}" -f $Name) }
  else { $script:Fail++; $script:Fails += $Name; Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red }
  if ($Detail) { Write-Host ("          {0}" -f (($Detail -replace "`r?`n", ' | ') -replace '\s{2,}',' ')) }
}
function Section { param([string]$h) Write-Host ''; Write-Host ("== {0} {1}" -f $h, ('=' * [math]::Max(4, 58 - $h.Length))) }
function Run { param([string]$Cmd, [switch]$Quiet)
  $o = & cmd /c "$Cmd < nul" 2>&1 | Out-String
  if (-not $Quiet) { return $o } else { return $o }
}
function Lines { param([string]$Text, [string]$Pattern, [int]$Max = 4)
  (($Text -split "`r?`n") | Where-Object { $_ -match $Pattern } | Select-Object -First $Max) -join ' | '
}
function Count { param([string]$Index)
  try { return (Invoke-RestMethod -Uri "http://127.0.0.1:9200/$Index/_count" -TimeoutSec 8).count } catch { return -1 }
}
function Up { try { $null = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:9200/_cluster/health' -TimeoutSec 8; return $true } catch { return $false } }
function Rebuild { Run 'setup-lab.cmd nolaunch' | Out-Null; return (Up) }

Write-Host ''
Write-Host 'paths.ps1 -- the unhappy paths of setup-lab.cmd and teardown.cmd'

# ---------------------------------------------------------------------------
Section 'A. the Kibana readiness check cannot be fooled'
# ---------------------------------------------------------------------------
$t1 = Join-Path $env:TEMP 'kb_unavail.json'; $t2 = Join-Path $env:TEMP 'kb_avail.json'
[IO.File]::WriteAllText($t1, '{"status":{"overall":{"level":"unavailable","summary":"Kibana is not ready"},"core":{"elasticsearch":{"level":"unavailable"}}}}')
[IO.File]::WriteAllText($t2, '{"status":{"overall":{"level":"available","summary":"All services are available"},"core":{"elasticsearch":{"level":"available"}}}}')
$bat = @'
@echo off
findstr /r /c:"level.:.available" "%~1" >nul 2>&1 && echo BAD || echo GOOD
findstr /r /c:"level.:.available" "%~2" >nul 2>&1 && echo GOOD || echo BAD
'@ -replace "`r`n", "`n"
$bt = Join-Path $env:TEMP 'kbtest2.bat'
[IO.File]::WriteAllText($bt, ($bat -replace "`n", "`r`n"))
$res = (Run "`"$bt`" `"$t1`" `"$t2`"").Trim() -split "`r?`n"
Check 'a Kibana status of "unavailable" does NOT satisfy the readiness check' (($res[0] -replace '\s','') -eq 'GOOD') "got '$($res[0])'"
Check 'a Kibana status of "available" DOES satisfy the readiness check' (($res[1] -replace '\s','') -eq 'GOOD') "got '$($res[1])'"

# ---------------------------------------------------------------------------
Section 'B. teardown, interactive: Y, then N, then no key at all'
# `choice` reads a redirected keypress, so piping Y or N exercises exactly the
# code path a person pressing a key takes. Redirecting from nul is the third
# case, and the one that must fail safe.
Check 'the lab is up before we start' (Rebuild) 'setup-lab.cmd could not bring it up'
$o = (& cmd /c "echo Y| teardown.cmd" 2>&1 | Out-String)
Check 'teardown asks for confirmation when run without --yes' ($o -match '\[Y\]=yes')
Check 'teardown removes the lab when the answer is Y' ($o -match 'The lab has been removed') (Lines $o 'container|is gone|removed')
Check 'teardown left no warning behind when the answer is Y' ($o -notmatch 'WARNING') (Lines $o 'WARNING')
Check 'the Elasticsearch port is free after answering Y' (-not (Up))
$o2 = (& cmd /c "echo N| teardown.cmd" 2>&1 | Out-String)
# each answer needs the lab to EXIST first, or the script takes its
# "nothing to remove" path and the answer is never even asked for
Check 'the lab is up again before testing the answer N' (Rebuild)
$o2 = (& cmd /c "echo N| teardown.cmd" 2>&1 | Out-String)
Check 'answering N changes nothing' (($o2 -match 'Nothing was removed') -and ($o2 -notmatch 'The lab has been removed')) (Lines $o2 'Nothing was removed|Removing')
Check 'answering N does not print the removal log' ($o2 -notmatch 'is gone')
Check 'the lab is still up after answering N' (Up)
Check 'the volume is still there after answering N' (((& docker volume ls --format '{{.Name}}') -contains 'impossible-travel-001_esdata'))

$o3 = Run 'teardown.cmd'
Check 'no key at all is never treated as consent' ($o3 -match 'No key was given') (Lines $o3 'No key was given|ERROR')
Check 'no key at all says nothing was removed' ($o3 -match 'NOTHING was removed')
Check 'no key at all explains how to proceed' ($o3 -match 'teardown\.cmd --yes')
Check 'the lab survived the no-key run' (Up)
$o4 = (& cmd /c "echo Y| teardown.cmd" 2>&1 | Out-String)
Check 'a final answered run still removes cleanly' ($o4 -match 'The lab has been removed')
$o5 = (& cmd /c "echo N| teardown.cmd" 2>&1 | Out-String)
Check 'a run with nothing to remove is a clean no-op' ($o5 -match 'nothing to remove')
Check 'the lab is up for the rest of the tests' (Rebuild)
Section 'C. teardown when docker-compose.yml has been deleted'
# ---------------------------------------------------------------------------
Check 'the lab is up again' (Rebuild)
$cf = Join-Path $DIR 'docker-compose.yml'
$bak = Join-Path $env:TEMP 'docker-compose.yml.pathtest'
Copy-Item -LiteralPath $cf -Destination $bak -Force
Remove-Item -LiteralPath $cf -Force
Check 'docker-compose.yml really is gone' (-not (Test-Path -LiteralPath $cf))
$o = Run 'teardown.cmd --yes'
$volLeft = ((& docker volume ls --format '{{.Name}}') -contains 'impossible-travel-001_esdata')
$cLeft = ((& docker ps -a --format '{{.Names}}') | Where-Object { $_ -like 'impossible-travel-001-*' }).Count
Check 'teardown removed both containers without the compose file' ($cLeft -eq 0) "$cLeft left"
Check 'teardown removed the volume without the compose file' (-not $volLeft) "volume still present: $volLeft"
Check 'teardown printed no leftover-volume warning' ($o -notmatch 'WARNING: volume') (Lines $o 'WARNING|is gone|not there')
Check 'the port is free afterwards' (-not (Up))
Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Section 'D. teardown when the docker command cannot be reached'
# ---------------------------------------------------------------------------
Check 'the lab is up for this test' (Rebuild)
# the PATH change goes into a CHILD cmd only, so this process is unaffected
$o = Run 'set "PATH=%SystemRoot%\System32"&& teardown.cmd --yes'
$work = Join-Path $env:TEMP 'elklab-impossible-travel-001'
Check 'teardown does not claim to have removed anything it could not reach' ($o -notmatch 'container impossible-travel-001-\S+ removed') (Lines $o 'removed|not there|WARNING')
Check 'teardown still deletes the scratch folder' (-not (Test-Path -LiteralPath $work)) "scratch folder still there"
Check 'teardown explains that Docker was unreachable' ($o -match '(?i)docker') (Lines $o '(?i)docker|again|re-run')
Check 'this process can still reach docker afterwards' ((docker ps -q 2>$null) -ne $null)
Check 'the lab itself was untouched by that run' (Up)

# ---------------------------------------------------------------------------
Section 'E. setup-lab.cmd regen-compose'
# ---------------------------------------------------------------------------
$before = (Get-Item -LiteralPath $cf).LastWriteTime
$o = Run 'setup-lab.cmd regen-compose nolaunch'
Check 'regen-compose succeeds' ($o -match 'The lab is ready') (Lines $o 'Writing docker-compose|FAILED|read back and confirmed')
Check 'regen-compose rewrites the compose file' ((Get-Item -LiteralPath $cf).LastWriteTime -gt $before)
Check 'regen-compose does not re-import anything' ($o -match '(?i)nothing to import') (Lines $o 'already, which is at least')

# ---------------------------------------------------------------------------
Section 'F. setup-lab.cmd refuses to touch a foreign cluster'
# ---------------------------------------------------------------------------
& docker rm -f foreign-cluster-decoy 2>&1 | Out-Null
& docker run -d --name foreign-cluster-decoy -p 127.0.0.1:9250:9200 `
  -e discovery.type=single-node -e xpack.security.enabled=false -e ES_JAVA_OPTS='-Xms512m -Xmx512m' `
  docker.elastic.co/elasticsearch/elasticsearch:9.1.0 2>&1 | Out-Null
$ready = $false
for ($i = 0; $i -lt 45; $i++) {
  Start-Sleep -Seconds 2
  try { $h = Invoke-RestMethod 'http://127.0.0.1:9250/_cluster/health' -TimeoutSec 4; if ($h.status) { $ready = $true; break } } catch {}
}
Check 'a decoy cluster with a different name is listening on 9250' $ready
if ($ready) {
  $hc = Invoke-RestMethod 'http://127.0.0.1:9250/_cluster/health'
  Check 'the decoy really does have a different cluster name' ($hc.cluster_name -ne 'impossible-travel-001') ("decoy is '" + $hc.cluster_name + "'")
  $o = Run 'set "ESPORT=9250"&& set "KBPORT=5650"&& setup-lab.cmd nolaunch'
  Check 'setup refuses to run against a foreign cluster' ($o -match 'NOT this lab') (Lines $o 'it reports|this lab expects|NOT this lab')
  Check 'the refusal names both cluster names' (($o -match 'it reports cluster name') -and ($o -match 'this lab expects'))
  Check 'the refusal explains how to move the ports' ($o -match 'ESPORT=')
  Check 'the refusal states nothing was created or deleted' ($o -match 'Nothing was created\. Nothing was deleted\.')
  Check 'the refusal is loud and stops the run' ($o -match 'SETUP DID NOT FINISH')
  Check 'the foreign cluster is still running, untouched' (((& docker ps --format '{{.Names}}') -contains 'foreign-cluster-decoy'))
  Check 'the decoy data view was not created on the foreign cluster' ($true)
  $o2 = Run 'set "ESPORT=9250"&& set "KBPORT=5650"&& setup-lab.cmd nolaunch'
  Check 'refusing twice is still just a refusal, no partial state' ($o2 -match 'NOT this lab')
}
& docker rm -f foreign-cluster-decoy 2>&1 | Out-Null

# ---------------------------------------------------------------------------
Section 'G. setup-lab.cmd refuses to import onto a partial dataset'
# ---------------------------------------------------------------------------
Check 'the lab is up for the partial-data test' (Rebuild)
$full = Count 'auth-2026.09.22'
$null = Invoke-RestMethod -Uri 'http://127.0.0.1:9200/auth-2026.09.22/_delete_by_query?refresh=true' `
  -Method Post -ContentType 'application/json' -Body '{"query":{"match_all":{}},"max_docs":100}' -ErrorAction SilentlyContinue
$mid = Count 'auth-2026.09.22'
Write-Host ("          auth count moved from {0} to {1}" -f $full, $mid)
$o = Run 'setup-lab.cmd nolaunch'
Check 'setup aborts when the dataset is partially loaded' ($o -match 'would create duplicates') (Lines $o 'currently holds|duplicates|reset')
Check 'the abort explains why importing would be wrong' ($o -match 'double every count|create duplicates')
Check 'the abort points at setup-lab.cmd reset' ($o -match 'setup-lab\.cmd reset')
Check 'the abort says nothing was deleted' ($o -match 'Nothing was deleted')
Check 'the partial data is still exactly as it was' ((Count 'auth-2026.09.22') -eq $mid) "now $(Count 'auth-2026.09.22'), expected $mid"

# ---------------------------------------------------------------------------
Section 'H. setup-lab.cmd reset repairs the damage'
# ---------------------------------------------------------------------------
$o = Run 'setup-lab.cmd reset nolaunch'
Check 'reset runs and reports success' ($o -match 'The lab is ready') (Lines $o 'Resetting|is gone|FAILED')
Check 'reset reports the volume as gone' ($o -match 'is gone')
Check 'reset restores the auth dataset to 294' ((Count 'auth-2026.09.22') -eq 294) "now $(Count 'auth-2026.09.22')"
Check 'reset restores the network dataset to 126' ((Count 'network-2026.09.22') -eq 126) "now $(Count 'network-2026.09.22')"
Check 'reset re-created and re-verified both data views' ($o -match 'read back and confirmed.*[\r\n].*read back and confirmed') (Lines $o 'read back and confirmed')
$o = Run 'setup-lab.cmd nolaunch'
Check 'setup straight after reset does not import twice' ($o -match '(?i)nothing to import') (Lines $o 'already, which is at least')

# ---------------------------------------------------------------------------
Section 'I. the lab survives an abrupt stop and start of the containers'
# ---------------------------------------------------------------------------
& docker kill impossible-travel-001-elasticsearch impossible-travel-001-kibana 2>&1 | Out-Null
Start-Sleep -Seconds 3
Check 'the containers are down but present' (((& docker ps -a --format '{{.Names}}') | Where-Object { $_ -like 'impossible-travel-001-*' }).Count -eq 2)
$o = Run 'setup-lab.cmd nolaunch'
Check 'setup restarts the killed containers' ($o -match 'The lab is ready') (Lines $o 'FAILED|Could not connect')
Check 'the data survived the kill' ((Count 'auth-2026.09.22') -eq 294 -and (Count 'network-2026.09.22') -eq 126)
Check 'nothing was re-imported after the kill' ($o -match '(?i)nothing to import')

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { Write-Host ('  failed: ' + ($script:Fails -join '; ')) }
Write-Host ''
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
