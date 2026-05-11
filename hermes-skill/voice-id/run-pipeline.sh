#!/usr/bin/env bash
# Wrapper that systemd's voice-id-daemon.service ExecStart points at.
# Activates the venv and pipes voice_id.py JSON Lines into tts_announce.py.
#
# Stdout from the wrapper is JSON Lines events (captured by systemd to
# events.jsonl); stderr is human-readable logs (captured to daemon.log).
# tts_announce.py reads from voice_id.py's stdout via the pipe and writes
# its own diagnostic logs to stderr.

set -euo pipefail

DATA_DIR="${HOME}/.hermes/voice-companion"
VENV="${DATA_DIR}/.venv"
SCRIPTS="${DATA_DIR}/scripts"
CONFIG="${DATA_DIR}/config.yaml"
GALLERY="${SCRIPTS}/gallery/voice_gallery.json"

# Language hint for "mirror" mode. The orchestrator (Hermes) can change this
# by editing config.yaml's preferred_language and restarting the unit, or by
# overriding LAST_INPUT_LANG via systemd drop-in.
LAST_INPUT_LANG="${LAST_INPUT_LANG:-zh}"

if [[ ! -x "${VENV}/bin/python" ]]; then
  echo "venv not found at ${VENV}; run install-on-hermes.sh first" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${VENV}/bin/activate"

# voice_id.py emits JSON Lines on stdout; tts_announce.py consumes them.
# We use process substitution to keep both in the same systemd unit so a
# crash of either tears down the whole pipeline (Restart=on-failure).
exec python -u "${SCRIPTS}/voice_id.py" \
    --listen-mic \
    --config "${CONFIG}" \
    --gallery "${GALLERY}" \
  | python -u "${SCRIPTS}/tts_announce.py" \
    --config "${CONFIG}" \
    --last-input-lang "${LAST_INPUT_LANG}"
