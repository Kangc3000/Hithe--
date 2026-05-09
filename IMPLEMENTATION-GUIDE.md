# Implementation Guide

How agents (Hermes Agent primarily, OpenClaw secondarily) implement
and orchestrate the Vision Companion skills. This document is the
contract between the agent layer and the daemon layer.

> **Read `PROJECT-SPEC.md` first.** This document assumes you've
> internalized the architecture and locked decisions there.

---

## 1. Two layers, two responsibilities

```
┌────────────────────────────────────────────┐
│              AGENT LAYER                   │
│   (Hermes Agent / OpenClaw / Claude Code)  │
│                                            │
│   - Reads SKILL.md                         │
│   - Handles user requests in natural lang  │
│   - Manages enrollment, config, status     │
│   - Learns and tunes thresholds over time  │
│   - Surfaces events to messaging channels  │
│                                            │
│   Latency budget: seconds (LLM-mediated)   │
└────────────────────┬───────────────────────┘
                     │
              JSON Lines events
              config.yaml
              gallery files
                     │
┌────────────────────┴───────────────────────┐
│              DAEMON LAYER                  │
│   (systemd services, plain Python)         │
│                                            │
│   - Real-time audio/image processing       │
│   - Embedding computation and matching     │
│   - TTS synthesis and playback             │
│   - No LLM in the hot path                 │
│                                            │
│   Latency budget: milliseconds             │
└────────────────────────────────────────────┘
```

**Why this split matters:** real-time identification cannot wait for
an LLM to make decisions on every audio window. The agent makes admin
decisions and learns *between* events; daemons do real-time work.

## 2. Skill format (agentskills.io standard)

All skills live under `~/.hermes/skills/<skill-name>/SKILL.md` with
this YAML frontmatter shape:

```yaml
---
name: skill-name
description: One-sentence description of what the skill does and when to use it. Be specific — agents use this string to decide whether to invoke the skill.
version: 0.1.0
metadata:
  hermes:
    tags: [accessibility, vision-companion, ...]
    category: assistive
    config:
      - key: voice_companion.data_dir
        description: Directory holding the voice gallery and event log
        default: "~/.hermes/voice-companion"
        prompt: "Where should this store its data?"
required_environment_variables:
  - OPENAI_API_KEY  # only when cloud APIs are used
platforms: [macos, linux]
---

# Skill markdown body

(prose teaching the agent when to use this skill, how to invoke
the underlying scripts, and what the success criteria are)
```

The body of `SKILL.md` should:
- Tell the agent **when to use** this skill (concrete trigger phrases)
- Tell the agent **when NOT to use** it (anti-triggers)
- Document the **exact CLI commands** to invoke
- List **edge cases the agent should handle**
- Include **self-improvement hints** for tuning over time

For a real example, see `hermes-skill/voice-id/SKILL.md`.

## 3. Daemon contracts

### 3.1 Process model

Each daemon is a single Python process managed by systemd (Linux user
unit) or launchd (macOS, future). It reads:

- **stdin** — for raw audio/video streams (when used in pipelines)
- **config file** — `~/.hermes/voice-companion/config.yaml`
- **gallery files** — `~/.hermes/voice-companion/scripts/gallery/*.json`

It writes:

- **stdout** — JSON Lines events (consumed by next stage in pipeline)
- **stderr** — human-readable logs
- **events.jsonl** — append-only event log for the agent to query later

### 3.2 JSON Lines event format (canonical)

Every event is one JSON object on one line, terminated with `\n`. All
events have these required fields:

```json
{
  "event": "<event_type>",
  "timestamp": "<ISO 8601 with seconds precision>",
  "...": "..."
}
```

