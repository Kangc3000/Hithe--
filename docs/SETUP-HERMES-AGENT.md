# Setting up Hermes Agent with the Ray-Ban Meta glasses

How to get Hermes Agent (the AI agent runtime by Nous Research)
running on the Ubuntu host, discovering the Vision Companion skills,
and able to drive the system via conversational commands.

This document covers the agent layer ONLY. The hardware setup is in:
- [SETUP-RAYBAN-META.md](SETUP-RAYBAN-META.md) — glasses + phone
- [INSTALLATION-ANDROID.md](../INSTALLATION-ANDROID.md) — full deployment
- [BOOTSTRAP-FOR-HERMES.md](../BOOTSTRAP-FOR-HERMES.md) — what Hermes itself reads to install the skills

---

## Prerequisites checklist

- [ ] Ubuntu 26.04 host running, accessible (SSH or local console)
- [ ] User account with sudo (not root)
- [ ] Tailscale installed and connected on the host (`tailscale status` works)
- [ ] Python 3.11 or later
- [ ] At least 8 GB RAM, 256 GB SSD, ~3 GB free disk
- [ ] Internet (for downloading model files and Python wheels on first install)
- [ ] (Optional but recommended) A USB microphone and USB webcam for the
      one-time enrollment step. Once enrolled, neither is needed in
      production.

---

## Step 1 — Install Hermes Agent itself

> The Hermes Agent installation is owned by Nous Research, not by this
> project. Follow their current install instructions; only the
> post-install integration is documented here.

Official sources:
- Product page: <https://hermes.nousresearch.com/>
- Documentation: <https://hermes.nousresearch.com/docs/>
- Nous Research org: <https://nousresearch.com/>

The expected install puts the agent runtime somewhere it can read
skill manifests from `~/.hermes/skills/`. Confirm this with the
following after their install completes:

```bash
ls -la ~/.hermes/skills/
# should exist (possibly empty); if not, create it:
mkdir -p ~/.hermes/skills/
```

If the Hermes install you ended up with uses a different skills
directory, edit each of the four `install-on-hermes.sh` scripts'
`HERMES_SKILLS_DIR` variable to match. The default
`~/.hermes/skills/<name>/` is what `agentskills.io` standardizes on.

---

## Step 2 — Install the Vision Companion skills

This is the bootstrap procedure in
[BOOTSTRAP-FOR-HERMES.md](../BOOTSTRAP-FOR-HERMES.md). The short form,
to run on the Ubuntu host as your normal user:

```bash
cd ~
git clone https://github.com/Kangc3000/Hithe-- vision-companion
cd vision-companion

./hermes-skill/voice-id/install-on-hermes.sh    # ~2 GB download, ~10 min on a fast link
./hermes-skill/face-id/install-on-hermes.sh     # ~250 MB, ~3 min
./hermes-skill/relay/install-on-hermes.sh       # seconds

systemctl --user enable --now relay-daemon
```

After completion the four skill manifests live at:

```
~/.hermes/skills/voice-id/SKILL.md
~/.hermes/skills/face-id/SKILL.md
~/.hermes/skills/control/SKILL.md
~/.hermes/skills/relay/SKILL.md
```

---

## Step 3 — Tell Hermes to reload its skill index

How you do this depends on the Hermes UI / CLI you have available.
Common forms:

```bash
# Option A: Hermes provides a CLI command:
hermes skills reload

# Option B: send a chat message that triggers a reload:
# "Hermes, please reload your skill index."

# Option C: restart the Hermes daemon (heavier):
systemctl --user restart hermes-agent    # if Hermes runs as a user unit
# OR whatever Hermes's restart procedure is
```

Confirm the four skills appear in Hermes's skill list. The exact
command depends on the Hermes UI. Typically:

```bash
hermes skills list
```

You should see `voice-id`, `face-id`, `control`, `relay`.

---

## Step 4 — One-time enrollment

Plug a USB microphone (and optionally a webcam) into the Ubuntu host
for this step. After enrollment they can be unplugged.

Have a conversation with Hermes:

