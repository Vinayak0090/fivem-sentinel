#!/usr/bin/env bash
#
# fivem-sentinel: FiveM server diagnostics for Linux.
#
# Samples system, network and FXServer health every few seconds so that when
# players time out you can tell what actually caused it: DDoS/flood, upstream
# network, CPU (single core), RAM, a misbehaving resource, or a server stall.
#
# Writes the same CSV layout as the Windows monitor, so tools/generate-report.py
# works on the output of either. Also writes logs/live.json every cycle for the
# live dashboard (linux/dashboard.py).
#
# Config via environment variables (see README) or the defaults below.
# Runs fine as an unprivileged user; run it as the same user as the FiveM
# server so /proc/<pid> is readable.

set -u
export LC_ALL=C

# --------------------------------------------------------------- config
INTERVAL="${INTERVAL:-5}"
SERVER_PORT="${SERVER_PORT:-30120}"
CONSOLE_LOG="${CONSOLE_LOG:-}"              # fxserver.log path; auto-detected if empty
TXDATA_ROOT="${TXDATA_ROOT:-$HOME}"         # searched for txData/*/logs/fxserver.log
EXT1="${EXT1:-1.1.1.1}"
EXT2="${EXT2:-8.8.8.8}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
RETAIN_DAYS="${RETAIN_DAYS:-14}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"
FX_PROCESS="${FX_PROCESS:-FXServer}"

# thresholds
T_CPU_CORE_HIGH=95        # single core pegged (FiveM main thread is single-core bound)
T_CPU_CORE_SAMPLES=3
T_CPU_TOTAL_HIGH=90
T_RAM_LOW_MB=700
T_MAJFLT_HIGH=800         # major page faults/sec = RAM thrash
T_HTTP_SLOW_MS=1500
T_PING_HIGH_MS=150
T_LOSS_HIGH_PCT=20
PING_WINDOW=12
T_UDP_SPIKE_FACTOR=4
T_UDP_SPIKE_FLOOR=4000
T_MBPS_SPIKE_FACTOR=4
T_MBPS_SPIKE_FLOOR=100
T_NOPORT_SPIKE=500
T_DROP_COUNT=3
T_DROP_PCT=20
ALERT_COOLDOWN=120

mkdir -p "$LOG_DIR"
renice 10 $$ >/dev/null 2>&1

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

METRICS_HEADER='ts,players,httpMs,httpOk,cpuTotal,cpuMaxCore,fxCpu,ramAvailMB,fxRamMB,pagesSec,udpInPps,udpOutPps,udpNoPortPps,udpErrors,nicInMbps,nicOutMbps,nicInPps,pingGwMs,pingExtMs,pingExt2Ms,gwLossPct,extLossPct,ext2LossPct,fxPid,fxThreads,fxHandles,hitches,scriptErrors,timeouts,alerts'
ALERTS_HEADER='ts,severity,cause,detail'
EVENTS_HEADER='ts,type,resource,line'

csv_file() { echo "$LOG_DIR/$1-$(date +%F).csv"; }
csv_line() { # prefix header line
  local f; f="$(csv_file "$1")"
  [ -f "$f" ] || echo "$2" > "$f"
  echo "$3" >> "$f"
}
csv_escape() { # escape a field that may contain commas/quotes/newlines
  local s="${1//$'\n'/ }"; s="${s//$'\r'/ }"
  case "$s" in
    *[\",]*) s="\"${s//\"/\"\"}\"" ;;
  esac
  printf '%s' "$s"
}

# purge old logs
find "$LOG_DIR" -name '*.csv' -mtime "+$RETAIN_DAYS" -delete 2>/dev/null

# --------------------------------------------------- console log discovery
if [ -z "$CONSOLE_LOG" ]; then
  for base in "$TXDATA_ROOT" "$HOME/txData" "$HOME/fivem/txData" /opt/fivem/txData /home; do
    [ -d "$base" ] || continue
    CONSOLE_LOG="$(find "$base" -maxdepth 5 -name fxserver.log -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    [ -n "$CONSOLE_LOG" ] && break
  done
fi
if [ -n "$CONSOLE_LOG" ] && [ -f "$CONSOLE_LOG" ]; then
  log "Console log: $CONSOLE_LOG"
  LOG_OFFSET=$(stat -c%s "$CONSOLE_LOG" 2>/dev/null || echo 0)
else
  log "WARNING: fxserver.log not found - hitch/script-error detection disabled (set CONSOLE_LOG=...)"
  CONSOLE_LOG=""; LOG_OFFSET=0
fi

GATEWAY="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
log "Gateway: ${GATEWAY:-n/a}   External: $EXT1, $EXT2"
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
NCORES=$(nproc 2>/dev/null || echo 1)

# ------------------------------------------------------------- fx process
find_fx_pid() {
  local pid
  pid="$(ss -Hulpn 2>/dev/null | awk -v p=":$SERVER_PORT" '$0 ~ p" " || $0 ~ p"$"' \
        | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
  if [ -z "$pid" ]; then
    pid="$(pgrep -x "$FX_PROCESS" 2>/dev/null | while read -r p; do
             printf '%s %s\n' "$(awk '/^VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0)" "$p"
           done | sort -rn | head -1 | awk '{print $2}')"
  fi
  echo "${pid:-}"
}

