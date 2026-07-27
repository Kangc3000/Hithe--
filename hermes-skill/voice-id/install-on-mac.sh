#!/usr/bin/env bash
# Idempotent installer for the Vision Companion voice-id skill on macOS.
# Mirrors install-on-hermes.sh; uses Homebrew + launchd instead of apt +
# systemd. Run as a non-root regular user.
#
# Prerequisites you handle yourself (the script checks and instructs):
#   - Homebrew installed (https://brew.sh)
#   - python@3.11 from brew
#
# Usage:
#   chmod +x install-on-mac.sh
#   ./install-on-mac.sh

set -euo pipefail

log()  { printf '[install/voice-id-mac] %s\n' "$*" >&2; }
warn() { printf '[install/voice-id-mac][warn] %s\n' "$*" >&2; }
err()  { printf '[install/voice-id-mac][err]  %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HERMES_SKILL_DIR="${REPO_ROOT}/hermes-skill/voice-id"
HERMES_CONTROL_DIR="${REPO_ROOT}/hermes-skill/control"
OPENCLAW_SKILL_DIR="${REPO_ROOT}/openclaw-skills/voice-id"
OPENCLAW_CONTROL_DIR="${REPO_ROOT}/openclaw-skills/control"

for required in \
    "${HERMES_SKILL_DIR}/config.yaml" \
    "${HERMES_SKILL_DIR}/tts_announce.py" \
    "${HERMES_SKILL_DIR}/run-pipeline.sh" \
    "${HERMES_SKILL_DIR}/voice-id-daemon.plist.template" \
    "${HERMES_SKILL_DIR}/SKILL.md" \
    "${HERMES_CONTROL_DIR}/SKILL.md" \
    "${OPENCLAW_SKILL_DIR}/voice_id.py" \
    "${OPENCLAW_SKILL_DIR}/enroll.py" \
    "${OPENCLAW_SKILL_DIR}/requirements.txt" \
    "${OPENCLAW_CONTROL_DIR}/hithe.py"
do
  [[ -f "${required}" ]] || err "missing source file: ${required}"
done

[[ "$(uname -s)" == "Darwin" ]] || err "this installer is macOS-only; use install-on-hermes.sh on Linux"
[[ "$(id -u)" -ne 0 ]] || err "do not run as root"

# ---------- brew + python preflight ----------
if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew not found. Install from https://brew.sh then re-run."
fi

if ! command -v python3.11 >/dev/null 2>&1; then
  err "python3.11 not found. Run:  brew install python@3.11   then re-run this script."
fi
PYTHON_BIN="$(command -v python3.11)"
log "using python: ${PYTHON_BIN} ($(${PYTHON_BIN} --version))"

if ! command -v curl >/dev/null 2>&1; then
  err "curl not on PATH (very unusual on macOS)"
fi

# afplay ships with macOS; warn only if absent (would block the standalone
# voice-id path from doing local TTS playback, but the relay path is the
# primary use case and doesn't need it).
if ! command -v afplay >/dev/null 2>&1; then
  warn "afplay not found — relay path still works, but standalone voice-id would not play TTS locally"
fi

# ---------- target layout ----------
DATA_DIR="${HOME}/.hermes/voice-companion"
SCRIPTS_DIR="${DATA_DIR}/scripts"
BIN_DIR="${DATA_DIR}/bin"
STATE_DIR="${DATA_DIR}/state"
GALLERY_DIR="${SCRIPTS_DIR}/gallery"
MODELS_DIR="${DATA_DIR}/models/ecapa"
VENV_DIR="${DATA_DIR}/.venv"
VOICES_DIR="${HOME}/.local/share/piper/voices"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
LOCAL_BIN_DIR="${HOME}/.local/bin"
HERMES_SKILLS_DIR="${HOME}/.hermes/skills/voice-id"
HERMES_CONTROL_SKILLS_DIR="${HOME}/.hermes/skills/control"

log "creating directories under ${DATA_DIR}"
mkdir -p "${SCRIPTS_DIR}" "${BIN_DIR}" "${STATE_DIR}" \
         "${GALLERY_DIR}" "${MODELS_DIR}" \
         "${VOICES_DIR}" "${LAUNCH_AGENTS_DIR}" "${LOCAL_BIN_DIR}" \
         "${HERMES_SKILLS_DIR}" "${HERMES_CONTROL_SKILLS_DIR}"

# ---------- copy scripts ----------
log "copying daemon scripts to ${SCRIPTS_DIR}"
install -m 0644 "${OPENCLAW_SKILL_DIR}/voice_id.py"        "${SCRIPTS_DIR}/voice_id.py"
install -m 0644 "${OPENCLAW_SKILL_DIR}/enroll.py"          "${SCRIPTS_DIR}/enroll.py"
install -m 0644 "${HERMES_SKILL_DIR}/tts_announce.py"      "${SCRIPTS_DIR}/tts_announce.py"
install -m 0755 "${HERMES_SKILL_DIR}/run-pipeline.sh"      "${SCRIPTS_DIR}/run-pipeline.sh"

log "registering SKILL.md files with Hermes"
install -m 0644 "${HERMES_SKILL_DIR}/SKILL.md"             "${HERMES_SKILLS_DIR}/SKILL.md"
install -m 0644 "${HERMES_CONTROL_DIR}/SKILL.md"           "${HERMES_CONTROL_SKILLS_DIR}/SKILL.md"

# hithe (control CLI). Pure-stdlib Python, no venv needed.
log "installing hithe control CLI to ${BIN_DIR} and ${LOCAL_BIN_DIR}"
install -m 0644 "${OPENCLAW_CONTROL_DIR}/hithe.py"         "${SCRIPTS_DIR}/hithe.py"
cat > "${BIN_DIR}/hithe" <<'WRAPPER'
#!/usr/bin/env bash
exec /usr/bin/env python3 "${HOME}/.hermes/voice-companion/scripts/hithe.py" "$@"
WRAPPER
chmod 0755 "${BIN_DIR}/hithe"
ln -sf "${BIN_DIR}/hithe" "${LOCAL_BIN_DIR}/hithe"

if [[ ! -f "${STATE_DIR}/active.flag" ]]; then
  touch "${STATE_DIR}/active.flag"
  log "default state set to ACTIVE (flag at ${STATE_DIR}/active.flag)"
fi

# ---------- config (preserve existing user edits) ----------
if [[ -f "${DATA_DIR}/config.yaml" ]]; then
  log "config.yaml already exists; leaving it alone"
else
  install -m 0644 "${HERMES_SKILL_DIR}/config.yaml" "${DATA_DIR}/config.yaml"
  # On macOS, switch audio_player default from aplay → afplay. afplay
  # cannot consume raw PCM from a pipe, so the standalone voice-id path
  # would still need `brew install sox` and `audio_player: play`; for the
  # relay path none of this matters.
  if command -v sed >/dev/null 2>&1; then
    sed -i '' 's|^audio_player: aplay|audio_player: afplay|' "${DATA_DIR}/config.yaml"
  fi
  log "wrote default config to ${DATA_DIR}/config.yaml (audio_player=afplay)"
fi

# Empty gallery if missing.
if [[ ! -f "${GALLERY_DIR}/voice_gallery.json" ]]; then
  echo '{}' > "${GALLERY_DIR}/voice_gallery.json"
  chmod 0600 "${GALLERY_DIR}/voice_gallery.json"
fi
chmod 0600 "${GALLERY_DIR}/voice_gallery.json" 2>/dev/null || true

# ---------- venv + deps ----------
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  log "creating venv at ${VENV_DIR}"
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi

log "upgrading pip / wheel inside venv"
"${VENV_DIR}/bin/pip" install --upgrade pip wheel >/dev/null

log "installing requirements (downloads torch on first run, ~700MB on macOS arm64)"
"${VENV_DIR}/bin/pip" install -r "${OPENCLAW_SKILL_DIR}/requirements.txt"

# ---------- piper voices ----------
download_voice() {
  local lang_dir="$1" speaker="$2" quality="$3"
  local file_base="${lang_dir}-${speaker}-${quality}"
  local onnx="${VOICES_DIR}/${file_base}.onnx"
  local cfg="${VOICES_DIR}/${file_base}.onnx.json"
  local lang_path
  case "${lang_dir}" in
    zh_CN) lang_path="zh/zh_CN" ;;
    en_US) lang_path="en/en_US" ;;
    *) err "unknown lang_dir: ${lang_dir}" ;;
  esac
  local base_url="https://huggingface.co/rhasspy/piper-voices/resolve/main/${lang_path}/${speaker}/${quality}/${file_base}"
  if [[ ! -f "${onnx}" ]]; then
    log "downloading piper voice ${file_base}.onnx"
    curl -fL --retry 3 -o "${onnx}" "${base_url}.onnx"
  fi
  if [[ ! -f "${cfg}" ]]; then
    log "downloading piper voice config ${file_base}.onnx.json"
    curl -fL --retry 3 -o "${cfg}" "${base_url}.onnx.json"
  fi
}

