#!/usr/bin/env bash
# Idempotent installer for the Vision Companion face-id skill on macOS.
# Mirrors install-on-hermes.sh; uses Homebrew + launchd; reuses the shared
# venv at ~/.hermes/voice-companion/.venv (must be created by
# voice-id/install-on-mac.sh first).

set -euo pipefail

log()  { printf '[install/face-id-mac] %s\n' "$*" >&2; }
warn() { printf '[install/face-id-mac][warn] %s\n' "$*" >&2; }
err()  { printf '[install/face-id-mac][err]  %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HERMES_SKILL_DIR="${REPO_ROOT}/hermes-skill/face-id"
OPENCLAW_SKILL_DIR="${REPO_ROOT}/openclaw-skills/face-id"

for required in \
    "${HERMES_SKILL_DIR}/SKILL.md" \
    "${HERMES_SKILL_DIR}/run-face-pipeline.sh" \
    "${HERMES_SKILL_DIR}/face-id-daemon.plist.template" \
    "${OPENCLAW_SKILL_DIR}/face_id.py" \
    "${OPENCLAW_SKILL_DIR}/face_enroll.py" \
    "${OPENCLAW_SKILL_DIR}/requirements.txt"
do
  [[ -f "${required}" ]] || err "missing source file: ${required}"
done

[[ "$(uname -s)" == "Darwin" ]] || err "this installer is macOS-only"
[[ "$(id -u)" -ne 0 ]] || err "do not run as root"

DATA_DIR="${HOME}/.hermes/voice-companion"
SCRIPTS_DIR="${DATA_DIR}/scripts"
GALLERY_DIR="${SCRIPTS_DIR}/gallery"
MODELS_DIR="${DATA_DIR}/models/insightface"
VENV_DIR="${DATA_DIR}/.venv"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
HERMES_SKILLS_DIR="${HOME}/.hermes/skills/face-id"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  err "voice-id venv not found at ${VENV_DIR}; install voice-id first (hermes-skill/voice-id/install-on-mac.sh)"
fi

mkdir -p "${SCRIPTS_DIR}" "${GALLERY_DIR}" "${MODELS_DIR}" \
         "${LAUNCH_AGENTS_DIR}" "${HERMES_SKILLS_DIR}"

log "copying daemon scripts to ${SCRIPTS_DIR}"
install -m 0644 "${OPENCLAW_SKILL_DIR}/face_id.py"           "${SCRIPTS_DIR}/face_id.py"
install -m 0644 "${OPENCLAW_SKILL_DIR}/face_enroll.py"       "${SCRIPTS_DIR}/face_enroll.py"
install -m 0755 "${HERMES_SKILL_DIR}/run-face-pipeline.sh"   "${SCRIPTS_DIR}/run-face-pipeline.sh"

log "registering SKILL.md with Hermes at ${HERMES_SKILLS_DIR}"
install -m 0644 "${HERMES_SKILL_DIR}/SKILL.md"               "${HERMES_SKILLS_DIR}/SKILL.md"

if [[ ! -f "${GALLERY_DIR}/face_gallery.json" ]]; then
  echo '{}' > "${GALLERY_DIR}/face_gallery.json"
  chmod 0600 "${GALLERY_DIR}/face_gallery.json"
fi
chmod 0600 "${GALLERY_DIR}/face_gallery.json" 2>/dev/null || true

log "installing face-id Python deps into shared venv"
"${VENV_DIR}/bin/pip" install -r "${OPENCLAW_SKILL_DIR}/requirements.txt"

# Pre-warm the InsightFace download.
if "${VENV_DIR}/bin/python" -c "from insightface.app import FaceAnalysis" 2>/dev/null; then
  log "pre-downloading InsightFace buffalo_l model (~250MB)"
  if ! "${VENV_DIR}/bin/python" - <<PY
import sys
from insightface.app import FaceAnalysis
try:
    app = FaceAnalysis(name="buffalo_l", root="${MODELS_DIR}", providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1, det_size=(640, 640))
    print("model ready")
except Exception as e:
    print(f"model prefetch failed: {e}", file=sys.stderr)
    sys.exit(1)
PY
  then
    warn "InsightFace prefetch failed; daemon will download on first run instead"
  fi
fi

# Render plist (don't auto-load).
PLIST_PATH="${LAUNCH_AGENTS_DIR}/com.hithe.face-id-daemon.plist"
EXEC_PATH="${SCRIPTS_DIR}/run-face-pipeline.sh"

log "rendering launchd plist to ${PLIST_PATH} (not auto-loaded — relay-daemon is the primary path)"
sed \
  -e "s|__EXEC_PATH__|${EXEC_PATH}|g" \
  -e "s|__HOME__|${HOME}|g" \
  -e "s|__DATA_DIR__|${DATA_DIR}|g" \
  "${HERMES_SKILL_DIR}/face-id-daemon.plist.template" > "${PLIST_PATH}"
chmod 0644 "${PLIST_PATH}"

if ! plutil -lint "${PLIST_PATH}" >/dev/null; then
  err "rendered plist failed plutil -lint; see ${PLIST_PATH}"
fi
log "plist syntax OK"

cat >&2 <<EOF

[install/face-id-mac] done.

next steps:

  1) (optional) enroll a face. Needs a working camera; macOS will prompt
     for Camera access on first call. Click Allow.

       ${VENV_DIR}/bin/python ${SCRIPTS_DIR}/face_enroll.py \\
         --capture --consent-confirmed --name-en Kang --name-zh 康

  2) install the relay-daemon (primary path):
       ${REPO_ROOT}/hermes-skill/relay/install-on-mac.sh

  3) (only if you want the standalone face-id daemon to also run on this
     host) bootstrap the standalone face-id agent:
       launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.hithe.face-id-daemon.plist

models:  ${MODELS_DIR}/         (InsightFace cache; ~250 MB)
gallery: ${GALLERY_DIR}/face_gallery.json
logs:    ${DATA_DIR}/face-daemon.log, events.jsonl (shared)
EOF
