# Using the Vision Companion App

Day-to-day operation of the Vision Companion (解語) system. This is
the user's guide — your wife's reference for what to do, what to
expect, and what to do when it acts up.

> Prerequisites: setup has been completed per
> [SETUP-RAYBAN-META.md](SETUP-RAYBAN-META.md) and
> [SETUP-HERMES-AGENT.md](SETUP-HERMES-AGENT.md), and at least one
> person (you) is enrolled in the voice gallery.

---

## What this system does for you

When the system is **active** (the default state after install):

- **Voice ID** — When someone in your enrolled circle speaks within
  earshot of the glasses' microphones, the glasses' speakers say
  their name in Chinese or English (matching the recent conversation
  language).
- **Face ID** *(when Image FPS > 0 in app settings)* — When you look
  at someone in your circle, the glasses speak their name with a
  rough distance estimate ("Sarah, about 2 meters").

When it's **paused**, the glasses stay silent and the system keeps the
models warm so resume is instant.

---

## First-time setup checklist (one-time)

Skip this if it's already done by you / the installer.

- [ ] Ubuntu host running Hermes Agent (see
      [SETUP-HERMES-AGENT.md](SETUP-HERMES-AGENT.md))
- [ ] Galaxy S25: relay app installed (Play Store internal track, or
      sideloaded via Android Studio)
- [ ] Glasses: paired, Developer Mode on (see
      [SETUP-RAYBAN-META.md](SETUP-RAYBAN-META.md))
- [ ] Tailscale running on both phone and Ubuntu host, both visible
      via `tailscale status`
- [ ] Your voice enrolled (~30 seconds of speech)
- [ ] (Optional) Your face enrolled (3 photos)
- [ ] (Optional) Other people in your circle enrolled with their
      verbal consent

---

## Starting a day

When you wake up:

1. **Put the glasses on.** They auto-connect to the phone over
   Bluetooth.
2. **Open the Vision Companion Relay app on the phone.** If it's
   still running from last night, the persistent notification will
   say "Connected to <host>". If it crashed overnight, tap **Start
   relay**.
3. **Confirm it's active.** Either:
   - Ask Hermes: "is the system active?"
   - Or run on the host: `hithe status` → "active (since ...)"
4. **Walk around normally.** When someone you know speaks, you'll
   hear their name through the glasses' open-ear speakers.

That's it. No further interaction needed during the day.

---

## Daily controls

### Pause and resume

When you want quiet (a meeting, a movie, focused work):

| What you do | What happens |
|-------------|--------------|
| Say to Hermes: "停一下" or "Deactivate" | System falls silent; models stay loaded |
| Say to Hermes: "啟動" or "Activate" | System resumes; near-instant |
| Or on the host: `hithe off` | Same as deactivate |
| Or on the host: `hithe on` | Same as activate |

The pause is global — it affects both voice-id and face-id at once.

### Check status

Either:
- Ask Hermes: "現在開著嗎?" / "is the system on?"
- Or run on host: `hithe status`

Output: `active (since 2h 14m ago)` or `paused`.

### Inspect recent events

Ask Hermes: "誰最近說話了?" / "show me the last hour of events."

Or directly on the host:
```bash
tail -n 30 ~/.hermes/voice-companion/events.jsonl
```

Each line is one JSON object describing one recognition event.

---

## Adding someone to the enrolled circle

You can only enroll people who give explicit verbal consent. Children
are NEVER enrolled, even with parental consent.

### Conversational flow (preferred)

```text
YOU:    "Hermes, I want to enroll Sarah's voice."
HERMES: "Has Sarah given verbal consent for her voice to be enrolled?
         The voice samples and embedding will stay only on this Ubuntu
         host and never be transmitted off-device."
YOU:    "Yes."
HERMES: "What's her English name and Chinese name?"
YOU:    "English: Sarah. Chinese: 莎拉."
HERMES: "Three samples of ~4 seconds. Please hand the laptop to her
         (or come over to the host). Ready when she is."
```

Hermes then runs the enrollment command, prompting Sarah to speak
three times. After completion, the relay automatically picks up the
new gallery on the next restart:

```bash
systemctl --user restart relay-daemon
```

### Direct CLI fallback

If Hermes can't drive this conversationally:

```bash
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/enroll.py \
  --record --consent-confirmed \
  --name-en "Sarah" --name-zh "莎拉" \
  --notes "Sarah's role / how I know her"
systemctl --user restart relay-daemon
```

For face enrollment, same flow with `face_enroll.py --capture` and a
webcam.

### Listing enrolled people

```bash
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/enroll.py --list
```

### Removing someone

If Sarah no longer consents (or you mis-enrolled someone), ask
Hermes: "Remove Sarah from the voice gallery."

Or directly:
```bash
python3 -c "
import json, pathlib
p = pathlib.Path.home() / '.hermes/voice-companion/scripts/gallery/voice_gallery.json'
d = json.loads(p.read_text())
d.pop('sarah', None)   # use the slug of the english name
p.write_text(json.dumps(d, ensure_ascii=False, indent=2))
"
systemctl --user restart relay-daemon
```

---

## Tuning the system

