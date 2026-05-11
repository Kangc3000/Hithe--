---
name: face-id
description: Real-time face identification for Vision Companion (Phase 2). Use this skill to enroll faces, check daemon health, inspect recent identifications, and tune sensitivity. The skill manages the agent-facing surface; the actual recognition runs in a systemd-managed Python daemon under ~/.hermes/voice-companion/.
version: 0.1.0
metadata:
  hermes:
    tags: [accessibility, vision-companion, face-id, biometric]
    category: assistive
    config:
      - key: voice_companion.data_dir
        description: Directory holding the face gallery, daemon scripts, and event log
        default: "~/.hermes/voice-companion"
        prompt: "Where should this skill store its data?"
required_environment_variables: []
platforms: [linux]
---

# face-id

Visual identification of consensually enrolled people, plus rough distance
and bearing estimates. Reads frames from a USB webcam (Phase 2) or from
the Android relay's image stream (Phase 2.5+), runs InsightFace
detection + ArcFace embedding, matches against the local face gallery,
and emits JSON Lines events that the shared TTS bridge announces through
the host (or eventually the glasses).

**This is the agent-facing skill.** The real-time work runs in
`face-id-daemon.service`. This file teaches the agent (Hermes / OpenClaw)
when to invoke administrative commands.

Most of the architecture, privacy posture, and operational guidance is
shared with `voice-id`. This file documents only what differs.

## When to use this skill

Trigger phrases (English):
- "enroll Sarah's face"
- "is face ID running?"
- "show me the last hour of face identifications"
- "raise/lower the face match sensitivity"
- "remove Sarah from the face gallery"

Trigger phrases (Chinese):
- "幫莎拉註冊臉"
- "臉部辨識還在跑嗎?"
- "最近看到誰?"
- "提高/降低臉部辨識的靈敏度"
- "把莎拉從臉部資料庫刪掉"

## When NOT to use this skill

Same constraints as voice-id, restated for clarity:

- **Stranger identification.** This is not a "who is that?" tool. It only
  identifies people who have given verbal consent and been enrolled.
- **Children.** Per PROJECT-SPEC.md section 7, never. Refuse and explain.
- **Classroom deployments.** If `config.yaml: classroom_mode: true`, the
  daemon refuses to run. Don't suggest disabling without an explicit ADA
  accommodation document referenced.
- **Cloud transmission.** Face embeddings live only in
  `~/.hermes/voice-companion/scripts/gallery/face_gallery.json`. Never
  propose syncing or backing up to cloud.

## Data layout

```
~/.hermes/voice-companion/
├── config.yaml                      # shared with voice-id
├── .venv/                           # shared venv with voice-id
├── scripts/
│   ├── face_id.py                   # face daemon
│   ├── face_enroll.py               # face enrollment CLI
│   ├── tts_announce.py              # shared TTS bridge (handles both event types)
│   ├── run-face-pipeline.sh         # wrapper systemd-face calls
│   └── gallery/
│       └── face_gallery.json        # biometric data, NEVER transmitted
├── models/
│   └── insightface/                 # cached InsightFace buffalo_l (~250MB)
└── events.jsonl                     # shared event log with voice-id
```

## Commands

### Enrollment from webcam

```bash
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/face_enroll.py \
  --capture \
  --consent-confirmed \
  --name-en "Sarah" --name-zh "莎拉" \
  --notes "colleague from school"
```

`--capture` defaults to 3 frames; pass `--capture 5` for more, or replace
with `--samples a.jpg b.jpg` for pre-existing image files.

### Enrollment from existing photos

```bash
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/face_enroll.py \
  --samples kang_1.jpg kang_2.jpg kang_3.jpg \
  --consent-confirmed \
  --name-en "Kang" --name-zh "康"
```

Photos should show one clear face per image, neutral lighting, no
sunglasses. If multiple faces are present, the largest one is used.

### List enrolled faces

```bash
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/face_enroll.py --list
```

### Daemon liveness

```bash
systemctl --user status face-id-daemon
journalctl --user -u face-id-daemon -n 100 --no-pager
```

### Recent face events

The face-id daemon writes to the same `events.jsonl` as voice-id.

```bash
tail -n 100 ~/.hermes/voice-companion/events.jsonl | grep -E 'face_identified|unknown_face'
```

### Threshold and tuning

| Complaint | Knob | Direction |
|-----------|------|-----------|
| "Wrong name said for someone's face" | `face_similarity_threshold` | Raise (0.55 → 0.62) |
| "Doesn't recognize me when I'm wearing a hat" | re-enroll with hat samples | n/a |
| "Distance announced is way off" | `face_camera_focal_length_px` | Calibrate (see below) |
| "Background people get announced" | reduce camera FOV / move camera | n/a |
| "Too many unknown_face events" | `unknown_face_emit_interval_seconds` | Raise |
| "CPU at 100%" | `face_target_fps` | Lower (5 → 3) |

### Distance calibration

Default `face_camera_focal_length_px: 600` is a guess. To calibrate:

1. Stand exactly 1 meter from the camera.
2. Wait for the daemon to announce you. Note the distance it reports.
3. Adjust: `new_focal_length = 600 × (announced_distance / 1.0)`
4. Edit config.yaml; restart the daemon.
5. Re-test at 2m and 3m to confirm.

## Edge cases

1. **Empty gallery** — daemon emits `daemon_status warning` and keeps
   running. Suggest enrollment.
2. **Multiple faces in frame** — daemon identifies each above threshold;
   per-name cooldown prevents spam.
3. **No face visible at all** — silent (no event); not an error.
4. **Webcam unplugged or held by another process** — daemon emits
   `daemon_status error` and exits; systemd restarts it.
5. **Face enrolled but consistently misidentified as someone else** —
   raise `face_similarity_threshold`, then if needed re-enroll the
   ambiguous person with more diverse samples.

## Soft activate / deactivate

Both face-id and voice-id share a single global on/off flag managed by
the `control` skill (`hithe on/off/toggle/status`). When deactivated,
face-id keeps its InsightFace model loaded but discards every frame on
the hot path — toggling back on is near-instant. Use `hithe`, not
`systemctl stop`, for routine pause/resume.

## Self-improvement hints

- If the same pair of people is repeatedly confused, store a memory and
  consider per-person threshold profiles in a future phase.
- Dim lighting → ArcFace quality drops. Note time-of-day patterns.
- Hat / glasses / mask changes → store and consider auxiliary samples.

## Phase 2 limitations the agent should disclose honestly

- Image source in Phase 2 is a USB webcam on the Hermes host. Glasses
  POV input arrives in Phase 2.5+ via the Android relay app.
- Distance estimation is best-effort pinhole geometry. Useful for "close
  vs far" but not measurement-grade.
- No face tracking across frames. Same person walking through frame
  may be identified multiple times unless the per-name cooldown applies.
- Cross-daemon coordination with voice-id is not implemented in Phase 2;
  if both fire within ~2s for the same person, both announcements play.
  The global `rate_limit_seconds` in each pipeline reduces collision
  but doesn't eliminate it.
