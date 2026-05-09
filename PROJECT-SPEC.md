# Vision Companion — Project Specification

**Status:** Design locked, Phase 1 in build
**Last updated:** 2026-05-09
**Owner:** Kang (kangatnewyork.com)

This is the canonical specification for Vision Companion. When agents
(Claude Code, Hermes, OpenClaw) work on this project, this document is
the source of truth. If `README.md` and this document disagree, this
document wins.

---

## 1. Purpose

A personal assistive system for one specific user — Kang's wife — who has
low vision. The system pairs Ray-Ban Meta Gen 1 glasses with a dedicated
Hermes Agent host to provide:

- **Real-time speaker identification** from a consenting enrolled circle
  of family, friends, and colleagues
- **Real-time face identification** of the same enrolled circle (Phase 2)
- **On-demand scene description** via cloud vision API (Phase 3)
- **Object/sign awareness** for street and traffic context (Phase 4,
  with safety caveats)

The system is deliberately *not* a stranger-recognition tool, *not*
deployable in classrooms without formal ADA accommodation, and *not*
a replacement for her white cane or other established AT.

## 2. User profile (locked)

| Attribute | Value |
|-----------|-------|
| Vision | Low vision (residual sight; uses screen magnification daily) |
| Phone | Samsung Galaxy S25 (Android 15 / One UI 7) |
| Glasses | Ray-Ban Meta Gen 1 (already owned and in use) |
| Languages | ~80% Traditional Chinese / 20% English personal life; 100% English at work |
| Profession | Music teacher in a NYC special education school |

## 3. Architecture (locked)

```
┌──────────────────────────────────────────┐
│  Ray-Ban Meta (Gen 1 + Gen 2)            │
│  • 12MP camera | 5-mic array             │
│  • Open-ear speakers                     │
│  • ~4hr active battery                   │
│  • Gen 1 is the currently-owned device   │
└────────────┬─────────────────────────────┘
             │ Bluetooth LE
             │ (Wearables Device Access Toolkit for Android)
             │
┌────────────┴─────────────────────────────┐
│  Samsung Galaxy S25 (Android relay app)  │
│  • Kotlin / Android Studio               │
│  • Min SDK 29 (Android 10)               │
│  • Streams audio frames + still images   │
│  • Plays TTS audio back to glasses       │
│  • Tailscale client for home tunnel      │
└────────────┬─────────────────────────────┘
             │ Tailscale (encrypted mesh, no port-forwarding)
             │
┌────────────┴─────────────────────────────┐
│  Hermes Agent host (Ubuntu 26.04, 8GB)   │
│                                          │
│  Skills (~/.hermes/skills/):             │
│  • voice-id        ← Phase 1             │
│  • face-id         ← Phase 2             │
│  • scene-describe  ← Phase 3             │
│  • traffic-aware   ← Phase 4 (caveats)   │
│                                          │
│  Daemons (~/.hermes/voice-companion/):   │
│  • voice-id-daemon.service (systemd)     │
│  • face-id-daemon.service  (systemd)     │
│                                          │
│  AI engines:                             │
│  • SpeechBrain ECAPA  (voice embed, local)│
│  • InsightFace ArcFace (face embed, local)│
│  • faster-whisper      (STT, local)       │
│  • Piper TTS           (synthesis, local) │
│  • OpenAI gpt-5-mini   (vision, cloud)   │
└──────────────────────────────────────────┘
```

### 3.1 Why this split

- **Biometric data stays local.** Voice and face embeddings of her
  enrolled circle never leave the Ubuntu box.
- **Heavy general-purpose vision stays in the cloud.** Scene description,
  OCR, road sign reading: these don't touch biometrics, and a $0.25/$2.00
  per-M-token model is far better than anything that fits on 8GB locally.
- **Real-time hot paths are not LLM-mediated.** The voice-id and face-id
  daemons run as plain Python services emitting JSON Lines events. The
  agent (Hermes) does administration and learning *between* events, not
  inside them.

