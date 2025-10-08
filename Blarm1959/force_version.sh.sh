#!/usr/bin/env bash
# force_version.sh
# Spoofs Dispatcharr version markers to force an update or test a specific version.
# Usage: sudo force_version.sh [--version <ver> | -V <ver>]
# If no version is provided, defaults to 0.0.0

set -euo pipefail

APP_DIR="/opt/dispatcharr"
DISPATCH_USER="dispatcharr"
MARKER="/root/.dispatcharr"

usage() {
  echo "Usage: $0 [--version <ver> | -V <ver>]"
  echo "Examples:"
  echo "  $0                 # defaults to 0.0.0 (forces next update)"
  echo "  $0 --version 0.9.9 # spoof as 0.9.9"
  echo "  $0 -V v0.9.9       # same, 'v' stripped automatically"
  exit 2
}

# Default version if none given
VERSION="0.0.0"

# Parse args (optional)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-V)
      VERSION="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

# Strip any leading 'v'
VERSION="${VERSION#v}"

# Spoof version.py (for internal checks)
printf "__version__ = '%s'\n" "$VERSION" > "${APP_DIR}/version.py"
chown "${DISPATCH_USER}:${DISPATCH_USER}" "${APP_DIR}/version.py"

# Spoof PVEH marker (for check_for_gh_release)
printf "%s\n" "$VERSION" > "${MARKER}"

echo "Forced Dispatcharr version markers to ${VERSION}"
echo "version.py  -> ${APP_DIR}/version.py"
echo "PVEH marker -> ${MARKER}"
echo "Run 'update' now to trigger a full rebuild from GitHub."
