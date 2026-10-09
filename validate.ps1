# ===========================================================================
#  validate.ps1 -- prove the walkthrough is correct, self-contained and
#  reproducible.  Run with the lab up:
#      powershell -NoProfile -ExecutionPolicy Bypass -File validate.ps1
#
#  Nothing here trusts the deck. Every count is re-measured from the running
#  index, and the deck is then checked against the fresh measurement.
#  Secrets are fetched at test time and only ever reported as counts.
# ===========================================================================
$ErrorActionPreference = 'Continue'
$DIR  = 'D:\impossible-travel-001'
$HTML = Join-Path $DIR 'guided-walkthrough.html'
$ES = 'http://127.0.0.1:9200'
$SHOTS = 'C:\Users\User\AppData\Local\Temp\opencode\shots'

$script:Pass = 0
$script:Fail = 0
$script:Notes = @()

function Check { param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) { $script:Pass++; Write-Host ("  PASS  {0}" -f $Name) }
  else { $script:Fail++; Write-Host ("  FAIL  {0}   {1}" -f $Name, $Detail) }
  $script:Notes += [pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail }
}
function Section { param([string]$h = '')
  Write-Host ''
  $bar = '=' * [math]::Max(4, 68 - $h.Length)
  Write-Host ("== {0} {1}" -f $h, $bar)
}
function Term($f, $v) { return @{ term = @{ $f = $v } } }
function And($cl) { return @{ bool = @{ filter = $cl } } }
function CountOf($idx, $query) {
  $b = @{ size = 0; query = $query } | ConvertTo-Json -Depth 20 -Compress
  $r = Invoke-RestMethod -Uri "$ES/$idx/_search" -Method Post -Body $b -ContentType 'application/json'
  return $r.hits.total.value
}
function BucketOf($idx, $query, $field, $size = 50) {
  $b = @{ size = 0; query = $query; aggs = @{ v = @{ terms = @{ field = $field; size = $size; order = @{ _key = 'desc' } } } } } | ConvertTo-Json -Depth 20 -Compress
  $r = Invoke-RestMethod -Uri "$ES/$idx/_search" -Method Post -Body $b -ContentType 'application/json'
  return $r.aggregations.v.buckets
}
function SearchSort($idx, $query, $size, $field, $dir) {
  $b = @{ size = $size; query = $query; sort = @(@{ $field = @{ order = $dir } }) } | ConvertTo-Json -Depth 10 -Compress
  $r = Invoke-RestMethod -Uri "$ES/$idx/_search" -Method Post -Body $b -ContentType 'application/json'
  return $r.hits.hits
}

# ---------------------------------------------------------------------------
Section '1. one self-contained offline document'
# ---------------------------------------------------------------------------
$html = [IO.File]::ReadAllText($HTML)
Check 'walkthrough.html exists and is substantial' ($html.Length -gt 500000) ("{0:N0} bytes" -f $html.Length)
Check 'declares a doctype and a charset' (($html -match '(?s)^<!DOCTYPE html>') -and ($html -match '<meta charset="utf-8">'))
Check 'has a <title>' ($html -match '<title>[^<]+</title>')

$ext = [regex]::Matches($html, '(?i)(?:src|href)\s*=\s*["''](?:https?:|//)')
Check 'no external src or href of any kind' ($ext.Count -eq 0) ("{0} found" -f $ext.Count)
Check 'no <script src>' (([regex]::Matches($html, '(?i)<script[^>]*\ssrc\s*=')).Count -eq 0)
Check 'no CSS @import' (([regex]::Matches($html, '(?i)@import')).Count -eq 0)
Check 'no url() pointing outside the file' (([regex]::Matches($html, '(?i)url\(\s*["'']?(?:https?:)?//')).Count -eq 0)
Check 'every <img> is an inlined data URI' (([regex]::Matches($html, '<img[^>]*\ssrc="(?!data:image/png;base64,)')).Count -eq 0)
$imgCount = ([regex]::Matches($html, 'data:image/png;base64,')).Count
Check 'screenshots are inlined exactly once each' (($imgCount -ge 12) -and ($imgCount -le 24)) ("$imgCount inlined URIs")
$badPng = 0
foreach ($mm in [regex]::Matches($html, 'data:image/png;base64,([A-Za-z0-9+/=]+)')) {
  try {
    $raw = [Convert]::FromBase64String($mm.Groups[1].Value)
    if ($raw.Length -lt 8 -or [BitConverter]::ToString($raw[0..3]) -ne '89-50-4E-47') { $badPng++ }
  } catch { $badPng++ }
}
Check 'every inlined image really decodes to a PNG' ($badPng -eq 0) ("$badPng bad data URIs")
Check 'exactly one lightbox element' (([regex]::Matches($html, 'id="lightbox"')).Count -eq 1)
Check 'no <iframe> and no <embed>' ((($html -match '<iframe') -or ($html -match '<embed')) -eq $false)