# --------------------------------------------------------------- sampling
ping_ms() { # -> integer ms, or -1
  [ -z "${1:-}" ] && { echo -1; return; }
  local out
  out="$(ping -n -c1 -W1 "$1" 2>/dev/null | grep -o 'time=[0-9.]*')" || { echo -1; return; }
  [ -z "$out" ] && { echo -1; return; }
  printf '%.0f\n' "${out#time=}"
}

# rolling ping windows stored as space-separated strings
GW_HIST=""; E1_HIST=""; E2_HIST=""
push_hist() { # varname value -> trimmed window
  local cur="${!1} $2"
  cur="$(echo "$cur" | awk -v w="$PING_WINDOW" '{n=NF; s=""; for(i=(n>w?n-w+1:1); i<=n; i++) s=s" "$i; print substr(s,2)}')"
  printf -v "$1" '%s' "$cur"
}
loss_pct() { # window string -> pct (or -1 if window not full)
  echo "$1" | awk -v w="$PING_WINDOW" '{ if (NF < w) { print -1; exit }
    lost=0; for(i=1;i<=NF;i++) if ($i < 0) lost++; printf "%d\n", 100*lost/NF }'
}

read_cpu_snapshot() { grep '^cpu' /proc/stat; }
cpu_from_snapshots() { # prev cur -> "total maxcore"
  awk 'NR==FNR { for(i=2;i<=9;i++) prev[$1]+=$i; pidle[$1]=$5+$6; next }
       { tot=0; for(i=2;i<=9;i++) tot+=$i; idle=$5+$6
         dt=tot-prev[$1]; di=idle-pidle[$1]
         pct = (dt>0) ? 100*(dt-di)/dt : 0
         if ($1=="cpu") total=pct
         else if (pct>maxc) maxc=pct }
       END { printf "%d %d\n", total, maxc }' "$1" "$2"
}

# /proc/net/snmp Udp header: InDatagrams NoPorts InErrors OutDatagrams ...
udp_snapshot() { awk '/^Udp:/ {l++} l==2 {print $2, $3, $4, $5; exit}' /proc/net/snmp; }
# -> InDatagrams NoPorts InErrors OutDatagrams (cumulative counters)

nic_snapshot() {
  awk -F: '/:/ { iface=$1; gsub(/ /,"",iface); if (iface=="lo") next
                 split($2,a," "); rxb+=a[1]; rxp+=a[2]; txb+=a[9] }
           END { printf "%d %d %d\n", rxb, txb, rxp }' /proc/net/dev
}

majflt_snapshot() { awk '/^pgmajfault/ {print $2}' /proc/vmstat; }

fx_cpu_snapshot() { # pid -> utime+stime ticks
  awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo ""
}

players_json() { # -> "count ms ok"
  local body t ok=1 cnt=0 ms
  body="$(mktemp)"
  t="$(curl -s -m 3 -o "$body" -w '%{time_total}' "http://127.0.0.1:$SERVER_PORT/players.json" 2>/dev/null)" || ok=0
  ms="$(awk -v t="${t:-0}" 'BEGIN { printf "%d", t*1000 }')"
  if [ "$ok" = 1 ]; then
    if command -v jq >/dev/null 2>&1; then
      cnt="$(jq 'length' "$body" 2>/dev/null || echo 0)"
    else
      cnt="$(grep -o '"id":' "$body" 2>/dev/null | wc -l)"
    fi
  else
    cnt=-1
  fi
  rm -f "$body"
  echo "$cnt $ms $ok"
}

