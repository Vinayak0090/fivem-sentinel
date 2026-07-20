<#
=====================================================================
 FiveM-Monitor.ps1  —  Deep, low-overhead diagnostics for FiveM on Windows
=====================================================================
 Purpose : Continuously samples system + network + FXServer health so that
           when players time out you can tell WHAT caused it:
             - DDoS / packet flood        (UDP pps + bandwidth + no-port spikes)
             - Upstream network problem   (ping loss / latency to gateway & internet)
             - CPU starvation             (per-core saturation — FiveM is single-thread bound)
             - RAM pressure               (low available MB, hard page faults)
             - FiveM script problem       (hitch warnings + SCRIPT ERROR lines w/ resource names)
             - Server crash / restart     (FXServer PID change)
             - Server thread stall        (players.json HTTP response time / failure)

 Design  : One lightweight loop. Locale-independent WMI perf classes (no
           Get-Counter English-name issues), no packet capture, no per-cycle
           process spawning. Typical overhead: <1% of one core, ~60 MB RAM.

 Output  : logs\metrics-YYYY-MM-DD.csv   (one row per sample)
           logs\alerts-YYYY-MM-DD.csv    (detected problems + suspected cause)
           logs\events-YYYY-MM-DD.csv    (notable console-log lines: hitches,
                                          script errors, timeouts, w/ resource)
           Generate a visual report any time with: .\New-MonitorReport.ps1

 Run     : powershell -ExecutionPolicy Bypass -File .\FiveM-Monitor.ps1
           (or install as a boot task with .\Install-Monitor.ps1)
=====================================================================
#>

[CmdletBinding()]
param(
    # Seconds between samples. 5s catches spikes without meaningful overhead.
    [int]$IntervalSec = 5,

    # FiveM game port (UDP+TCP). Used to find the right FXServer.exe under txAdmin.
    [int]$ServerPort = 30120,

    # Path to the live FXServer console log written by txAdmin.
    # Leave empty to auto-detect (searches common txData locations).
    [string]$ConsoleLogPath = "",

    # Root folder to search for txData when auto-detecting the console log.
    [string]$TxDataSearchRoot = "C:\",

    # External hosts used to test internet path health. UPSTREAM_NETWORK is only
    # raised when ALL of them look degraded - one slow anycast node (or one
    # provider deprioritizing ICMP) can't cause a false positive on its own.
    [string[]]$ExternalPingTargets = @('1.1.1.1', '8.8.8.8'),

    # Where CSV logs go (created if missing). Default: 'logs' next to this script.
    [string]$LogDir = "",

    # Days of CSV logs to keep.
    [int]$RetainDays = 14,

    # Live dashboard: open http://localhost:<port> on the server to watch
    # counters + charts update every cycle. 'localhost' keeps it private to the
    # machine (view it in the RDP session's browser). To view from your own PC,
    # use -DashboardBind '+' AND open the port in Windows Firewall restricted
    # to your own IP (see README - do not leave it open to the world).
    [int]$DashboardPort = 8123,
    [string]$DashboardBind = 'localhost',
    [switch]$NoDashboard,

    # CFX join code of your server (the code in your cfx.re/join/... link).
    # When set (e.g. 'abc123'), the player count is fetched from the FiveM
    # master API (frontend.cfx-services.net) every ~15s and used as the
    # authoritative count; the local players.json is still polled for
    # responsiveness checks. Empty = use only the local players.json count.
    [string]$CfxJoinCode = '',

    # Optional Discord webhook URL. WARN/CRIT alerts are posted there in
    # addition to the alerts CSV. Leave empty to disable.
    [string]$DiscordWebhook = ''
)

# ------------------------------------------------------------------ setup
$ErrorActionPreference = 'Continue'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bound = $PSBoundParameters

# ---------------------------------------------------- optional config file
# sentinel.conf (KEY=VALUE, # comments) next to this script or in the repo
# root. Explicit command-line parameters win over the file. The profiler
# settings only live here - see sentinel.conf.example.
$ProfilerEnabled = $false; $ProfilerFrames = 200; $ProfilerCooldownSec = 600
$ProfilerTriggers = 'SCRIPT_HITCH,SERVER_THREAD_SLOW,CPU_CORE_SATURATED,MASS_PLAYER_DROP'
$RconPassword = ''; $RconPort = 0
$confPath = @((Join-Path $scriptRoot 'sentinel.conf'),
              (Join-Path (Split-Path -Parent $scriptRoot) 'sentinel.conf')) |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ($confPath) {
    $conf = @{}
    foreach ($ln in (Get-Content $confPath)) {
        $t = $ln.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $kv = $t -split '=', 2
        if ($kv.Count -ne 2) { continue }
        $conf[$kv[0].Trim().ToUpper()] = $kv[1].Trim().Trim('"')
    }
    if ($conf['SERVER_PORT']   -and -not $bound.ContainsKey('ServerPort'))     { $ServerPort  = [int]$conf['SERVER_PORT'] }
    if ($conf['INTERVAL']      -and -not $bound.ContainsKey('IntervalSec'))    { $IntervalSec = [int]$conf['INTERVAL'] }
    if ($conf['CONSOLE_LOG']   -and -not $bound.ContainsKey('ConsoleLogPath')) { $ConsoleLogPath = $conf['CONSOLE_LOG'] }
    if (($conf['EXT1'] -or $conf['EXT2']) -and -not $bound.ContainsKey('ExternalPingTargets')) {
        $ExternalPingTargets = @(@($conf['EXT1'], $conf['EXT2']) | Where-Object { $_ })
    }
    if ($conf['DISCORD_WEBHOOK'] -and -not $bound.ContainsKey('DiscordWebhook')) { $DiscordWebhook = $conf['DISCORD_WEBHOOK'] }
    if ($conf['CFX_JOIN_CODE']  -and -not $bound.ContainsKey('CfxJoinCode'))    { $CfxJoinCode = $conf['CFX_JOIN_CODE'] }
    if ($conf['DASHBOARD_PORT'] -and -not $bound.ContainsKey('DashboardPort'))  { $DashboardPort = [int]$conf['DASHBOARD_PORT'] }
    if ($conf['DASHBOARD_BIND'] -and -not $bound.ContainsKey('DashboardBind'))  { $DashboardBind = $conf['DASHBOARD_BIND'] }
    if ($conf['PROFILER_ENABLED'])  { $ProfilerEnabled = ($conf['PROFILER_ENABLED'] -match '^(true|1|yes|on)$') }
    if ($conf['PROFILER_FRAMES'])   { $ProfilerFrames = [int]$conf['PROFILER_FRAMES'] }
    if ($conf['PROFILER_TRIGGERS']) { $ProfilerTriggers = $conf['PROFILER_TRIGGERS'] }
    if ($conf['PROFILER_COOLDOWN']) { $ProfilerCooldownSec = [int]$conf['PROFILER_COOLDOWN'] }
    if ($conf['RCON_PASSWORD'])     { $RconPassword = $conf['RCON_PASSWORD'] }
    if ($conf['RCON_PORT'])         { $RconPort = [int]$conf['RCON_PORT'] }
}
if ($RconPort -eq 0) { $RconPort = $ServerPort }
$ProfilerTriggerSet = @($ProfilerTriggers -split ',' | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ })
$ProfilerActive = [bool]($ProfilerEnabled -and $RconPassword)

