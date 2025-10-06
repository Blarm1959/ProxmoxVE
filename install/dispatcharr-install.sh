#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Blarm1959
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Dispatcharr/Dispatcharr

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Setup App

## Blarm1959 Start ##

# Variables
APP="Dispatcharr"
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
SYSTEMD_DIR="/etc/systemd/system"
NGINX_SITE="/etc/nginx/sites-available/dispatcharr.conf"

# System packages minimal (curl, sudo, etc.)
msg_info "Installing core packages"
export DEBIAN_FRONTEND=noninteractive
$STD apt-get update -qq
$STD apt-get install -y -qq --no-install-recommends curl ca-certificates git python3-venv python3-pip ffmpeg nginx sudo procps redis-server
msg_ok "Core packages installed"

# Create app user/group and dirs
msg_info "Preparing user and directories"
if ! getent group "$DISPATCH_GROUP" >/dev/null; then
  $STD groupadd "$DISPATCH_GROUP"
fi
if ! id -u "$DISPATCH_USER" >/dev/null 2>&1; then
  $STD useradd -m -g "$DISPATCH_GROUP" -s /bin/bash "$DISPATCH_USER"
fi
mkdir -p "$APP_DIR"
$STD chown "$DISPATCH_USER:$DISPATCH_GROUP" "$APP_DIR"
msg_ok "User and directories ready"

# Node.js via PVE Helper (tools.func)
msg_info "Installing Node.js (tools.func)"
NODE_VERSION="${NODE_VERSION:-24}" setup_nodejs
msg_ok "Node.js installed"

# PostgreSQL engine via PVE Helper, then provision DB/user
msg_info "Installing PostgreSQL (tools.func)"
PG_VERSION="${PG_VERSION:-16}" setup_postgresql
$STD systemctl enable --now postgresql >/dev/null 2>&1 || true
msg_ok "PostgreSQL installed"

msg_info "Provisioning PostgreSQL database and role"
if ! sudo -H -u postgres bash -lc "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'\" | grep -q 1"; then
  $STD sudo -H -u postgres bash -lc "createdb '${POSTGRES_DB}'"
fi
if ! sudo -H -u postgres bash -lc "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${POSTGRES_USER}'\" | grep -q 1"; then
  $STD sudo -H -u postgres bash -lc "psql -c \"CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';\""
fi
$STD sudo -H -u postgres bash -lc "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};\""
$STD sudo -H -u postgres bash -lc "psql -c \"ALTER DATABASE ${POSTGRES_DB} OWNER TO ${POSTGRES_USER};\""
$STD sudo -H -u postgres bash -lc "psql -d \"${POSTGRES_DB}\" -c \"ALTER SCHEMA public OWNER TO ${POSTGRES_USER};\""
msg_ok "PostgreSQL database and role provisioned"

# Fetch code via GitHub release helper
msg_info "Fetching Dispatcharr (latest GitHub release via tools.func)"
fetch_and_deploy_gh_release "dispatcharr" "Dispatcharr/Dispatcharr"
$STD chown -R "$DISPATCH_USER:$DISPATCH_GROUP" "$APP_DIR"
msg_ok "Dispatcharr deployed to ${APP_DIR}"

# Python venv & backend deps
msg_info "Setting up Python virtual environment and backend dependencies"
$STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; \"${PYTHON_BIN}\" -m venv env"
$STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; source env/bin/activate; pip install -q --upgrade pip"
$STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; source env/bin/activate; pip install -q -r requirements.txt"
$STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; source env/bin/activate; pip install -q gunicorn"
ln -sf /usr/bin/ffmpeg "${APP_DIR}/env/bin/ffmpeg"
msg_ok "Python virtual environment ready"

# Frontend build
msg_info "Building frontend"
$STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}/frontend\"; rm -rf node_modules .cache dist build .next 2>/dev/null || true"
$STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}/frontend\"; if [ -f package-lock.json ]; then npm ci --loglevel=error --no-audit --no-fund; else npm install --legacy-peer-deps --loglevel=error --no-audit --no-fund; fi"
$STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}/frontend\"; npm run build --loglevel=error -- --logLevel error"
msg_ok "Frontend built"

# App data dirs
msg_info "Creating application data directories"
mkdir -p /data/logos \
         /data/recordings \
         /data/uploads/m3us \
         /data/uploads/epgs \
         /data/m3us \
         /data/epgs \
         /data/plugins \
         /data/db \
         /app/logo_cache \
         /app/media
$STD chown -R "$DISPATCH_USER:$DISPATCH_GROUP" /data
$STD chown -R "$DISPATCH_USER:$DISPATCH_GROUP" /app
$STD chown -R postgres:postgres /data/db || true
chmod +x /data
msg_ok "Application data directories ready"

# Django migrate/static
msg_info "Running Django migrations and collectstatic"
$STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; source env/bin/activate; POSTGRES_DB='${POSTGRES_DB}' POSTGRES_USER='${POSTGRES_USER}' POSTGRES_PASSWORD='${POSTGRES_PASSWORD}' POSTGRES_HOST=localhost python manage.py migrate --noinput"
$STD sudo -u "$DISPATCH_USER" bash -lc "cd \"${APP_DIR}\"; source env/bin/activate; python manage.py collectstatic --noinput"
msg_ok "Django tasks complete"