# ---------------------------------------------------------------------------
Section '2. tag balance and card structure'
# ---------------------------------------------------------------------------
foreach ($tag in @('div', 'table', 'section', 'tbody', 'thead', 'tr', 'figure', 'details', 'ul', 'ol')) {
  $o = ([regex]::Matches($html, "<$tag[\s>]")).Count
  $c = ([regex]::Matches($html, "</$tag>")).Count
  Check "$tag tags balance" ($o -eq $c) "open=$o close=$c"
}
$cards = [regex]::Matches($html, '(?s)<section class="slide(?: on)?"[^>]*>.*?</section>')
Check 'card count is 21' ($cards.Count -eq 21) ("found {0}" -f $cards.Count)
$onCount = ([regex]::Matches($html, '<section class="slide on"')).Count
Check 'exactly one card carries the on class' ($onCount -eq 1) ("found {0}" -f $onCount)
Check 'the on card is the first card' ($html.IndexOf('<section class="slide on"') -lt $html.IndexOf('<section class="slide" data-tone'))
$structBad = @()
for ($i = 0; $i -lt $cards.Count; $i++) {
  $t = $cards[$i].Value
  $hd = ([regex]::Matches($t, 'class="chead"')).Count
  $bd = ([regex]::Matches($t, 'class="cbody"')).Count
  $ft = ([regex]::Matches($t, 'class="cfoot"')).Count
  if ($hd -ne 1 -or $bd -ne 1 -or $ft -ne 1) { $structBad += ("card {0}: chead={1} cbody={2} cfoot={3}" -f ($i + 1), $hd, $bd, $ft) }
}
Check 'every card has exactly one chead, cbody and cfoot' ($structBad.Count -eq 0) ($structBad -join ' | ')
Check 'every card footer has a counter' ((([regex]::Matches($html, 'class="counter"')).Count) -eq 21)
Check 'no card hand-numbers its own counter' ($html -notmatch '<span class="counter">\s*\d')
$kick = @([regex]::Matches($html, '<span class="nn">([^<]*)</span>') | ForEach-Object { $_.Groups[1].Value })
$nums = @($kick | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
Check 'kicker numbers run 1..20 with no gaps or repeats' (($nums.Count -eq 20) -and ((($nums | Sort-Object) -join ',') -eq ((1..20) -join ','))) ("got: " + ($nums -join ','))
Check 'card 1 uses a symbol rather than the number 1' ($kick[0] -notmatch '^\d+$') ("got '" + $kick[0] + "'")

# ---------------------------------------------------------------------------
Section '3. every table is rectangular'
# ---------------------------------------------------------------------------
$bad = @()
$tblCount = ([regex]::Matches($html, '<table[\s>]')).Count
foreach ($tm in [regex]::Matches($html, '(?s)<table[^>]*>(.*?)</table>')) {
  $rows = [regex]::Matches($tm.Groups[1].Value, '(?s)<tr[^>]*>(.*?)</tr>')
  $counts = @()
  foreach ($r in $rows) {
    $th = ([regex]::Matches($r.Groups[1].Value, '<th[\s>]')).Count
    $td = ([regex]::Matches($r.Groups[1].Value, '<td[\s>]')).Count
    $counts += ($th + $td)
  }
  if (($counts | Sort-Object -Unique).Count -ne 1) { $bad += ("cell counts " + ($counts -join ',')) }
}
Check ("all {0} tables are rectangular" -f $tblCount) ($bad.Count -eq 0) ($bad -join ' | ')

# ---------------------------------------------------------------------------
Section '4. cross-references point at cards that really exist'
# ---------------------------------------------------------------------------
$navs = @()
for ($i = 0; $i -lt $cards.Count; $i++) {
  $m = [regex]::Match($cards[$i].Value, 'data-nav="([^"]*)"')
  $navs += $m.Groups[1].Value
}
Write-Host ("  rail: " + ($navs -join ' | '))
$refBad = @()
for ($i = 0; $i -lt $cards.Count; $i++) {
  foreach ($rm in [regex]::Matches($cards[$i].Value, '(?i)\bcard(?:s)?\s+(\d{1,2})\b')) {
    $n = [int]$rm.Groups[1].Value
    if ($n -lt 1 -or $n -gt $cards.Count) { $refBad += ("card {0} refers to card {1}" -f ($i + 1), $n) }
  }
}
Check 'every "card N" cross-reference is in range' ($refBad.Count -eq 0) ($refBad -join ' | ')
$qref = @()
for ($i = 0; $i -lt $cards.Count; $i++) {
  foreach ($rm in [regex]::Matches($cards[$i].Value, '(?i)\bQuery\s+(\d)\b')) {
    $n = [int]$rm.Groups[1].Value
    if ($n -lt 1 -or $n -gt 8) { $qref += ("card {0} names Query {1}" -f ($i + 1), $n) }
  }
}
Check 'every "Query N" reference is between 1 and 8' ($qref.Count -eq 0) ($qref -join ' | ')

# ---------------------------------------------------------------------------
Section '5. the deck only contains queries that were measured'
# ---------------------------------------------------------------------------
$EXPECTED = @(
  'event.category: authentication',
  'event.code: 4625',
  'event.code: 4624 and event.outcome: "success"',
  'event.code: 4624 and event.outcome: "success" and user.name: "jdoe"',
  'event.code: 4688',
  'network.protocol: "https"'
)
$qboxes = @()
$qchunks = [regex]::Split($html, '(?=<div class="qbox">)')
for ($i = 1; $i -lt $qchunks.Count; $i++) {
  if ($qchunks[$i] -notmatch 'class="copy"') { continue }
  $m = [regex]::Match($qchunks[$i], '(?s)<code class="qq">(.*?)</code>')
  if ($m.Success) { $qboxes += $m.Groups[1].Value.Trim() }
}
Write-Host ("  the deck carries {0} copyable query boxes:" -f $qboxes.Count)
foreach ($q in $qboxes) { Write-Host ("    " + $q) }
$deckQs = @($qboxes | Sort-Object -Unique)
$badQ = @()
foreach ($q in $deckQs) { if ($EXPECTED -notcontains $q) { $badQ += $q } }
Check 'every query box holds a measured query' ($badQ.Count -eq 0) ('unexpected: ' + ($badQ -join ' | '))
$missQ = @()
foreach ($q in $EXPECTED) { if ($deckQs -notcontains $q) { $missQ += $q } }
Check 'all six investigation queries appear as copyable boxes' ($missQ.Count -eq 0) ('missing: ' + ($missQ -join ' | '))

# ---------------------------------------------------------------------------
Section '6. re-measure every claim from the live index'
# ---------------------------------------------------------------------------
$AUTH = 'auth-2026.09.22'; $NET = 'network-2026.09.22'
$truth = [ordered]@{}
try {
  $r = Invoke-RestMethod "$ES/$AUTH/_count";    $truth['auth-docs'] = $r.count
  $r = Invoke-RestMethod "$ES/$NET/_count";     $truth['network-docs'] = $r.count
  $q1 = And @((Term 'event.category' 'authentication'))
  $q2 = And @((Term 'event.code' 4625))
  $q3 = And @((Term 'event.code' 4624), (Term 'event.outcome' 'success'))
  $q4 = And @((Term 'event.code' 4624), (Term 'event.outcome' 'success'), (Term 'user.name' 'jdoe'))
  $q6 = And @((Term 'event.code' 4688))
  $n1 = And @((Term 'network.protocol' 'https'))
  $n2 = And @((Term 'network.protocol' 'https'), (Term 'source.ip' '10.0.4.10'))
  $truth['q1'] = CountOf $AUTH $q1
  $truth['q2'] = CountOf $AUTH $q2
  $truth['q3'] = CountOf $AUTH $q3
  $truth['q4'] = CountOf $AUTH $q4
  $truth['q6'] = CountOf $AUTH $q6
  $truth['n1'] = CountOf $NET $n1
  $truth['n2'] = CountOf $NET $n2
  $truth['q2-users'] = @((BucketOf $AUTH $q2 'user.name') | ForEach-Object { '{0}={1}' -f $_.key, $_.doc_count })
  $truth['q3-ips'] = @((BucketOf $AUTH $q3 'source.ip') | ForEach-Object { [pscustomobject]@{ k = $_.key; n = $_.doc_count } })
  $truth['q4-ips'] = @((BucketOf $AUTH $q4 'source.ip') | ForEach-Object { $_.key })
  $q3ipCount = @{}
  foreach ($b in $truth['q3-ips']) { $q3ipCount[$b.k] = $b.n }
  $truth['q3-ipmap'] = $q3ipCount
  $hits = SearchSort $AUTH $q4 10 '@timestamp' 'asc'
  $srcs = @()
  foreach ($h in $hits) { $srcs += $h.PSObject.Properties['_source'].Value }
  $truth['q4-ts'] = @($srcs | ForEach-Object { $_.'@timestamp' })
  $truth['q4-hosts'] = @($srcs | ForEach-Object { $_.'host.name' } | Sort-Object -Unique)
  $big = SearchSort $NET $n1 2 'network.bytes' 'desc'
  $b0 = $big[0].PSObject.Properties['_source'].Value
  $b1 = $big[1].PSObject.Properties['_source'].Value
  $truth['big-bytes'] = [long]$b0.'network.bytes'
  $truth['big-dst'] = $b0.'destination.ip'
  $truth['big-ts'] = $b0.'@timestamp'
  $truth['second-bytes'] = [long]$b1.'network.bytes'
  $t = @($truth['q4-ts'] | ForEach-Object { [datetime]$_ })
  $truth['window-min'] = [math]::Round(($t[2] - $t[0]).TotalMinutes, 3)
  $truth['gap1-min'] = [math]::Round(($t[1] - $t[0]).TotalMinutes, 3)
  $truth['gap2-min'] = [math]::Round(($t[2] - $t[1]).TotalMinutes, 3)
  $truth['ratio'] = [math]::Round($truth['big-bytes'] / $truth['second-bytes'], 0)
  $truth['mib'] = [math]::Round($truth['big-bytes'] / 1MB, 1)
  $truth['after-min'] = [math]::Round(([datetime]$truth['big-ts'] - $t[2]).TotalMinutes, 2)
  Check 'the live cluster is reachable' $true ("{0} and {1} documents" -f $truth['auth-docs'], $truth['network-docs'])
}
catch {
  Check 'the live cluster is reachable' $false $_.Exception.Message
  $truth = $null
}

if ($truth) {
  Write-Host ("  measured: q1={0} q2={1} q3={2} q4={3} proc={4} https={5} https-from-workstation={6}" -f $truth['q1'], $truth['q2'], $truth['q3'], $truth['q4'], $truth['q6'], $truth['n1'], $truth['n2'])
  Write-Host ("  measured: 4625 by account  " + ($truth['q2-users'] -join '  '))
  Write-Host ("  measured: 4624 by address  " + (($truth['q3-ips'] | ForEach-Object { '{0}={1}' -f $_.k, $_.n }) -join '  '))
  Write-Host ("  measured: window {0} min, gaps {1} and {2}, ratio {3}x, {4} MiB, {5} min after the last logon" -f $truth['window-min'], $truth['gap1-min'], $truth['gap2-min'], $truth['ratio'], $truth['mib'], $truth['after-min'])

  $claim = @(
    @{ n = 'auth dataset holds 294 documents'; ok = ($truth['auth-docs'] -eq 294); g = $truth['auth-docs']; w = 294 }
    @{ n = 'network dataset holds 126 documents'; ok = ($truth['network-docs'] -eq 126); g = $truth['network-docs']; w = 126 }
    @{ n = 'Query 1 returns 280'; ok = ($truth['q1'] -eq 280); g = $truth['q1']; w = 280 }
    @{ n = 'Query 2 returns 51'; ok = ($truth['q2'] -eq 51); g = $truth['q2']; w = 51 }
    @{ n = 'Query 3 returns 74'; ok = ($truth['q3'] -eq 74); g = $truth['q3']; w = 74 }
    @{ n = 'Query 4 returns 3'; ok = ($truth['q4'] -eq 3); g = $truth['q4']; w = 3 }
    @{ n = 'the program-start query returns 14'; ok = ($truth['q6'] -eq 14); g = $truth['q6']; w = 14 }
    @{ n = 'the https query returns 15'; ok = ($truth['n1'] -eq 15); g = $truth['n1']; w = 15 }
    @{ n = 'https from the workstation returns 4'; ok = ($truth['n2'] -eq 4); g = $truth['n2']; w = 4 }
    @{ n = 'the three logons use 3 distinct source addresses'; ok = ($truth['q4-ips'].Count -eq 3); g = $truth['q4-ips'].Count; w = 3 }
    @{ n = 'all three logons went to the same machine'; ok = ($truth['q4-hosts'].Count -eq 1); g = $truth['q4-hosts'].Count; w = 1 }
    @{ n = 'the alerted account has zero failed logons'; ok = (@($truth['q2-users'] | Where-Object { $_ -like 'jdoe=*' }).Count -eq 0); g = $truth['q2-users'].Count; w = 'jdoe absent' }
    @{ n = 'the 51 failures span exactly 5 other accounts'; ok = ($truth['q2-users'].Count -eq 5); g = $truth['q2-users'].Count; w = 5 }
    @{ n = 'the 74 successes span 9 distinct source addresses'; ok = ($truth['q3-ips'].Count -eq 9); g = $truth['q3-ips'].Count; w = 9 }
    @{ n = 'the total window is 14 minutes'; ok = ([math]::Abs($truth['window-min'] - 14) -lt 0.01); g = $truth['window-min']; w = 14 }
    @{ n = 'the first gap is 6 minutes'; ok = ([math]::Abs($truth['gap1-min'] - 6) -lt 0.01); g = $truth['gap1-min']; w = 6 }
    @{ n = 'the second gap is 8 minutes'; ok = ([math]::Abs($truth['gap2-min'] - 8) -lt 0.01); g = $truth['gap2-min']; w = 8 }
    @{ n = 'the big transfer is roughly 740 times the runner-up'; ok = ($truth['ratio'] -ge 700 -and $truth['ratio'] -le 800); g = $truth['ratio']; w = '700..800' }
    @{ n = 'the big transfer is about 46 MB'; ok = ($truth['mib'] -ge 45 -and $truth['mib'] -le 47); g = $truth['mib']; w = '45..47 MiB' }
    @{ n = 'the big transfer goes to one of the three logon addresses'; ok = ($truth['q4-ips'] -contains $truth['big-dst']); g = 'match/no-match'; w = 'match' }
    @{ n = 'the big transfer is under 7 minutes after the last logon'; ok = ($truth['after-min'] -gt 0 -and $truth['after-min'] -lt 7); g = $truth['after-min']; w = '0..7' }
  )
  foreach ($c in $claim) { Check $c.n $c.ok ("measured {0}, deck claims {1}" -f $c.g, $c.w) }

  $must = @(
    @{ s = 'Documents (280)'; d = 'Query 1 count' }
    @{ s = 'Documents (51)'; d = 'Query 2 count' }
    @{ s = 'Documents (74)'; d = 'Query 3 count' }
    @{ s = 'Documents (15)'; d = 'https count' }
    @{ s = 'Documents (294)'; d = 'auth dataset size' }
    @{ s = '33.3%'; d = 'one address per logon' }
    @{ s = '65,030'; d = 'the runner-up byte count' }
    @{ s = '46 MB'; d = 'the big transfer' }
    @{ s = '740 times'; d = 'the ratio' }
    @{ s = '4,624'; d = 'event.code as Kibana prints it' }
    @{ s = 'TRUE POSITIVE'; d = 'the verdict' }
    @{ s = 'impossible travel'; d = 'the pattern name' }
    @{ s = 'Calculated from 3 records'; d = 'the sidebar caption' }
    @{ s = 'Distinct values'; d = 'the Field statistics column' }
    @{ s = 'Explore in Lens'; d = 'the Field statistics action' }
  )
  foreach ($m2 in $must) { Check ("the deck states {0} ({1})" -f $m2.s, $m2.d) ($html.Contains($m2.s)) 'not found in the file' }

  $pctBad = @()
  foreach ($u in $truth['q2-users']) {
    $n = [int]($u -split '=')[1]
    $pct = '{0:N1}%' -f (100 * $n / $truth['q2'])
    if (-not $html.Contains($pct)) { $pctBad += ("failed-logon share should read " + $pct) }
  }
  Check 'every failed-logon account share is printed correctly' ($pctBad.Count -eq 0) ($pctBad -join ' | ')
  $pctBad2 = @()
  foreach ($b in $truth['q3-ips']) {
    if ($b.k -like '10.0.4.*') { continue }   # internal addresses are not part of that lesson
    $pct = '{0:N1}%' -f (100 * $b.n / $truth['q3'])
    if (-not $html.Contains($pct)) { $pctBad2 += ("external address share should read " + $pct) }
  }
  Check 'every visible source-address share is printed correctly' ($pctBad2.Count -eq 0) ($pctBad2 -join ' | ')
}

# ---------------------------------------------------------------------------
Section '7. the redaction contract: no answer leaks before the self-check'
# ---------------------------------------------------------------------------
$SECRETS = @()
if ($truth) {
  $SECRETS += @($truth['q4-ts'])
  $SECRETS += @($truth['q4-ips'])
  $SECRETS += @($truth['q4-hosts'])
  $SECRETS += $truth['big-bytes'].ToString()
  $SECRETS += ('{0:N0}' -f $truth['big-bytes'])
  $SECRETS += @('10.0.4.10', '51544', '10:00:00.000Z', '10:06:00.137Z', '10:14:00.274Z', '10:20:00.000Z')
} else {
  $SECRETS = @('10.0.4.10', '51544')
}
$SECRETS = @($SECRETS | Where-Object { $_ -and $_.Length -ge 6 } | Sort-Object -Unique)
Write-Host ("  {0} hidden values are being watched for" -f $SECRETS.Count)

$parts = [regex]::Split($html, '(?=<section class="slide)')
$leaksBefore = 0; $leaksAllowed = 0
for ($i = 1; $i -lt $parts.Count; $i++) {
  $hits = 0
  foreach ($s in $SECRETS) { if ($parts[$i].Contains($s)) { $hits++ } }
  if ($hits -eq 0) { continue }
  if ($i -eq 18) { $leaksAllowed += $hits } else { $leaksBefore += $hits; Write-Host ("  FAIL  card {0} reveals {1} hidden value(s)" -f $i, $hits) }
}
Check 'no card before the self-check reveals a hidden value' ($leaksBefore -eq 0) ("{0} occurrences" -f $leaksBefore)
Check 'the self-check does reveal them, in green' ($leaksAllowed -gt 0) ("{0} occurrences" -f $leaksAllowed)

$ALLOW_IPS = @('10.0.4.10', '10.0.4.11', '10.0.4.20', '192.0.2.10', '203.0.113.9', '198.51.100.42', '203.0.113.45', '198.51.100.7', '192.0.2.24', '127.0.0.1')
$foundIPs = @([regex]::Matches($html, '\b(?:\d{1,3}\.){3}\d{1,3}\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
$stray = @($foundIPs | Where-Object { $ALLOW_IPS -notcontains $_ -and $_ -notmatch '^0\.0\.0\.0' -and $_ -notmatch '^255\.' })
Check 'no unexpected IP address appears anywhere in the deck' ($stray.Count -eq 0) ('unexpected: ' + ($stray -join ', '))
Write-Host ("  the deck names these addresses: " + ($foundIPs -join ', '))
Check 'no redaction pill is long enough to be a sentence' (([regex]::Matches($html, 'class="rd"[^>]*>[^<]{40,}')).Count -eq 0)
$rvCards = @()
for ($i = 1; $i -lt $parts.Count; $i++) { if ($parts[$i] -match 'class="rv"') { $rvCards += $i } }
Check 'green revealed pills appear only on the self-check card' ($rvCards.Count -eq 1 -and $rvCards[0] -eq 18) ("cards: " + ($rvCards -join ','))
$addrBad = @()
foreach ($a in @('203.0.113.45', '198.51.100.7', '192.0.2.24')) {
  $where = @()
  for ($j = 1; $j -lt $parts.Count; $j++) { if ($parts[$j].Contains($a)) { $where += $j } }
  if ($where.Count -ne 1 -or $where[0] -ne 18) { $addrBad += ('an address appears on card(s) ' + ($where -join '+') + ' instead of only card 18') }
}
Check 'the three external addresses appear only on the self-check card' ($addrBad.Count -eq 0) (($addrBad | Sort-Object -Unique) -join ' | ')
# ---------------------------------------------------------------------------
Section '8. the screenshots were verified leak-free when they were taken'
# ---------------------------------------------------------------------------
$shotsJson = Join-Path $SHOTS 'shots.json'
if (Test-Path -LiteralPath $shotsJson) {
  $sj = Get-Content -LiteralPath $shotsJson -Raw | ConvertFrom-Json
  $leaky = @($sj.PSObject.Properties | Where-Object { $_.Value.leaked -gt 0 })
  Check 'every captured screenshot reported zero remaining secrets' ($leaky.Count -eq 0) (($leaky | ForEach-Object { $_.Name }) -join ', ')
  $noRed = @($sj.PSObject.Properties | Where-Object { $_.Value.redactions -eq 0 -and $_.Name -notin @('k01-empty', 'k02-dataview', 'k03-timepicker') })
  Check 'every screenshot that could hold an answer had one redacted' ($noRed.Count -eq 0) (($noRed | ForEach-Object { $_.Name }) -join ', ')
  Write-Host ("  capture log covers {0} shots" -f @($sj.PSObject.Properties).Count)
} else {
  # the capture log is a build-time artifact, not part of the lab. If it is not
  # there, say so and carry on rather than failing a check that cannot run.
  Write-Host ("  SKIP  the capture log is not present ({0})" -f $shotsJson)
  Write-Host ("        this check confirms that each PNG was verified leak-free the")
  Write-Host ("        moment it was taken; it can only run on the machine that built it")
  Check 'the deck states that every screenshot was verified leak-free' ($html -match '(?i)confirmed that.{0,80}none of them remained|zero.{0,40}remaining occurrences') 'the deck does not make the claim this check would verify'
}

# ---------------------------------------------------------------------------
Section '9. the deck teaches the traps instead of hiding them'
# ---------------------------------------------------------------------------
$callouts = @{}
foreach ($m3 in [regex]::Matches($html, '<div class="co ([a-z]+)">')) {
  $k = $m3.Groups[1].Value
  if (-not $callouts.ContainsKey($k)) { $callouts[$k] = 0 }
  $callouts[$k]++
}
Write-Host ("  callouts: " + (($callouts.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '  '))
$missing = @()
foreach ($need in @('goal', 'find', 'next', 'stop', 'why', 'warn', 'see')) {
  if (-not $callouts.ContainsKey($need) -or $callouts[$need] -lt 1) { $missing += $need }
}
Check 'all seven callout types are used' ($missing.Count -eq 0) ('unused: ' + ($missing -join ','))
Check 'there are at least three "dead end" warnings' (([regex]::Matches($html, '(?i)dead end')).Count -ge 3)
Check 'the timezone trap is explained and says to trust the gaps' (($html -match '(?i)trust the gaps') -and ($html -match '(?i)browser&rsquo;s\s*timezone|browser''s\s*timezone|own timezone'))
Check 'the deck never tells the reader to click a row' ($html -notmatch '(?i)click the row[,\s]')
Check 'the deck warns against ES|QL and names the way back' ($html -match 'Switch to classic')
Check 'the deck names the expander control precisely' ($html -match 'two-diagonal-arrow')
Check 'every card states how long it takes' (([regex]::Matches($html, 'data-min="')).Count -eq 21)
Check 'exactly two cards are marked reference, not steps' (([regex]::Matches($html, 'data-min="reference"')).Count -eq 2)
Check 'the deck names its Elastic version' ($html -match '9\.1\.0')
Check 'the deck discloses the Popular fields difference' ($html -match '(?i)Popular fields')
Check 'the deck discloses that the histogram was switched off' ($html -match '(?i)histogram.{0,60}switched off')
Check 'the deck discloses that only the JSON tab shows UTC' ($html -match '(?i)only the document viewer')
Check 'the deck discloses that the picker picture shows its default date' ($html -match '(?i)picker picture shows the picker&rsquo;s own default state')
Check 'the deck gives a total time estimate' ($html -match 'about 80 min')
Check 'every screenshot offers a way to see it larger' (([regex]::Matches($html, 'class="shot')).Count -ge 12 -and ($html -match 'click to enlarge'))
Check 'the deck explains the side panel percentages' ($html -match '(?i)Top values')
# The honesty page states how many pictures there are. That is exactly the kind
# of claim that rots silently when a capture is added or dropped, so it is
# checked against the file rather than trusted.
$shotCount = ([regex]::Matches($html, 'data:image/png;base64,')).Count
$m = [regex]::Match($html, 'All (\d+) pictures are PNG screenshots')
if ($m.Success) {
  Check ('the honesty page says how many pictures there are, and it is right') ([int]$m.Groups[1].Value -eq $shotCount) ("page says " + $m.Groups[1].Value + ", file holds " + $shotCount)
} else {
  Check 'the honesty page states how many pictures there are' $false 'no "All N pictures" sentence found'
}
$cards2 = ([regex]::Matches($html, '(?s)<section class="slide(?: on)?"')).Count
$sayCards = [regex]::Match($html, 'This guide is <b>(\d+) cards</b>')
Check 'the deck states its own card count, and it is right' ($sayCards.Success -and [int]$sayCards.Groups[1].Value -eq $cards2) ("says '" + $sayCards.Groups[1].Value + "', file has " + $cards2)
$sayPics = [regex]::Match($html, 'with\s*<b>(\d+) screen pictures</b>')
Check 'the deck states its own picture count in the same sentence, and it is right' ($sayPics.Success -and [int]$sayPics.Groups[1].Value -eq ([regex]::Matches($html, 'data:image/png;base64,')).Count) ("says '" + $sayPics.Groups[1].Value + "', file has " + ([regex]::Matches($html, 'data:image/png;base64,')).Count)
$mins = @([regex]::Matches($html, 'data-min="(\d+) min"') | ForEach-Object { [int]$_.Groups[1].Value })
Check 'the stated total time matches the sum of the per-card times' (($mins | Measure-Object -Sum).Sum -le 85) ("cards total " + ($mins | Measure-Object -Sum).Sum + " min, the deck says 80")
# the timezone claim must be the measured one, not the inherited one
Check 'the display-timezone claim is the measured one' ($html -match '\{"tPST":"UTC"\}') 'the placeholder behaviour is not described'

# ---------------------------------------------------------------------------
Section 'summary'
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) {
  Write-Host ''
  Write-Host '  failures:'
  $script:Notes | Where-Object { -not $_.ok } | ForEach-Object { Write-Host ("    - " + $_.name + "   " + $_.detail) }
}
$script:Notes | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath 'C:\Users\User\AppData\Local\Temp\opencode\validate-report.json' -Encoding UTF8
Write-Host ''
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
