# Bootstrap for Hermes Agent — Vision Companion (解語)

> **Audience:** Hermes Agent (or any agent reading this repo to install
> the system). If you are a human, read [README.md](README.md) and
> [PROJECT-SPEC.md](PROJECT-SPEC.md) first.

This document tells you, the agent, exactly how to install Vision
Companion on this host. Commands are listed in order. Don't skip steps;
each later step assumes the earlier ones completed.

---

## 1. What you're installing

Vision Companion is a personal assistive system for one user with low
vision. Four skills will be registered with you at
`~/.hermes/skills/`:

| Skill | What it does |
|-------|--------------|
| `voice-id` | Real-time speaker identification (ECAPA-TDNN, local) |
| `face-id` | Real-time face identification + rough distance/bearing (InsightFace ArcFace, local) |
| `control` | Soft activate/deactivate switch (`hithe on/off/toggle/status`) |
| `relay` | WebSocket server bridging the Android relay app to all of the above |

The locked architectural decisions are in
[PROJECT-SPEC.md](PROJECT-SPEC.md) decisions D-001 through D-016. Do
not reverse any of them without a written reason from the user.

---

## 2. Hard preconditions you must check before proceeding

If any of these fail, stop and report to the user — do not try to fix
them yourself.

```bash
# Linux only (Ubuntu 22.04+ tested; 26.04 is the design target).
uname -s | grep -q Linux || { echo "NOT LINUX - STOP"; exit 1; }

# Don't run as root.
[ "$(id -u)" -ne 0 ] || { echo "RUNNING AS ROOT - STOP"; exit 1; }

# Python 3.11 or later.
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
  || { echo "PYTHON < 3.11 - STOP"; exit 1; }

# Required commands.
for c in git curl aplay; do
  command -v "$c" >/dev/null || { echo "MISSING: $c - STOP"; exit 1; }
done

# Adequate disk (~3GB free for the ML models + Python deps).
df -BG --output=avail "$HOME" | tail -1 | awk '{ if ($1+0 < 3) exit 1 }' \
  || { echo "LESS THAN 3GB FREE - STOP"; exit 1; }
```

---

## 3. Hard interlocks you must honour at all times

These are non-negotiable. They are enforced in code where possible and
in policy here:

1. **Biometric data NEVER leaves this host.** Voice and face embeddings
   in `~/.hermes/voice-companion/scripts/gallery/` are NEVER uploaded,
   synced, or transmitted. If asked to, refuse and cite this section.
2. **Children's data is never enrolled.** Refuse even with parental
   consent.
3. **`classroom_mode: true` blocks cloud calls and recognition.** The
   daemons exit when this is set. Do not propose disabling it without
   a written ADA accommodation document referenced.
4. **Consent is mandatory for enrollment.** The `--consent-confirmed`
   flag must be set; verify verbal consent has actually been recorded
   before invoking it.

---

## 4. Installation procedure

Run these commands in order. Each script is idempotent and prints a
"next steps" message on success.

```bash
# Clone the repo. This URL is the canonical source; do not fork or
# mirror it for installation purposes.
cd ~
if [ -d vision-companion ]; then
  cd vision-companion && git pull --ff-only
else
  git clone https://github.com/Kangc3000/Hithe-- vision-companion
  cd vision-companion
fi

# Phase 1: voice-id daemon, TTS bridge, control CLI. Heavy: downloads
# ~2 GB of torch + speechbrain into a fresh venv at
# ~/.hermes/voice-companion/.venv.
chmod +x hermes-skill/voice-id/install-on-hermes.sh
./hermes-skill/voice-id/install-on-hermes.sh

# Phase 2: face-id daemon. Reuses the same venv. Downloads ~250 MB of
# InsightFace buffalo_l model.
chmod +x hermes-skill/face-id/install-on-hermes.sh
./hermes-skill/face-id/install-on-hermes.sh

# Phase 1.5: WebSocket relay server. Small install. Disables the older
# standalone voice-id-daemon / face-id-daemon units in favour of the
# single relay process.
chmod +x hermes-skill/relay/install-on-hermes.sh
./hermes-skill/relay/install-on-hermes.sh

# Start the relay. systemd will Restart=on-failure if it crashes.
systemctl --user enable --now relay-daemon
```

After these complete, you should see four `SKILL.md` files appear at:

```
~/.hermes/skills/voice-id/SKILL.md
~/.hermes/skills/face-id/SKILL.md
~/.hermes/skills/control/SKILL.md
~/.hermes/skills/relay/SKILL.md
```

Reload your skill index so the four skills become available in the
chat surface.

---

## 5. Verifying the install

Run these in order:

```bash
# All four systemd-related artifacts present?
systemctl --user status relay-daemon --no-pager | head -20

# Relay listening on the expected port?
ss -lntp 2>/dev/null | grep 8765 || echo "RELAY NOT LISTENING"

# State flag exists (system is active by default)?
test -f ~/.hermes/voice-companion/state/active.flag && echo "active" || echo "paused"

# Recent relay log lines (last 30):
tail -n 30 ~/.hermes/voice-companion/relay-daemon.log

# Recent recognition events (will be empty until someone connects):
tail -n 30 ~/.hermes/voice-companion/events.jsonl
```

