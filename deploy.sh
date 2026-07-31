#!/usr/bin/env bash
# deploy.sh – Deploy pv-calc-forecast API service
# Run with: sudo ./deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Help ──────────────────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<'EOF'
Usage: sudo ./deploy.sh

One-time deployment for pv-calc-forecast. Steps performed:
  1. Install system packages  (python3 python3-pip)
  2. Install Python packages  (from requirements.txt)
  3. Ensure config.cfg exists (copied from config.cfg.example if missing)
  4. Generate + install pv-calc-forecast-api.service
  5. daemon-reload
  6. Start service
  7. Health check: curl localhost:<port>/

Safe to re-run – all steps are idempotent, except step 3, which only
copies the example config once and never overwrites an existing one.

Unlike solar-management, there's nothing to auto-discover here: if
config.cfg didn't exist yet, it's created from the example with
placeholder coordinates and PV strings. The service will start and run
fine either way -- but until you edit config.cfg with your real site
data, the forecast it serves is meaningless.
EOF
            exit 0
            ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

ok()   { printf "  \033[32m✓\033[0m  %s\n" "$*"; }
fail() { printf "  \033[31m✗\033[0m  %s\n" "$*" >&2; }
step() { printf "\n\033[1;36m══ %s\033[0m\n" "$*"; }
die()  { fail "$*"; exit 1; }

# Read a single value from an INI file: ini_get <file> <section> <key>
ini_get() {
    awk -F' *= *' -v sec="[$2]" -v k="$3" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && $1 == k { print $2; exit }
    ' "$1"
}

# ── Sudo guard ────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Must run as root:  sudo $0"

# ── Step 1: System packages ───────────────────────────────────────────────────

step "1/7  System packages"
APT_PKGS=(python3 python3-pip)
MISSING_APT=()
for pkg in "${APT_PKGS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING_APT+=("$pkg")
done

if (( ${#MISSING_APT[@]} )); then
    echo "  Installing: ${MISSING_APT[*]}"
    apt-get install -y "${MISSING_APT[@]}" 2>&1 \
        | grep -E '^(Get:|Unpacking|Setting up|Processing)' \
        | sed 's/^/    /' || true
    ok "Installed: ${MISSING_APT[*]}"
else
    ok "All apt packages already present"
fi

# ── Step 2: Python packages ───────────────────────────────────────────────────

step "2/7  Python packages"
REQUIREMENTS="$SCRIPT_DIR/requirements.txt"
[[ -f "$REQUIREMENTS" ]] || die "requirements.txt not found at $REQUIREMENTS"

MISSING_PY=()
while IFS= read -r req; do
    [[ -z "$req" || "$req" == \#* ]] && continue
    pkg=$(echo "$req" | sed 's/[>=<!].*//')
    python3 -c "import $pkg" &>/dev/null || MISSING_PY+=("$req")
done < "$REQUIREMENTS"

if (( ${#MISSING_PY[@]} )); then
    echo "  Installing: ${MISSING_PY[*]}"
    pip install -q "${MISSING_PY[@]}" --break-system-packages || die "pip install failed"
    ok "Installed: ${MISSING_PY[*]}"
else
    ok "All Python packages already present"
fi

# ── Step 3: Config ─────────────────────────────────────────────────────────────

step "3/7  Config"
CONFIG="$SCRIPT_DIR/config.cfg"
CONFIG_JUST_CREATED=0

if [[ -f "$CONFIG" ]]; then
    ok "config.cfg already present -- left untouched"
else
    cp "$SCRIPT_DIR/config.cfg.example" "$CONFIG"
    CONFIG_JUST_CREATED=1
    ok "config.cfg created from config.cfg.example (placeholder site data)"
fi

# ── Step 4: Generate service file ─────────────────────────────────────────────

step "4/7  Generate pv-calc-forecast-api.service"

API_PORT=$(ini_get "$CONFIG" system port)
API_PORT=${API_PORT:-5001}

SERVICE_FILE="$SCRIPT_DIR/pv-calc-forecast-api.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Solar PV Forecast API
Documentation=https://github.com/hvbattcom/pv-calc-forecast
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=solar
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/usr/bin/python3 ${SCRIPT_DIR}/pv-calc-forecast-api.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pv-calc-forecast-api

[Install]
WantedBy=multi-user.target
EOF

ok "pv-calc-forecast-api.service written (port ${API_PORT}, user solar)"

# ── Step 5: Install + enable ──────────────────────────────────────────────────

step "5/7  Install service"
cp "$SERVICE_FILE" /etc/systemd/system/pv-calc-forecast-api.service
systemctl enable pv-calc-forecast-api --quiet
ok "Installed and enabled /etc/systemd/system/pv-calc-forecast-api.service"

# ── Step 6: daemon-reload + start ─────────────────────────────────────────────

step "6/7  daemon-reload + start"
systemctl daemon-reload
systemctl restart pv-calc-forecast-api
ok "pv-calc-forecast-api started"

# ── Step 7: Health check ──────────────────────────────────────────────────────

step "7/7  Health check"
sleep 2
if curl -sf "http://localhost:${API_PORT}/" >/dev/null; then
    ok "API responding on :${API_PORT}  →  http://localhost:${API_PORT}/"
else
    fail "API did not respond on :${API_PORT}"
    echo "  Check logs:  journalctl -u pv-calc-forecast-api -n 30" >&2
    exit 1
fi

if (( CONFIG_JUST_CREATED )); then
    printf "\n\033[33mDeployment complete, but config.cfg still has placeholder data.\033[0m\n"
    printf "Edit %s with your real latitude/longitude and PV strings, then run:\n" "$CONFIG"
    printf "  sudo systemctl restart pv-calc-forecast-api\n"
else
    printf "\n\033[32mDeployment complete.\033[0m\n"
fi
