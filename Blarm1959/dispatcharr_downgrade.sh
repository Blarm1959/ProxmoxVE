#!/usr/bin/env bash
# Minimal downgrade helper for fast test loops
# Usage: sudo ./dispatcharr_downgrade.sh --ver v0.10.2

set -euo pipefail

APP_DIR="/opt/dispatcharr"
DISPATCH_USER="dispatcharr"
REPO_OWNER="Dispatcharr"
REPO_NAME="Dispatcharr"
SERVICES=(dispatcharr dispatcharr-celery dispatcharr-celerybeat dispatcharr-daphne)

usage() {
  echo "Usage: $0 --ver <TAG_OR_COMMIT>"; exit 2
}

# Parse args
VER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ver) VER="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[[ -n "$VER" ]] || usage

# Tiny prereq (these are small; no backup done)
command -v rsync >/dev/null 2>&1 || { apt-get update -y && apt-get install -y rsync; }
command -v curl  >/dev/null 2>&1 || { apt-get update -y && apt-get install -y curl; }

# Stop services quickly (ignore if not running)
for s in "${SERVICES[@]}"; do systemctl stop "$s" || true; done

# Fetch & overlay old tag/commit (keep env/static/media/node_modules)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
url_tag="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/${VER}.tar.gz"
url_commit="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${VER}.tar.gz"
curl -fsSL -o "${tmp}/src.tar.gz" "$url_tag" || curl -fsSL -o "${tmp}/src.tar.gz" "$url_commit"
tar -xzf "${tmp}/src.tar.gz" -C "$tmp"
src_dir="$(find "$tmp" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)"
[ -d "$src_dir" ] || { echo "Could not extract ${VER}"; exit 1; }

rsync -a --delete \
  --exclude "env" \
  --exclude "static" \
  --exclude "media" \
  --exclude ".git" \
  --exclude "node_modules" \
  "$src_dir"/ "$APP_DIR"/

# Ownership + quick version echo
chown -R "${DISPATCH_USER}:${DISPATCH_USER}" "$APP_DIR"
if [[ -f "${APP_DIR}/version.py" ]]; then
  echo -n "LOCAL version.py -> "; grep -Eo "__version__\s*=\s*.+$" "${APP_DIR}/version.py" || true
fi

# Start services again
for s in "${SERVICES[@]}"; do systemctl start "$s" || true; done
echo "Downgrade to ${VER} staged. Run your updater next."