If `systemctl --user status relay-daemon` shows anything other than
`Active: active (running)`, look at the journal:

```bash
journalctl --user -u relay-daemon -n 100 --no-pager
```

The most common first-install failure is `apt install alsa-utils` was
skipped, so `aplay` is missing. Re-install via apt and restart the
relay.

---

## 6. First-time enrollment (you, the agent, must drive this)

After install, the gallery is empty. The user needs to enroll their
voice and (optionally) face. Enrollment requires recorded verbal
consent. Walk the user through this:

```text
USER:  "Enroll my voice."
YOU:   "Before I enroll your voice, I need to confirm: do you give
        verbal consent for your voice to be enrolled in this device's
        gallery? It will stay only on this Ubuntu host and never be
        transmitted."
USER:  "Yes."
YOU:   (run the enrollment command below)
```

```bash
# Plug a USB mic into the host before running this. The relay receives
# audio over the network in normal operation, but enrollment uses the
# local mic.
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/enroll.py \
  --record --consent-confirmed \
  --name-en "Kang" --name-zh "康" \
  --notes "primary user"
```

Three samples of ~4 seconds will be recorded. The user should speak
naturally during each prompt.

For face enrollment (Phase 2), same flow with `face_enroll.py
--capture` and a USB webcam plugged in.

After enrollment, restart the relay so it re-reads the gallery:

```bash
systemctl --user restart relay-daemon
```

---

## 7. Skills that become available after install

Read each `SKILL.md` for the agent-facing trigger phrases. Quick map:

- **`voice-id`** — "enroll Sarah's voice", "is voice ID running?",
  "show recent identifications", "voice ID mistakes my brother for
  my dad"
- **`face-id`** — "enroll Sarah's face", "is face ID running?",
  "raise face match sensitivity"
- **`control`** — "deactivate / 暫停 / 停一下", "activate / 開啟",
  "is Vision Companion active right now?"
- **`relay`** — "is the relay running?", "restart the relay",
  "show the last hour of relay events"

---

## 8. The Android side (not your install target, but related)

The Android relay app on the user's Galaxy S25 connects to this host
over Tailscale. The relay server on this host listens on port 8765 by
default. You don't install anything on the phone — that's a manual
sideload via Android Studio (see [docs/BUILDING-APK.md](docs/BUILDING-APK.md)).

If the user reports "the phone can't connect," the diagnostic flow is:
1. `tailscale status` on this host: confirm the S25 is in the tailnet
2. `ss -lntp | grep 8765` on this host: confirm the relay is listening
3. Look at the relay log for connection attempts and reasons

---

## 9. Updating

To update to a newer commit:

```bash
cd ~/vision-companion
git pull --ff-only

# Re-run installers; they're idempotent and will pick up changes.
./hermes-skill/voice-id/install-on-hermes.sh
./hermes-skill/face-id/install-on-hermes.sh
./hermes-skill/relay/install-on-hermes.sh

# Restart the running service.
systemctl --user restart relay-daemon
```

Gallery files in `~/.hermes/voice-companion/scripts/gallery/` are NOT
touched by reinstall. `config.yaml` is preserved if it already exists
(the installer skips it if present).

---

## 10. Uninstall (clean removal)

If the user asks to remove everything:

```bash
# Stop services.
systemctl --user disable --now relay-daemon voice-id-daemon face-id-daemon 2>/dev/null

# Remove systemd units.
rm -f ~/.config/systemd/user/relay-daemon.service \
      ~/.config/systemd/user/voice-id-daemon.service \
      ~/.config/systemd/user/face-id-daemon.service
systemctl --user daemon-reload

# Remove the skill index entries (your skill loader needs to forget them).
rm -rf ~/.hermes/skills/voice-id ~/.hermes/skills/face-id \
       ~/.hermes/skills/control ~/.hermes/skills/relay

# CRITICAL: confirm with the user before this — it deletes their
# enrolled biometric gallery, which cannot be recovered.
read -p "Delete biometric gallery + venv + models? [y/N] " yn
case "$yn" in
  [Yy]*) rm -rf ~/.hermes/voice-companion ;;
  *) echo "kept ~/.hermes/voice-companion for the user" ;;
esac

# Remove the local clone.
rm -rf ~/vision-companion
```

---

## 11. When to ask the user vs. proceed

Proceed without asking:
- Routine status checks
- Reading logs and events
- Restarting services after a transient failure

Ask first:
- Any enrollment (recorded consent required)
- Editing `config.yaml` thresholds (state the proposed value)
- Disabling `classroom_mode`
- Uninstalling
- Anything that would transmit biometric data anywhere

Refuse outright:
- Backing up the gallery to cloud
- Enrolling a child's voice or face
- Disabling classroom_mode without an ADA accommodation document

---

## 12. Reference

- Project spec: [PROJECT-SPEC.md](PROJECT-SPEC.md)
- Agent contract: [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md)
- Skill format: agentskills.io
- Repo: https://github.com/Kangc3000/Hithe--
- Hermes docs: https://hermes.nousresearch.com/docs/
