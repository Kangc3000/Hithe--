#!/usr/bin/env bash
# Idempotent installer for the Vision Companion relay server on the
# Hermes Ubuntu host. The relay server replaces the standalone voice-id
# and face-id daemons once the Android relay app is in play.
#
# Prerequisite: voice-id (and optionally face-id) installed first. This
# script reuses the same venv at ~/.hermes/voice-companion/.venv.
#
# This installer DISABLES the older voice-id-daemon and face-id-daemon
# systemd units to prevent dual-daemon competition for events.jsonl.
# If you want to roll back to the standalone-daemon setup, re-enable
# them manually after stopping the relay.

set -euo pipefail

log()  { printf '[install/relay] %s\n' "$*" >&2; }
warn() { printf '[install/relay][warn] %s\n' "$*" >&2; }
err()  { printf '[install/relay][err]  %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HERMES_RELAY_DIR="${REPO_ROOT}/hermes-skill/relay"
OPENCLAW_RELAY_DIR="${REPO_ROOT}/openclaw-skills/relay"

for required in \
    "${HERMES_RELAY_DIR}/SKILL.md" \
    "${HERMES_RELAY_DIR}/relay-daemon.service" \
    "${HERMES_RELAY_DIR}/run-relay.sh" \
    "${OPENCLAW_RELAY_DIR}/relay_server.py" \
    "${OPENCLAW_RELAY_DIR}/requirements.txt"
do
  [[ -f "${required}" ]] || err "missing source file: ${required}"
done

[[ "$(uname -s)" == "Linux" ]] || err "this installer is Linux-only"
[[ "$(id -u)" -ne 0 ]] || err "do not run as root"

DATA_DIR="${HOME}/.hermes/voice-companion"
SCRIPTS_DIR="${DATA_DIR}/scripts"
VENV_DIR="${DATA_DIR}/.venv"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
HERMES_SKILLS_DIR="${HOME}/.hermes/skills/relay"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  err "voice-id venv not found at ${VENV_DIR}; install voice-id first"
fi

mkdir -p "${SCRIPTS_DIR}" "${SYSTEMD_USER_DIR}" "${HERMES_SKILLS_DIR}"

log "copying relay_server and wrapper to ${SCRIPTS_DIR}"
install -m 0644 "${OPENCLAW_RELAY_DIR}/relay_server.py"  "${SCRIPTS_DIR}/relay_server.py"
install -m 0755 "${HERMES_RELAY_DIR}/run-relay.sh"        "${SCRIPTS_DIR}/run-relay.sh"

log "registering relay SKILL.md with Hermes"
install -m 0644 "${HERMES_RELAY_DIR}/SKILL.md"            "${HERMES_SKILLS_DIR}/SKILL.md"

log "installing relay Python deps into shared venv"
"${VENV_DIR}/bin/pip" install -r "${OPENCLAW_RELAY_DIR}/requirements.txt"

log "installing systemd user unit for relay"
install -m 0644 "${HERMES_RELAY_DIR}/relay-daemon.service" \
                "${SYSTEMD_USER_DIR}/relay-daemon.service"
systemctl --user daemon-reload

# Stop and disable the older standalone daemons. The relay server provides
# a superset of their functionality and writes to the same events.jsonl.
# Running both would interleave events and double-count TTS.
for unit in voice-id-daemon face-id-daemon; do
  if systemctl --user is-enabled --quiet "${unit}" 2>/dev/null; then
    log "disabling ${unit} (replaced by relay-daemon)"
    systemctl --user disable --now "${unit}" || warn "could not disable ${unit}"
  fi
done

# Firewall hint (UFW). Most Hermes hosts use Tailscale only, but if UFW
# is on, the relay port needs to be reachable on the tailnet interface.
if command -v ufw >/dev/null 2>&1 && sudo -n ufw status 2>/dev/null | grep -q '^Status: active'; then
  warn "UFW is active. If the Android relay can't connect, allow port 8765 on the tailnet interface, e.g.:"
  warn "  sudo ufw allow in on tailscale0 to any port 8765 proto tcp"
fi

cat >&2 <<EOF

[install/relay] done.

next steps:

  1) start the relay:
       systemctl --user enable --now relay-daemon
       systemctl --user status relay-daemon

  2) confirm it's listening:
       ss -lntp | grep 8765
       tail -f ${DATA_DIR}/relay-daemon.log

  3) on the Galaxy S25, install the Android relay app, set the Hermes
     host to your tailnet hostname (or IP), and connect. The "session_started"
     event should appear in the relay log within a second.

  4) speak; expect a 'speech segment' log line, then a 'speaker_identified'
     event, then a TTS frame sent back. Look in:
       tail -f ${DATA_DIR}/events.jsonl

verbose debug logs:  RELAY_LOG_LEVEL=DEBUG systemctl --user restart relay-daemon
config (shared):     ${DATA_DIR}/config.yaml
events:              ${DATA_DIR}/events.jsonl
relay log:           ${DATA_DIR}/relay-daemon.log

note: the standalone voice-id-daemon and face-id-daemon units have been
disabled. The relay server is now the single point of recognition. To
roll back, run:
  systemctl --user disable --now relay-daemon
  systemctl --user enable --now voice-id-daemon face-id-daemon
EOF