```text
YOU:  "Hermes, I want to enroll my voice."
HERMES: (asks for consent)
YOU:  "Yes, I give consent."
HERMES: (offers to record samples or accept WAV files)
YOU:  "Record."
HERMES: (runs ~/.hermes/voice-companion/scripts/enroll.py --record ...)
```

If Hermes won't do this conversationally yet (the skill is registered
but Hermes hasn't been trained on the trigger phrases), fall back to
the direct CLI:

```bash
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/enroll.py \
  --record --consent-confirmed \
  --name-en "Kang" --name-zh "康" \
  --notes "primary user"
```

Speak naturally for each of the three ~4-second prompts.

Verify:
```bash
~/.hermes/voice-companion/.venv/bin/python \
  ~/.hermes/voice-companion/scripts/enroll.py --list
```

Repeat for everyone in her enrolled circle. **Children's voices are
NEVER enrolled.** The script refuses without `--consent-confirmed`.

For face enrollment (Phase 2), the same flow with `face_enroll.py`
and a webcam.

After enrollments, restart the relay so it re-reads the galleries:

```bash
systemctl --user restart relay-daemon
```

---

## Step 5 — Wire the Android relay to this host

On the Galaxy S25:

1. Install the relay app (per [BUILDING-APK.md](BUILDING-APK.md) or
   sideload via Android Studio).
2. Confirm Tailscale is connected on the S25 too.
3. Open the relay app.
4. Settings:
   - **Hermes host**: the tailnet hostname of your Ubuntu host
     (find it with `tailscale status` on the host)
   - **Port**: `8765`
   - **Image FPS**: `0` for now (audio-only until you verify the loop)
   - **Glasses transport**: `Phone mic + camera (dev)` to start
5. **Test connection** → should show "Connected to host:8765".
6. **Start relay**.

On the Ubuntu host, watch the live log:

```bash
tail -f ~/.hermes/voice-companion/relay-daemon.log
```

You should see:
```
INFO  relay: client connecting peer=100.x.y.z:51822
INFO  relay: session opened peer=100.x.y.z:51822
```

Now speak near the phone (or wherever its mic is). You should see:
```
INFO  relay: speech segment duration=2.10s samples=33600
INFO  relay: announce speaker_identified lang=zh text='康'
INFO  tts_announce: synthesize lang=zh text='康' bytes=88200 in 298ms
```

And the phone speaker should play "康". This is the **without-glasses
end-to-end loop**.

---

## Step 6 — Try Hermes-mediated commands

With everything running, talk to Hermes. Examples of phrases that
should work (per the SKILL.md trigger phrases):

```text
"Is voice-id running?"
"How many people are enrolled?"
"Show me the last 10 events."
"Voice-id mistakes my brother for my dad too often."  # threshold tuning
"Deactivate the system."  # → hithe off
"Reactivate."             # → hithe on
"Is the relay running?"
"Restart the relay."
```

Each should trigger the corresponding action. If Hermes doesn't know
how to handle one, paste the relevant SKILL.md into the conversation
once to teach it — or report the gap back so the trigger phrases can
be improved.

---

## Step 7 — Day-to-day operation

The system is meant to run continuously. Your wife wears the glasses,
the phone is in her pocket, the Ubuntu host stays on at home.

Daily checks (Hermes can do these for you on request):

| Question | What Hermes / you check |
|----------|--------------------------|
| "Is everything running?" | `systemctl --user status relay-daemon` |
| "Did anything misfire today?" | `tail -n 200 ~/.hermes/voice-companion/events.jsonl` |
| "How accurate has voice-id been?" | grep recent `speaker_identified` events, look at confidence |
| "Is Tailscale connected?" | `tailscale status` |
| "How much memory is in use?" | `systemctl --user status relay-daemon | grep Memory` |

---

## Troubleshooting

### Hermes can't find the skills after install

Check:
```bash
ls -la ~/.hermes/skills/
cat ~/.hermes/skills/voice-id/SKILL.md | head -10
```

If the files are missing, the install script was running for a
different user. Re-run as the user that owns the Hermes install.

If the files are present but Hermes still doesn't see them: it might
be looking in a different directory. Find out where with:
```bash
# Whatever Hermes's "show skill loader configuration" command is.
hermes config show | grep -i skill
```

### Relay daemon won't start

