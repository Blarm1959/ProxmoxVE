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
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

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
  SYSTEMD_DIR="/etc/systemd/system"
  NGINX_SITE="/etc/nginx/sites-available/dispatcharr.conf"
  NGINX_SITE_ENABLED="${NGINX_SITE/sites-available/sites-enabled}"

  SERVER_IP="$(hostname -I | tr -s ' ' | cut -d' ' -f1)"

  DTHHMM="$(date +%F_%H-%M)"
  BACKUP_STEM=${APP,,}
  BACKUP_FILE="/root/${BACKUP_STEM}_${DTHHMM}.tar.gz"
  TMP_PGDUMP="/tmp/pgdump"
  DB_BACKUP_FILE="${TMP_PGDUMP}/${APP}_DB_${DTHHMM}.dump"
  BACKUPS_TOKEEP=3
  BACKUP_GLOB="/root/${BACKUP_STEM}_*.tar.gz"

  APP_LC=$(echo "${APP,,}" | tr -d ' ')
  VERSION_FILE="$HOME/.${APP_LC}"

  # Check if installation is present
  if [[ ! -d "$APP_DIR" ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if ! check_for_gh_release "dispatcharr" "Dispatcharr/Dispatcharr"; then
    exit
  fi

  # --- Remove any leftover temporary DB dumps (safe cleanup) ---
  if [ -d "$TMP_PGDUMP" ]; then
    shown=0
    for f in "$TMP_PGDUMP/${APP}_DB_"*.dump; do
      # If the glob didn't match anything, skip the literal pattern
      [ -e "$f" ] || continue
      if [ "$shown" -eq 0 ]; then
        msg_warn "Found leftover database dump(s) that may have been included in previous backups — removing:"
        shown=1
      fi
      echo "  - $(basename "$f")"
      sudo -u postgres rm -f "$f" 2>/dev/null || true
    done
  fi

  # --- Early check: too many existing backups (pre-flight) ---
  BACKUPS_TOKEEP=${BACKUPS_TOKEEP:-3}
  BACKUP_GLOB="/root/${BACKUP_STEM}_*.tar.gz"

  # shellcheck disable=SC2086
  EXISTING_BACKUPS=( $(ls -1 $BACKUP_GLOB 2>/dev/null | sort -r || true) )
  COUNT=${#EXISTING_BACKUPS[@]}

  if [ "$COUNT" -ge "$BACKUPS_TOKEEP" ]; then
    # After creating a new backup, this many will be pruned:
    TO_REMOVE=$((COUNT - BACKUPS_TOKEEP + 1))
    # Preview the oldest files that will be removed after the new backup
    LIST_PREVIEW=$(printf '%s\n' "${EXISTING_BACKUPS[@]}" | tail -n "$TO_REMOVE" | sed 's/^/  - /')

    MSG="Detected $COUNT existing backups in /root.
  A new backup will be created now, then $TO_REMOVE older backup(s) will be deleted
  to keep only the newest ${BACKUPS_TOKEEP}.

  Backups that would be removed:
  ${LIST_PREVIEW}

  Do you want to continue?"
    if ! whiptail --title "Dispatcharr Backup Warning" --yesno "$MSG" 20 78; then
      msg_warn "Backup/update cancelled by user at pre-flight backup limit check."
      exit 0
    fi
  fi

  msg_info "Updating $APP LXC"
  $STD bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update && apt-get -y upgrade'
  msg_ok "Updated $APP LXC"

  msg_info "Stopping services for $APP"
  systemctl stop dispatcharr-celery
  systemctl stop dispatcharr-celerybeat
  systemctl stop dispatcharr-daphne
  systemctl stop dispatcharr
  msg_ok "Services stopped for $APP"

  # --- Backup important paths and database ---
  msg_info "Creating Backup of current installation"

  # DB dump (custom format for pg_restore)
  [ -d "$TMP_PGDUMP" ] || install -d -m 700 -o postgres -g postgres "$TMP_PGDUMP"
  sudo -u postgres pg_dump -Fc -f "${DB_BACKUP_FILE}" "$POSTGRES_DB"
  [ -s "${DB_BACKUP_FILE}" ] || { msg_error "Database dump is empty — aborting backup"; exit 1; }

  # Build TAR_* variables (NO /data; exclude rebuildable dirs)
  TAR_OPTS=( -C / --warning=no-file-changed --ignore-failed-read )
  TAR_EXCLUDES=(
    --exclude=opt/dispatcharr/env
    --exclude=opt/dispatcharr/env/**
    --exclude=opt/dispatcharr/frontend
    --exclude=opt/dispatcharr/frontend/**
    --exclude=opt/dispatcharr/static
    --exclude=opt/dispatcharr/static/**
  )
  TAR_ITEMS=(
    "${APP_DIR#/}"
    "${NGINX_SITE#/}"
    "${NGINX_SITE_ENABLED#/}"
    "${SYSTEMD_DIR#/}/dispatcharr.service"
    "${SYSTEMD_DIR#/}/dispatcharr-celery.service"
    "${SYSTEMD_DIR#/}/dispatcharr-celerybeat.service"
    "${SYSTEMD_DIR#/}/dispatcharr-daphne.service"
    "${DB_BACKUP_FILE#/}"
  )
  $STD tar -czf "${BACKUP_FILE}" "${TAR_OPTS[@]}" "${TAR_EXCLUDES[@]}" "${TAR_ITEMS[@]}"

  # Cleanup temp DB dump
  rm -f "${DB_BACKUP_FILE}"

  # --- Prune old backups (keep newest N by filename order) ---
  BACKUPS_TOKEEP=${BACKUPS_TOKEEP:-3}
  BACKUP_GLOB="/root/${BACKUP_STEM}_*.tar.gz"

  # shellcheck disable=SC2086
  EXISTING_BACKUPS=( $(ls -1 $BACKUP_GLOB 2>/dev/null | sort -r || true) )
  COUNT=${#EXISTING_BACKUPS[@]}

  if [ "$COUNT" -gt "$BACKUPS_TOKEEP" ]; then
    TO_REMOVE=$((COUNT - BACKUPS_TOKEEP))
    LIST_PREVIEW=$(printf '%s\n' "${EXISTING_BACKUPS[@]}" | tail -n "$TO_REMOVE" | sed 's/^/  - /')

    msg_warn "Found $COUNT existing backups — keeping newest $BACKUPS_TOKEEP and removing $TO_REMOVE older backup(s):"
    echo "$LIST_PREVIEW"
    printf '%s\n' "${EXISTING_BACKUPS[@]}" | tail -n "$TO_REMOVE" | xargs -r rm -f
  fi

  msg_ok "Backup Created: ${BACKUP_FILE}"

  # ====== BEGIN update steps ======

  # Fetch latest release into APP_DIR (PVE Helper tools.func)
  msg_info "Fetching latest Dispatcharr release"
  fetch_and_deploy_gh_release "dispatcharr" "Dispatcharr/Dispatcharr"
  $STD chown -R "$DISPATCH_USER:$DISPATCH_GROUP" "$APP_DIR"
  CURRENT_VERSION=""
  [[ -f "$VERSION_FILE" ]] && CURRENT_VERSION=$(<"$VERSION_FILE")
  msg_ok "Release deployed"

  # Ensure required runtime dirs inside $APP_DIR (in case clean unpack removed them)
  msg_info "Ensuring runtime directories in APP_DIR"
  mkdir -p "${APP_DIR}/static" "${APP_DIR}/media"
  chown -R "$DISPATCH_USER:$DISPATCH_GROUP" "${APP_DIR}/static" "${APP_DIR}/media"
  msg_ok "Runtime directories ensured"

  # Rebuild frontend (clean)
  msg_info "Rebuilding frontend"
  sudo -u "$DISPATCH_USER" bash -c "cd \"${APP_DIR}/frontend\"; rm -rf node_modules .cache dist build .next || true"
  sudo -u "$DISPATCH_USER" bash -c "cd \"${APP_DIR}/frontend\"; if [ -f package-lock.json ]; then npm ci --silent --no-progress --no-audit --no-fund; else npm install --legacy-peer-deps --silent --no-progress --no-audit --no-fund; fi"
  $STD sudo -u "$DISPATCH_USER" bash -c "cd \"${APP_DIR}/frontend\"; npm run build --loglevel=error -- --logLevel error"
  msg_ok "Frontend rebuilt"

  msg_info "Refreshing Python environment (uv)"
  export UV_INDEX_URL="https://pypi.org/simple"
  export UV_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cpu"
  export UV_INDEX_STRATEGY="unsafe-best-match"
  export PATH="/usr/local/bin:$PATH"
  $STD runuser -u "$DISPATCH_USER" -- bash -c 'cd "'"${APP_DIR}"'"; [ -x env/bin/python ] || uv venv --seed env || uv venv env'

  # Filter out uWSGI and install
  runuser -u "$DISPATCH_USER" -- bash -c '
    cd "'"${APP_DIR}"'"
    REQ=requirements.txt
    REQF=requirements.nouwsgi.txt
    if [ -f "$REQ" ]; then
      if grep -qiE "^\s*uwsgi(\b|[<>=~])" "$REQ"; then
        sed -E "/^\s*uwsgi(\b|[<>=~]).*/Id" "$REQ" > "$REQF"
      else
        cp "$REQ" "$REQF"
      fi
    fi
  '

  runuser -u "$DISPATCH_USER" -- bash -c 'cd "'"${APP_DIR}"'"; . env/bin/activate; uv pip install -q -r requirements.nouwsgi.txt'
  runuser -u "$DISPATCH_USER" -- bash -c 'cd "'"${APP_DIR}"'"; . env/bin/activate; uv pip install -q gunicorn'
  ln -sf /usr/bin/ffmpeg "${APP_DIR}/env/bin/ffmpeg"
  msg_ok "Python environment refreshed"

  # Run Django migrations (one-liner, PVEH-friendly)
  msg_info "Running Django migrations"
  $STD sudo -u "$DISPATCH_USER" bash -c "cd \"${APP_DIR}\"; source env/bin/activate; POSTGRES_DB='${POSTGRES_DB}' POSTGRES_USER='${POSTGRES_USER}' POSTGRES_PASSWORD='${POSTGRES_PASSWORD}' POSTGRES_HOST=localhost python manage.py migrate --noinput"
  msg_ok "Django migrations complete"

  # Restart services
  msg_info "Restarting services"
  $STD systemctl daemon-reload || true
  $STD systemctl restart dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne || true
  $STD systemctl reload nginx 2>/dev/null || true
  msg_ok "Services restarted"

  # ====== END update steps ======
  
  msg_ok "Updated ${APP} to v${CURRENT_VERSION}"
 
  echo "Nginx is listening on port ${NGINX_HTTP_PORT}."
  echo "Gunicorn socket: ${GUNICORN_SOCKET}."
  echo "WebSockets on port ${WEBSOCKET_PORT} (path /ws/)."
  echo
  echo "You can check logs via:"
  echo "  sudo journalctl -u dispatcharr -f"
  echo "  sudo journalctl -u dispatcharr-celery -f"
  echo "  sudo journalctl -u dispatcharr-celerybeat -f"
  echo "  sudo journalctl -u dispatcharr-daphne -f"
  echo
  echo "Visit the app at:"
  echo "  http://${SERVER_IP}:${NGINX_HTTP_PORT}"

  exit 0
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:9191${CL}"
