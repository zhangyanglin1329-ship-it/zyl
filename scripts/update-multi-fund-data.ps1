param(
  [string]$HtmlPath = (Join-Path $PSScriptRoot 'multi-fund-swing-system-v2.html'),
  [string]$BackupDir = (Join-Path $PSScriptRoot 'backups')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$culture = [Globalization.CultureInfo]::InvariantCulture
$fundCodes = @('002849','005125','007467','003027','002010','009690')
$statusPath = Join-Path $PSScriptRoot 'multi-fund-update-status.json'
$logPath = Join-Path $PSScriptRoot 'multi-fund-update.log'
$lockPath = Join-Path $PSScriptRoot 'multi-fund-update.lock'
$lockStream = $null

try {
  $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch {
  Write-Error 'Another multi-fund update is already running; this run was skipped safely.'
  exit 2
}

function Set-EmbeddedStatus($payload) {
  if (-not (Test-Path -LiteralPath $HtmlPath)) { return }
  $currentHtml = Get-Content -Raw -Encoding UTF8 -LiteralPath $HtmlPath
  $compact = [ordered]@{
    success = [bool]$payload.success
    checkedAt = [string]$payload.checkedAt
    message = [string]$payload.message
  } | ConvertTo-Json -Compress
  $pattern = 'window\.MULTI_FUND_UPDATE_STATUS=\{.*?\};window\.MULTI_FUND_DB='
  if (-not [regex]::IsMatch($currentHtml, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)) {
    throw 'Embedded update-status marker was not found in V2 HTML'
  }
  $replacement = "window.MULTI_FUND_UPDATE_STATUS=$compact;window.MULTI_FUND_DB="
  $nextHtml = [regex]::Replace(
    $currentHtml,
    $pattern,
    [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement },
    [Text.RegularExpressions.RegexOptions]::Singleline
  )
  $statusTempPath = "$HtmlPath.status.tmp"
  [IO.File]::WriteAllText($statusTempPath, $nextHtml, [Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $statusTempPath -Destination $HtmlPath -Force
}

function Write-Status([bool]$success, [string]$message, $details) {
  $payload = [ordered]@{
    success = $success
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    message = $message
    details = $details
  }
  $payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statusPath -Encoding UTF8
  ('{0} | {1} | {2}' -f $payload.checkedAt, $(if ($success) { 'OK' } else { 'FAILED' }), $message) |
    Add-Content -LiteralPath $logPath -Encoding UTF8
  Set-EmbeddedStatus $payload
}

function Invoke-WithRetry([scriptblock]$operation, [string]$name) {
  $lastError = $null
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try { return & $operation }
    catch {
      $lastError = $_
      if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
    }
  }
  throw "$name failed after 3 attempts: $($lastError.Exception.Message)"
}

function Parse-Number([string]$text, [string]$label) {
  $value = 0.0
  if (-not [double]::TryParse($text, [Globalization.NumberStyles]::Any, $culture, [ref]$value)) {
    throw "Invalid $label`: $text"
  }
  return $value
}

function Get-PrimaryRows([string]$code, [string]$storedDate, [hashtable]$headers) {
  $allRaw = [Collections.Generic.List[object]]::new()
  $foundStoredDate = $false
  $page = 1
  $totalCount = 0

  while (-not $foundStoredDate -and $page -le 30) {
    $url = "https://api.fund.eastmoney.com/f10/lsjz?fundCode=$code&pageIndex=$page&pageSize=20&startDate=&endDate="
    $response = Invoke-WithRetry { Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 30 } "$code primary page $page"
    if ($response.ErrCode -ne 0) { throw "$code primary source error: $($response.ErrMsg)" }
    if ($page -eq 1) { $totalCount = [int]$response.TotalCount }
    $pageRows = @($response.Data.LSJZList)
    if ($pageRows.Count -lt 1) { throw "$code primary page $page was empty" }
    foreach ($item in $pageRows) {
      [void]$allRaw.Add($item)
      if ([string]$item.FSRQ -eq $storedDate) { $foundStoredDate = $true }
    }
    $page++
  }
  if (-not $foundStoredDate) { throw "$code stored date $storedDate was not found within 600 recent NAV rows" }

  $rows = foreach ($item in $allRaw) {
    $unit = Parse-Number ([string]$item.DWJZ) "$code unit NAV"
    $cumulative = Parse-Number ([string]$item.LJJZ) "$code cumulative NAV"
    $dividend = 0.0
    if (-not [string]::IsNullOrWhiteSpace([string]$item.FHFCZ)) {
      $dividend = Parse-Number ([string]$item.FHFCZ) "$code dividend"
    }
    [pscustomobject]@{
      Date = [string]$item.FSRQ
      Unit = $unit
      Cumulative = $cumulative
      Dividend = $dividend
    }
  }

  return [pscustomobject]@{
    Rows = @($rows | Sort-Object Date -Unique)
    TotalCount = $totalCount
    PagesFetched = $page - 1
  }
}

function Get-BackupLatest([string]$code, [string]$userAgent) {
  $verificationUrl = "https://fund.eastmoney.com/pingzhongdata/$code.js?v=$((Get-Date).ToString('yyyyMMddHHmmss'))"
  try {
    $verificationText = Invoke-WithRetry {
      Invoke-RestMethod -Uri $verificationUrl -Headers @{'User-Agent' = $userAgent} -TimeoutSec 20
    } "$code verification source"
    $netMatch = [regex]::Match([string]$verificationText, 'var Data_netWorthTrend = (\[.*?\]);', [Text.RegularExpressions.RegexOptions]::Singleline)
    $accMatch = [regex]::Match([string]$verificationText, 'var Data_ACWorthTrend = (\[.*?\]);', [Text.RegularExpressions.RegexOptions]::Singleline)
    $netRows = [regex]::Matches($netMatch.Groups[1].Value, '"x":(\d+),"y":([0-9.]+)')
    $accRows = [regex]::Matches($accMatch.Groups[1].Value, '\[(\d+),([0-9.]+)\]')
    if (-not ($netMatch.Success -and $accMatch.Success) -or $netRows.Count -lt 1 -or $accRows.Count -lt 1) {
      throw "$code verification source latest row not found"
    }
    $latestNet = $netRows[$netRows.Count - 1]
    $latestAcc = $accRows[$accRows.Count - 1]
    $latestTimestamp = [int64]$latestNet.Groups[1].Value
    if ($latestTimestamp -ne [int64]$latestAcc.Groups[1].Value) { throw "$code verification source dates disagree" }
    return [pscustomobject]@{
      Date = [DateTimeOffset]::FromUnixTimeMilliseconds($latestTimestamp).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd')
      Unit = Parse-Number $latestNet.Groups[2].Value "$code verification unit NAV"
      Cumulative = Parse-Number $latestAcc.Groups[2].Value "$code verification cumulative NAV"
      Url = $verificationUrl
    }
  }
  catch {
    # Continue to the independent backup site below only when the fund page is unavailable.
  }
  $url = "https://www.etf88.com/jj/$code/"
  try {
    $html = Invoke-WithRetry {
      Invoke-RestMethod -Uri $url -Headers @{'User-Agent' = $userAgent} -TimeoutSec 12
    } "$code backup source"
    $dateMatch = [regex]::Match([string]$html, 'id="fund-declaredate"[^>]*>\s*(\d{4}-\d{2}-\d{2})\s*<')
    $unitMatch = [regex]::Match([string]$html, '<b[^>]*id="fund-f001"[^>]*>\s*([0-9.]+)\s*</b>')
    $cumulativeMatch = [regex]::Match([string]$html, '<b[^>]*id="fund-f002"[^>]*>\s*([0-9.]+)\s*</b>')
    if (-not ($dateMatch.Success -and $unitMatch.Success -and $cumulativeMatch.Success)) {
      throw "$code backup source latest row not found"
    }
    return [pscustomobject]@{
      Date = $dateMatch.Groups[1].Value
      Unit = Parse-Number $unitMatch.Groups[1].Value "$code backup unit NAV"
      Cumulative = Parse-Number $cumulativeMatch.Groups[1].Value "$code backup cumulative NAV"
      Url = $url
    }
  }
  catch {
    $fallbackUrl = "https://fund.eastmoney.com/pingzhongdata/$code.js?v=$((Get-Date).ToString('yyyyMMddHHmmss'))"
    $scriptText = Invoke-WithRetry {
      Invoke-RestMethod -Uri $fallbackUrl -Headers @{'User-Agent' = $userAgent} -TimeoutSec 20
    } "$code fallback verification source"
    $netMatch = [regex]::Match([string]$scriptText, 'var Data_netWorthTrend = (\[.*?\]);', [Text.RegularExpressions.RegexOptions]::Singleline)
    $accMatch = [regex]::Match([string]$scriptText, 'var Data_ACWorthTrend = (\[.*?\]);', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not ($netMatch.Success -and $accMatch.Success)) {
      throw "$code fallback verification source latest row not found"
    }
    $netRows = [regex]::Matches($netMatch.Groups[1].Value, '"x":(\d+),"y":([0-9.]+)')
    $accRows = [regex]::Matches($accMatch.Groups[1].Value, '\[(\d+),([0-9.]+)\]')
    if ($netRows.Count -lt 1 -or $accRows.Count -lt 1) { throw "$code fallback verification source was empty" }
    $latestNet = $netRows[$netRows.Count - 1]
    $latestAcc = $accRows[$accRows.Count - 1]
    $latestTimestamp = [int64]$latestNet.Groups[1].Value
    if ($latestTimestamp -ne [int64]$latestAcc.Groups[1].Value) { throw "$code fallback verification dates disagree" }
    return [pscustomobject]@{
      Date = [DateTimeOffset]::FromUnixTimeMilliseconds($latestTimestamp).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd')
      Unit = Parse-Number $latestNet.Groups[2].Value "$code fallback unit NAV"
      Cumulative = Parse-Number $latestAcc.Groups[2].Value "$code fallback cumulative NAV"
      Url = $fallbackUrl
    }
  }
}

try {
  if (-not (Test-Path -LiteralPath $HtmlPath)) { throw "HTML not found: $HtmlPath" }
  $html = Get-Content -Raw -Encoding UTF8 -LiteralPath $HtmlPath
  $dbMatch = [regex]::Match(
    $html,
    'window\.MULTI_FUND_DB=(\{.*?\});\(function appMain\(\)',
    [Text.RegularExpressions.RegexOptions]::Singleline
  )
  if (-not $dbMatch.Success) { throw 'Multi-fund database could not be read from V2 HTML' }
  $db = $dbMatch.Groups[1].Value | ConvertFrom-Json

  $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) MultiFundSwingV2/2.1'
  $headers = @{
    Referer = 'https://fundf10.eastmoney.com/'
    'User-Agent' = $userAgent
  }
  $details = [Collections.Generic.List[object]]::new()
  $totalNewRows = 0

  foreach ($code in $fundCodes) {
    $fund = $db.$code
    if ($null -eq $fund) { throw "Fund $code was not found in V2 database" }
    $storedDate = [string]$fund.latestDate
    $storedUnit = [double]$fund.latestUnit
    $storedCumulative = [double]$fund.latestCumulative
    $primary = Get-PrimaryRows $code $storedDate $headers
    $rows = @($primary.Rows)
    $storedRow = $rows | Where-Object Date -eq $storedDate | Select-Object -First 1
    if ($null -eq $storedRow) { throw "$code stored row disappeared after sorting" }
    if ([math]::Abs($storedRow.Unit - $storedUnit) -gt 0.00005 -or
        [math]::Abs($storedRow.Cumulative - $storedCumulative) -gt 0.00005) {
      throw "$code stored latest NAV was revised; full audit required before update"
    }

    $latest = $rows[-1]
    if ($latest.Date -lt $storedDate) { throw "$code source date moved backwards to $($latest.Date)" }
    $backup = Get-BackupLatest $code $userAgent
    if ($backup.Date -ne $latest.Date -or
        [math]::Abs($backup.Unit - $latest.Unit) -gt 0.00005 -or
        [math]::Abs($backup.Cumulative - $latest.Cumulative) -gt 0.00005) {
      throw "$code cross-check failed: primary $($latest.Date)/$($latest.Unit)/$($latest.Cumulative), backup $($backup.Date)/$($backup.Unit)/$($backup.Cumulative)"
    }

    $series = [Collections.Generic.List[object]]::new()
    foreach ($pair in @($fund.data)) {
      $savedPair = [object[]]@([string]$pair[0], [double]$pair[1])
      [void]$series.Add($savedPair)
    }
    if ($series.Count -lt 2 -or [string]$series[-1][0] -ne $storedDate) {
      throw "$code embedded adjusted history integrity check failed"
    }

    $adjusted = [double]$fund.current
    $peak = [double]$fund.high
    $peakDate = [string]$fund.peakDate
    $previousUnit = $storedUnit
    $newRows = @($rows | Where-Object Date -gt $storedDate)
    foreach ($row in $newRows) {
      $adjusted = $adjusted * (($row.Unit + $row.Dividend) / $previousUnit)
      if ($adjusted -gt $peak) {
        $peak = $adjusted
        $peakDate = $row.Date
      }
      $newPair = [object[]]@($row.Date, [math]::Round($adjusted, 8))
      [void]$series.Add($newPair)
      $previousUnit = $row.Unit
    }

    $drawdown = $adjusted / $peak - 1
    if ($drawdown -gt 0.0000001 -or $drawdown -lt -0.70) {
      throw "$code adjusted-series sanity check failed: $drawdown"
    }
    $fund.data = $series.ToArray()
    $fund.latestDate = $latest.Date
    $fund.latestUnit = [math]::Round($latest.Unit, 4)
    $fund.latestCumulative = [math]::Round($latest.Cumulative, 4)
    $fund.current = [math]::Round($adjusted, 8)
    $fund.high = [math]::Round($peak, 8)
    $fund.peakDate = $peakDate
    $fund.drawdown = $drawdown
    $fund.rows = $series.Count
    $totalNewRows += $newRows.Count

    [void]$details.Add([pscustomobject][ordered]@{
      fundCode = $code
      latestDate = $latest.Date
      latestUnit = $latest.Unit
      latestCumulative = $latest.Cumulative
      embeddedRows = $series.Count
      newRows = $newRows.Count
      adjustedValue = [math]::Round($adjusted, 8)
      adjustedPeak = [math]::Round($peak, 8)
      adjustedPeakDate = $peakDate
      drawdownPct = [math]::Round($drawdown * 100, 4)
      pagesFetched = $primary.PagesFetched
      sourceTotalRows = $primary.TotalCount
      primarySource = 'https://api.fund.eastmoney.com/f10/lsjz'
      backupSource = $backup.Url
    })
  }

  $backupPath = $null
  if ($totalNewRows -gt 0) {
    $updatedJson = $db | ConvertTo-Json -Depth 100 -Compress
    $replacement = "window.MULTI_FUND_DB=$updatedJson;(function appMain()"
    $newHtml = [regex]::Replace(
      $html,
      'window\.MULTI_FUND_DB=\{.*?\};\(function appMain\(\)',
      [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement },
      [Text.RegularExpressions.RegexOptions]::Singleline
    )
    if ($newHtml -eq $html -or -not $newHtml.Contains("latestDate`":`"$($details[0].latestDate)")) {
      throw 'V2 HTML update pattern failed'
    }
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backupPath = Join-Path $backupDir ("multi-fund-swing-system-{0}.html" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $HtmlPath -Destination $backupPath
    $tempPath = "$HtmlPath.tmp"
    [IO.File]::WriteAllText($tempPath, $newHtml, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $HtmlPath -Force
  }

  $summary = [ordered]@{
    fundsChecked = $fundCodes.Count
    totalNewRows = $totalNewRows
    latestDate = ($details | Select-Object -ExpandProperty latestDate | Sort-Object -Descending | Select-Object -First 1)
    backupFile = $backupPath
    funds = $details.ToArray()
  }
  Write-Status $true "Checked $($fundCodes.Count) funds; $totalNewRows new row(s) added" $summary
  Write-Output ($summary | ConvertTo-Json -Depth 12)
}
catch {
  Write-Status $false $_.Exception.Message @{ navDataPreserved = $true; funds = $fundCodes }
  Write-Error $_.Exception.Message
  exit 1
}
finally {
  if ($null -ne $lockStream) { $lockStream.Dispose() }
}