Defined event types (this list is canonical — don't add ad-hoc events):

| event | Emitted by | Required fields beyond base |
|-------|------------|-----------------------------|
| `speaker_identified` | voice-id | `name_en`, `name_zh`, `confidence` |
| `face_identified` (Phase 2) | face-id | `name_en`, `name_zh`, `distance_estimate_m`, `bearing`, `confidence` |
| `unknown_speaker` | voice-id | `confidence` (best non-match score) |
| `unknown_face` (Phase 2) | face-id | `confidence`, `distance_estimate_m`, `bearing` |
| `scene_described` (Phase 3) | scene-describe | `frame_id`, `description`, `language`, `model` |
| `daemon_status` | any daemon | `daemon`, `status`, `message` |
| `mode_changed` | any daemon | `daemon`, `from_mode`, `to_mode` |

If a future skill needs a new event type, add it to this table first,
then implement.

### 3.3 Config schema

`~/.hermes/voice-companion/config.yaml` is the single source of runtime
config. Keys are namespaced by daemon. Daemons reload on
`systemctl --user restart <name>-daemon`, not on file write.

Top-level keys (current):

```yaml
# Voice ID
similarity_threshold: 0.65
announcement_cooldown_seconds: 8.0
silence_rms: 0.005

# Language routing
language_mode: mirror              # mirror | preferred_zh | preferred_en
preferred_language: zh

# TTS
piper_binary: piper
voices_dir: /home/<user>/.local/share/piper/voices
voice_zh: zh_CN-huayan-medium.onnx
voice_en: en_US-amy-medium.onnx
audio_player: aplay
announcement_template_zh: "{name_zh}"
announcement_template_en: "{name_en}"
rate_limit_seconds: 3.0

# Face ID (Phase 2)
face_similarity_threshold: 0.55    # ArcFace uses different scale than ECAPA
face_announcement_template_zh: "{name_zh},距離大約{distance_m}公尺"
face_announcement_template_en: "{name_en}, about {distance_m} meters"

# Scene description (Phase 3)
openai_model: gpt-5-mini
openai_max_tokens: 200
scene_describe_default_language: zh
scene_describe_modes: [scene, ocr, sign, menu]

# Hard interlocks (NEVER weaken these in code)
classroom_mode: false              # when true, blocks all cloud calls and face/voice ID
disable_cloud_apis_globally: false # emergency kill switch
```

### 3.4 Hard interlocks

Some flags MUST be enforced at the daemon level, not just the agent
level. The agent can lie or be tricked; the daemon is the source of
truth.

```python
# Pseudocode — every cloud-calling daemon MUST have this guard
def cloud_call_allowed(cfg):
    if cfg.get("classroom_mode"):
        return False, "classroom mode is active"
    if cfg.get("disable_cloud_apis_globally"):
        return False, "cloud APIs globally disabled"
    return True, None
```

## 4. Agent orchestration patterns

### 4.1 Enrollment (admin operation, agent-mediated)

The agent reads `SKILL.md`, the user says "enroll Sarah," the agent:

1. Confirms it has both the English and Chinese names
2. Confirms verbal consent has been given
3. Either runs the recording flow (`enroll.py --record`) or accepts
   sample paths (`enroll.py --samples ...`)
4. Reports back the result

The agent should never silently overwrite an existing entry — always
confirm overwrite explicitly with the user.

### 4.2 Status check (agent reads, doesn't write)

Agent reads:
- `systemctl --user status voice-id-daemon` for liveness
- `~/.hermes/voice-companion/daemon.log` (last N lines)
- `~/.hermes/voice-companion/events.jsonl` (last hour)

Reports a summary: daemon running, X events in last hour, last error
(if any), people enrolled.

### 4.3 Threshold tuning (agent-mediated, daemon-reloaded)

User says "voice-id is mistaking my brother for my dad too often."
Agent:

1. Reviews recent events to confirm the pattern
2. Suggests raising `similarity_threshold` from 0.65 → 0.70
3. On user approval, edits `config.yaml`
4. Restarts the daemon
5. Stores a memory of the change with reasoning

This is exactly what Hermes's persistent memory + skill system was
designed for. Use it.

### 4.4 Self-improvement memory hints

In `SKILL.md`, the agent gets prompted to capture learnings:

> "She says it announces [name] too often" → consider raising
> `announcement_cooldown_seconds` in config.yaml.

Hermes's persistent memory should accumulate these observations across
sessions. Patterns to track:

- Time-of-day effects
- Per-person accuracy
- Environmental noise correlations
- Language preference drift

### 4.5 Cloud-API skills (Phase 3)

Scene description uses OpenAI gpt-5-mini. The agent flow:

1. User taps Ray-Ban Meta touchpad → Android relay sends frame to
   `scene-describe` daemon over Tailscale
2. Daemon checks `cloud_call_allowed(cfg)` interlocks
3. Daemon calls OpenAI API with the frame
4. Daemon emits `scene_described` event
5. TTS bridge speaks the description

The agent never sees this hot path. Agent gets involved only if user
asks "what was the last thing the system told me?" — answered from
`events.jsonl`.

## 5. OpenClaw compatibility

The skills are framework-agnostic by design (D-012):

- The Python scripts (`enroll.py`, `voice_id.py`, `tts_announce.py`)
  are plain CLIs with no Hermes-specific imports.
- The `SKILL.md` follows the agentskills.io standard, which OpenClaw
  also supports.
- The systemd service file works on any modern Ubuntu, regardless of
  which agent framework manages the SKILL.md side.

To run on OpenClaw instead of (or in addition to) Hermes:

1. Place `SKILL.md` in OpenClaw's skills directory (typically
   `~/.openclaw/skills/voice-id/SKILL.md`).
2. Adjust paths in `config.yaml` if OpenClaw runs as a different user.
3. The systemd daemon runs unchanged.

You can run both Hermes and OpenClaw against the same daemon
simultaneously — they're just two readers of `events.jsonl`.

## 6. Messaging channel integration

The Hermes host already has a Line Developer endpoint set up
(per Kang's existing integration work). Suggested wiring:

- **Status queries** ("daemon 還在跑嗎?") → answer from systemctl status
- **Recent events** ("剛才誰說話?") → answer from events.jsonl
- **Threshold adjustments** ("提高靈敏度") → edit config + restart
- **Enrollment** kept to local CLI for now (consent confirmation needs
  more friction than a chat message)

Telegram or Signal would work equivalently. Don't add SMS — too easy
for spoofing in a system that has authority over biometric data.

## 7. What this guide does NOT cover

- The Android relay app (Kotlin) — see `docs/INSTALLATION-ANDROID.md`
- The Wearables Device Access Toolkit specifics — see Meta's docs
- Internal model architecture for ECAPA / ArcFace — see model docs
- Cloud API rate limiting / cost monitoring — implement when usage
  patterns are observable

## 8. Glossary

| Term | Meaning |
|------|---------|
| Skill | A `SKILL.md` markdown file teaching an agent what it can do |
| Daemon | A persistent Python service doing real-time work |
| Embedding | A numeric vector representing a voice or face |
| Gallery | The local JSON file holding embeddings + names |
| Hot path | Real-time code with strict latency requirements |
| Cold path | Admin/config code where seconds-of-latency is fine |
| Interlock | A hard safety check enforced in code, not just policy |
| Classroom mode | A config flag that disables all cloud + biometric features |
