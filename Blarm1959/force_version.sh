#!/usr/bin/env bash
# force_version.sh
# Forces the PVEH updater to run by spoofing the version stored in ~/.dispatcharr.
# Usage: sudo force_version.sh [--version <ver> | -V <ver>]
# If no version is provided, defaults to 0.0.0

set -euo pipefail

MARKER="${HOME}/.dispatcharr"

usage() {
  echo "Usage: $0 [--version <ver> | -V <ver>]"
  echo "Examples:"
  echo "  $0                 # defaults to 0.0.0 (forces next update)"
  echo "  $0 --version 0.9.9 # spoof as 0.9.9"
  echo "  $0 -V v0.9.9       # same, 'v' stripped automatically"
  exit 2
}

# Default version if none provided
VERSION="0.0.0"

# Parse args
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

# Spoof the PVEH GitHub-release marker only
printf "%s\n" "$VERSION" > "$MARKER"

echo "Forced ~/.dispatcharr version marker to ${VERSION}"
echo "Run 'update' now to trigger a full rebuild from GitHub."
