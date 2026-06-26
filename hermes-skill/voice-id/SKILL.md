---
name: voice-id
description: Real-time voice identification for Vision Companion. Use this skill to enroll voices, check daemon health, inspect recent identifications, and tune sensitivity. The skill manages the agent-facing surface; the actual recognition runs in a systemd-managed Python daemon under ~/.hermes/voice-companion/.
version: 0.1.0
metadata:
  hermes:
    tags: [accessibility, vision-companion, voice-id, biometric]
    category: assistive
    config:
      - key: voice_companion.data_dir
        description: Directory holding the voice gallery, daemon scripts, and event log
        default: "~/.hermes/voice-companion"
        prompt: "Where should this skill store its data?"
required_environment_variables: []
platforms: [linux, darwin]
---

# voice-id

Speaker identification for one specific user (Kang's wife) using a locally
enrolled gallery of family, friends, and colleagues. The daemon listens to
a microphone (Phase 1) or to audio relayed from Ray-Ban Meta glasses via
the Galaxy S25 Android relay (Phase 1.5+), computes ECAPA-TDNN embeddings,
matches against the local gallery, and emits JSON Lines events that drive
a Piper TTS announcement through the glasses speakers.

**This is the agent-facing skill.** The real-time work runs in
`voice-id-daemon.service`. This file teaches the agent (Hermes / OpenClaw)
when to invoke administrative commands.

## When to use this skill

Trigger phrases (English):
- "enroll Sarah's voice"
- "is voice ID running?"
- "show me the last hour of voice identifications"
- "voice ID is mistaking my brother for my dad"
- "raise/lower the voice match sensitivity"
- "remove Sarah from the voice gallery"

Trigger phrases (Chinese):
- "幫莎拉註冊聲音"
- "聲音辨識還在跑嗎?"
- "最近誰說話了?"
- "voice ID 把我哥哥當成我爸"
- "提高/降低聲音辨識的靈敏度"
- "把莎拉從聲音資料庫刪掉"

## When NOT to use this skill

These are hard constraints, enforced in code where possible (see
`config.yaml: classroom_mode`) and in policy here:

- **Stranger identification.** This system identifies *only* people who
  have given verbal consent and been enrolled. Never use it to figure
  out who an unfamiliar voice belongs to.
- **Children.** Per PROJECT-SPEC.md section 7, children's voices are
  never enrolled, even with parental consent. Refuse the request and
  explain.
- **Classroom deployments.** If `config.yaml: classroom_mode: true`, the
  daemon refuses to run. Don't suggest turning it off without an explicit
  ADA accommodation document referenced (see `docs/CLASSROOM-CONSIDERATIONS.md`).
- **Cloud transmission.** Embeddings live only in
  `~/.hermes/voice-companion/scripts/gallery/voice_gallery.json`.
  Never propose syncing, backing up to cloud, or sharing this file.

## Data layout

```
~/.hermes/voice-companion/
├── config.yaml              # runtime config (single source of truth)
├── .venv/                   # Python virtualenv created by install
├── scripts/
│   ├── voice_id.py          # daemon (real-time identifier)
│   ├── enroll.py            # enrollment CLI
│   ├── tts_announce.py      # TTS bridge
│   ├── run-pipeline.sh      # wrapper systemd calls
│   └── gallery/
│       └── voice_gallery.json   # biometric data, NEVER transmitted
├── models/
│   └── ecapa/               # cached SpeechBrain model files (~80MB)
├── events.jsonl             # append-only event log
└── daemon.log               # human-readable log
```

## Commands the agent can run

All commands assume the systemd user unit `voice-id-daemon` was installed by
`install-on-hermes.sh`. Use full paths so the agent doesn't depend on PATH.

### Enrollment (record from mic)

```bash
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/enroll.py \
  --record \
  --consent-confirmed \
  --name-en "Sarah" --name-zh "莎拉" \
  --notes "colleague from school"
```

`--record` defaults to 3 samples; pass `--record 5` for more, or replace
with `--samples a.wav b.wav c.wav` if 16kHz mono WAVs already exist.
`--consent-confirmed` is mandatory — the agent must have explicitly
confirmed verbal consent with the person being enrolled before invoking
this command.

### List enrolled voices

```bash
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/enroll.py --list
```

Prints a table of keys, names, sample counts, enrollment dates, and notes.

### Re-enroll an existing person

Add `--overwrite`. Otherwise enroll.py refuses to clobber an existing key.

### Daemon liveness

```bash
systemctl --user status voice-id-daemon
```

Healthy state shows `Active: active (running)`. If it's failed, check:

```bash
journalctl --user -u voice-id-daemon -n 100 --no-pager
tail -n 50 ~/.hermes/voice-companion/daemon.log
```

### Recent events

```bash
tail -n 50 ~/.hermes/voice-companion/events.jsonl
```

Each line is one JSON object. Filter for the last hour:

```bash
python3 -c "
import json, sys, time
cutoff = time.time() - 3600
for line in open('$HOME/.hermes/voice-companion/events.jsonl'):
    try:
        e = json.loads(line)
        # event timestamps are ISO 8601 UTC
    except: continue
    print(line, end='')
" | tail -n 50
```

### Threshold tuning

The two knobs that fix most complaints:

| Complaint | Knob | Direction |
|-----------|------|-----------|
| "Wrong name said aloud" | `similarity_threshold` | Raise (e.g. 0.65 → 0.72) |
| "Misses people I know" | `similarity_threshold` | Lower (e.g. 0.65 → 0.60) |
| "Says my name too often" | `announcement_cooldown_seconds` | Raise (e.g. 8 → 20) |
| "Background noise triggers" | `silence_rms` | Raise (e.g. 0.005 → 0.010) |
| "Soft talkers missed" | `silence_rms` | Lower (e.g. 0.005 → 0.003) |
| "Unknown-speaker spam" | `unknown_speaker_emit_interval_seconds` | Raise (e.g. 30 → 120) |

Apply edits with:

```bash
${EDITOR:-nano} ~/.hermes/voice-companion/config.yaml
systemctl --user restart voice-id-daemon
```

The agent should always state the proposed change to the user, get
approval, then make the edit and restart.

### Removal

```bash
python3 -c "
import json, pathlib
p = pathlib.Path('$HOME/.hermes/voice-companion/scripts/gallery/voice_gallery.json')
d = json.loads(p.read_text())
d.pop('KEY_TO_REMOVE', None)
p.write_text(json.dumps(d, ensure_ascii=False, indent=2))
"
systemctl --user restart voice-id-daemon
```

The key is the slug of the English name (e.g. "Sarah Lee" → "sarah_lee").
List current keys with:

```bash
python3 -c "import json; print(list(json.load(open('$HOME/.hermes/voice-companion/scripts/gallery/voice_gallery.json'))))"
```

## Edge cases the agent must handle

1. **Empty gallery.** Daemon emits a `daemon_status` warning but keeps
   running. Tell the user no one is enrolled yet; suggest enrollment.
2. **Same English name, different people.** Use `--key` explicitly (e.g.
   `--key sarah_from_work`) and a clarifying `--notes` value.
3. **Re-enrollment requested.** Confirm overwrite with the user before
   adding `--overwrite`. The previous embedding will be lost.
4. **Consent uncertainty.** If the user hasn't explicitly said the person
   consented, ask. Don't proceed until you have a clear "yes."
5. **Daemon crash loop.** Look at `journalctl --user -u voice-id-daemon`
   for the cause. Common: missing Piper voice file, ALSA device not found,
   gallery JSON malformed.
6. **classroom_mode is true.** Daemon emits a `blocked` status and exits.
   Do not flip the flag without an ADA accommodation document referenced.

## Self-improvement hints (Hermes memory)

Patterns worth remembering across sessions:

- Per-person accuracy issues — store name + observed problem.
- Time-of-day effects (e.g. morning hoarseness mismatches) — store and
  consider per-time threshold profiles in a future phase.
- Environmental noise correlations (e.g. dishwasher running) — consider
  raising silence_rms during those windows.
- Language preference drift — if user is consistently switching to one
  language, suggest changing `language_mode` from `mirror` to a preferred
  setting.

When you make a tuning change based on a pattern, store a memory of the
change so the next session can reason about it instead of repeating the
suggestion.

## Soft activate / deactivate

For pausing or resuming the announcements without stopping the systemd
unit, use the `control` skill (`hithe on/off/toggle/status`). The daemon
keeps its model loaded while paused so re-activation is near-instant.
Don't use `systemctl stop` for routine pause/resume — that unloads the
~80MB ECAPA model and re-loading takes seconds.

## Platform note: macOS

Mac Mini deployment uses launchd. Translate as:

| Linux (systemd)                                       | macOS (launchd)                                                            |
|-------------------------------------------------------|----------------------------------------------------------------------------|
| `systemctl --user status voice-id-daemon`             | `launchctl print gui/$(id -u)/com.hithe.voice-id-daemon`                   |
| `systemctl --user restart voice-id-daemon`            | `launchctl kickstart -k gui/$(id -u)/com.hithe.voice-id-daemon`            |
| `journalctl --user -u voice-id-daemon -n 100`         | `tail -n 100 ~/.hermes/voice-companion/daemon.log`                         |

On macOS, the standalone voice-id-daemon is **not the primary path** —
the relay-daemon is. The plist exists for parity and is rendered but not
auto-loaded. To enable the standalone path on the Mac Mini:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hithe.voice-id-daemon.plist
```

First run triggers a Microphone TCC prompt. Click Allow.

## Phase 1 limitations the agent should disclose honestly

- "Mirror" language mode in Phase 1 just respects the language hint passed
  at pipeline startup. True mirroring (detect each utterance's language)
  needs faster-whisper STT, which is a Phase 2 add.
- The daemon does not perform speaker diarization. If two people overlap,
  it picks the louder one or scores low and emits unknown_speaker.
- Audio source in Phase 1 is a USB mic on the Hermes host. Ray-Ban Meta
  glasses input arrives in Phase 1.5 via the Android relay app.