## 4. Locked design decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D-001 | Android-first relay (not iOS) | Better low-vision tooling on Galaxy ecosystem |
| D-002 | Dedicated Hermes instance, not shared | Privacy isolation; biometric data never on a shared system |
| D-003 | Tailscale (not public endpoint) | Encrypted, no port-forwarding, already proven on her host |
| D-004 | Mirror language mode default | Match input language; respects natural code-switching |
| D-005 | Piper TTS default voices for prototype | Fast setup; voice cloning deferred to optional later phase |
| D-006 | SpeechBrain ECAPA-TDNN for voice ID | Open license, ~80MB model, ~192-dim embeddings |
| D-007 | Voice ID is language-agnostic | Embeddings encode speaker, not language — works for code-switchers |
| D-008 | Conservative similarity threshold (0.65) | False positives socially worse than false negatives |
| D-009 | InsightFace ArcFace for face ID (Phase 2) | Open license, fast on CPU, well-documented |
| D-010 | OpenAI gpt-5-mini for scene description | Cheapest current vision model, ~$0.0002/call, bilingual |
| D-011 | Hot paths run as systemd services | Reliable restart, lifecycle management, log capture |
| D-012 | Skills follow agentskills.io standard | Portable across Hermes / OpenClaw / Claude Code skills |
| D-013 | Personal/home version first; classroom only via ADA | See `docs/CLASSROOM-CONSIDERATIONS.md` |
| D-014 | All scripts under `~/.hermes/voice-companion/` | One stable home; survives Hermes upgrades |
| D-015 | All daemons capped at 1GB RAM via systemd | Prevents runaway processes on 8GB host |

## 5. Component contracts (locked)

These are the inter-component contracts. **Don't break these without
updating this section first** — other components depend on them.

### 5.1 Voice-id event format

The voice-id daemon emits JSON Lines on stdout. Each line is one event:

```json
{
  "event": "speaker_identified",
  "name_en": "Sarah",
  "name_zh": "莎拉",
  "confidence": 0.81,
  "timestamp": "2026-05-09T14:32:11"
}
```

Event types:
- `speaker_identified` — match found, above threshold
- `unknown_speaker` — speech detected, no match (suppressed by default to
  avoid spam; emitted only once per ~30s of unknown speech)
- `daemon_status` — heartbeat, errors, config reloads

### 5.2 Face-id event format (Phase 2)

```json
{
  "event": "face_identified",
  "name_en": "Sarah",
  "name_zh": "莎拉",
  "distance_estimate_m": 1.8,
  "bearing": "ahead-left",
  "confidence": 0.78,
  "timestamp": "2026-05-09T14:32:11"
}
```

### 5.3 Scene-describe request/response (Phase 3)

Request (from Android relay → Hermes skill):
```json
{
  "frame_id": "uuid",
  "image_b64": "<JPEG base64>",
  "language_hint": "zh",
  "mode": "scene" | "ocr" | "sign" | "menu",
  "prompt_overlay": null
}
```

Response:
```json
{
  "frame_id": "uuid",
  "description": "你前方是一條人行道,大約十呎處有一個郵筒。",
  "language": "zh",
  "model": "gpt-5-mini",
  "tokens_used": 412,
  "latency_ms": 1340
}
```

### 5.4 Gallery file format

`~/.hermes/voice-companion/scripts/gallery/voice_gallery.json`:

```json
{
  "kang": {
    "name_en": "Kang",
    "name_zh": "康",
    "embedding": [0.12, -0.04, ...],
    "enrolled_on": "2026-05-09T14:32:11",
    "consent_recorded": true,
    "sample_count": 3,
    "notes": "primary user / spouse"
  }
}
```

Embeddings are 192-dim L2-normalized floats (ECAPA-TDNN output). Face
gallery (Phase 2) follows the same shape with 512-dim ArcFace embeddings.

### 5.5 Configuration

`~/.hermes/voice-companion/config.yaml` is the single source of runtime
config for all daemons. See the file itself for the canonical schema.
Daemons reload on `systemctl restart`.

## 6. Phase plan

| # | Phase | Status | Deliverables |
|---|-------|--------|--------------|
| 1 | Voice ID + bilingual TTS | **In build** | `voice_id.py`, `enroll.py`, `tts_announce.py`, daemon |
| 2 | Face ID (consensual gallery) | Designed | `face_id.py`, face enrollment, daemon |
| 3 | Scene description via gpt-5-mini | Designed | `scene_describe.py`, Hermes skill, S25 capture button |
| 4 | Traffic / motion awareness | Designed with safety caveats | YOLO11n on S25, conservative announcements |

