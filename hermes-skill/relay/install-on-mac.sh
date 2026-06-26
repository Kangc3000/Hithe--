#!/usr/bin/env bash
# Idempotent installer for the Vision Companion relay server on a macOS
# host (intended target: the home Mac Mini at 192.168.0.99, tailnet name
# `mac-mini`). Mirrors install-on-hermes.sh but uses Homebrew + launchd
# instead of apt + systemd.
#
# Prerequisite: voice-id (and optionally face-id) installed first via
# hermes-skill/voice-id/install-on-mac.sh — this script reuses the same
# venv at ~/.hermes/voice-companion/.venv.
#
# Run as the regular (non-root) Mac user that owns the Hermes Agent install.
# Requires Homebrew + python@3.11 (the voice-id installer instructs how to
# get those).
#
# Usage:
#   chmod +x install-on-mac.sh
#   ./install-on-mac.sh

set -euo pipefail

log()  { printf '[install/relay-mac] %s\n' "$*" >&2; }
warn() { printf '[install/relay-mac][warn] %s\n' "$*" >&2; }
err()  { printf '[install/relay-mac][err]  %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HERMES_RELAY_DIR="${REPO_ROOT}/hermes-skill/relay"
OPENCLAW_RELAY_DIR="${REPO_ROOT}/openclaw-skills/relay"

for required in \
    "${HERMES_RELAY_DIR}/SKILL.md" \
    "${HERMES_RELAY_DIR}/relay-daemon.plist.template" \
    "${HERMES_RELAY_DIR}/run-relay.sh" \
    "${OPENCLAW_RELAY_DIR}/relay_server.py" \
    "${OPENCLAW_RELAY_DIR}/requirements.txt"
do
  [[ -f "${required}" ]] || err "missing source file: ${required}"
done

[[ "$(uname -s)" == "Darwin" ]] || err "this installer is macOS-only; use install-on-hermes.sh on Linux"
[[ "$(id -u)" -ne 0 ]] || err "do not run as root"

DATA_DIR="${HOME}/.hermes/voice-companion"
SCRIPTS_DIR="${DATA_DIR}/scripts"
VENV_DIR="${DATA_DIR}/.venv"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
HERMES_SKILLS_DIR="${HOME}/.hermes/skills/relay"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  err "voice-id venv not found at ${VENV_DIR}; install voice-id first (hermes-skill/voice-id/install-on-mac.sh)"
fi

mkdir -p "${SCRIPTS_DIR}" "${LAUNCH_AGENTS_DIR}" "${HERMES_SKILLS_DIR}"

log "copying relay_server and wrapper to ${SCRIPTS_DIR}"
install -m 0644 "${OPENCLAW_RELAY_DIR}/relay_server.py"  "${SCRIPTS_DIR}/relay_server.py"
install -m 0755 "${HERMES_RELAY_DIR}/run-relay.sh"        "${SCRIPTS_DIR}/run-relay.sh"

log "registering relay SKILL.md with Hermes"
install -m 0644 "${HERMES_RELAY_DIR}/SKILL.md"            "${HERMES_SKILLS_DIR}/SKILL.md"

log "installing relay Python deps into shared venv"
"${VENV_DIR}/bin/pip" install -r "${OPENCLAW_RELAY_DIR}/requirements.txt"

# Render the plist template. Token is empty here; the user (or Hermes via
# the rotate-token SKILL recipe) sets the actual value via PlistBuddy after
# this install completes.
PLIST_PATH="${LAUNCH_AGENTS_DIR}/com.hithe.relay-daemon.plist"
EXEC_PATH="${SCRIPTS_DIR}/run-relay.sh"

log "rendering launchd plist to ${PLIST_PATH}"
sed \
  -e "s|__EXEC_PATH__|${EXEC_PATH}|g" \
  -e "s|__HOME__|${HOME}|g" \
  -e "s|__DATA_DIR__|${DATA_DIR}|g" \
  -e "s|__RELAY_TOKEN__||g" \
  "${HERMES_RELAY_DIR}/relay-daemon.plist.template" > "${PLIST_PATH}"
chmod 0644 "${PLIST_PATH}"

# Validate the rendered plist (plutil ships with macOS).
if ! plutil -lint "${PLIST_PATH}" >/dev/null; then
  err "rendered plist failed plutil -lint; see ${PLIST_PATH}"
fi
log "plist syntax OK"

# Remove obsolete standalone-daemon plists so the relay is the only path.
# Equivalent of the Linux installer's `systemctl --user disable voice-id-daemon`.
for label in com.hithe.voice-id-daemon com.hithe.face-id-daemon; do
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  rm -f "${LAUNCH_AGENTS_DIR}/${label}.plist"
done

# macOS firewall hint (optional). We don't need inbound from the public
# internet — Apache/EC2 reaches us via Tailscale — but the user's local
# firewall may still prompt the first time relay_server binds 8765.
if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q 'enabled'; then
  warn "macOS application firewall is enabled. If the relay can't accept connections,"
  warn "  System Settings → Network → Firewall → Options → allow incoming for python3."
fi

cat >&2 <<EOF

[install/relay-mac] done.

next steps:

  1) set a relay token (Hermes will use the same value the Android app gets):
       NEW="vcr_\$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
       PLIST=${PLIST_PATH}
       /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:RELAY_TOKEN \${NEW}" "\${PLIST}"
       sed -i '' "s|^relay_token:.*|relay_token: \"\${NEW}\"|" \
         ${DATA_DIR}/config.yaml
       echo "TOKEN: \${NEW}     <-- copy this; you'll paste it into the Android app"

  2) load the launchd agent (starts now and at every login):
       launchctl bootstrap gui/\$(id -u) ${PLIST_PATH}

  3) confirm it's running:
       launchctl list | grep com.hithe.relay-daemon
       lsof -nP -iTCP:8765 -sTCP:LISTEN
       tail -f ${DATA_DIR}/relay-daemon.log

     You should see "INFO  relay: token auth enabled (token length=33)" and
     "INFO  relay: starting WebSocket server on 0.0.0.0:8765".

  4) On the first WebSocket accept from a non-loopback peer, macOS may
     prompt: "Python wants to find devices on your local network." Click Allow.

verbose debug:
  PlistBuddy add LogLevel via EnvironmentVariables.RELAY_LOG_LEVEL=DEBUG,
  then  launchctl kickstart -k gui/\$(id -u)/com.hithe.relay-daemon

config (shared with voice-id/face-id):  ${DATA_DIR}/config.yaml
events:                                  ${DATA_DIR}/events.jsonl
relay log:                               ${DATA_DIR}/relay-daemon.log

note: the standalone voice-id and face-id launchd agents (if previously
installed) have been removed. The relay server is now the single point of
recognition.
EOF