```bash
journalctl --user -u relay-daemon -n 100 --no-pager
```

Common causes:
- Port 8765 already taken (another process or a stale relay): `ss -lntp | grep 8765`
- Missing apt deps: `sudo apt install alsa-utils curl`
- Model files corrupt: `rm -rf ~/.hermes/voice-companion/models/` then re-run the install scripts (re-downloads)
- `classroom_mode: true` in `config.yaml`: change to false, restart

### "Hermes responded but nothing happened on the system"

Hermes's natural-language → command mapping can be imperfect. Try the
literal trigger phrases from each SKILL.md. If those work, the issue
is intent classification; if those don't work either, the issue is
permissions / paths / something concrete.

### Relay sees connection but no audio reaches the daemon

Verbose log mode on:
```bash
RELAY_LOG_LEVEL=DEBUG systemctl --user restart relay-daemon
tail -f ~/.hermes/voice-companion/relay-daemon.log
```

You'll see `audio chunk samples=1600 rms=0.0123` lines. If the RMS is
always ~0, the phone isn't actually sending non-silent audio:
- Phone's mic permission denied
- App's "Start relay" was tapped but the service crashed (check
  Logcat on the phone with `adb logcat -s VC*:I`)
- App's Hermes host setting is pointing somewhere wrong

### Wrong name announced

Voice ID confused similar voices. Two fixes:

1. Raise `similarity_threshold` in `config.yaml`:
   ```yaml
   similarity_threshold: 0.72   # was 0.65
   ```
   Restart: `systemctl --user restart relay-daemon`
2. Re-enroll the confused person with more diverse samples:
   ```bash
   ~/.hermes/voice-companion/.venv/bin/python \
     ~/.hermes/voice-companion/scripts/enroll.py \
     --record 5 --overwrite --consent-confirmed \
     --name-en "Brother" --name-zh "哥哥"
   ```

### Too many false silence detections (system never seems to "hear" anyone)

Lower `silence_rms`:
```yaml
silence_rms: 0.003   # was 0.005
```
Restart.

---

## Architecture map (where things live)

```
~/.hermes/                                    Hermes Agent root
├── skills/                                   skill manifests loaded by Hermes
│   ├── voice-id/SKILL.md                     ← installed by hermes-skill/voice-id/install-on-hermes.sh
│   ├── face-id/SKILL.md                      ← installed by hermes-skill/face-id/install-on-hermes.sh
│   ├── control/SKILL.md                      ← installed by hermes-skill/voice-id/install-on-hermes.sh
│   └── relay/SKILL.md                        ← installed by hermes-skill/relay/install-on-hermes.sh
│
└── voice-companion/                          data + scripts (NOT touched by Hermes itself)
    ├── config.yaml                           single config; restart relay to reload
    ├── .venv/                                shared Python venv for all skills
    ├── scripts/                              the actual Python code
    │   ├── voice_id.py, enroll.py
    │   ├── face_id.py, face_enroll.py
    │   ├── tts_announce.py, hithe.py
    │   ├── relay_server.py                   ← the systemd service runs this
    │   ├── run-relay.sh                      ← what systemd ExecStarts
    │   └── gallery/
    │       ├── voice_gallery.json            ← biometric data, mode 0600, NEVER transmit
    │       └── face_gallery.json
    ├── models/
    │   ├── ecapa/                            SpeechBrain cache
    │   └── insightface/                      buffalo_l cache
    ├── state/active.flag                     hithe-managed on/off
    ├── bin/hithe                             control CLI (also symlinked to ~/.local/bin/)
    ├── events.jsonl                          append-only event log
    └── relay-daemon.log                      rotating relay log
```

When in doubt about where something lives, `find ~/.hermes -name <pattern>`.

---

## Reference

- [BOOTSTRAP-FOR-HERMES.md](../BOOTSTRAP-FOR-HERMES.md) — what Hermes
  reads to install the skills
- [PROJECT-SPEC.md](../PROJECT-SPEC.md) — locked architectural
  decisions (D-001 .. D-016)
- [IMPLEMENTATION-GUIDE.md](../IMPLEMENTATION-GUIDE.md) — agent/daemon
  contract details
- Hermes Agent: https://hermes.nousresearch.com/docs/
