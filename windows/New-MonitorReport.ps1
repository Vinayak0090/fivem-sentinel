<#
=====================================================================
 New-MonitorReport.ps1 — build a visual HTML report from the monitor CSVs
=====================================================================
 Usage:
   .\New-MonitorReport.ps1                 # today's data
   .\New-MonitorReport.ps1 -Date 2026-07-18
   .\New-MonitorReport.ps1 -Open           # open in browser when done

 Output: reports\report-YYYY-MM-DD.html (self-contained; Chart.js from CDN)
=====================================================================
#>
[CmdletBinding()]
param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [string]$LogDir = "",
    [string]$OutDir = "",
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $LogDir) { $LogDir = Join-Path $scriptRoot 'logs' }
if (-not $OutDir) { $OutDir = Join-Path $scriptRoot 'reports' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$metricsFile = Join-Path $LogDir "metrics-$Date.csv"
$alertsFile  = Join-Path $LogDir "alerts-$Date.csv"
$eventsFile  = Join-Path $LogDir "events-$Date.csv"

if (-not (Test-Path $metricsFile)) {
    Write-Error "No metrics file for $Date ($metricsFile). Is the monitor running?"
    exit 1
}

Write-Host "Reading $metricsFile ..."
$rows = Import-Csv $metricsFile
if ($rows.Count -eq 0) { Write-Error "Metrics file is empty."; exit 1 }

# ---- downsample to <= MaxPoints so the report stays snappy ----
$MaxPoints = 1200
$stride = [Math]::Max(1, [Math]::Ceiling($rows.Count / $MaxPoints))
$sampled = for ($i = 0; $i -lt $rows.Count; $i += $stride) { $rows[$i] }
Write-Host ("{0} samples -> {1} points (stride {2})" -f $rows.Count, $sampled.Count, $stride)

function NumOrNull($v) {
    $d = 0.0
    if ([double]::TryParse($v, [ref]$d)) { if ($d -lt 0) { return $null } else { return $d } }
    return $null
}

$data = [ordered]@{
    labels   = @($sampled | ForEach-Object { ($_.ts -split ' ')[1] })
    players  = @($sampled | ForEach-Object { NumOrNull $_.players })
    httpMs   = @($sampled | ForEach-Object { NumOrNull $_.httpMs })
    cpuTotal = @($sampled | ForEach-Object { NumOrNull $_.cpuTotal })
    cpuMax   = @($sampled | ForEach-Object { NumOrNull $_.cpuMaxCore })
    fxCpu    = @($sampled | ForEach-Object { NumOrNull $_.fxCpu })
    ramAvail = @($sampled | ForEach-Object { NumOrNull $_.ramAvailMB })
    fxRam    = @($sampled | ForEach-Object { NumOrNull $_.fxRamMB })
    udpIn    = @($sampled | ForEach-Object { NumOrNull $_.udpInPps })
    udpNoPort= @($sampled | ForEach-Object { NumOrNull $_.udpNoPortPps })
    nicIn    = @($sampled | ForEach-Object { NumOrNull $_.nicInMbps })
    nicOut   = @($sampled | ForEach-Object { NumOrNull $_.nicOutMbps })
    pingGw   = @($sampled | ForEach-Object { NumOrNull $_.pingGwMs })
    pingExt  = @($sampled | ForEach-Object { NumOrNull $_.pingExtMs })
    pingExt2 = @($sampled | ForEach-Object { NumOrNull $_.pingExt2Ms })
    hitches  = @($sampled | ForEach-Object { NumOrNull $_.hitches })
    timeouts = @($sampled | ForEach-Object { NumOrNull $_.timeouts })
}
$dataJson = ($data | ConvertTo-Json -Compress -Depth 4)

# ---- alerts ----
$alerts = @()
if (Test-Path $alertsFile) { $alerts = @(Import-Csv $alertsFile) }
$alertRowsHtml = if ($alerts.Count -eq 0) {
    '<tr><td colspan="4" class="muted">No alerts recorded for this day.</td></tr>'
} else {
    ($alerts | ForEach-Object {
        $sevClass = switch ($_.severity) { 'CRIT' { 'sev-crit' } 'INFO' { 'sev-info' } default { 'sev-warn' } }
        $detail = [System.Net.WebUtility]::HtmlEncode($_.detail)
        $cause  = [System.Net.WebUtility]::HtmlEncode($_.cause)
        "<tr><td class='mono'>$($_.ts)</td><td><span class='pill $sevClass'>$($_.severity)</span></td><td class='cause'>$cause</td><td>$detail</td></tr>"
    }) -join "`n"
}

# cause frequency summary
$causeSummaryHtml = if ($alerts.Count -eq 0) { '<span class="muted">none</span>' } else {
    ($alerts | Group-Object cause | Sort-Object Count -Descending | ForEach-Object {
        "<span class='tag'>$([System.Net.WebUtility]::HtmlEncode($_.Name)) &times;$($_.Count)</span>"
    }) -join ' '
}

# ---- events: top error resources + counts ----
$events = @()
if (Test-Path $eventsFile) { $events = @(Import-Csv $eventsFile) }
$evCounts = $events | Group-Object type | Sort-Object Count -Descending
$evSummaryHtml = if ($events.Count -eq 0) { '<span class="muted">none</span>' } else {
    ($evCounts | ForEach-Object { "<span class='tag'>$($_.Name) &times;$($_.Count)</span>" }) -join ' '
}
$topResHtml = ''
$resGroups = $events | Where-Object { $_.type -eq 'script_error' -and $_.resource } |
    Group-Object resource | Sort-Object Count -Descending | Select-Object -First 10
if ($resGroups) {
    $topResHtml = ($resGroups | ForEach-Object {
        "<tr><td class='mono'>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.Count)</td></tr>"
    }) -join "`n"
} else {
    $topResHtml = '<tr><td colspan="2" class="muted">No script errors attributed to a resource.</td></tr>'
}

# ---- headline stats ----
function StatMax($arr) { $m = ($arr | Where-Object { $_ -ne $null } | Measure-Object -Maximum).Maximum; if ($null -eq $m) { '-' } else { [math]::Round($m,0) } }
$statPlayersMax = StatMax $data.players
$statCpuMax     = StatMax $data.cpuMax
$statUdpMax     = StatMax $data.udpIn
$statAlerts     = $alerts.Count
$statTimeouts   = [int](($rows | ForEach-Object { NumOrNull $_.timeouts } | Where-Object { $_ } | Measure-Object -Sum).Sum)

# ================= HTML template (single-quoted: no PS interpolation) =================
$html = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FiveM Monitor Report — __DATE__</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.4/chart.umd.min.js"></script>
<style>
  .viz-root{
    color-scheme: light;
    --page:#f9f9f7; --surface-1:#fcfcfb;
    --text-primary:#0b0b0b; --text-secondary:#52514e; --muted:#898781;
    --grid:#e1e0d9; --baseline:#c3c2b7; --border:rgba(11,11,11,0.10);
    --s-blue:#2a78d6; --s-green:#008300; --s-yellow:#eda100; --s-aqua:#1baf7a;
    --s-orange:#eb6834; --s-violet:#4a3aa7; --s-red:#e34948;
    --st-warning:#fab219; --st-critical:#d03b3b;
  }
  @media (prefers-color-scheme: dark){
    :root:where(:not([data-theme="light"])) .viz-root{
      color-scheme: dark;
      --page:#0d0d0d; --surface-1:#1a1a19;
      --text-primary:#ffffff; --text-secondary:#c3c2b7; --muted:#898781;
      --grid:#2c2c2a; --baseline:#383835; --border:rgba(255,255,255,0.10);
      --s-blue:#3987e5; --s-green:#008300; --s-yellow:#c98500; --s-aqua:#199e70;
      --s-orange:#d95926; --s-violet:#9085e9; --s-red:#e66767;
    }
  }
  *{box-sizing:border-box}
  body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",sans-serif}
  .viz-root{background:var(--page);color:var(--text-primary);min-height:100vh;padding:24px}
  .wrap{max-width:1100px;margin:0 auto}
  h1{font-size:20px;margin:0 0 4px}
  h2{font-size:15px;margin:28px 0 10px;color:var(--text-primary)}
  .sub{color:var(--text-secondary);font-size:13px;margin-bottom:20px}
  .muted{color:var(--muted)}
  .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:8px}
  .tile{background:var(--surface-1);border:1px solid var(--border);border-radius:10px;padding:14px 16px}
  .tile .v{font-size:26px;font-weight:600;line-height:1.1}
  .tile .l{font-size:12px;color:var(--text-secondary);margin-top:4px}
  .card{background:var(--surface-1);border:1px solid var(--border);border-radius:10px;padding:16px;margin-bottom:16px}
  .chart-box{position:relative;height:190px}
  table{width:100%;border-collapse:collapse;font-size:13px}
  th{text-align:left;color:var(--muted);font-weight:500;padding:6px 8px;border-bottom:1px solid var(--baseline)}
  td{padding:6px 8px;border-bottom:1px solid var(--grid);vertical-align:top;color:var(--text-secondary)}
  td.cause{color:var(--text-primary);font-weight:600;white-space:nowrap}
  .mono{font-variant-numeric:tabular-nums;white-space:nowrap}
  .pill{display:inline-block;padding:1px 8px;border-radius:99px;font-size:11px;font-weight:700;color:#fff}
  .sev-crit{background:var(--st-critical)}
  .sev-warn{background:var(--st-warning);color:#0b0b0b}
  .sev-info{background:var(--muted)}
  .tag{display:inline-block;background:transparent;border:1px solid var(--border);border-radius:99px;
       padding:2px 10px;font-size:12px;color:var(--text-secondary);margin:2px 4px 2px 0}
  .note{font-size:12px;color:var(--muted);margin-top:6px}
</style>
</head>
<body>
<div class="viz-root"><div class="wrap">
  <h1>FiveM Monitor — __DATE__</h1>
  <div class="sub">__NSAMPLES__ samples · generated __GENTIME__ · times are server local</div>

  <div class="tiles">
    <div class="tile"><div class="v">__STAT_PLAYERS__</div><div class="l">Peak players</div></div>
    <div class="tile"><div class="v">__STAT_CPU__%</div><div class="l">Peak single-core CPU</div></div>
    <div class="tile"><div class="v">__STAT_UDP__</div><div class="l">Peak UDP in (pps)</div></div>
    <div class="tile"><div class="v">__STAT_TIMEOUTS__</div><div class="l">Timeout lines in console</div></div>
    <div class="tile"><div class="v">__STAT_ALERTS__</div><div class="l">Alerts raised</div></div>
  </div>

  <h2>Alert causes today</h2>
  <div class="card">__CAUSE_SUMMARY__<div class="note">Console events: __EV_SUMMARY__</div></div>

  <h2>Players online</h2>
  <div class="card"><div class="chart-box"><canvas id="cPlayers"></canvas></div></div>

  <h2>Server responsiveness — players.json round-trip (ms)</h2>
  <div class="card"><div class="chart-box"><canvas id="cHttp"></canvas></div>
    <div class="note">Spikes here mean the FXServer main thread is stalling (script hitch / overload), independent of network.</div></div>

  <h2>CPU (%)</h2>
  <div class="card"><div class="chart-box"><canvas id="cCpu"></canvas></div>
    <div class="note">Watch <b>max core</b>: FiveM's main/sync threads are single-core bound — one core at 100% causes timeouts even if total CPU looks fine.</div></div>

  <h2>Memory (MB)</h2>
  <div class="card"><div class="chart-box"><canvas id="cRam"></canvas></div></div>

  <h2>UDP packets/sec in</h2>
  <div class="card"><div class="chart-box"><canvas id="cUdp"></canvas></div>
    <div class="note"><b>no-port</b> = datagrams to closed ports; a sustained spike is a classic flood signature.</div></div>

  <h2>Bandwidth (Mbps)</h2>
  <div class="card"><div class="chart-box"><canvas id="cNic"></canvas></div></div>

  <h2>Ping (ms)</h2>
  <div class="card"><div class="chart-box"><canvas id="cPing"></canvas></div>
    <div class="note">Gateway bad = local/host network problem. BOTH externals bad = upstream/ISP route problem. Only one external bad = that provider's node, ignored. Gaps = lost pings.</div></div>

  <h2>Alerts</h2>
  <div class="card" style="overflow-x:auto">
    <table>
      <thead><tr><th>Time</th><th>Sev</th><th>Cause</th><th>Detail</th></tr></thead>
      <tbody>__ALERT_ROWS__</tbody>
    </table>
  </div>

  <h2>Top script-error resources</h2>
  <div class="card">
    <table>
      <thead><tr><th>Resource</th><th>Errors</th></tr></thead>
      <tbody>__TOP_RES__</tbody>
    </table>
    <div class="note">Full lines are in logs\events-__DATE__.csv</div>
  </div>
</div></div>

<script>
const D = __DATA__;

function cssVar(n){ return getComputedStyle(document.querySelector('.viz-root')).getPropertyValue(n).trim(); }

let charts = [];
function render(){
  charts.forEach(c => c.destroy()); charts = [];
  const ink2  = cssVar('--text-secondary');
  const muted = cssVar('--muted');
  const grid  = cssVar('--grid');

  Chart.defaults.font.family = 'system-ui,-apple-system,"Segoe UI",sans-serif';
  Chart.defaults.color = muted;

  function mk(id, series, opts){
    opts = opts || {};
    const ctx = document.getElementById(id);
    const c = new Chart(ctx, {
      type: 'line',
      data: { labels: D.labels, datasets: series.map(s => ({
        label: s.label, data: s.data,
        borderColor: cssVar(s.color), backgroundColor: cssVar(s.color),
        borderWidth: 2, pointRadius: 0, pointHitRadius: 8, tension: 0, spanGaps: false
      }))},
      options: {
        responsive: true, maintainAspectRatio: false, animation: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { display: series.length > 1, labels: { boxWidth: 10, boxHeight: 10, color: ink2 } },
          tooltip: { intersect: false, mode: 'index' }
        },
        scales: {
          x: { ticks: { maxTicksLimit: 10, color: muted }, grid: { display: false } },
          y: { beginAtZero: opts.zero !== false, ticks: { maxTicksLimit: 6, color: muted },
               grid: { color: grid, drawTicks: false } }
        }
      }
    });
    charts.push(c);
  }

  mk('cPlayers', [{label:'Players', data:D.players, color:'--s-blue'}]);
  mk('cHttp',    [{label:'players.json ms', data:D.httpMs, color:'--s-orange'}]);
  mk('cCpu',     [{label:'Max core', data:D.cpuMax, color:'--s-red'},
                  {label:'Total',    data:D.cpuTotal, color:'--s-blue'},
                  {label:'FXServer', data:D.fxCpu, color:'--s-green'}]);
  mk('cRam',     [{label:'Available', data:D.ramAvail, color:'--s-blue'},
                  {label:'FXServer working set', data:D.fxRam, color:'--s-green'}]);
  mk('cUdp',     [{label:'UDP in pps', data:D.udpIn, color:'--s-blue'},
                  {label:'no-port pps', data:D.udpNoPort, color:'--s-red'}]);
  mk('cNic',     [{label:'In', data:D.nicIn, color:'--s-blue'},
                  {label:'Out', data:D.nicOut, color:'--s-green'}]);
  mk('cPing',    [{label:'Gateway', data:D.pingGw, color:'--s-green'},
                  {label:'External 1 (1.1.1.1)', data:D.pingExt, color:'--s-blue'},
                  {label:'External 2 (8.8.8.8)', data:D.pingExt2, color:'--s-violet'}]);
}

if (window.Chart) { render(); }
else { document.querySelectorAll('.chart-box').forEach(b => b.innerHTML =
  '<div style="padding:20px;color:#898781;font-size:13px">Chart.js CDN unreachable — data is still in the CSV logs.</div>'); }

if (window.matchMedia) {
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (window.Chart) render(); });
}
</script>
</body>
</html>
'@