if (-not $LogDir) { $LogDir = Join-Path $scriptRoot 'logs' }
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# Keep ourselves cheap: below-normal priority, single threaded apartment.
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch {}

# PS 5.1 defaults to old TLS - needed for the CFX master API (https).
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function Write-Log([string]$msg) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg)
}

# --------------------------------------------------------- alert thresholds
$T = @{
    CpuCoreHighPct      = 95     # any single core pegged (FiveM main/sync thread bound)
    CpuCoreHighSamples  = 3      # ...for this many consecutive samples
    CpuTotalHighPct     = 90
    RamAvailLowMB       = 700
    PagesPerSecHigh     = 800    # sustained hard paging = RAM thrash
    HttpSlowMs          = 1500   # players.json slower than this = server thread stalling
    PingHighMs          = 150
    PingLossPctHigh     = 20     # % lost over the rolling window
    PingWindow          = 12     # samples in the rolling ping-loss window
    UdpSpikeFactor      = 4.0    # pps > factor * baseline  -> flood suspicion
    UdpSpikeFloorPps    = 4000   # ...and above this absolute floor
    MbpsSpikeFactor     = 4.0
    MbpsSpikeFloor      = 100
    NoPortSpikePps      = 500    # datagrams to closed ports/sec (classic flood tell)
    PlayerDropCount     = 3      # players lost in one interval considered a "mass drop"
    PlayerDropPct       = 20
    AlertCooldownSec    = 120    # don't repeat the same cause more often than this
}

# ------------------------------------------------------------ log helpers
function Get-DailyFile([string]$prefix) {
    Join-Path $LogDir ("{0}-{1}.csv" -f $prefix, (Get-Date -Format 'yyyy-MM-dd'))
}

$metricsHeader = 'ts,players,httpMs,httpOk,cpuTotal,cpuMaxCore,fxCpu,ramAvailMB,fxRamMB,pagesSec,udpInPps,udpOutPps,udpNoPortPps,udpErrors,nicInMbps,nicOutMbps,nicInPps,pingGwMs,pingExtMs,pingExt2Ms,gwLossPct,extLossPct,ext2LossPct,fxPid,fxThreads,fxHandles,hitches,scriptErrors,timeouts,alerts'
$alertsHeader  = 'ts,severity,cause,detail'
$eventsHeader  = 'ts,type,resource,line'

function Add-CsvLine([string]$prefix, [string]$header, [string]$line) {
    $f = Get-DailyFile $prefix
    if (-not (Test-Path $f)) { Set-Content -Path $f -Value $header -Encoding UTF8 }
    Add-Content -Path $f -Value $line -Encoding UTF8
}

function CsvEscape([string]$s) {
    if ($null -eq $s) { return '' }
    $s = $s -replace '[\r\n]+', ' '
    if ($s -match '[",]') { return '"' + ($s -replace '"', '""') + '"' }
    return $s
}

# Purge old logs
Get-ChildItem $LogDir -Filter '*.csv' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetainDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# ------------------------------------------------- console log auto-detect
function Find-ConsoleLog {
    if ($ConsoleLogPath -and (Test-Path $ConsoleLogPath)) { return $ConsoleLogPath }
    $candidates = @()
    # Specific likely locations first; full-disk scan (slow, one-time) last.
    foreach ($base in @('C:\txData', 'C:\FXServer\txData', 'C:\fivem\txData', "$env:LOCALAPPDATA\FiveM", $TxDataSearchRoot)) {
        if (-not (Test-Path $base -ErrorAction SilentlyContinue)) { continue }
        try {
            $candidates += Get-ChildItem -Path $base -Recurse -Depth 4 -Filter 'fxserver.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 3
        } catch {}
        if ($candidates.Count -gt 0) { break }
    }
    if ($candidates.Count -gt 0) { return $candidates[0].FullName }
    return $null
}

$resolvedLog = Find-ConsoleLog
if ($resolvedLog) { Write-Log "Console log: $resolvedLog" }
else { Write-Log "WARNING: FXServer console log not found - hitch/script-error detection disabled. Pass -ConsoleLogPath explicitly." }
$logOffset = if ($resolvedLog) { (Get-Item $resolvedLog).Length } else { 0 }

# ------------------------------------------------------- FXServer discovery
function Find-FxProcess {
    # Under txAdmin there are 2+ FXServer.exe (txAdmin host + game server).
    # The game server is the one that owns the UDP game port.
    try {
        $ep = Get-NetUDPEndpoint -LocalPort $ServerPort -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ep) {
            $p = Get-Process -Id $ep.OwningProcess -ErrorAction SilentlyContinue
            if ($p) { return $p }
        }
    } catch {}
    # Fallback: biggest FXServer by working set
    Get-Process -Name 'FXServer' -ErrorAction SilentlyContinue |
        Sort-Object WorkingSet64 -Descending | Select-Object -First 1
}

# --------------------------------------------------------- network helpers
$gateway = $null
try {
    $gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1).NextHop
} catch {}
if (-not $gateway -or $gateway -eq '0.0.0.0') { $gateway = $null }
$extTarget1 = $ExternalPingTargets[0]
$extTarget2 = if ($ExternalPingTargets.Count -gt 1) { $ExternalPingTargets[1] } else { $null }
Write-Log ("Gateway: {0}   External: {1}" -f ($(if ($gateway) { $gateway } else { 'n/a' })), ($ExternalPingTargets -join ', '))

