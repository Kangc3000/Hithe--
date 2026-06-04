#!/usr/bin/env bash
# Wrapper that systemd's relay-daemon.service ExecStart points at.
# Activates the venv (shared with voice-id / face-id) and starts the
# WebSocket relay server.
#
# Override port / log-level via environment variables; systemd drop-in
# files are the recommended place to set these in production.

set -euo pipefail

DATA_DIR="${HOME}/.hermes/voice-companion"
VENV="${DATA_DIR}/.venv"
SCRIPTS="${DATA_DIR}/scripts"

RELAY_HOST="${RELAY_HOST:-0.0.0.0}"
RELAY_PORT="${RELAY_PORT:-8765}"
RELAY_LOG_LEVEL="${RELAY_LOG_LEVEL:-INFO}"

# Shared secret for the WebSocket auth. Set this via systemd drop-in:
#   ~/.config/systemd/user/relay-daemon.service.d/token.conf
# Leaving it empty disables auth (only safe if 0.0.0.0:8765 is NOT exposed
# to the public internet — e.g. tailnet-only deployments without reverse
# proxy). For public deployments via Apache + Tailscale + kangatnewyork.com,
# this MUST be set.
RELAY_TOKEN="${RELAY_TOKEN:-}"

if [[ ! -x "${VENV}/bin/python" ]]; then
  echo "venv not found at ${VENV}; run install-on-hermes.sh first" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${VENV}/bin/activate"

exec python -u "${SCRIPTS}/relay_server.py" \
  --host "${RELAY_HOST}" \
  --port "${RELAY_PORT}" \
  --token "${RELAY_TOKEN}" \
  --log-level "${RELAY_LOG_LEVEL}"
