#!/usr/bin/env bash
#
# Installs fivem-sentinel as systemd services:
#   fivem-sentinel.service       - the monitor (always)
#   fivem-sentinel-dash.service  - the live dashboard on port 8123 (optional)
#
# Usage:
#   sudo ./install.sh [--user <user>] [--no-dashboard]
#   sudo ./install.sh --uninstall
#
# Run the monitor as the same user that runs your FiveM server so it can read
# /proc/<pid> and the txData console log.

set -eu

RUN_USER="${SUDO_USER:-$(whoami)}"
WITH_DASH=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --user) RUN_USER="$2"; shift 2 ;;
    --no-dashboard) WITH_DASH=0; shift ;;
    --uninstall)
      systemctl disable --now fivem-sentinel.service fivem-sentinel-dash.service 2>/dev/null || true
      rm -f /etc/systemd/system/fivem-sentinel.service /etc/systemd/system/fivem-sentinel-dash.service
      systemctl daemon-reload
      echo "fivem-sentinel services removed."
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
chmod +x "$SCRIPT_DIR/fivem-monitor.sh"

cat > /etc/systemd/system/fivem-sentinel.service <<EOF
[Unit]
Description=fivem-sentinel FiveM diagnostics monitor
After=network-online.target

[Service]
Type=simple
User=$RUN_USER
ExecStart=/usr/bin/env bash $SCRIPT_DIR/fivem-monitor.sh
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
EOF

if [ "$WITH_DASH" = 1 ]; then
cat > /etc/systemd/system/fivem-sentinel-dash.service <<EOF
[Unit]
Description=fivem-sentinel live dashboard
After=fivem-sentinel.service

[Service]
Type=simple
User=$RUN_USER
ExecStart=/usr/bin/env python3 $SCRIPT_DIR/dashboard.py --logs $SCRIPT_DIR/logs
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now fivem-sentinel.service
[ "$WITH_DASH" = 1 ] && systemctl enable --now fivem-sentinel-dash.service

echo "Installed. Check with:  systemctl status fivem-sentinel"
echo "Logs land in:           $SCRIPT_DIR/logs/"
[ "$WITH_DASH" = 1 ] && echo "Dashboard:              http://localhost:8123 (on the server)"
echo "Daily report:           python3 $SCRIPT_DIR/../tools/generate-report.py --logs $SCRIPT_DIR/logs"