$pinger = New-Object System.Net.NetworkInformation.Ping
function Ping-Ms([string]$target) {
    if (-not $target) { return -1 }
    try {
        $r = $pinger.Send($target, 700)
        if ($r.Status -eq 'Success') { return [int]$r.RoundtripTime }
    } catch {}
    return -1   # -1 == lost / failed
}

# -------------------------------------------------- rcon / auto-profiler
# Fire-and-forget console command over FiveM's rcon (UDP, Quake-style OOB).
function Send-Rcon([string]$cmd) {
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $bytes = [byte[]](255, 255, 255, 255) + [System.Text.Encoding]::UTF8.GetBytes("rcon $RconPassword $cmd")
        [void]$udp.Send($bytes, $bytes.Length, '127.0.0.1', $RconPort)
        $udp.Close()
        return $true
    } catch { return $false }
}
$script:profilerSaveDue = $null
$script:profilerLastRun = [datetime]::MinValue
$script:profilerCause   = ''

function Get-CfxPlayers {
    # Player count from the FiveM master list API. Returns [int] or $null on failure.
    try {
        $req = [System.Net.WebRequest]::Create("https://frontend.cfx-services.net/api/servers/single/$CfxJoinCode")
        $req.Timeout = 4000
        $req.UserAgent = 'FiveM-Monitor/1.0'
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader ($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        $j = $body | ConvertFrom-Json
        foreach ($v in @($j.Data.clients, $j.Data.selfReportedClients, $j.clients)) {
            if ($null -ne $v) { return [int]$v }
        }
    } catch {}
    return $null
}

function Get-PlayersJson {
    # Returns @{ count; ms; ok }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $req = [System.Net.WebRequest]::Create("http://127.0.0.1:$ServerPort/players.json")
        $req.Timeout = 3000
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader ($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        $sw.Stop()
        # NB: assign FIRST, then @() - wrapping the pipeline directly (@($x | ConvertFrom-Json))
        # treats the whole JSON array as one item in PS 5.1 and always counts 1.
        $cnt = 0
        try {
            $parsed = $body | ConvertFrom-Json
            if ($null -ne $parsed) { $cnt = @($parsed).Count }
        } catch {}
        return @{ count = $cnt; ms = [int]$sw.ElapsedMilliseconds; ok = $true }
    } catch {
        $sw.Stop()
        return @{ count = -1; ms = [int]$sw.ElapsedMilliseconds; ok = $false }
    }
}

# ------------------------------------------------------ live dashboard
$dashHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FiveM Live Monitor</title>
<script src="chart.js"></script>
<style>
  .viz-root{
    color-scheme: light;
    --page:#f9f9f7; --surface-1:#fcfcfb;
    --text-primary:#0b0b0b; --text-secondary:#52514e; --muted:#898781;
    --grid:#e1e0d9; --baseline:#c3c2b7; --border:rgba(11,11,11,0.10);
    --s-blue:#2a78d6; --s-green:#008300; --s-violet:#4a3aa7; --s-orange:#eb6834; --s-red:#e34948;
    --st-good:#0ca30c; --st-warning:#fab219; --st-critical:#d03b3b;
  }
  @media (prefers-color-scheme: dark){
    :root:where(:not([data-theme="light"])) .viz-root{
      color-scheme: dark;
      --page:#0d0d0d; --surface-1:#1a1a19;
      --text-primary:#ffffff; --text-secondary:#c3c2b7; --muted:#898781;
      --grid:#2c2c2a; --baseline:#383835; --border:rgba(255,255,255,0.10);
      --s-blue:#3987e5; --s-green:#008300; --s-violet:#9085e9; --s-orange:#d95926; --s-red:#e66767;
    }
  }
  *{box-sizing:border-box}
  body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",sans-serif}
  .viz-root{background:var(--page);color:var(--text-primary);min-height:100vh;padding:20px}
  .wrap{max-width:1100px;margin:0 auto}
  h1{font-size:18px;margin:0}
  .sub{color:var(--text-secondary);font-size:12px;margin:2px 0 16px}
  .dot{display:inline-block;width:9px;height:9px;border-radius:99px;background:var(--st-good);margin-right:6px}
  .dot.stale{background:var(--st-critical)}
  .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:14px}
  .tile{background:var(--surface-1);border:1px solid var(--border);border-radius:10px;padding:12px 14px}
  .tile .v{font-size:24px;font-weight:600;line-height:1.1}
  .tile .l{font-size:11px;color:var(--text-secondary);margin-top:4px}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:14px}
  @media (max-width:900px){.grid2{grid-template-columns:1fr}}
  .card{background:var(--surface-1);border:1px solid var(--border);border-radius:10px;padding:12px 14px;margin-bottom:14px}
  .card h2{font-size:13px;margin:0 0 8px;color:var(--text-primary)}
  .chart-box{position:relative;height:160px}
  table{width:100%;border-collapse:collapse;font-size:12px}
  th{text-align:left;color:var(--muted);font-weight:500;padding:4px 6px;border-bottom:1px solid var(--baseline)}
  td{padding:4px 6px;border-bottom:1px solid var(--grid);color:var(--text-secondary);vertical-align:top}
  td.cause{color:var(--text-primary);font-weight:600;white-space:nowrap}
  .mono{font-variant-numeric:tabular-nums;white-space:nowrap}
  .pill{display:inline-block;padding:0 7px;border-radius:99px;font-size:10px;font-weight:700;color:#fff}
  .sev-crit{background:var(--st-critical)} .sev-warn{background:var(--st-warning);color:#0b0b0b}
  .sev-info{background:var(--muted)}
  .muted{color:var(--muted)}
</style>
</head>
<body>
<div class="viz-root"><div class="wrap">
  <h1><span id="dot" class="dot"></span>FiveM Live Monitor</h1>
  <div class="sub">updated <span id="upd" class="mono">-</span> &middot; refreshes every 5s &middot; last 30 min shown</div>

  <div class="tiles">
    <div class="tile"><div class="v" id="tPlayers">-</div><div class="l">Players</div></div>
    <div class="tile"><div class="v" id="tHttp">-</div><div class="l">players.json ms</div></div>
    <div class="tile"><div class="v" id="tCore">-</div><div class="l">Max core %</div></div>
    <div class="tile"><div class="v" id="tFxCpu">-</div><div class="l">FXServer CPU %</div></div>
    <div class="tile"><div class="v" id="tRam">-</div><div class="l">RAM free MB</div></div>
    <div class="tile"><div class="v" id="tUdp">-</div><div class="l">UDP in pps</div></div>
    <div class="tile"><div class="v" id="tPing">-</div><div class="l">Ping ext ms</div></div>
  </div>

  <div class="grid2">
    <div class="card"><h2>Players</h2><div class="chart-box"><canvas id="cPlayers"></canvas></div></div>
    <div class="card"><h2>CPU % (max core / total / FXServer)</h2><div class="chart-box"><canvas id="cCpu"></canvas></div></div>
    <div class="card"><h2>UDP in pps (+ no-port)</h2><div class="chart-box"><canvas id="cUdp"></canvas></div></div>
    <div class="card"><h2>Ping ms (1.1.1.1 / 8.8.8.8)</h2><div class="chart-box"><canvas id="cPing"></canvas></div></div>
  </div>

  <div class="card"><h2>Recent alerts</h2>
    <table><thead><tr><th>Time</th><th>Sev</th><th>Cause</th><th>Detail</th></tr></thead>
    <tbody id="alerts"><tr><td colspan="4" class="muted">none yet</td></tr></tbody></table>
  </div>
</div></div>
<script>
function cssVar(n){ return getComputedStyle(document.querySelector('.viz-root')).getPropertyValue(n).trim(); }
function esc(s){ const d=document.createElement('div'); d.textContent=(s==null?'':String(s)); return d.innerHTML; }
let charts = {};
function mk(id, series){
  const muted = cssVar('--muted'), grid = cssVar('--grid');
  Chart.defaults.font.family = 'system-ui,-apple-system,"Segoe UI",sans-serif';
  Chart.defaults.color = muted;
  charts[id] = new Chart(document.getElementById(id), {
    type:'line',
    data:{ labels:[], datasets: series.map(s => ({ label:s.label, data:[],
      borderColor:cssVar(s.color), backgroundColor:cssVar(s.color),
      borderWidth:2, pointRadius:0, pointHitRadius:8, tension:0, spanGaps:false })) },
    options:{ responsive:true, maintainAspectRatio:false, animation:false,
      interaction:{mode:'index',intersect:false},
      plugins:{ legend:{display:series.length>1,labels:{boxWidth:9,boxHeight:9,color:cssVar('--text-secondary')}} },
      scales:{ x:{ticks:{maxTicksLimit:6,color:muted},grid:{display:false}},
               y:{beginAtZero:true,ticks:{maxTicksLimit:5,color:muted},grid:{color:grid,drawTicks:false}} } }
  });
}
function initCharts(){
  if (!window.Chart || charts.cPlayers) return;
  mk('cPlayers',[{label:'Players',data:null,color:'--s-blue'}]);
  mk('cCpu',[{label:'Max core',color:'--s-red'},{label:'Total',color:'--s-blue'},{label:'FXServer',color:'--s-green'}]);
  mk('cUdp',[{label:'UDP in',color:'--s-blue'},{label:'no-port',color:'--s-red'}]);
  mk('cPing',[{label:'1.1.1.1',color:'--s-blue'},{label:'8.8.8.8',color:'--s-violet'}]);
}
initCharts();
if (!window.Chart){
  // local chart.js missing - try the CDN as a last resort
  var s = document.createElement('script');
  s.src = 'https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.4/chart.umd.min.js';
  s.onload = initCharts;
  document.head.appendChild(s);
}
function setChart(id, labels, seriesData){
  const c = charts[id]; if (!c) return;
  c.data.labels = labels;
  seriesData.forEach((d,i)=>{ c.data.datasets[i].data = d; });
  c.update('none');
}
function nn(v){ return (v==null || v<0) ? null : v; }
let lastOk = 0;
async function tick(){
  try{
    const r = await fetch('data', {cache:'no-store'});
    const d = await r.json();
    lastOk = Date.now();
    initCharts();
    const now = d.now || {};
    const set=(id,v,suf)=>{ document.getElementById(id).textContent = (v==null||v<0)?'-':(v+(suf||'')); };
    set('tPlayers', now.players); set('tHttp', now.httpMs); set('tCore', now.cpuMax);
    set('tFxCpu', now.fxCpu); set('tRam', now.ramAvail); set('tUdp', now.udpIn); set('tPing', now.pingExt);
    document.getElementById('upd').textContent = now.ts || '-';
    const h = d.hist || [];
    const L = h.map(x=>x.t);
    setChart('cPlayers', L, [h.map(x=>nn(x.p))]);
    setChart('cCpu', L, [h.map(x=>nn(x.cm)), h.map(x=>nn(x.ct)), h.map(x=>nn(x.fc))]);
    setChart('cUdp', L, [h.map(x=>nn(x.ui)), h.map(x=>nn(x.un))]);
    setChart('cPing', L, [h.map(x=>nn(x.p1)), h.map(x=>nn(x.p2))]);
    const al = d.alerts || [];
    document.getElementById('alerts').innerHTML = al.length === 0
      ? '<tr><td colspan="4" class="muted">none yet</td></tr>'
      : al.map(a=>{
          const cls = a.severity==='CRIT'?'sev-crit':(a.severity==='INFO'?'sev-info':'sev-warn');
          return '<tr><td class="mono">'+esc(a.ts)+'</td><td><span class="pill '+cls+'">'+esc(a.severity)+'</span></td>'+
                 '<td class="cause">'+esc(a.cause)+'</td><td>'+esc(a.detail)+'</td></tr>';
        }).join('');
  }catch(e){}
  document.getElementById('dot').className = 'dot' + ((Date.now()-lastOk) > 20000 ? ' stale' : '');
}
setInterval(tick, 5000); tick();
</script>
</body>
</html>
'@

$dash = $null
if (-not $NoDashboard) {
    try {
        # chart.umd.min.js may sit next to the script or in ../assets (repo layout)
        $chartLibJs = ''
        foreach ($p in @((Join-Path $scriptRoot 'chart.umd.min.js'),
                         (Join-Path (Split-Path -Parent $scriptRoot) 'assets\chart.umd.min.js'))) {
            if (Test-Path $p) { $chartLibJs = [IO.File]::ReadAllText($p); break }
        }
        # prefer the shared dashboard page from ../assets when available
        $assetDash = Join-Path (Split-Path -Parent $scriptRoot) 'assets\dashboard.html'
        if (Test-Path $assetDash) { $dashHtml = [IO.File]::ReadAllText($assetDash) }
        if (-not $chartLibJs) { Write-Log "NOTE: chart.umd.min.js not found next to the script - dashboard charts will need CDN access." }
        $dash = [hashtable]::Synchronized(@{
            json = '{"now":{},"hist":[],"alerts":[]}'
            html = $dashHtml
            chartjs = $chartLibJs
        })
        $dashListener = New-Object System.Net.HttpListener
        $dashListener.Prefixes.Add("http://${DashboardBind}:${DashboardPort}/")
        $dashListener.Start()
        $dashRunspace = [runspacefactory]::CreateRunspace()
        $dashRunspace.Open()
        $dashRunspace.SessionStateProxy.SetVariable('dash', $dash)
        $dashRunspace.SessionStateProxy.SetVariable('listener', $dashListener)
        $dashPS = [powershell]::Create()
        $dashPS.Runspace = $dashRunspace
        [void]$dashPS.AddScript({
            while ($listener.IsListening) {
                try {
                    $ctx = $listener.GetContext()
                    $path = $ctx.Request.Url.AbsolutePath
                    if ($path -match '/data$') {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$dash.json)
                        $ctx.Response.ContentType = 'application/json'
                    } elseif ($path -match 'chart\.js$') {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$dash.chartjs)
                        $ctx.Response.ContentType = 'text/javascript'
                    } else {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$dash.html)
                        $ctx.Response.ContentType = 'text/html; charset=utf-8'
                    }
                    $ctx.Response.Headers.Add('Cache-Control','no-store')
                    $ctx.Response.ContentLength64 = $bytes.Length
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $ctx.Response.Close()
                } catch {}
            }
        })
        [void]$dashPS.BeginInvoke()
        Write-Log "Live dashboard: http://${DashboardBind}:${DashboardPort}/  (open in the server's browser)"
    } catch {
        Write-Log "WARNING: dashboard failed to start on port $DashboardPort ($($_.Exception.Message)) - continuing without it."
        $dash = $null
    }
}