# ----------------------------------------------------------------- alerts
declare -A LAST_ALERT
RECENT_ALERTS=()   # json objects, newest last
CYCLE_ALERTS=""
raise_alert() { # severity cause detail
  local now epoch
  epoch=$(date +%s)
  if [ -n "${LAST_ALERT[$2]:-}" ] && [ $((epoch - LAST_ALERT[$2])) -lt "$ALERT_COOLDOWN" ]; then return; fi
  LAST_ALERT[$2]=$epoch
  now="$(date '+%F %T')"
  CYCLE_ALERTS="${CYCLE_ALERTS:+$CYCLE_ALERTS|}$2"
  csv_line alerts "$ALERTS_HEADER" "$now,$1,$2,$(csv_escape "$3")"
  log "ALERT [$1] $2 :: $3"
  local esc="${3//\\/\\\\}"; esc="${esc//\"/\\\"}"
  RECENT_ALERTS+=("{\"ts\":\"$(date +%H:%M:%S)\",\"severity\":\"$1\",\"cause\":\"$2\",\"detail\":\"$esc\"}")
  [ "${#RECENT_ALERTS[@]}" -gt 15 ] && RECENT_ALERTS=("${RECENT_ALERTS[@]:1}")
  if [ -n "$DISCORD_WEBHOOK" ] && [ "$1" != "INFO" ]; then
    curl -s -m 3 -H 'Content-Type: application/json' \
      -d "{\"content\":\"**[$1] $2**\\n$esc\"}" "$DISCORD_WEBHOOK" >/dev/null 2>&1 &
  fi
}

# ------------------------------------------------------------------ state
PREV_CPU="$(mktemp)"; CUR_CPU="$(mktemp)"
trap 'rm -f "$PREV_CPU" "$CUR_CPU"' EXIT
read_cpu_snapshot > "$PREV_CPU"
read -r P_UDP_IN P_UDP_NP P_UDP_ERR P_UDP_OUT <<< "$(udp_snapshot)"
read -r P_RXB P_TXB P_RXP <<< "$(nic_snapshot)"
P_MAJFLT="$(majflt_snapshot)"
PREV_FX_PID=""; PREV_FX_TICKS=""
PREV_PLAYERS=-1
CORE_HOT_STREAK=0
GW_ANSWERED=0
EMA_UDP=""; EMA_MBPS=""
HIST=()   # dashboard history ring

log "fivem-sentinel started. Interval=${INTERVAL}s Port=$SERVER_PORT Cores=$NCORES Logs=$LOG_DIR"

