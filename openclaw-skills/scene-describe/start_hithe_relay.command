#!/bin/zsh

set -e

SERVICE_NAME="Hithe OpenAI API Key"
ACCOUNT_NAME="$USER"
SCRIPT_DIR="${0:A:h}"

OPENAI_API_KEY="$(security find-generic-password -a "$ACCOUNT_NAME" -s "$SERVICE_NAME" -w 2>/dev/null || true)"

if [[ -z "$OPENAI_API_KEY" ]]; then
  echo "Hithe needs an OpenAI API key for visual questions."
  echo "The key will be stored in your Mac Keychain and will not be saved in Git."
  echo
  read -s "OPENAI_API_KEY?Paste your OpenAI API key, then press Return: "
  echo
  if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "No key entered. The relay was not started."
    read "?Press Return to close this window."
    exit 1
  fi
  security add-generic-password \
    -U \
    -a "$ACCOUNT_NAME" \
    -s "$SERVICE_NAME" \
    -w "$OPENAI_API_KEY" >/dev/null
  echo "Key saved securely in Mac Keychain."
fi

export OPENAI_API_KEY
cd "$SCRIPT_DIR"
echo "Starting Hithe. Keep this Terminal window open while using Timothy."
exec python3 scene_server.py