# ------------------------------------------------------------- state
$coreCount     = [Environment]::ProcessorCount
$prevFxCpuTime = $null
$prevFxPid     = $null
$prevPlayers   = -1
$pingGwHist    = New-Object System.Collections.Queue
$pingExtHist   = New-Object System.Collections.Queue
$pingExt2Hist  = New-Object System.Collections.Queue
$cpuCoreHighStreak = 0
$gwEverAnswered = $false
$emaUdpPps     = $null   # exponential moving baseline (spike detection)
$emaMbps       = $null
$emaAlpha      = 0.05    # slow-moving baseline (~ last 100 samples)
$lastAlertAt   = @{}     # cause -> datetime, for cooldown
$resourceErrCount = @{}  # resource -> cumulative error count this session
$recentAlerts  = New-Object System.Collections.Queue   # last 15 alerts, for the live dashboard
$cfxPlayers    = -1
$cfxLastTry    = [datetime]::MinValue
$cfxLastOk     = [datetime]::MinValue
$dashHist      = New-Object System.Collections.Queue   # last ~30 min of samples, for the live dashboard

function Raise-Alert([string]$severity, [string]$cause, [string]$detail, [ref]$alertList) {
    $now = Get-Date
    if ($lastAlertAt.ContainsKey($cause) -and ($now - $lastAlertAt[$cause]).TotalSeconds -lt $T.AlertCooldownSec) {
        return
    }
    $lastAlertAt[$cause] = $now
    $alertList.Value += $cause
    Add-CsvLine 'alerts' $alertsHeader ("{0},{1},{2},{3}" -f `
        $now.ToString('yyyy-MM-dd HH:mm:ss'), $severity, $cause, (CsvEscape $detail))
    Write-Log ("ALERT [{0}] {1} :: {2}" -f $severity, $cause, $detail)
    $recentAlerts.Enqueue(@{ ts = $now.ToString('HH:mm:ss'); severity = $severity; cause = $cause; detail = $detail })
    while ($recentAlerts.Count -gt 15) { [void]$recentAlerts.Dequeue() }
    # auto-profiler: start a capture when a configured trigger alert fires
    if ($ProfilerActive -and $severity -ne 'INFO' -and $null -eq $script:profilerSaveDue -and
        ($ProfilerTriggerSet -contains $cause) -and
        ($now - $script:profilerLastRun).TotalSeconds -ge $ProfilerCooldownSec) {
        if (Send-Rcon "profiler record $ProfilerFrames") {
            $script:profilerLastRun = $now
            $script:profilerCause   = $cause
            $script:profilerSaveDue = $now.AddSeconds([math]::Ceiling($ProfilerFrames / 30) + 3)
            Write-Log "Profiler: recording $ProfilerFrames frames (trigger: $cause)"
        }
    }
    if ($DiscordWebhook -and $severity -ne 'INFO') {
        try {
            $payload = (@{ content = ("**[{0}] {1}**`n{2}" -f $severity, $cause, $detail) } | ConvertTo-Json -Compress)
            $wr = [System.Net.WebRequest]::Create($DiscordWebhook)
            $wr.Method = 'POST'; $wr.ContentType = 'application/json'; $wr.Timeout = 3000
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $wr.ContentLength = $bytes.Length
            $os = $wr.GetRequestStream(); $os.Write($bytes, 0, $bytes.Length); $os.Close()
            $wr.GetResponse().Close()
        } catch {}
    }
}