# ================================================================ main loop
while true; do
  CYCLE_START=$(date +%s)
  TS="$(date '+%F %T')"
  CYCLE_ALERTS=""

  # ---- cpu ----
  read_cpu_snapshot > "$CUR_CPU"
  read -r CPU_TOTAL CPU_MAX <<< "$(cpu_from_snapshots "$PREV_CPU" "$CUR_CPU")"
  cp "$CUR_CPU" "$PREV_CPU"

  # ---- memory ----
  RAM_AVAIL=$(awk '/^MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
  MAJFLT="$(majflt_snapshot)"
  PAGES_SEC=$(( (MAJFLT - P_MAJFLT) / INTERVAL )); P_MAJFLT="$MAJFLT"

  # ---- udp / nic ----
  read -r UDP_IN UDP_NP UDP_ERR UDP_OUT <<< "$(udp_snapshot)"
  # counters wrap/reset on reboot; guard against negative deltas
  UDP_IN_PPS=$(( (UDP_IN - P_UDP_IN) / INTERVAL ))
  UDP_OUT_PPS=$(( (UDP_OUT - P_UDP_OUT) / INTERVAL ))
  UDP_NP_PPS=$(( (UDP_NP - P_UDP_NP) / INTERVAL ))
  UDP_ERR_D=$(( UDP_ERR - P_UDP_ERR ))
  P_UDP_IN="$UDP_IN"; P_UDP_NP="$UDP_NP"; P_UDP_ERR="$UDP_ERR"; P_UDP_OUT="$UDP_OUT"

  read -r RXB TXB RXP <<< "$(nic_snapshot)"
  NIC_IN_MBPS=$(awk -v a="$RXB" -v b="$P_RXB" -v i="$INTERVAL" 'BEGIN {printf "%.2f", (a-b)*8/1000000/i}')
  NIC_OUT_MBPS=$(awk -v a="$TXB" -v b="$P_TXB" -v i="$INTERVAL" 'BEGIN {printf "%.2f", (a-b)*8/1000000/i}')
  NIC_IN_PPS=$(( (RXP - P_RXP) / INTERVAL ))
  P_RXB="$RXB"; P_TXB="$TXB"; P_RXP="$RXP"

  # ---- fx process ----
  FX_PID="$(find_fx_pid)"
  FX_CPU=-1; FX_RAM=-1; FX_THREADS=-1; FX_HANDLES=-1
  if [ -n "$FX_PID" ] && [ -d "/proc/$FX_PID" ]; then
    FX_RAM=$(awk '/^VmRSS/ {printf "%d", $2/1024}' "/proc/$FX_PID/status" 2>/dev/null || echo -1)
    FX_THREADS=$(awk '/^Threads/ {print $2}' "/proc/$FX_PID/status" 2>/dev/null || echo -1)
    FX_HANDLES=$(ls "/proc/$FX_PID/fd" 2>/dev/null | wc -l)
    TICKS="$(fx_cpu_snapshot "$FX_PID")"
    if [ "$FX_PID" = "$PREV_FX_PID" ] && [ -n "$PREV_FX_TICKS" ] && [ -n "$TICKS" ]; then
      FX_CPU=$(awk -v t="$TICKS" -v p="$PREV_FX_TICKS" -v hz="$CLK_TCK" -v i="$INTERVAL" -v c="$NCORES" \
        'BEGIN { v=100*(t-p)/hz/i/c; printf "%.1f", (v<0)?-1:v }')
    fi
    if [ -n "$PREV_FX_PID" ] && [ "$PREV_FX_PID" != "$FX_PID" ]; then
      raise_alert CRIT SERVER_RESTARTED "FXServer PID changed $PREV_FX_PID -> $FX_PID (crash or txAdmin restart)"
    fi
    PREV_FX_TICKS="$TICKS"; PREV_FX_PID="$FX_PID"
  else
    [ -n "$PREV_FX_PID" ] && raise_alert CRIT SERVER_DOWN "FXServer process not found / not bound to game port"
    PREV_FX_PID=""; PREV_FX_TICKS=""; FX_PID=-1
  fi

  # ---- players.json ----
  read -r PLAYERS HTTP_MS HTTP_OK <<< "$(players_json)"

  # ---- pings ----
  PING_GW="$(ping_ms "$GATEWAY")"
  PING_E1="$(ping_ms "$EXT1")"
  PING_E2="$(ping_ms "$EXT2")"
  push_hist GW_HIST "$PING_GW"; push_hist E1_HIST "$PING_E1"; push_hist E2_HIST "$PING_E2"
  GW_LOSS=-1; [ -n "$GATEWAY" ] && GW_LOSS="$(loss_pct "$GW_HIST")"
  E1_LOSS="$(loss_pct "$E1_HIST")"
  E2_LOSS="$(loss_pct "$E2_HIST")"

  # gateways that never answer ICMP (common in datacenters): disable, don't false-alarm
  if [ -n "$GATEWAY" ] && [ "$GW_ANSWERED" = 0 ]; then
    if [ "$PING_GW" -ge 0 ]; then GW_ANSWERED=1
    elif [ "$GW_LOSS" = 100 ] && { [ "$E1_LOSS" != -1 ] && [ "$E1_LOSS" -lt 50 ]; }; then
      log "NOTE: gateway $GATEWAY does not answer ICMP - disabling gateway checks."
      csv_line alerts "$ALERTS_HEADER" "$TS,INFO,GATEWAY_ICMP_BLOCKED,$(csv_escape "Gateway $GATEWAY does not respond to ping; gateway checks disabled automatically.")"
      GATEWAY=""
    fi
  fi

  # ---- console log tail ----
  HITCHES=0; SCRIPT_ERRORS=0; TIMEOUTS=0
  if [ -n "$CONSOLE_LOG" ] && [ -f "$CONSOLE_LOG" ]; then
    SIZE=$(stat -c%s "$CONSOLE_LOG" 2>/dev/null || echo 0)
    [ "$SIZE" -lt "$LOG_OFFSET" ] && LOG_OFFSET=0
    if [ "$SIZE" -gt "$LOG_OFFSET" ]; then
      CHUNK="$(tail -c +$((LOG_OFFSET+1)) "$CONSOLE_LOG" 2>/dev/null | head -c 262144)"
      LOG_OFFSET="$SIZE"
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        short="$(printf '%.220s' "$line")"
        case "$line" in
          *'hitch warning'*)
            HITCHES=$((HITCHES+1))
            csv_line events "$EVENTS_HEADER" "$TS,hitch,,$(csv_escape "$short")" ;;
          *'SCRIPT ERROR'*|*'error running'*|*'Error running system event'*|*'Failed to load script'*)
            SCRIPT_ERRORS=$((SCRIPT_ERRORS+1))
            res="$(printf '%s' "$line" | grep -o '@[A-Za-z0-9_.-]*/' | head -1 | tr -d '@/')"
            csv_line events "$EVENTS_HEADER" "$TS,script_error,$res,$(csv_escape "$short")" ;;
          *'timed out'*|*'Timed out'*)
            TIMEOUTS=$((TIMEOUTS+1))
            csv_line events "$EVENTS_HEADER" "$TS,timeout,,$(csv_escape "$short")" ;;
        esac
      done <<< "$CHUNK"
    fi
  fi

  # ---- flood baselines (EMA over ~100 samples) ----
  UDP_SPIKE=0; MBPS_SPIKE=0
  [ -z "$EMA_UDP" ] && EMA_UDP="$UDP_IN_PPS"
  read -r UDP_SPIKE EMA_UDP <<< "$(awk -v v="$UDP_IN_PPS" -v e="$EMA_UDP" -v fl="$T_UDP_SPIKE_FLOOR" -v fa="$T_UDP_SPIKE_FACTOR" \
      'BEGIN { s = (v>fl && v>e*fa) ? 1 : 0; if (!s) e = 0.95*e + 0.05*v; printf "%d %.1f", s, e }')"
  [ -z "$EMA_MBPS" ] && EMA_MBPS="$NIC_IN_MBPS"
  read -r MBPS_SPIKE EMA_MBPS <<< "$(awk -v v="$NIC_IN_MBPS" -v e="$EMA_MBPS" -v fl="$T_MBPS_SPIKE_FLOOR" -v fa="$T_MBPS_SPIKE_FACTOR" \
      'BEGIN { s = (v>fl && v>e*fa) ? 1 : 0; if (!s) e = 0.95*e + 0.05*v; printf "%d %.1f", s, e }')"
  NOPORT_SPIKE=0; [ "$UDP_NP_PPS" -ge "$T_NOPORT_SPIKE" ] && NOPORT_SPIKE=1

  # ---- condition flags ----
  [ "$CPU_MAX" -ge "$T_CPU_CORE_HIGH" ] && CORE_HOT_STREAK=$((CORE_HOT_STREAK+1)) || CORE_HOT_STREAK=0
  CORE_HOT=0; [ "$CORE_HOT_STREAK" -ge "$T_CPU_CORE_SAMPLES" ] && CORE_HOT=1
  TOTAL_HOT=0; [ "$CPU_TOTAL" -ge "$T_CPU_TOTAL_HIGH" ] && TOTAL_HOT=1
  RAM_LOW=0; [ "$RAM_AVAIL" -le "$T_RAM_LOW_MB" ] && RAM_LOW=1
  RAM_THRASH=0; [ "$PAGES_SEC" -ge "$T_MAJFLT_HIGH" ] && RAM_THRASH=1
  HTTP_SLOW=0; [ "$HTTP_OK" = 1 ] && [ "$HTTP_MS" -ge "$T_HTTP_SLOW_MS" ] && HTTP_SLOW=1
  HTTP_DEAD=0; [ "$HTTP_OK" = 0 ] && [ "$FX_PID" != -1 ] && HTTP_DEAD=1
  E1_BAD=0; { [ "$E1_LOSS" != -1 ] && [ "$E1_LOSS" -ge "$T_LOSS_HIGH_PCT" ]; } || { [ "$PING_E1" -ge 0 ] && [ "$PING_E1" -gt "$T_PING_HIGH_MS" ]; } && E1_BAD=1
  E2_BAD=0; { [ "$E2_LOSS" != -1 ] && [ "$E2_LOSS" -ge "$T_LOSS_HIGH_PCT" ]; } || { [ "$PING_E2" -ge 0 ] && [ "$PING_E2" -gt "$T_PING_HIGH_MS" ]; } && E2_BAD=1
  NET_UP=0; [ "$E1_BAD" = 1 ] && [ "$E2_BAD" = 1 ] && NET_UP=1
  NET_LOCAL=0
  if [ -n "$GATEWAY" ] && [ "$GW_ANSWERED" = 1 ] && [ "$GW_LOSS" != -1 ] && [ "$GW_LOSS" -ge "$T_LOSS_HIGH_PCT" ]; then NET_LOCAL=1; fi
  FLOOD=0
  if { [ "$UDP_SPIKE" = 1 ] && [ "$MBPS_SPIKE" = 1 ]; } || [ "$NOPORT_SPIKE" = 1 ]; then FLOOD=1; fi

  # ---- standing alerts ----
  [ "$FLOOD" = 1 ] && raise_alert CRIT POSSIBLE_DDOS \
    "UDP flood pattern: in=$UDP_IN_PPS pps (baseline ~${EMA_UDP%.*}), noPort=$UDP_NP_PPS pps, inbound=$NIC_IN_MBPS Mbps (baseline ~$EMA_MBPS)"
  [ "$CORE_HOT" = 1 ] && raise_alert WARN CPU_CORE_SATURATED \
    "A core pegged at ${CPU_MAX}% for ${T_CPU_CORE_SAMPLES}+ samples (FXServer CPU ${FX_CPU}%). FiveM's main thread is single-core bound - this hitches the server even with idle cores."
  [ "$TOTAL_HOT" = 1 ] && raise_alert WARN CPU_TOTAL_HIGH "Total CPU ${CPU_TOTAL}% (FXServer ${FX_CPU}%)"
  { [ "$RAM_LOW" = 1 ] || [ "$RAM_THRASH" = 1 ]; } && raise_alert WARN RAM_PRESSURE \
    "Available RAM ${RAM_AVAIL} MB, major faults/sec ${PAGES_SEC}, FXServer ${FX_RAM} MB"
  [ "$NET_LOCAL" = 1 ] && raise_alert CRIT LOCAL_NETWORK_LOSS \
    "Packet loss to gateway ${GW_LOSS}% (host/NIC problem, not the internet)"
  [ "$NET_LOCAL" = 0 ] && [ "$NET_UP" = 1 ] && raise_alert WARN UPSTREAM_NETWORK \
    "External path degraded on ALL targets: $EXT1 loss ${E1_LOSS}%/${PING_E1} ms, $EXT2 loss ${E2_LOSS}%/${PING_E2} ms"
  [ "$HTTP_DEAD" = 1 ] && raise_alert CRIT SERVER_UNRESPONSIVE \
    "FXServer process alive but players.json not answering (main thread stalled)"
  [ "$HTTP_DEAD" = 0 ] && [ "$HTTP_SLOW" = 1 ] && raise_alert WARN SERVER_THREAD_SLOW \
    "players.json took ${HTTP_MS} ms - server thread hitching"
  [ "$HITCHES" -gt 0 ] && [ "$CORE_HOT" = 0 ] && raise_alert WARN SCRIPT_HITCH \
    "$HITCHES hitch warning(s) without core saturation - a resource is blocking the tick (see events CSV)"

  # ---- mass player-drop correlation ----
  if [ "$PREV_PLAYERS" -ge 0 ] && [ "$PLAYERS" -ge 0 ]; then
    DROPPED=$((PREV_PLAYERS - PLAYERS))
    MASS=0
    if [ "$DROPPED" -ge "$T_DROP_COUNT" ] && [ "$PREV_PLAYERS" -gt 0 ] \
       && [ $((100*DROPPED/PREV_PLAYERS)) -ge "$T_DROP_PCT" ]; then MASS=1; fi
    [ "$TIMEOUTS" -ge "$T_DROP_COUNT" ] && MASS=1
    if [ "$MASS" = 1 ]; then
      S=""
      [ "$FLOOD" = 1 ] && S="$S+DDOS/FLOOD"
      [ "$NET_LOCAL" = 1 ] && S="$S+LOCAL-NETWORK"
      [ "$NET_UP" = 1 ] && S="$S+UPSTREAM-NETWORK"
      { [ "$CORE_HOT" = 1 ] || [ "$TOTAL_HOT" = 1 ]; } && S="$S+CPU"
      { [ "$RAM_LOW" = 1 ] || [ "$RAM_THRASH" = 1 ]; } && S="$S+RAM"
      { [ "$HITCHES" -gt 0 ] || [ "$SCRIPT_ERRORS" -gt 0 ]; } && S="$S+SCRIPT"
      { [ "$HTTP_DEAD" = 1 ] || [ "$HTTP_SLOW" = 1 ]; } && S="$S+SERVER-THREAD-STALL"
      S="${S#+}"
      [ -z "$S" ] && S="UNKNOWN (nothing local abnormal - suspect provider edge filtering or player-side routes; check your host's DDoS console for this timestamp)"
      SEV=WARN; case "$S" in *DDOS*|*LOCAL-NETWORK*) SEV=CRIT ;; esac
      raise_alert "$SEV" MASS_PLAYER_DROP \
        "$PREV_PLAYERS -> $PLAYERS players ($DROPPED lost, $TIMEOUTS timeout lines). Suspected: ${S//+/ + }"
    fi
  fi
  [ "$PLAYERS" -ge 0 ] && PREV_PLAYERS="$PLAYERS"

  # ---- write metrics row ----
  csv_line metrics "$METRICS_HEADER" \
