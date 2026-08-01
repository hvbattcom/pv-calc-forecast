#!/usr/bin/env bash
# deploy.sh – Deploy pv-calc-forecast API service
# Run with: sudo ./deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Help / flags ──────────────────────────────────────────────────────────────

VERBOSE=0
RUN_SERVICE_AS=""
LATITUDE=""
LONGITUDE=""
TIMEZONE=""
FORECAST="open-meteo"
PV_STRINGS=()
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            cat <<'EOF'
Usage: sudo ./deploy.sh [-v|--verbose] [--run-service-as=<user>]
                         [--latitude=<lat> --longitude=<lon>] [--timezone=<tz>]
                         [--forecast=<source>] [--pv-string=NAME:CAPACITY:TILT:AZIMUTH ...]

One-time deployment for pv-calc-forecast. Steps performed:
  1. Install system packages  (python3 python3-pip)
  2. Install Python packages  (from requirements.txt)
  3. Ensure config.cfg exists (generated from --latitude/--longitude/
     --pv-string if given, else copied from config.cfg.example)
  4. Generate + install pv-calc-forecast-api.service
  5. daemon-reload
  6. Start service
  7. Health check: curl localhost:<port>/

Safe to re-run – all steps are idempotent, except step 3, which only
writes config.cfg once and never overwrites an existing one.

  -v, --verbose             Full shell tracing (set -x) plus unfiltered
                             apt/pip output, for debugging a failed run.
  --run-service-as=<user>   Systemd unit's User=. Defaults to whoever ran
                             sudo (falls back to $USER if that's unset).
  --latitude=<lat>          Site latitude. Requires --longitude and at
  --longitude=<lon>         least one --pv-string to take effect.
  --timezone=<tz>           Optional -- auto-detected from coordinates if
                             omitted (see pv-calc-forecast.py).
  --forecast=<source>       Default forecast source written to config.cfg:
                             forecast-solar, open-meteo (default), solcast.
  --pv-string=NAME:CAPACITY:TILT:AZIMUTH
                             Define one PV string. Repeatable (PV1, PV2,
                             ...) -- same NAME:CAPACITY:TILT:AZIMUTH format
                             as pv-calc-forecast.py's own --string flag.
                             Example: --pv-string=PV1:15.0:30:205

If config.cfg doesn't exist yet and --latitude/--longitude/--pv-string are
all given, it's generated straight from them. Otherwise (nothing passed,
or an incomplete combination) it's created from config.cfg.example with
placeholder coordinates and PV strings instead -- the service will still
start and run fine, but the forecast it serves is meaningless until you
edit config.cfg with real site data.
EOF
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=1
            ;;
        --run-service-as=*)
            RUN_SERVICE_AS="${arg#*=}"
            ;;
        --latitude=*)
            LATITUDE="${arg#*=}"
            ;;
        --longitude=*)
            LONGITUDE="${arg#*=}"
            ;;
        --timezone=*)
            TIMEZONE="${arg#*=}"
            ;;
        --forecast=*)
            FORECAST="${arg#*=}"
            ;;
        --pv-string=*)
            PV_STRINGS+=("${arg#*=}")
            ;;
    esac
done

(( VERBOSE )) && set -x

# ── Helpers ───────────────────────────────────────────────────────────────────

ok()    { printf "  \033[32m✓\033[0m  %s\n" "$*"; }
fail()  { printf "  \033[31m✗\033[0m  %s\n" "$*" >&2; }
step()  { printf "\n\033[1;36m══ %s\033[0m\n" "$*"; }
die()   { fail "$*"; exit 1; }
debug() { (( VERBOSE )) && printf "  \033[2m[debug] %s\033[0m\n" "$*" || true; }