Write-Log "FiveM monitor started. Interval=${IntervalSec}s  Port=$ServerPort  Cores=$coreCount  Logs=$LogDir"
if ($confPath) { Write-Log "Config: $confPath" }
if ($ProfilerActive) {
    Write-Log "Auto-profiler: ON  ($ProfilerFrames frames, cooldown ${ProfilerCooldownSec}s, triggers: $($ProfilerTriggerSet -join ', '))"
} elseif ($ProfilerEnabled) {
    Write-Log "Auto-profiler: PROFILER_ENABLED=true but RCON_PASSWORD is empty - feature disabled (set rcon_password in server.cfg and sentinel.conf)"
}

# ================================================================= MAIN LOOP
while ($true) {
    $cycleStart = Get-Date
    $alerts = @()

    # ---- perf counters (locale-independent WMI formatted classes) ----
    $cpuTotal = -1; $cpuMaxCore = -1
    try {
        $cores = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop
        $cpuTotal   = [int]($cores | Where-Object Name -eq '_Total').PercentProcessorTime
        $cpuMaxCore = [int](($cores | Where-Object Name -ne '_Total' |
                        Measure-Object PercentProcessorTime -Maximum).Maximum)
    } catch {}

    $ramAvail = -1; $pagesSec = -1
    try {
        $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $ramAvail = [int]$mem.AvailableMBytes
        $pagesSec = [int]$mem.PagesPersec
    } catch {}

    $udpIn = -1; $udpOut = -1; $udpNoPort = -1; $udpErr = -1
    try {
        $udp = Get-CimInstance Win32_PerfFormattedData_Tcpip_UDPv4 -ErrorAction Stop
        $udpIn     = [int]$udp.DatagramsReceivedPersec
        $udpOut    = [int]$udp.DatagramsSentPersec
        $udpNoPort = [int]$udp.DatagramsNoPortPersec
        $udpErr    = [int]$udp.DatagramsReceivedErrors
    } catch {}

    $nicInMbps = -1.0; $nicOutMbps = -1.0; $nicInPps = -1
    try {
        $nics = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
            Where-Object { $_.Name -notmatch 'isatap|Loopback|Teredo' }
        $nicInMbps  = [math]::Round((($nics | Measure-Object BytesReceivedPersec -Sum).Sum * 8 / 1MB), 2)
        $nicOutMbps = [math]::Round((($nics | Measure-Object BytesSentPersec    -Sum).Sum * 8 / 1MB), 2)
        $nicInPps   = [int](($nics | Measure-Object PacketsReceivedPersec -Sum).Sum)
    } catch {}

    # ---- FXServer process ----
    $fx = Find-FxProcess
    $fxCpu = -1.0; $fxRam = -1; $fxPid = -1; $fxThreads = -1; $fxHandles = -1
    if ($fx) {
        $fxPid = $fx.Id; $fxRam = [int]($fx.WorkingSet64 / 1MB)
        $fxThreads = $fx.Threads.Count; $fxHandles = $fx.HandleCount
        if ($prevFxPid -eq $fxPid -and $null -ne $prevFxCpuTime) {
            $deltaMs = ($fx.TotalProcessorTime - $prevFxCpuTime).TotalMilliseconds
            $fxCpu   = [math]::Round(100.0 * $deltaMs / ($IntervalSec * 1000) / $coreCount, 1)
            if ($fxCpu -lt 0) { $fxCpu = -1.0 }
        }
        if ($null -ne $prevFxPid -and $prevFxPid -ne $fxPid -and $prevFxPid -ne -1) {
            Raise-Alert 'CRIT' 'SERVER_RESTARTED' "FXServer PID changed $prevFxPid -> $fxPid (crash or txAdmin restart)" ([ref]$alerts)
        }
        $prevFxCpuTime = $fx.TotalProcessorTime
        $prevFxPid = $fxPid
    } else {
        if ($prevFxPid -and $prevFxPid -ne -1) {
            Raise-Alert 'CRIT' 'SERVER_DOWN' 'FXServer process not found / not bound to game port' ([ref]$alerts)
        }
        $prevFxCpuTime = $null; $prevFxPid = -1
    }

    # ---- server responsiveness + player count ----
    $pj = Get-PlayersJson
    $httpMs = $pj.ms; $httpOk = if ($pj.ok) { 1 } else { 0 }

    # Player count: CFX master API when enabled and fresh; local players.json otherwise.
    if ($CfxJoinCode -and ((Get-Date) - $cfxLastTry).TotalSeconds -ge 15) {
        $cfxLastTry = Get-Date
        $c = Get-CfxPlayers
        if ($null -ne $c) { $cfxPlayers = $c; $cfxLastOk = Get-Date }
    }
    $cfxFresh = ($cfxPlayers -ge 0 -and ((Get-Date) - $cfxLastOk).TotalSeconds -lt 60)
    $players = if ($cfxFresh) { $cfxPlayers } else { $pj.count }

    # ---- ping health ----
    $pingGw   = Ping-Ms $gateway
    $pingExt  = Ping-Ms $extTarget1
    $pingExt2 = if ($extTarget2) { Ping-Ms $extTarget2 } else { -1 }
    foreach ($pair in @(@($pingGwHist, $pingGw), @($pingExtHist, $pingExt), @($pingExt2Hist, $pingExt2))) {
        $q = $pair[0]; $q.Enqueue($pair[1])
        while ($q.Count -gt $T.PingWindow) { $q.Dequeue() | Out-Null }
    }
    function LossPct($q) {
        if ($q.Count -eq 0) { return 0 }
        $lost = @($q.ToArray() | Where-Object { $_ -lt 0 }).Count
        return [int](100 * $lost / $q.Count)
    }
    # Only compute loss once a full window of samples exists (prevents a
    # false 100%-loss alert on the first samples after startup).
    $gwWindowFull  = ($pingGwHist.Count  -ge $T.PingWindow)
    $extWindowFull = ($pingExtHist.Count -ge $T.PingWindow)
    $gwLoss   = if ($gateway -and $gwWindowFull) { LossPct $pingGwHist } else { -1 }
    $extLoss  = if ($extWindowFull) { LossPct $pingExtHist } else { -1 }
    $ext2Loss = if ($extTarget2 -and $extWindowFull) { LossPct $pingExt2Hist } else { -1 }

    # Many datacenter gateways (OVH etc.) never answer ICMP at all. If the
    # gateway has answered nothing across a full window while the external
    # target answers fine, it's ICMP-blocked - disable gateway checks rather
    # than raising bogus LOCAL_NETWORK_LOSS alerts.
    if ($gateway -and -not $gwEverAnswered) {
        if ($pingGw -ge 0) { $gwEverAnswered = $true }
        elseif ($gwWindowFull) {
            $anyExtOk = ((LossPct $pingExtHist) -lt 50) -or ($extTarget2 -and (LossPct $pingExt2Hist) -lt 50)
            if ($anyExtOk) {
                Write-Log "NOTE: gateway $gateway does not answer ICMP (normal on datacenter gateways) - disabling gateway checks; using external ping only."
                Add-CsvLine 'alerts' $alertsHeader ("{0},INFO,GATEWAY_ICMP_BLOCKED,{1}" -f `
                    (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), `
                    (CsvEscape "Gateway $gateway does not respond to ping; gateway-based local-network detection disabled automatically."))
                $gateway = $null
            }
        }
    }

    # ---- console log tail: hitches / script errors / timeouts ----
    $hitches = 0; $scriptErrors = 0; $timeouts = 0
    if ($resolvedLog -and (Test-Path $resolvedLog)) {
        try {
            $len = (Get-Item $resolvedLog).Length
            if ($len -lt $logOffset) { $logOffset = 0 }   # rotated
            if ($len -gt $logOffset) {
                $fs = [IO.File]::Open($resolvedLog, 'Open', 'Read', 'ReadWrite')
                $fs.Seek($logOffset, 'Begin') | Out-Null
                $sr = New-Object IO.StreamReader ($fs)
                $chunk = $sr.ReadToEnd()
                $sr.Close(); $fs.Close()
                $logOffset = $len

                foreach ($line in ($chunk -split "`n")) {
                    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    if ($line -match 'hitch warning') {
                        $hitches++
                        Add-CsvLine 'events' $eventsHeader ("{0},hitch,,{1}" -f $ts, (CsvEscape $line.Trim().Substring(0, [Math]::Min(220, $line.Trim().Length))))
                    }
                    elseif ($line -match 'SCRIPT ERROR|error running|Error running system event|Failed to load script') {
                        $scriptErrors++
                        $res = ''
                        if ($line -match '@([\w\-\.]+)/') { $res = $Matches[1] }
                        if ($res) {
                            if (-not $resourceErrCount.ContainsKey($res)) { $resourceErrCount[$res] = 0 }
                            $resourceErrCount[$res]++
                        }
                        Add-CsvLine 'events' $eventsHeader ("{0},script_error,{1},{2}" -f $ts, $res, (CsvEscape $line.Trim().Substring(0, [Math]::Min(220, $line.Trim().Length))))
                    }
                    elseif ($line -match 'timed out|connection timed out|Timed out') {
                        $timeouts++
                        Add-CsvLine 'events' $eventsHeader ("{0},timeout,,{1}" -f $ts, (CsvEscape $line.Trim().Substring(0, [Math]::Min(220, $line.Trim().Length))))
                    }
                }
            }
        } catch {}
    }

    # ---- baselines (EMA) for flood detection ----
    $udpSpike = $false; $mbpsSpike = $false
    if ($udpIn -ge 0) {
        if ($null -eq $emaUdpPps) { $emaUdpPps = [double]$udpIn }
        $udpSpike = ($udpIn -gt $T.UdpSpikeFloorPps) -and ($udpIn -gt $emaUdpPps * $T.UdpSpikeFactor)
        if (-not $udpSpike) { $emaUdpPps = (1 - $emaAlpha) * $emaUdpPps + $emaAlpha * $udpIn }
    }
    if ($nicInMbps -ge 0) {
        if ($null -eq $emaMbps) { $emaMbps = [double]$nicInMbps }
        $mbpsSpike = ($nicInMbps -gt $T.MbpsSpikeFloor) -and ($nicInMbps -gt $emaMbps * $T.MbpsSpikeFactor)
        if (-not $mbpsSpike) { $emaMbps = (1 - $emaAlpha) * $emaMbps + $emaAlpha * $nicInMbps }
    }
    $noPortSpike = ($udpNoPort -ge $T.NoPortSpikePps)

    # ---- condition flags ----
    if ($cpuMaxCore -ge $T.CpuCoreHighPct) { $cpuCoreHighStreak++ } else { $cpuCoreHighStreak = 0 }
    $cpuCoreHot  = ($cpuCoreHighStreak -ge $T.CpuCoreHighSamples)
    $cpuTotalHot = ($cpuTotal -ge $T.CpuTotalHighPct)
    $ramLow      = ($ramAvail -ge 0 -and $ramAvail -le $T.RamAvailLowMB)
    $ramThrash   = ($pagesSec -ge $T.PagesPerSecHigh)
    $httpSlow    = ($httpOk -eq 1 -and $httpMs -ge $T.HttpSlowMs)
    $httpDead    = ($httpOk -eq 0 -and $fxPid -ne -1)
    # A target is "degraded" if its rolling loss is high or its latency spiked.
    # Upstream is only declared when EVERY external target is degraded at once -
    # a single bad anycast node can't trigger it.
    $ext1Bad = ($extLoss -ge $T.PingLossPctHigh) -or ($pingExt -gt $T.PingHighMs -and $pingExt -ge 0)
    $ext2Bad = if ($extTarget2) { ($ext2Loss -ge $T.PingLossPctHigh) -or ($pingExt2 -gt $T.PingHighMs -and $pingExt2 -ge 0) } else { $ext1Bad }
    $netUpstream = ($ext1Bad -and $ext2Bad)
    $netLocal    = ($gateway -and $gwEverAnswered -and $gwLoss -ge $T.PingLossPctHigh)
    $floodLike   = (($udpSpike -and $mbpsSpike) -or $noPortSpike -or ($udpSpike -and $noPortSpike))

    # ---- standing alerts (independent of player drops) ----
    if ($floodLike) {
        $emaMbpsDisp = if ($null -ne $emaMbps) { [math]::Round($emaMbps, 1) } else { 0 }
        Raise-Alert 'CRIT' 'POSSIBLE_DDOS' ("UDP flood pattern: in={0} pps (baseline ~{1}), noPort={2} pps, inbound={3} Mbps (baseline ~{4})" -f `
            $udpIn, [int]$emaUdpPps, $udpNoPort, $nicInMbps, $emaMbpsDisp) ([ref]$alerts)
    }
    if ($cpuCoreHot) {
        Raise-Alert 'WARN' 'CPU_CORE_SATURATED' ("A core pegged at {0}% for {1}+ samples (FXServer CPU {2}%). FiveM main/sync thread is single-core bound - this causes hitches/timeouts even with idle cores." -f `
            $cpuMaxCore, $T.CpuCoreHighSamples, $fxCpu) ([ref]$alerts)
    }
    if ($cpuTotalHot) {
        Raise-Alert 'WARN' 'CPU_TOTAL_HIGH' ("Total CPU {0}% (FXServer {1}%)" -f $cpuTotal, $fxCpu) ([ref]$alerts)
    }
    if ($ramLow -or $ramThrash) {
        Raise-Alert 'WARN' 'RAM_PRESSURE' ("Available RAM {0} MB, pages/sec {1}, FXServer {2} MB" -f $ramAvail, $pagesSec, $fxRam) ([ref]$alerts)
    }
    if ($netLocal) {
        Raise-Alert 'CRIT' 'LOCAL_NETWORK_LOSS' ("Packet loss to gateway {0}% (host/NIC/virtual-switch problem, not the internet)" -f $gwLoss) ([ref]$alerts)
    }
    elseif ($netUpstream) {
        Raise-Alert 'WARN' 'UPSTREAM_NETWORK' ("External path degraded on ALL targets: {0} loss {1}%/{2} ms, {3} loss {4}%/{5} ms (gateway: {6} ms/{7}% loss)" -f `
            $extTarget1, $extLoss, $pingExt, $extTarget2, $ext2Loss, $pingExt2, $pingGw, $gwLoss) ([ref]$alerts)
    }
    if ($httpDead) {
        Raise-Alert 'CRIT' 'SERVER_UNRESPONSIVE' 'FXServer process alive but players.json not answering (main thread stalled or deadlocked)' ([ref]$alerts)
    }
    elseif ($httpSlow) {
        Raise-Alert 'WARN' 'SERVER_THREAD_SLOW' ("players.json took {0} ms - server thread hitching" -f $httpMs) ([ref]$alerts)
    }
    if ($hitches -gt 0 -and -not $cpuCoreHot) {
        Raise-Alert 'WARN' 'SCRIPT_HITCH' ("{0} hitch warning(s) in console without core saturation - a script/resource is blocking the tick (check events CSV / top offenders)" -f $hitches) ([ref]$alerts)
    }

    # ---- mass player-drop correlation ----
    if ($prevPlayers -ge 0 -and $players -ge 0) {
        $dropped = $prevPlayers - $players
        $massDrop = ($dropped -ge $T.PlayerDropCount) -and `
                    ($prevPlayers -gt 0 -and (100.0 * $dropped / $prevPlayers) -ge $T.PlayerDropPct)
        if ($massDrop -or ($timeouts -ge $T.PlayerDropCount)) {
            $suspects = @()
            if ($floodLike)             { $suspects += 'DDOS/FLOOD' }
            if ($netLocal)              { $suspects += 'LOCAL-NETWORK' }
            if ($netUpstream)           { $suspects += 'UPSTREAM-NETWORK' }
            if ($cpuCoreHot -or $cpuTotalHot) { $suspects += 'CPU' }
            if ($ramLow -or $ramThrash) { $suspects += 'RAM' }
            if ($hitches -gt 0 -or $scriptErrors -gt 0) { $suspects += 'SCRIPT' }
            if ($httpDead -or $httpSlow){ $suspects += 'SERVER-THREAD-STALL' }
            if ($suspects.Count -eq 0)  { $suspects += 'UNKNOWN (nothing local abnormal - suspect client-side ISP/route or provider edge filtering; compare timestamps with your host''s DDoS console)' }
            $sev = if ($suspects -contains 'DDOS/FLOOD' -or $netLocal) { 'CRIT' } else { 'WARN' }
            Raise-Alert $sev 'MASS_PLAYER_DROP' ("{0} -> {1} players ({2} lost, {3} timeout lines). Suspected: {4}" -f `
                $prevPlayers, $players, $dropped, $timeouts, ($suspects -join ' + ')) ([ref]$alerts)
        }
    }
    if ($players -ge 0) { $prevPlayers = $players }

    # ---- write metrics row ----
    $row = ($cycleStart.ToString('yyyy-MM-dd HH:mm:ss'), $players, $httpMs, $httpOk,
            $cpuTotal, $cpuMaxCore, $fxCpu, $ramAvail, $fxRam, $pagesSec,
            $udpIn, $udpOut, $udpNoPort, $udpErr,
            $nicInMbps, $nicOutMbps, $nicInPps,
            $pingGw, $pingExt, $pingExt2, $gwLoss, $extLoss, $ext2Loss,
            $fxPid, $fxThreads, $fxHandles,
            $hitches, $scriptErrors, $timeouts,
            (CsvEscape ($alerts -join '|'))) -join ','
    Add-CsvLine 'metrics' $metricsHeader $row

    # ---- live dashboard snapshot ----
    if ($dash) {
        $dashHist.Enqueue(@{ t=$cycleStart.ToString('HH:mm:ss'); p=$players; cm=$cpuMaxCore; ct=$cpuTotal; fc=$fxCpu
                             ui=$udpIn; un=$udpNoPort; p1=$pingExt; p2=$pingExt2 })
        while ($dashHist.Count -gt 360) { [void]$dashHist.Dequeue() }
        $alertsArr = @($recentAlerts.ToArray())
        [array]::Reverse($alertsArr)   # newest first
        $snap = @{
            now = @{ ts=$cycleStart.ToString('HH:mm:ss'); players=$players; httpMs=$httpMs; cpuMax=$cpuMaxCore
                     fxCpu=$fxCpu; ramAvail=$ramAvail; udpIn=$udpIn; pingExt=$pingExt }
            hist = @($dashHist.ToArray())
            alerts = $alertsArr
        }
        try { $dash.json = ($snap | ConvertTo-Json -Depth 5 -Compress) } catch {}
    }

    # ---- top offender snapshot every ~5 min ----
    if ($resourceErrCount.Count -gt 0 -and ((Get-Date).Minute % 5 -eq 0) -and ((Get-Date).Second -lt $IntervalSec)) {
        $top = ($resourceErrCount.GetEnumerator() | Sort-Object Value -Descending |
                Select-Object -First 5 | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
        Add-CsvLine 'events' $eventsHeader ("{0},top_error_resources,,{1}" -f `
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), (CsvEscape $top))
    }

    # ---- auto-profiler: save a finished recording ----
    if ($ProfilerActive -and $script:profilerSaveDue -and (Get-Date) -ge $script:profilerSaveDue) {
        $pf = 'sentinel_profile_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
        if (Send-Rcon "profiler save $pf") {
            Raise-Alert 'INFO' 'PROFILER_CAPTURED' ("Saved {0} in the server data directory (trigger: {1}). Inspect with: profiler view {0}" -f $pf, $script:profilerCause) ([ref]$alerts)
        }
        $script:profilerSaveDue = $null
    }

    # ---- sleep the remainder of the interval ----
    $elapsed = ((Get-Date) - $cycleStart).TotalMilliseconds
    $sleepMs = [Math]::Max(500, ($IntervalSec * 1000) - $elapsed)
    Start-Sleep -Milliseconds $sleepMs
}