$gen = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$tokens = @(
    @('__DATA__',          $dataJson),
    @('__DATE__',          $Date),
    @('__NSAMPLES__',      "$($rows.Count)"),
    @('__GENTIME__',       $gen),
    @('__STAT_PLAYERS__',  "$statPlayersMax"),
    @('__STAT_CPU__',      "$statCpuMax"),
    @('__STAT_UDP__',      "$statUdpMax"),
    @('__STAT_TIMEOUTS__', "$statTimeouts"),
    @('__STAT_ALERTS__',   "$statAlerts"),
    @('__CAUSE_SUMMARY__', $causeSummaryHtml),
    @('__EV_SUMMARY__',    $evSummaryHtml),
    @('__ALERT_ROWS__',    $alertRowsHtml),
    @('__TOP_RES__',       $topResHtml)
)
foreach ($t in $tokens) { $html = $html.Replace($t[0], [string]$t[1]) }

# Inline the bundled Chart.js if present, so the report works with no internet
# (CDN reference stays as fallback when the file is missing).
foreach ($chartLib in @((Join-Path $scriptRoot 'chart.umd.min.js'),
                        (Join-Path (Split-Path -Parent $scriptRoot) 'assets\chart.umd.min.js'))) {
    if (Test-Path $chartLib) {
        $libJs = [IO.File]::ReadAllText($chartLib)
        $cdnTag = '<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.4/chart.umd.min.js"></script>'
        $html = $html.Replace($cdnTag, ('<script>' + $libJs + '</script>'))
        break
    }
}

$outFile = Join-Path $OutDir "report-$Date.html"
Set-Content -Path $outFile -Value $html -Encoding UTF8
Write-Host "Report written: $outFile"
if ($Open) { Start-Process $outFile }
