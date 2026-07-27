# Vision Companion

APP Name:Hithe-解語



A personal assistive system that connects Ray-Ban Meta glasses
(Gen 1 + Gen 2) to a dedicated Hermes Agent host, providing real-time
voice/face identification and scene awareness for low-vision users.

This project is built specifically for one person — design choices
reflect her actual needs, not generic accessibility patterns.

\---

## Documents

Read in this order depending on your role:

|If you are...|Read first|
|-|-|
|**Kang (the project owner)**|`PROJECT-SPEC.md` then `docs/INSTALLATION-ANDROID.md`|
|**Claude Code or any other AI agent working on this repo**|`CLAUDE.md` then `PROJECT-SPEC.md`|
|**Hermes Agent / OpenClaw integrator**|`PROJECT-SPEC.md` then `docs/IMPLEMENTATION-GUIDE.md`|
|**Privacy / legal reviewer**|`PROJECT-SPEC.md` §7 then `docs/CLASSROOM-CONSIDERATIONS.md`|

## What's where

```
vision-companion/
├── PROJECT-SPEC.md                  # Locked design + decision log
├── CLAUDE.md                         # Instructions for Claude Code
├── README.md                         # This file
├── docs/
│   ├── CLASSROOM-CONSIDERATIONS.md   # ADA / FERPA path for classroom use
│   ├── IMPLEMENTATION-GUIDE.md       # Skill format, contracts, agent patterns
│   └── INSTALLATION-ANDROID.md       # End-to-end install walkthrough
├── hermes-skill/voice-id/            # Hermes-style skill (Phase 1)
│   ├── SKILL.md
│   ├── tts\_announce.py
│   ├── config.yaml
│   ├── voice-id-daemon.service
│   └── install-on-hermes.sh
├── openclaw-skills/voice-id/         # Same scripts, OpenClaw-compatible
│   ├── enroll.py
│   ├── voice\_id.py
│   └── requirements.txt
└── android-relay/                    # Phase 1.5 — to be scaffolded
```

## Quick architecture

```
Ray-Ban Meta (Gen 1 + Gen 2)
   │ (Bluetooth, Wearables Device Access Toolkit)
   ▼
Galaxy S25 relay app (Kotlin)
   │ (Tailscale)
   ▼
Hermes Agent host (Ubuntu 26.04, 8GB RAM)
   ├── voice-id daemon       (local, ECAPA-TDNN)
   ├── face-id daemon        (local, ArcFace, Phase 2)
   ├── scene-describe skill  (cloud, OpenAI gpt-5-mini, Phase 3)
   └── traffic-aware skill   (S25-on-device, Phase 4 with caveats)
```

See `PROJECT-SPEC.md` §3 for the full architecture and §4 for the
locked design decisions.

## Phase status

|Phase|Status|
|-|-|
|1 — Voice ID + bilingual TTS|**In build** (host backend done; Android relay pending)|
|2 — Face ID (consensual gallery)|Designed|
|3 — Scene description via gpt-5-mini|Designed|
|4 — Traffic / motion awareness|Designed with safety caveats|

## Privacy posture (high level)

* All biometric data lives on the home Ubuntu host. Never transmitted.
* Each enrolled person gives consent; consent is logged.
* Children's data is never collected.
* Classroom deployment requires formal ADA accommodation first.
* Cloud vision calls (gpt-5-mini) gated by `classroom\_mode: false`.

Full posture: `PROJECT-SPEC.md` §7.

