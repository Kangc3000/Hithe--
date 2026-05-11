#!/usr/bin/env bash
# Idempotent installer for the Vision Companion voice-id skill on the
# dedicated Hermes Ubuntu host. Safe to re-run.
#
# Run as the regular (non-root) user that owns the Hermes Agent install.
# Requires Python 3.11+, alsa-utils (for aplay), curl, and ~3GB free disk
# (most of which is torch's wheel).
#
# Usage:
#   chmod +x install-on-hermes.sh
#   ./install-on-hermes.sh

set -euo pipefail

# ---------- helpers ----------
log()  { printf '[install] %s\n' "$*" >&2; }
warn() { printf '[install][warn] %s\n' "$*" >&2; }
err()  { printf '[install][err]  %s\n' "$*" >&2; exit 1; }

# ---------- locate sources ----------
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HERMES_SKILL_DIR="${REPO_ROOT}/hermes-skill/voice-id"
HERMES_CONTROL_DIR="${REPO_ROOT}/hermes-skill/control"
OPENCLAW_SKILL_DIR="${REPO_ROOT}/openclaw-skills/voice-id"
OPENCLAW_CONTROL_DIR="${REPO_ROOT}/openclaw-skills/control"

for required in \
    "${HERMES_SKILL_DIR}/config.yaml" \
    "${HERMES_SKILL_DIR}/tts_announce.py" \
    "${HERMES_SKILL_DIR}/run-pipeline.sh" \
    "${HERMES_SKILL_DIR}/voice-id-daemon.service" \
    "${HERMES_SKILL_DIR}/SKILL.md" \
    "${HERMES_CONTROL_DIR}/SKILL.md" \
    "${OPENCLAW_SKILL_DIR}/voice_id.py" \
    "${OPENCLAW_SKILL_DIR}/enroll.py" \
    "${OPENCLAW_SKILL_DIR}/requirements.txt" \
    "${OPENCLAW_CONTROL_DIR}/hithe.py"
do
  [[ -f "${required}" ]] || err "missing source file: ${required}"
done

# ---------- preflight ----------
[[ "$(uname -s)" == "Linux" ]] || err "this installer is Linux-only (detected: $(uname -s))"
[[ "$(id -u)" -ne 0 ]] || err "do not run as root; run as the regular user that owns Hermes"

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 not found; install python3.11+ first"
fi

PY_MIN="3.11"
PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)"; then
  err "python3 ${PY_VER} found; voice-id needs >= ${PY_MIN}"
fi

for cmd in curl aplay; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    warn "'${cmd}' not found on PATH; voice-id may not work until you install it"
  fi
done

# ---------- target layout ----------
DATA_DIR="${HOME}/.hermes/voice-companion"
SCRIPTS_DIR="${DATA_DIR}/scripts"
BIN_DIR="${DATA_DIR}/bin"
STATE_DIR="${DATA_DIR}/state"
GALLERY_DIR="${SCRIPTS_DIR}/gallery"
MODELS_DIR="${DATA_DIR}/models/ecapa"
VENV_DIR="${DATA_DIR}/.venv"
VOICES_DIR="${HOME}/.local/share/piper/voices"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
LOCAL_BIN_DIR="${HOME}/.local/bin"
HERMES_SKILLS_DIR="${HOME}/.hermes/skills/voice-id"
HERMES_CONTROL_SKILLS_DIR="${HOME}/.hermes/skills/control"

log "creating directories under ${DATA_DIR}"
mkdir -p "${SCRIPTS_DIR}" "${BIN_DIR}" "${STATE_DIR}" \
         "${GALLERY_DIR}" "${MODELS_DIR}" \
         "${VOICES_DIR}" "${SYSTEMD_USER_DIR}" "${LOCAL_BIN_DIR}" \
         "${HERMES_SKILLS_DIR}" "${HERMES_CONTROL_SKILLS_DIR}"

