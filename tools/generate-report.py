#!/usr/bin/env python3
"""Builds the daily HTML report from fivem-sentinel CSV logs.

Works with logs produced by either the Windows (PowerShell) or Linux (bash)
monitor - the CSV layout is identical. Standard library only.

    python3 generate-report.py [--date YYYY-MM-DD] [--logs DIR] [--out DIR]
"""
import argparse
import csv
import datetime
import html as html_mod
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.dirname(HERE), "assets")
MAX_POINTS = 1200

TEMPLATE = r'''<!DOCTYPE html>
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
</html>'''


def num_or_none(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f < 0:
        return None
    return int(f) if f == int(f) else f


def esc(s):
    return html_mod.escape(s or "", quote=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--logs", default=os.path.join(HERE, "..", "linux", "logs"))
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    logs = os.path.abspath(args.logs)
    out_dir = os.path.abspath(args.out or os.path.join(logs, "..", "reports"))
    os.makedirs(out_dir, exist_ok=True)

    metrics_file = os.path.join(logs, f"metrics-{args.date}.csv")
    if not os.path.isfile(metrics_file):
        sys.exit(f"No metrics file for {args.date} ({metrics_file}). Is the monitor running?")

    with open(metrics_file, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit("Metrics file is empty.")

    stride = max(1, -(-len(rows) // MAX_POINTS))
    sampled = rows[::stride]
    print(f"{len(rows)} samples -> {len(sampled)} points (stride {stride})")

    def col(name):
        return [num_or_none(r.get(name)) for r in sampled]

    data = {
        "labels":   [ (r.get("ts") or " ").split(" ")[-1] for r in sampled ],
        "players":  col("players"),  "httpMs":  col("httpMs"),
        "cpuTotal": col("cpuTotal"), "cpuMax":  col("cpuMaxCore"), "fxCpu": col("fxCpu"),
        "ramAvail": col("ramAvailMB"), "fxRam": col("fxRamMB"),
        "udpIn":    col("udpInPps"), "udpNoPort": col("udpNoPortPps"),
        "nicIn":    col("nicInMbps"), "nicOut": col("nicOutMbps"),
        "pingGw":   col("pingGwMs"), "pingExt": col("pingExtMs"), "pingExt2": col("pingExt2Ms"),
        "hitches":  col("hitches"),  "timeouts": col("timeouts"),
    }

    alerts = []
    af = os.path.join(logs, f"alerts-{args.date}.csv")
    if os.path.isfile(af):
        with open(af, newline="", encoding="utf-8-sig") as f:
            alerts = list(csv.DictReader(f))

    if alerts:
        sev_class = {"CRIT": "sev-crit", "INFO": "sev-info"}
        alert_rows = "\n".join(
            f"<tr><td class='mono'>{esc(a.get('ts'))}</td>"
            f"<td><span class='pill {sev_class.get(a.get('severity'), 'sev-warn')}'>{esc(a.get('severity'))}</span></td>"
            f"<td class='cause'>{esc(a.get('cause'))}</td><td>{esc(a.get('detail'))}</td></tr>"
            for a in alerts)
        counts = {}
        for a in alerts:
            counts[a.get("cause")] = counts.get(a.get("cause"), 0) + 1
        cause_summary = " ".join(
            f"<span class='tag'>{esc(c)} &times;{n}</span>"
            for c, n in sorted(counts.items(), key=lambda kv: -kv[1]))
    else:
        alert_rows = "<tr><td colspan='4' class='muted'>No alerts recorded for this day.</td></tr>"
        cause_summary = "<span class='muted'>none</span>"

    events = []
    ef = os.path.join(logs, f"events-{args.date}.csv")
    if os.path.isfile(ef):
        with open(ef, newline="", encoding="utf-8-sig") as f:
            events = list(csv.DictReader(f))
    ev_counts = {}
    for e in events:
        ev_counts[e.get("type")] = ev_counts.get(e.get("type"), 0) + 1
    ev_summary = (" ".join(f"<span class='tag'>{esc(t)} &times;{n}</span>"
                           for t, n in sorted(ev_counts.items(), key=lambda kv: -kv[1]))
                  or "<span class='muted'>none</span>")
    res_counts = {}
    for e in events:
        if e.get("type") == "script_error" and e.get("resource"):
            res_counts[e["resource"]] = res_counts.get(e["resource"], 0) + 1
    if res_counts:
        top_res = "\n".join(f"<tr><td class='mono'>{esc(r)}</td><td>{n}</td></tr>"
                             for r, n in sorted(res_counts.items(), key=lambda kv: -kv[1])[:10])
    else:
        top_res = "<tr><td colspan='2' class='muted'>No script errors attributed to a resource.</td></tr>"

    def stat_max(vals):
        vals = [v for v in vals if v is not None]
        return str(int(max(vals))) if vals else "-"

    timeouts_total = int(sum(num_or_none(r.get("timeouts")) or 0 for r in rows))

    page = TEMPLATE
    for token, value in {
        "__DATA__": json.dumps(data, separators=(",", ":")),
        "__DATE__": args.date,
        "__NSAMPLES__": str(len(rows)),
        "__GENTIME__": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
        "__STAT_PLAYERS__": stat_max(data["players"]),
        "__STAT_CPU__": stat_max(data["cpuMax"]),
        "__STAT_UDP__": stat_max(data["udpIn"]),
        "__STAT_TIMEOUTS__": str(timeouts_total),
        "__STAT_ALERTS__": str(len(alerts)),
        "__CAUSE_SUMMARY__": cause_summary,
        "__EV_SUMMARY__": ev_summary,
        "__ALERT_ROWS__": alert_rows,
        "__TOP_RES__": top_res,
    }.items():
        page = page.replace(token, value)

    chart_lib = os.path.join(ASSETS, "chart.umd.min.js")
    if os.path.isfile(chart_lib):
        with open(chart_lib, encoding="utf-8") as f:
            lib = f.read()
        cdn = '<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.4/chart.umd.min.js"></script>'
        page = page.replace(cdn, "<script>" + lib + "</script>")

    out_file = os.path.join(out_dir, f"report-{args.date}.html")
    with open(out_file, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"Report written: {out_file}")


if __name__ == "__main__":
    main()
