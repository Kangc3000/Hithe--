#!/usr/bin/env bash
# Idempotent installer for the Vision Companion face-id skill on the
# dedicated Hermes Ubuntu host. Adds Phase 2 face recognition on top of
# the Phase 1 voice-id install. Safe to re-run.
#
# Prerequisite: voice-id must already be installed (this script reuses its
# venv at ~/.hermes/voice-companion/.venv). Run hermes-skill/voice-id/install-on-hermes.sh first.
#
# Run as the regular (non-root) user that owns the Hermes Agent install.
# Requires Python 3.11+, a USB webcam (or built-in camera) accessible at
# /dev/video0, and ~500MB free disk for InsightFace model + Python deps.
#
# Usage:
#   chmod +x install-on-hermes.sh
#   ./install-on-hermes.sh

set -euo pipefail

log()  { printf '[install/face-id] %s\n' "$*" >&2; }
warn() { printf '[install/face-id][warn] %s\n' "$*" >&2; }
err()  { printf '[install/face-id][err]  %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HERMES_SKILL_DIR="${REPO_ROOT}/hermes-skill/face-id"
OPENCLAW_SKILL_DIR="${REPO_ROOT}/openclaw-skills/face-id"

for required in \
    "${HERMES_SKILL_DIR}/SKILL.md" \
    "${HERMES_SKILL_DIR}/run-face-pipeline.sh" \
    "${HERMES_SKILL_DIR}/face-id-daemon.service" \
    "${OPENCLAW_SKILL_DIR}/face_id.py" \
    "${OPENCLAW_SKILL_DIR}/face_enroll.py" \
    "${OPENCLAW_SKILL_DIR}/requirements.txt"
do
  [[ -f "${required}" ]] || err "missing source file: ${required}"
done

[[ "$(uname -s)" == "Linux" ]] || err "this installer is Linux-only"
[[ "$(id -u)" -ne 0 ]] || err "do not run as root"

DATA_DIR="${HOME}/.hermes/voice-companion"
SCRIPTS_DIR="${DATA_DIR}/scripts"
GALLERY_DIR="${SCRIPTS_DIR}/gallery"
MODELS_DIR="${DATA_DIR}/models/insightface"
VENV_DIR="${DATA_DIR}/.venv"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
HERMES_SKILLS_DIR="${HOME}/.hermes/skills/face-id"

# Sanity check: voice-id must already be installed (shared venv + dirs).
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  err "voice-id venv not found at ${VENV_DIR}; install voice-id first (hermes-skill/voice-id/install-on-hermes.sh)"
fi

mkdir -p "${SCRIPTS_DIR}" "${GALLERY_DIR}" "${MODELS_DIR}" \
         "${SYSTEMD_USER_DIR}" "${HERMES_SKILLS_DIR}"

log "copying daemon scripts to ${SCRIPTS_DIR}"
install -m 0644 "${OPENCLAW_SKILL_DIR}/face_id.py"           "${SCRIPTS_DIR}/face_id.py"
install -m 0644 "${OPENCLAW_SKILL_DIR}/face_enroll.py"       "${SCRIPTS_DIR}/face_enroll.py"
install -m 0755 "${HERMES_SKILL_DIR}/run-face-pipeline.sh"   "${SCRIPTS_DIR}/run-face-pipeline.sh"

log "registering SKILL.md with Hermes at ${HERMES_SKILLS_DIR}"
install -m 0644 "${HERMES_SKILL_DIR}/SKILL.md"               "${HERMES_SKILLS_DIR}/SKILL.md"

# Empty face gallery if missing.
if [[ ! -f "${GALLERY_DIR}/face_gallery.json" ]]; then
  echo '{}' > "${GALLERY_DIR}/face_gallery.json"
  chmod 0600 "${GALLERY_DIR}/face_gallery.json"
  log "initialized empty face gallery (mode 0600)"
fi
chmod 0600 "${GALLERY_DIR}/face_gallery.json" 2>/dev/null || true

log "installing face-id Python deps into shared venv"
"${VENV_DIR}/bin/pip" install -r "${OPENCLAW_SKILL_DIR}/requirements.txt"

# Pre-warm the InsightFace download so first run isn't a 5-minute pause.
# Skipping if the user is offline or wants to defer; warn only.
if "${VENV_DIR}/bin/python" -c "from insightface.app import FaceAnalysis" 2>/dev/null; then
  log "pre-downloading InsightFace buffalo_l model (~250MB)"
  if ! "${VENV_DIR}/bin/python" - <<PY
import os, sys
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

log "installing systemd user unit for face-id"
install -m 0644 "${HERMES_SKILL_DIR}/face-id-daemon.service" \
                "${SYSTEMD_USER_DIR}/face-id-daemon.service"
systemctl --user daemon-reload

# Webcam device sanity check (warn only).
if [[ ! -e /dev/video0 ]]; then
  warn "/dev/video0 not present — plug in a USB webcam before starting the daemon"
fi
if ! groups | tr ' ' '\n' | grep -qx video; then
  warn "your user is not in the 'video' group; the daemon may fail to open the camera"
  warn "  fix:  sudo usermod -aG video ${USER}   (then log out/in)"
fi

cat >&2 <<EOF

[install/face-id] done.

next steps:

  1) enroll a face (start with yourself):
       ${VENV_DIR}/bin/python ${SCRIPTS_DIR}/face_enroll.py \\
         --capture --consent-confirmed \\
         --name-en Kang --name-zh 康

  2) start the face-id daemon:
       systemctl --user enable --now face-id-daemon

  3) check it's alive:
       systemctl --user status face-id-daemon
       tail -f ${DATA_DIR}/events.jsonl | grep -E 'face_identified|unknown_face|daemon_status'

  4) face the camera; you should hear your name + rough distance within ~1s.

  5) calibrate distance: stand at exactly 1m from the camera, note the
     announced distance, scale 'face_camera_focal_length_px' in
     ${DATA_DIR}/config.yaml accordingly, then restart the daemon.

shared with voice-id:
  config:  ${DATA_DIR}/config.yaml
  venv:    ${VENV_DIR}
  events:  ${DATA_DIR}/events.jsonl
EOF