download_voice zh_CN huayan medium
download_voice en_US amy    medium

# ---------- launchd plist (render but do NOT load) ----------
PLIST_PATH="${LAUNCH_AGENTS_DIR}/com.hithe.voice-id-daemon.plist"
EXEC_PATH="${SCRIPTS_DIR}/run-pipeline.sh"

log "rendering launchd plist to ${PLIST_PATH} (not auto-loaded — relay-daemon is the primary path)"
sed \
  -e "s|__EXEC_PATH__|${EXEC_PATH}|g" \
  -e "s|__HOME__|${HOME}|g" \
  -e "s|__DATA_DIR__|${DATA_DIR}|g" \
  "${HERMES_SKILL_DIR}/voice-id-daemon.plist.template" > "${PLIST_PATH}"
chmod 0644 "${PLIST_PATH}"

if ! plutil -lint "${PLIST_PATH}" >/dev/null; then
  err "rendered plist failed plutil -lint; see ${PLIST_PATH}"
fi
log "plist syntax OK"

# ---------- next steps ----------
cat >&2 <<EOF

[install/voice-id-mac] done.

next steps:

  1) enroll yourself first (anchor for testing; needs a working mic):
       ${VENV_DIR}/bin/python ${SCRIPTS_DIR}/enroll.py \\
         --record --consent-confirmed --name-en Kang --name-zh 康
     macOS will prompt for Microphone access on first attempt; click Allow.

  2) install face-id (optional but recommended for parity):
       ${REPO_ROOT}/hermes-skill/face-id/install-on-mac.sh

  3) install the relay-daemon (this is the production path):
       ${REPO_ROOT}/hermes-skill/relay/install-on-mac.sh
     Then bootstrap it:
       launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.hithe.relay-daemon.plist

  4) hithe toggle (already on PATH if ~/.local/bin is on yours):
       hithe status
       hithe off
       hithe on

config:      ${DATA_DIR}/config.yaml          (audio_player=afplay on macOS)
gallery:     ${GALLERY_DIR}/voice_gallery.json (NEVER commit/transmit)
state flag:  ${STATE_DIR}/active.flag         (present = on)
logs:        ${DATA_DIR}/daemon.log, events.jsonl
EOF
