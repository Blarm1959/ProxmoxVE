#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/Blarm1959/ProxmoxVE/refs/heads/Dispatcharr/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: Blarm1959
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Dispatcharr/Dispatcharr

APP="Dispatcharr"
var_tags="${var_tags:-}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  ## Blarm1959 Start ##

  # Variables
  DISPATCH_USER="dispatcharr"
  DISPATCH_GROUP="dispatcharr"
  APP_DIR="/opt/dispatcharr"

  POSTGRES_DB="dispatcharr"
  POSTGRES_USER="dispatch"
  POSTGRES_PASSWORD="secret"

  NGINX_HTTP_PORT="9191"
  WEBSOCKET_PORT="8001"
  GUNICORN_RUNTIME_DIR="dispatcharr"
  GUNICORN_SOCKET="/run/${GUNICORN_RUNTIME_DIR}/dispatcharr.sock"
  PYTHON_BIN="$(command -v python3)"


  # Check if installation is present
  if [[ ! -d "$APP_DIR" ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "dispatcharr" "Dispatcharr/Dispatcharr"; then
    msg_error "No ${APP} GitHub Found!"
    exit
  fi

  # --- Version check using version.py on main vs local ---
  REMOTE_VERSION="$($STD curl -fsSL "https://raw.githubusercontent.com/Dispatcharr/Dispatcharr/main/version.py" | awk -F"'" '/__version__/ {print $2; exit}')"

  if [ -z "${REMOTE_VERSION:-}" ]; then
    warn "Could not determine remote version from version.py on main; skipping versioned update check."
    exit 0
  fi

  LOCAL_VERSION=""
  if [ -f "$APP_DIR/version.py" ]; then
    LOCAL_VERSION="$(awk -F"'" '/__version__/ {print $2; exit}' "$APP_DIR/version.py" 2>/dev/null || true)"
  fi

  if [[ -n "${LOCAL_VERSION:-}" && "${REMOTE_VERSION}" == "${LOCAL_VERSION}" ]]; then
    msg_ok "No update required. ${APP} is already at v${REMOTE_VERSION}"
    exit 0
  fi

  # --- Backup important paths ---
  msg_info "Creating Backup"
  tar -czf "${APP_DIR}_backup_$(date +%F).tar.gz" "$APP_DIR" /data /etc/nginx/sites-available/dispatcharr.conf /etc/systemd/system/dispatcharr.service /etc/systemd/system/dispatcharr-celery.service /etc/systemd/system/dispatcharr-celerybeat.service /etc/systemd/system/dispatcharr-daphne.service 2>/dev/null || true
  msg_ok "Backup Created"

  # --- Stop services (safer for file replacement) ---
  msg_info "Stopping services"
  $STD systemctl stop dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne >/dev/null 2>&1 || true
  msg_ok "Services stopped"

  # ====== BEGIN update steps ======

  # Fetch latest release into APP_DIR (PVE Helper tools.func)
  msg_info "Fetching latest Dispatcharr release"
  fetch_and_deploy_gh_release "dispatcharr" "Dispatcharr/Dispatcharr"
  $STD chown -R "$DISPATCH_USER:$DISPATCH_GROUP" "$APP_DIR"
  msg_ok "Release deployed"

  # Ensure required runtime dirs inside $APP_DIR (in case clean unpack removed them)
  msg_info "Ensuring runtime directories in APP_DIR"
  mkdir -p "${APP_DIR}/static" "${APP_DIR}/media"
  $STD chown -R "$DISPATCH_USER:$DISPATCH_GROUP" "${APP_DIR}/static" "${APP_DIR}/media"
  msg_ok "Runtime directories ensured"

  # Rebuild frontend (clean)
  msg_info "Rebuilding frontend"
  $STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}/frontend\"; rm -rf node_modules .cache dist build .next 2>/dev/null || true"
  $STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}/frontend\"; if [ -f package-lock.json ]; then npm ci --loglevel=error --no-audit --no-fund; else npm install --legacy-peer-deps --loglevel=error --no-audit --no-fund; fi"
  $STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}/frontend\"; npm run build --loglevel=error -- --logLevel error"
  msg_ok "Frontend rebuilt"

  # Ensure venv deps are in place (idempotent)
  msg_info "Refreshing Python environment"
  if [ ! -f "${APP_DIR}/env/bin/activate" ]; then
    $STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; \"${PYTHON_BIN}\" -m venv env"
  fi
  $STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; source env/bin/activate; pip install -q --upgrade pip"
  if [ -f "${APP_DIR}/requirements.txt" ]; then
    $STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; source env/bin/activate; pip install -q -r requirements.txt"
  fi
  $STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; source env/bin/activate; pip install -q gunicorn"
  ln -sf /usr/bin/ffmpeg "${APP_DIR}/env/bin/ffmpeg"
  msg_ok "Python environment refreshed"

  # Run Django migrations (one-liner, PVEH-friendly)
  msg_info "Running Django migrations"
  $STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; source env/bin/activate; POSTGRES_DB='${POSTGRES_DB}' POSTGRES_USER='${POSTGRES_USER}' POSTGRES_PASSWORD='${POSTGRES_PASSWORD}' POSTGRES_HOST=localhost python manage.py migrate --noinput"
  msg_ok "Django migrations complete"

  # Restart services
  msg_info "Restarting services"
  $STD systemctl daemon-reload || true
  $STD systemctl restart dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne || true
  $STD systemctl reload nginx 2>/dev/null || true
  msg_ok "Services restarted"

  # ====== END update steps ======
  
  msg_ok "Updated ${APP} to v${REMOTE_VERSION}"
 
  ## Blarm1959 End ##

  exit 0
}

start
build_container
description

msg_ok "Completed Successfully!\n"

cat <<EOF
Nginx is listening on port ${NGINX_HTTP_PORT}.
Gunicorn socket: ${GUNICORN_SOCKET}.
WebSockets on port ${WEBSOCKET_PORT} (path /ws/).

You can check logs via:
  sudo journalctl -u dispatcharr -f
  sudo journalctl -u dispatcharr-celery -f
  sudo journalctl -u dispatcharr-celerybeat -f
  sudo journalctl -u dispatcharr-daphne -f

Visit the app at:
  http://${server_ip}:${NGINX_HTTP_PORT}
EOF
