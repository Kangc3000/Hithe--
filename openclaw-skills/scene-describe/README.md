# Hithe Scene Relay

This small Mac service receives an on-demand spoken question and up to eight
ordered JPEG frames from the Hithe iPhone app, asks OpenAI for a concise
accessibility answer, and returns only the text. It does not save images,
questions, or descriptions.

## Run

On this Mac, double-click `start_hithe_relay.command`. The first run prompts
privately for an OpenAI API key and stores it in macOS Keychain. Keep that
Terminal window open while using Timothy.

The equivalent manual command is:

```bash
cd openclaw-skills/scene-describe
export OPENAI_API_KEY="your-key-here"
python3 scene_server.py
```

The iPhone and Mac must be on the same local network. The default iPhone app
setting is `http://Kangs-iMac.local:8787/describe`.

Check the relay with:

```bash
curl http://localhost:8787/health
```

Set `HITHE_CLASSROOM_MODE=true` or `HITHE_DISABLE_CLOUD_APIS=true` to block all
cloud image requests.
