---
name: control
description: Global activate/deactivate switch for Vision Companion (解語). Use this skill when the user wants to pause or resume all auto-announcements (voice-id and face-id), or to check whether the system is currently active. Manipulates a single state flag; daemons stay loaded so re-activation is near-instant.
version: 0.1.0
metadata:
  hermes:
    tags: [accessibility, vision-companion, control]
    category: assistive
required_environment_variables: []
platforms: [linux, darwin]
---

# control

The single on/off switch for the entire Vision Companion system. Both the
voice-id and the face-id daemons consult one state flag at
`~/.hermes/voice-companion/state/active.flag`. When the flag exists, the
daemons emit recognition events (which the TTS bridge speaks aloud). When
the flag is absent, the daemons keep their models loaded but discard all
input on the hot path — no events, no TTS, no embedding compute.

This means turning the system off is essentially free (no model unload,
no resource cleanup) and turning it back on is near-instant.

## When to use this skill

Trigger phrases (English):
- "deactivate / pause / mute / stop announcing"
- "activate / resume / unmute / start announcing"
- "is Vision Companion / 解語 active right now?"
- "toggle the recognizer"

Trigger phrases (Chinese):
- "停一下 / 暫停 / 關掉 / 安靜"
- "打開 / 啟動 / 恢復"
- "現在開著嗎? / 解語還在跑嗎?"
- "切換"

Note: "stop the daemon" is different — that means `systemctl --user stop`
(Linux) or `launchctl bootout` (macOS), which unloads the model and is a
heavier operation. This skill is for the soft activate/deactivate, not
full daemon shutdown.

## When NOT to use this skill

- For a hard daemon stop (model unload, free memory): use systemctl
  (Linux) or launchctl bootout (macOS), not this skill. Tell the user
  the difference if they seem to want a full stop.
- For removing a person from the gallery: that's the voice-id / face-id
  skill's `--overwrite` or gallery edit, not this one.
- For changing language mode: that edits `config.yaml` and restarts the
  daemon; not in scope here.

## Commands

The CLI is installed at `~/.local/bin/hithe` (so it's on PATH on a typical
Ubuntu setup). Falls back to the absolute path if not on PATH.

```bash
hithe on        # activate (creates active.flag)
hithe off       # deactivate (removes active.flag)
hithe toggle    # flip current state
hithe status    # print "active" or "paused"
```

If `hithe` isn't on PATH:

```bash
~/.hermes/voice-companion/bin/hithe on
```

## Behavior at the daemon level

- Both `voice-id-daemon` and `face-id-daemon` poll the flag at the start of
  each processing cycle.
- On state transitions (active→paused or paused→active), each daemon emits
  a `daemon_status` event with `status: "active"` or `"paused"`. This shows
  up in `~/.hermes/voice-companion/events.jsonl` and lets you confirm the
  toggle landed.
- Audio/video capture continues even when paused (cheap). Only the
  recognition pipeline is short-circuited.
- The cooldown / rate-limit timers in the TTS bridge are independent of
  the active flag — they reset naturally because no events arrive while
  paused.

## Edge cases

1. **State dir missing** — `hithe` creates it on first invocation; harmless.
2. **Daemon running but flag absent** — daemon emits one `paused` status
   event when it next checks (at most one chunk later), then stays silent.
3. **Daemon not running** — `hithe` still works (it only manipulates the
   flag file). When the daemon starts, it picks up the flag state.
4. **Multiple `hithe on` in a row** — idempotent; prints "already active".
5. **System reboot** — the flag does not persist by default since
   `~/.hermes/voice-companion/state/` is a regular directory. After
   reboot, the flag's last-modified state determines initial behavior:
   if the flag was present when shut down, it'll be present after boot
   (state dir is not in tmpfs). The daemons will resume in whatever
   state was last set. To force a default, the systemd unit could be
   modified with `ExecStartPre=` — defer.

## Self-improvement hints

- Frequent toggling at certain times of day might suggest the user wants
  a scheduled mode (e.g. "off after 10pm"). Note the pattern; consider a
  cron-driven schedule if it stabilizes.
- If the user asks to "turn it off" but seems frustrated, ask whether
  they actually want a tuning change (cooldown, threshold) instead of
  a full pause.

## Phase-1 limitations to disclose

- This is a manual toggle. The ergonomic plan ("Activate Jie-Yu" voice
  command, glasses touchpad press) requires a wake-word listener daemon
  and the Android relay — both deferred.
- There is no per-skill toggle yet (one global flag controls both
  voice-id and face-id). Add per-skill flags later if needed.
- No state restoration policy: if the user pauses, then the daemon
  restarts (e.g. systemd restart on crash), the flag state is preserved
  on disk so the daemon comes back up in the same paused/active mode.
  This is usually what you want, but document if surprising.
