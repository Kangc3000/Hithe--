# CLAUDE.md — Project Instructions for Claude Code

This file is automatically loaded by Claude Code when it works in this
repository. It captures project conventions, commands, and constraints
so the agent doesn't have to re-discover them every session.

If you are an AI agent reading this: **read `PROJECT-SPEC.md` before
making any non-trivial change.** Decisions D-001 through D-015 in that
document are locked. Don't reverse them without a written reason.

---

## Project at a glance

Vision Companion is a personal assistive system for one user with low
vision. It runs across:

- A **Ray-Ban Meta** — Gen 1 (currently owned) and Gen 2 (assumed
  compatible; see `PROJECT-SPEC.md` §10)
- A **Samsung Galaxy S25** (Android relay app, Kotlin)
- A **dedicated Hermes Agent host** (Ubuntu 26.04, 8GB RAM)

This is not a generic accessibility framework. Design choices are
intentionally tight to one user's actual needs.

## Repository layout

```
vision-companion/
├── PROJECT-SPEC.md                 # ⭐ READ THIS FIRST
├── CLAUDE.md                        # this file
├── README.md                        # top-level orientation
├── docs/
│   ├── CLASSROOM-CONSIDERATIONS.md  # legal + ADA path
│   ├── IMPLEMENTATION-GUIDE.md      # for Hermes/OpenClaw integration
│   └── INSTALLATION-ANDROID.md      # end-user install walkthrough
├── hermes-skill/
│   └── voice-id/
│       ├── SKILL.md                 # agentskills.io format manifest
│       ├── tts_announce.py
│       ├── config.yaml
│       ├── voice-id-daemon.service  # systemd user unit
│       └── install-on-hermes.sh
├── openclaw-skills/
│   └── voice-id/
│       ├── enroll.py                # enrollment CLI
│       ├── voice_id.py              # real-time identifier
│       └── requirements.txt
└── android-relay/                   # Phase 1.5 — not yet built
    └── (Kotlin Android Studio project)
```

## Critical constraints (do not violate)

1. **Biometric data NEVER leaves the home host.** Voice and face
   embeddings stay in `~/.hermes/voice-companion/scripts/gallery/`.
   Don't add code that uploads, syncs, or transmits these embeddings.
2. **No classroom features without explicit user instruction citing
   the ADA accommodation document.** Even helpful-sounding additions
   ("auto-detect students in frame") are off-limits.
3. **Cloud vision calls (gpt-5-mini) must respect classroom mode.**
   When `config.yaml` has `classroom_mode: true`, all cloud calls
   are blocked at the daemon level.
4. **No code that captures children's voices or faces**, even for
   benign-seeming reasons (testing, family use).
5. **Conservative defaults.** False positives (identifying the wrong
   person) are socially worse than false negatives. Tune thresholds up,
   not down, when in doubt.

## Coding conventions

- **Python:** 3.11+. Type hints encouraged on public functions.
  Use `dataclass` for structured records, `pathlib.Path` for paths,
  `logging` for output (not `print`), `argparse` for CLIs.
- **Kotlin:** standard Android Studio conventions. Min SDK 29.
- **Shell:** bash with `set -euo pipefail`. Idempotent scripts only.
- **Logging:** to stderr for human-readable, to stdout only for
  machine-consumed JSON Lines events.
- **JSON Lines events:** see `PROJECT-SPEC.md` §5 for canonical
  contracts. Don't extend without updating the spec.
- **Error handling:** assistive systems must fail gracefully. Never
  let an exception kill a daemon — log it, emit a `daemon_status`
  event, continue.
- **No emojis in code or logs.** Keep output greppable.

## Commands

### Run tests (when test suite exists)
```bash
cd openclaw-skills/voice-id
source .venv/bin/activate
pytest -v
```

### Verify Python syntax of all skill files
```bash
find . -name '*.py' -not -path './*/.venv/*' -exec python3 -m py_compile {} +
```

### Verify YAML config files
```bash
find . -name '*.yaml' -o -name '*.yml' | xargs -I{} python3 -c "import yaml; yaml.safe_load(open('{}'))"
```

### Verify shell scripts
```bash
find . -name '*.sh' | xargs -n1 bash -n
```

### Install on the Hermes Ubuntu host
```bash
cd hermes-skill/voice-id
chmod +x install-on-hermes.sh
./install-on-hermes.sh
```

### Run voice-id locally for testing (without daemon)
```bash
cd ~/.hermes/voice-companion/scripts
source .venv/bin/activate
python voice_id.py --listen-mic | python tts_announce.py --last-input-lang zh
```

### Check daemon status
```bash
systemctl --user status voice-id-daemon
journalctl --user -u voice-id-daemon -f
tail -f ~/.hermes/voice-companion/daemon.log
```

## When adding a new skill

1. Read `PROJECT-SPEC.md` §5 to understand the event contracts.
2. Create the skill directory: `hermes-skill/<skill-name>/`
3. Write a `SKILL.md` with valid agentskills.io frontmatter (see
   `hermes-skill/voice-id/SKILL.md` for reference).
4. The skill itself should be the *admin/management* interface. The
   real-time work goes in a separate daemon under `~/.hermes/voice-companion/scripts/`.
5. If the skill makes cloud calls, gate them on
   `config.classroom_mode == false`.
6. If the skill touches biometric data, gate writes on
   `consent_confirmed == true`.
7. Update `PROJECT-SPEC.md` Phase plan if the skill represents
   a phase deliverable.

## Honest gaps to flag to the user

When implementing, surface these to Kang explicitly rather than
quietly making decisions:

- Anything that affects the latency-budget for traffic-aware features
  (the latency story is fragile and safety-relevant)
- Memory pressure additions (the host is 8GB; if a feature needs
  500MB+, say so)
- Any cloud API addition beyond gpt-5-mini for scene description
- Any change that affects the consent or enrollment flow
- Any reduction in the classroom-mode interlocks

## What "done" looks like for each phase

- **Phase 1 (in build):** She wears the glasses at home, someone says
  hello, the system speaks the matched name through her glasses
  speakers in the appropriate language within ~2 seconds.
- **Phase 2:** Same, but visual — she looks at someone, system speaks
  their name with rough distance/bearing.
- **Phase 3:** She taps the glasses, system speaks a 1-2 sentence
  description of what's in front of her, in the language matching
  the most recent context.
- **Phase 4:** While walking, system periodically announces salient
  static obstacles ("car parked ahead", "construction zone"). Does
  NOT make real-time fast-vehicle warnings.

## References

- Project spec: `PROJECT-SPEC.md`
- Implementation guide (skills/agents): `docs/IMPLEMENTATION-GUIDE.md`
- Install walkthrough: `docs/INSTALLATION-ANDROID.md`
- Classroom legal posture: `docs/CLASSROOM-CONSIDERATIONS.md`
- Meta Wearables Toolkit docs: <https://wearables.developer.meta.com/docs/>
- Hermes Agent docs: <https://hermes.nousresearch.com/docs/>
- agentskills.io standard: <https://agentskills.io/>