You'll find a few patterns where the system isn't quite right. These
are the knobs to ask Hermes (or edit `config.yaml`) for:

| Symptom | What to ask Hermes |
|---------|--------------------|
| "It's saying the wrong person's name" | "Raise voice-id sensitivity" (raises similarity_threshold) |
| "It's not recognizing me when it should" | "Lower voice-id sensitivity" |
| "It keeps saying my husband's name over and over" | "Increase the cooldown between announcements" |
| "It's announcing strangers too often" | "Increase unknown-speaker silence period" |
| "It's missing soft talkers" | "Lower the silence threshold" |
| "Random noise is triggering it" | "Raise the silence threshold" |
| "Distance estimates are way off" | "Calibrate face-id distance" (recipe in SKILL.md) |
| "Face-id is using too much CPU" | "Lower face-id frame rate" |

Hermes will state the proposed change, get your OK, edit
`config.yaml`, and restart the relay. The restart takes a few seconds
(models reload).

---

## What the glasses can and can't do

### Can do
- Speak names of enrolled people in 中 or 英
- Estimate rough distance to recognized faces (within ~30% accuracy)
- Stay silent when you say "stop" / "deactivate"

### Can't do (today)
- Identify strangers (by design — this is not a stranger-recognition
  tool)
- Read text in front of you (Phase 3, not yet built)
- Describe a scene on demand (Phase 3, not yet built)
- Warn about traffic (Phase 4, not yet built, with safety caveats)
- Work outside your home WiFi unless Tailscale routing is preserved
  (the Hermes host stays at home; the phone needs to reach it)

### Hard limits (will never do)
- Send any biometric data to the cloud
- Identify children
- Work in classroom contexts without ADA accommodation in writing

---

## Troubleshooting

### "I'm putting on the glasses but nothing speaks."

Step through this in order:

1. **App running?** Look at the phone's notification shade. Should
   say "Connected to <host>." If not, open the app and tap **Start
   relay**.
2. **System active?** Ask Hermes: "is the system on?" If paused, ask
   to activate.
3. **Tailscale connected?** On the phone, open Tailscale → confirm
   the Ubuntu host is reachable.
4. **Speak louder.** The default silence threshold might filter you
   out if you're being too quiet.
5. **Is anyone enrolled?** Ask Hermes "list enrolled voices." If
   empty, that's why nothing speaks — enroll yourself first.

### "It says random people's names when nobody's around."

The mic is hot. Either:
- Pause the system (`hithe off`) when not needed
- Or raise `silence_rms` (ask Hermes to "raise the silence threshold")

### "It's confusing me with someone else."

Raise the match threshold (Hermes: "raise voice-id sensitivity") or
re-enroll the confused person with more diverse samples.

### "I'm not hearing audio through the glasses, it's coming out of the phone."

Two possibilities:
1. The app's transport setting is still **Phone mic + camera (dev)**.
   Switch to **Meta Wearables SDK** (only available after Meta SDK
   is integrated; see [SETUP-RAYBAN-META.md](SETUP-RAYBAN-META.md)).
2. The glasses are not actively connected. Open Meta AI app and check.

### "The phone is hot."

The relay app uses the mic continuously. Some heating is normal. If
it's uncomfortable:
- Pause the system when not needed
- Lower **Image FPS** in the app settings (or set to 0 to disable
  image upload entirely)

### "Battery on the phone is draining fast."

Same root cause. Same fixes. Also: keep Tailscale's battery-saver
preference appropriate (Tailscale's notification has an "always-on"
toggle).

### "Battery on the glasses is dying mid-day."

Glasses are ~4 hours of active use (PROJECT-SPEC.md). For all-day
use, swap to a charging case mid-day. The relay continues to run on
the host even when the glasses are off, so re-pairing later picks up
where you left off.

---

## How to get more verbose logging (if something is weird)

On the **phone**: open the app → **Log level** → DEBUG. Logs go to
`/Android/data/com.kangatnewyork.visioncompanion.relay/files/logs/`
and are also visible via `adb logcat -s VC*:D` from a connected
computer.

On the **host**:
```bash
RELAY_LOG_LEVEL=DEBUG systemctl --user restart relay-daemon
tail -f ~/.hermes/voice-companion/relay-daemon.log
```

Restore normal logging by restarting without the env var:
```bash
systemctl --user restart relay-daemon
```

---

## When to ask Hermes vs. directly run a command

**Ask Hermes when:**
- You want a conversation about what's happening ("why did it just say
  that?")
- You want it to look something up and explain in natural language
- You want a change applied with confirmation ("change the threshold
  to X")

**Run a command directly when:**
- Hermes is itself unreachable (restart needed)
- You want the literal shortest path (one-line scripts)
- You're debugging something Hermes shouldn't have opinions about

---

## What to do if you forget any of this

The system has self-documenting trigger phrases. Just ask Hermes:

```text
"What can you do with voice ID?"
"How do I pause the system?"
"How do I enroll someone?"
"Where are the logs?"
```

The SKILL.md files (`~/.hermes/skills/*/SKILL.md`) are the source of
truth for what Hermes knows. They're plain Markdown — you can read
them yourself.