# Systemd services
msg_info "Writing systemd services and Nginx config"
cat <<EOF >${SYSTEMD_DIR}/dispatcharr.service
[Unit]
Description=Gunicorn for Dispatcharr
After=network.target postgresql.service redis-server.service

[Service]
User=${DISPATCH_USER}
Group=${DISPATCH_GROUP}
WorkingDirectory=${APP_DIR}
RuntimeDirectory=${GUNICORN_RUNTIME_DIR}
RuntimeDirectoryMode=0775
Environment="PATH=${APP_DIR}/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
Environment="POSTGRES_DB=${POSTGRES_DB}"
Environment="POSTGRES_USER=${POSTGRES_USER}"
Environment="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
Environment="POSTGRES_HOST=localhost"
ExecStartPre=/usr/bin/bash -c 'until pg_isready -h localhost -U ${POSTGRES_USER}; do sleep 1; done'
ExecStart=${APP_DIR}/env/bin/gunicorn \
    --workers=4 \
    --worker-class=gevent \
    --timeout=300 \
    --bind unix:${GUNICORN_SOCKET} \
    dispatcharr.wsgi:application
Restart=always
KillMode=mixed
SyslogIdentifier=dispatcharr
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >${SYSTEMD_DIR}/dispatcharr-celery.service
[Unit]
Description=Celery Worker for Dispatcharr
After=network.target redis-server.service
Requires=dispatcharr.service

[Service]
User=${DISPATCH_USER}
Group=${DISPATCH_GROUP}
WorkingDirectory=${APP_DIR}
Environment="PATH=${APP_DIR}/env/bin"
Environment="POSTGRES_DB=${POSTGRES_DB}"
Environment="POSTGRES_USER=${POSTGRES_USER}"
Environment="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
Environment="POSTGRES_HOST=localhost"
Environment="CELERY_BROKER_URL=redis://localhost:6379/0"
ExecStart=${APP_DIR}/env/bin/celery -A dispatcharr worker -l info
Restart=always
KillMode=mixed
SyslogIdentifier=dispatcharr-celery
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >${SYSTEMD_DIR}/dispatcharr-celerybeat.service
[Unit]
Description=Celery Beat Scheduler for Dispatcharr
After=network.target redis-server.service
Requires=dispatcharr.service

[Service]
User=${DISPATCH_USER}
Group=${DISPATCH_GROUP}
WorkingDirectory=${APP_DIR}
Environment="PATH=${APP_DIR}/env/bin"
Environment="POSTGRES_DB=${POSTGRES_DB}"
Environment="POSTGRES_USER=${POSTGRES_USER}"
Environment="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
Environment="POSTGRES_HOST=localhost"
Environment="CELERY_BROKER_URL=redis://localhost:6379/0"
ExecStart=${APP_DIR}/env/bin/celery -A dispatcharr beat -l info
Restart=always
KillMode=mixed
SyslogIdentifier=dispatcharr-celerybeat
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >${SYSTEMD_DIR}/dispatcharr-daphne.service
[Unit]
Description=Daphne for Dispatcharr (ASGI/WebSockets)
After=network.target
Requires=dispatcharr.service

[Service]
User=${DISPATCH_USER}
Group=${DISPATCH_GROUP}
WorkingDirectory=${APP_DIR}
Environment="PATH=${APP_DIR}/env/bin"
Environment="POSTGRES_DB=${POSTGRES_DB}"
Environment="POSTGRES_USER=${POSTGRES_USER}"
Environment="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
Environment="POSTGRES_HOST=localhost"
ExecStart=${APP_DIR}/env/bin/daphne -b 0.0.0.0 -p ${WEBSOCKET_PORT} dispatcharr.asgi:application
Restart=always
KillMode=mixed
SyslogIdentifier=dispatcharr-daphne
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >"${NGINX_SITE}"
server {
    listen ${NGINX_HTTP_PORT};
    location / {
        include proxy_params;
        proxy_pass http://unix:${GUNICORN_SOCKET};
    }
    location /static/ {
        alias ${APP_DIR}/static/;
    }
    location /assets/ {
        alias ${APP_DIR}/frontend/dist/assets/;
    }
    location /media/ {
        alias ${APP_DIR}/media/;
    }
    location /ws/ {
        proxy_pass http://127.0.0.1:${WEBSOCKET_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf "${NGINX_SITE}" "/etc/nginx/sites-enabled/$(basename "${NGINX_SITE}")"
[ -f /etc/nginx/sites-enabled/default ] && rm /etc/nginx/sites-enabled/default
$STD nginx -t >/dev/null
$STD systemctl restart nginx
$STD systemctl enable nginx >/dev/null 2>&1 || true
msg_ok "Systemd and Nginx configuration written"

# Enable/start services
msg_info "Enabling and starting Dispatcharr services"
$STD systemctl daemon-reexec
$STD systemctl daemon-reload
$STD systemctl enable --now dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne >/dev/null 2>&1 || true
msg_ok "Services are running"
  
msg_ok "Installed ${APP} : v${REMOTE_VERSION}"
 
## Blarm1959 End ##

motd_ssh
customize

# Cleanup
msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"

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