"$TS,$PLAYERS,$HTTP_MS,$HTTP_OK,$CPU_TOTAL,$CPU_MAX,$FX_CPU,$RAM_AVAIL,$FX_RAM,$PAGES_SEC,$UDP_IN_PPS,$UDP_OUT_PPS,$UDP_NP_PPS,$UDP_ERR_D,$NIC_IN_MBPS,$NIC_OUT_MBPS,$NIC_IN_PPS,$PING_GW,$PING_E1,$PING_E2,$GW_LOSS,$E1_LOSS,$E2_LOSS,$FX_PID,$FX_THREADS,$FX_HANDLES,$HITCHES,$SCRIPT_ERRORS,$TIMEOUTS,$(csv_escape "$CYCLE_ALERTS")"

  # ---- live.json for the dashboard ----
  HHMMSS="$(date +%H:%M:%S)"
  HIST+=("{\"t\":\"$HHMMSS\",\"p\":$PLAYERS,\"cm\":$CPU_MAX,\"ct\":$CPU_TOTAL,\"fc\":$FX_CPU,\"ui\":$UDP_IN_PPS,\"un\":$UDP_NP_PPS,\"p1\":$PING_E1,\"p2\":$PING_E2}")
  [ "${#HIST[@]}" -gt 360 ] && HIST=("${HIST[@]:1}")
  {
    printf '{"now":{"ts":"%s","players":%s,"httpMs":%s,"cpuMax":%s,"fxCpu":%s,"ramAvail":%s,"udpIn":%s,"pingExt":%s},' \
      "$HHMMSS" "$PLAYERS" "$HTTP_MS" "$CPU_MAX" "$FX_CPU" "$RAM_AVAIL" "$UDP_IN_PPS" "$PING_E1"
    printf '"hist":['
    (IFS=,; printf '%s' "${HIST[*]}")
    printf '],"alerts":['
    if [ "${#RECENT_ALERTS[@]}" -gt 0 ]; then
      # newest first
      for ((idx=${#RECENT_ALERTS[@]}-1; idx>=0; idx--)); do
        printf '%s' "${RECENT_ALERTS[$idx]}"
        [ "$idx" -gt 0 ] && printf ','
      done
    fi
    printf ']}'
  } > "$LOG_DIR/live.json.tmp" && mv "$LOG_DIR/live.json.tmp" "$LOG_DIR/live.json"

  # ---- sleep out the interval ----
  ELAPSED=$(( $(date +%s) - CYCLE_START ))
  SLEEP=$(( INTERVAL - ELAPSED ))
  [ "$SLEEP" -lt 1 ] && SLEEP=1
  sleep "$SLEEP"
done
