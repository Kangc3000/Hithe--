#!/usr/bin/env bash
# Wrapper that systemd's face-id-daemon.service ExecStart points at.
# Activates the venv (shared with voice-id) and pipes face_id.py JSON Lines
# into tts_announce.py.

set -euo pipefail

DATA_DIR="${HOME}/.hermes/voice-companion"
VENV="${DATA_DIR}/.venv"
SCRIPTS="${DATA_DIR}/scripts"
CONFIG="${DATA_DIR}/config.yaml"
GALLERY="${SCRIPTS}/gallery/face_gallery.json"
EVENTS_LOG="${DATA_DIR}/events.jsonl"

# Language hint for "mirror" mode. Same convention as run-pipeline.sh.
LAST_INPUT_LANG="${LAST_INPUT_LANG:-zh}"

# Webcam device index, in case the host has multiple cameras. Default 0.
WEBCAM_DEVICE="${WEBCAM_DEVICE:-0}"

if [[ ! -x "${VENV}/bin/python" ]]; then
  echo "venv not found at ${VENV}; run install-on-hermes.sh (Linux) or install-on-mac.sh (macOS) first" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${VENV}/bin/activate"

mkdir -p "$(dirname "${EVENTS_LOG}")"

# face_id.py emits JSON Lines on stdout. tee to events.jsonl so the event
# history persists across daemon restarts on both systemd and launchd
# (launchd's StandardOutPath truncates; tee -a doesn't).
exec python -u "${SCRIPTS}/face_id.py" \
    --webcam "${WEBCAM_DEVICE}" \
    --config "${CONFIG}" \
    --gallery "${GALLERY}" \
  | tee -a "${EVENTS_LOG}" \
  | python -u "${SCRIPTS}/tts_announce.py" \
    --config "${CONFIG}" \
    --last-input-lang "${LAST_INPUT_LANG}"