## 7. Privacy & legal posture (locked)

- **All biometric data lives only on the home Ubuntu host.** Never
  transmitted to any cloud service, ever.
- **Each enrolled person must give recorded consent.** Consent timestamp
  is logged in the gallery JSON.
- **Children's data is never collected**, even for family children.
- **Classroom deployment requires formal ADA accommodation.** See
  `docs/CLASSROOM-CONSIDERATIONS.md`.
- **Cloud vision API (gpt-5-mini) calls** for scene description are OK
  — but only for general scenes. The system MUST NOT send images
  containing identifiable students, classroom interiors, or any context
  that could expose a minor's identity.
- **No retention of recordings.** Audio and video frames are processed
  and discarded; only embeddings of enrolled (consenting) adults persist.

## 8. What this system intentionally does NOT do

- Identify strangers (no internet face search, no PimEyes, no Name Tag)
- Store recordings for later review
- Send any data to Meta beyond what's needed for glasses pairing
- Replace her white cane, screen magnifier, or other established AT
- Make safety-critical claims about traffic detection (latency-bounded)
- Run any classroom features without ADA accommodation in writing

## 9. Hardware constraints (locked, with mitigation)

The Hermes host is Ubuntu 26.04 with 8GB RAM and 256GB SSD. Memory budget:

| Component | RAM at runtime |
|-----------|---------------|
| Ubuntu Desktop + base services | ~1.8 GB |
| Hermes Agent | ~0.8 GB |
| Voice-id daemon (ECAPA) | ~0.2 GB |
| Face-id daemon (ArcFace, Phase 2) | ~0.4 GB |
| Whisper-small (STT) | ~0.5 GB |
| Piper TTS | ~0.2 GB |
| **Headroom** | **~4 GB** ✓ |

**Phase 3 (scene description) goes to OpenAI API.** Local vision LLM is
explicitly NOT supported on this hardware. If/when a 16GB+ host becomes
available, local vision can be re-evaluated.

## 10. Glasses hardware compatibility

The system targets the Ray-Ban Meta line — both **Gen 1** (the
currently-owned device, primary build target) and **Gen 2** (assumed
compatible at the toolkit API level; verification deferred until a
Gen 2 device is in hand).

Most of the architecture is glasses-agnostic. The Hermes daemons consume
audio frames and image frames without caring which device produced them —
JSON Lines event contracts, gallery formats, TTS pipeline, and the
Tailscale tunnel are all unchanged across Gen 1 and Gen 2.

The Gen-specific surface is confined to the Android relay app's transport
layer, which talks to Meta's Wearables Device Access Toolkit. To keep
future swaps cheap, the relay app's glasses-facing layer is designed as a
thin adapter:

```kotlin
interface GlassesTransport {
    fun streamAudio(): Flow<AudioFrame>
    suspend fun captureFrame(): ImageFrame
    suspend fun playAudio(pcm: ByteArray)
    val touchpadEvents: Flow<TouchpadEvent>
}
```

Gen 1, Gen 2, the Oakley Meta line, and any future variants are
adapter-level swaps — not rewrites of the rest of the stack. If Gen 2
ships capability changes (e.g. heads-up display, different mic count,
new gesture vocabulary), they are exposed by extending the adapter
contract, not by branching the stack.

| Device | Status |
|--------|--------|
| Ray-Ban Meta Gen 1 | Primary build target; smoke test target |
| Ray-Ban Meta Gen 2 | Expected compatible — verify on device acquisition |
| Oakley HSTN / other Meta lines | Out of scope; adapter pattern allows future addition |

Firmware floor for Gen 1 is **v20** (set by the Wearables Device Access
Toolkit Public Preview); the Gen 2 floor will be confirmed when Meta
publishes Gen 2 toolkit support.

## 11. Open questions (TBD)

These are deliberately unresolved. Don't lock them prematurely.

- Voice cloning (XTTS-v2) for a personal TTS voice — deferred to
  post-Phase-1 evaluation
- Whether to add Hermes Telegram or Line bot front-end — Line endpoint
  already exists on the host, so it's a quick add when prioritized
- Watch haptic feedback (Galaxy Watch) for traffic alerts — interesting
  but not in scope until Phase 4
- Whether to deploy a second Hermes instance on the Mac mini for
  failover — currently single point of failure is acceptable