# Read a single value from an INI file: ini_get <file> <section> <key>
ini_get() {
    awk -F' *= *' -v sec="[$2]" -v k="$3" '
        /^\[/ { in_sec = ($0 == sec) }
        in_sec && $1 == k { print $2; exit }
    ' "$1"
}

# ── Sudo guard ────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Must run as root:  sudo $0"
SERVICE_USER="${RUN_SERVICE_AS:-${SUDO_USER:-$USER}}"
debug "service user: $SERVICE_USER"

for pv in "${PV_STRINGS[@]}"; do
    [[ "$pv" =~ ^[^:]+:[^:]+:[^:]+:[^:]+$ ]] \
        || die "--pv-string must be NAME:CAPACITY:TILT:AZIMUTH, got: $pv"
done

# ── Step 1: System packages ───────────────────────────────────────────────────

step "1/7  System packages"
APT_PKGS=(python3 python3-pip)
MISSING_APT=()
for pkg in "${APT_PKGS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING_APT+=("$pkg")
done

if (( ${#MISSING_APT[@]} )); then
    echo "  Installing: ${MISSING_APT[*]}"
    if (( VERBOSE )); then
        apt-get install -y "${MISSING_APT[@]}"
    else
        apt-get install -y "${MISSING_APT[@]}" 2>&1 \
            | grep -E '^(Get:|Unpacking|Setting up|Processing)' \
            | sed 's/^/    /' || true
    fi
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
    if (( VERBOSE )); then
        pip install "${MISSING_PY[@]}" --break-system-packages || die "pip install failed"
    else
        pip install -q "${MISSING_PY[@]}" --break-system-packages || die "pip install failed"
    fi
    ok "Installed: ${MISSING_PY[*]}"
else
    ok "All Python packages already present"
fi

# ── Step 3: Config ─────────────────────────────────────────────────────────────

step "3/7  Config"
CONFIG="$SCRIPT_DIR/config.cfg"
CONFIG_JUST_CREATED=0
CONFIG_IS_PLACEHOLDER=0

if [[ -f "$CONFIG" ]]; then
    ok "config.cfg already present -- left untouched"
elif [[ -n "$LATITUDE" && -n "$LONGITUDE" && ${#PV_STRINGS[@]} -gt 0 ]]; then
    {
        echo "# Generated by deploy.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "[system]"
        echo "latitude  = $LATITUDE"
        echo "longitude = $LONGITUDE"
        [[ -n "$TIMEZONE" ]] && echo "timezone  = $TIMEZONE"
        echo "forecast = $FORECAST"
        echo "format   = prometheus"
        for pv in "${PV_STRINGS[@]}"; do
            IFS=':' read -r pv_name pv_capacity pv_tilt pv_azimuth <<< "$pv"
            echo ""
            echo "[$pv_name]"
            echo "capacity = $pv_capacity"
            echo "tilt     = $pv_tilt"
            echo "azimuth  = $pv_azimuth"
        done
    } > "$CONFIG"
    CONFIG_JUST_CREATED=1
    ok "config.cfg generated from --latitude/--longitude/--pv-string (${#PV_STRINGS[@]} string(s), forecast=${FORECAST})"
else
    if [[ -n "$LATITUDE" || -n "$LONGITUDE" || ${#PV_STRINGS[@]} -gt 0 ]]; then
        fail "Incomplete site data (--latitude, --longitude and at least one --pv-string are all required together) -- falling back to placeholder config.cfg"
    fi
    cp "$SCRIPT_DIR/config.cfg.example" "$CONFIG"
    CONFIG_JUST_CREATED=1
    CONFIG_IS_PLACEHOLDER=1
    ok "config.cfg created from config.cfg.example (placeholder site data)"
fi

# ── Step 4: Generate service file ─────────────────────────────────────────────

step "4/7  Generate pv-calc-forecast-api.service"

API_PORT=$(ini_get "$CONFIG" system port)
API_PORT=${API_PORT:-5001}
debug "port=$API_PORT workdir=$SCRIPT_DIR"

SERVICE_FILE="$SCRIPT_DIR/pv-calc-forecast-api.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Solar PV Forecast API
Documentation=https://github.com/hvbattcom/pv-calc-forecast
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
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

ok "pv-calc-forecast-api.service written (port ${API_PORT}, user ${SERVICE_USER})"

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
# First startup imports pandas/pvlib/timezonefinder, which can take well
# over a couple of seconds on a Radxa-class ARM board -- poll instead of
# guessing a fixed sleep.
HEALTHY=0
for i in $(seq 1 20); do
    if curl -sf "http://localhost:${API_PORT}/" >/dev/null 2>&1; then
        HEALTHY=1
        break
    fi
    debug "waiting for API (attempt $i/20)"
    sleep 1
done

if (( HEALTHY )); then
    ok "API responding on :${API_PORT}  →  http://localhost:${API_PORT}/"
else
    fail "API did not respond on :${API_PORT} within 20s"
    echo "  Check logs:  journalctl -u pv-calc-forecast-api -n 30" >&2
    echo "  Or re-run with -v/--verbose for full output" >&2
    exit 1
fi

if (( CONFIG_IS_PLACEHOLDER )); then
    printf "\n\033[33mDeployment complete, but config.cfg still has placeholder data.\033[0m\n"
    printf "Edit %s with your real latitude/longitude and PV strings, then run:\n" "$CONFIG"
    printf "  sudo systemctl restart pv-calc-forecast-api\n"
else
    printf "\n\033[32mDeployment complete.\033[0m\n"
fi