# ---------- copy scripts ----------
log "copying daemon scripts to ${SCRIPTS_DIR}"
install -m 0644 "${OPENCLAW_SKILL_DIR}/voice_id.py"        "${SCRIPTS_DIR}/voice_id.py"
install -m 0644 "${OPENCLAW_SKILL_DIR}/enroll.py"          "${SCRIPTS_DIR}/enroll.py"
install -m 0644 "${HERMES_SKILL_DIR}/tts_announce.py"      "${SCRIPTS_DIR}/tts_announce.py"
install -m 0755 "${HERMES_SKILL_DIR}/run-pipeline.sh"      "${SCRIPTS_DIR}/run-pipeline.sh"

# Hermes Agent looks for skills under ~/.hermes/skills/<skill>/SKILL.md.
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

# Default to active on first install (don't overwrite existing flag state).
if [[ ! -f "${STATE_DIR}/active.flag" ]]; then
  touch "${STATE_DIR}/active.flag"
  log "default state set to ACTIVE (flag at ${STATE_DIR}/active.flag)"
fi

# ---------- config (don't clobber a customized file) ----------
if [[ -f "${DATA_DIR}/config.yaml" ]]; then
  log "config.yaml already exists; leaving it alone"
  log "  if you want the new defaults, diff against ${HERMES_SKILL_DIR}/config.yaml"
else
  install -m 0644 "${HERMES_SKILL_DIR}/config.yaml" "${DATA_DIR}/config.yaml"
  log "wrote default config to ${DATA_DIR}/config.yaml"
fi

# Empty gallery if missing so the daemon doesn't warn on first start.
if [[ ! -f "${GALLERY_DIR}/voice_gallery.json" ]]; then
  echo '{}' > "${GALLERY_DIR}/voice_gallery.json"
  chmod 0600 "${GALLERY_DIR}/voice_gallery.json"
  log "initialized empty voice gallery (mode 0600)"
fi
# Tighten gallery permissions even if it existed.
chmod 0600 "${GALLERY_DIR}/voice_gallery.json" 2>/dev/null || true

# ---------- venv + deps ----------
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  log "creating venv at ${VENV_DIR}"
  python3 -m venv "${VENV_DIR}"
fi

log "upgrading pip / wheel inside venv"
"${VENV_DIR}/bin/pip" install --upgrade pip wheel >/dev/null

log "installing requirements (this downloads ~2GB of torch on first run)"
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

if command -v curl >/dev/null 2>&1; then
  download_voice zh_CN huayan medium
  download_voice en_US amy    medium
else
  warn "skipping piper voice download because curl is missing"
fi

# ---------- systemd user unit ----------
log "installing systemd user unit"
install -m 0644 "${HERMES_SKILL_DIR}/voice-id-daemon.service" \
                "${SYSTEMD_USER_DIR}/voice-id-daemon.service"

systemctl --user daemon-reload

# Enable lingering so the unit can run when the user isn't logged in via tty.
# loginctl enable-linger requires sudo; print a hint instead of failing.
if loginctl show-user "${USER}" 2>/dev/null | grep -q '^Linger=no'; then
  warn "user lingering is OFF; the daemon will only run while you're logged in"
  warn "to keep it running headless, run:  sudo loginctl enable-linger ${USER}"
fi

# ---------- next steps ----------
cat >&2 <<EOF

[install] done.

next steps:

  1) enroll yourself first (your voice anchors testing):
       ${VENV_DIR}/bin/python ${SCRIPTS_DIR}/enroll.py \\
         --record --consent-confirmed --name-en Kang --name-zh 康

  2) start the daemon:
       systemctl --user enable --now voice-id-daemon

  3) check it's alive:
       systemctl --user status voice-id-daemon
       tail -f ${DATA_DIR}/events.jsonl

  4) when you (or someone enrolled) speak, you should hear their name spoken
     back through the default audio output within ~2 seconds.

  5) toggle the system on/off:
       hithe status      # if ~/.local/bin is on PATH
       hithe off
       hithe on
       hithe toggle
     (full path: ${BIN_DIR}/hithe)

config lives at:  ${DATA_DIR}/config.yaml
gallery lives at: ${GALLERY_DIR}/voice_gallery.json   (NEVER commit/transmit this)
state flag:       ${STATE_DIR}/active.flag           (default: present = active)
logs:             ${DATA_DIR}/daemon.log  +  ${DATA_DIR}/events.jsonl
EOF
