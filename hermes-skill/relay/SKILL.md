---
name: relay
description: WebSocket relay server bridging the Galaxy S25 Android relay app and the on-host voice-id and face-id pipelines. Use this skill to check connection status, reload galleries, view connection stats, restart on connection issues, and tail the structured debug log. Replaces the old voice-id-daemon and face-id-daemon CLI pipelines.
version: 0.1.0
metadata:
  hermes:
    tags: [accessibility, vision-companion, relay, network]
    category: assistive
required_environment_variables: []
platforms: [linux]
---

# relay

Single-process WebSocket server that:

- Receives PCM audio chunks (16kHz mono int16) from the Android relay
  app and feeds them into the voice-id ECAPA pipeline
- Receives JPEG image frames from the Android relay app and feeds them
  into the face-id InsightFace pipeline
- Routes recognition events to (a) the WebSocket client as text frames
  so the phone can log/display them, and (b) the persistent
  `events.jsonl` log
- Synthesizes Piper TTS audio for spoken events and streams it back as
  binary frames (Piper-native format: 22050 Hz mono int16 LE)

This replaces the older split daemon pipeline (`voice-id-daemon` and
`face-id-daemon`) once the Android relay is in play. Models are loaded
once at process start; per-connection state (speech aggregator, TTS
cooldowns) is created fresh for each Android session.

## When to use this skill

English:
- "is the relay server running?"
- "show me the last hour of relay events"
- "reload the voice gallery without restarting"  *(future)*
- "what's the latency to the phone?"  *(future, ping/pong telemetry)*
- "restart the relay"

中文:
- "Relay 還在跑嗎?"
- "最近一小時 relay 有什麼事件?"
- "重啟 relay 服務"

## When NOT to use this skill

- For the soft on/off pause: use `control` (`hithe`) instead. The relay
  honours the `active.flag` state, so toggling there is enough — no
  reason to bounce the relay.
- For enrolling: use `voice-id` (`enroll.py`) and `face-id`
  (`face_enroll.py`). They write the gallery files; the relay re-reads
  them on next start (live reload is a future enhancement).
- For changing thresholds / cooldowns: edit `config.yaml` then restart
  the relay with `systemctl --user restart relay-daemon`.

## Wire format (for debugging)

The Android relay app and the relay_server agree on this protocol:

| Direction | Type | Tag | Payload |
|-----------|------|-----|---------|
| Android → Hermes | binary | 0x01 | raw PCM, 16kHz mono int16 LE |
| Android → Hermes | binary | 0x02 | JPEG bytes |
| Android → Hermes | text   | -    | JSON `{"type": "ping"\|"shutdown", ...}` |
| Hermes → Android | binary | 0x03 | TTS PCM, 22050Hz mono int16 LE |
| Hermes → Android | text   | -    | JSON event line (recognition / status) |

## Commands the agent can run

### Liveness

```bash
systemctl --user status relay-daemon
journalctl --user -u relay-daemon -n 100 --no-pager
tail -f ~/.hermes/voice-companion/relay-daemon.log
```

The structured log lines look like:

```
2026-05-10T14:32:11.452 INFO    relay: client connecting peer=100.64.0.5:51822
2026-05-10T14:32:11.470 INFO    relay: session opened peer=100.64.0.5:51822
2026-05-10T14:32:13.901 INFO    relay: speech segment duration=2.10s samples=33600
2026-05-10T14:32:14.120 INFO    relay: announce speaker_identified lang=zh text='康'
2026-05-10T14:32:14.420 INFO    tts_announce: synthesize lang=zh text='康' bytes=88200 in 298ms
```

A typical debug session is a `grep` for the peer IP, then the chronology
falls out from the timestamps.

### Recent events (recognition only)

```bash
tail -n 50 ~/.hermes/voice-companion/events.jsonl
```

### Restart

```bash
systemctl --user restart relay-daemon
```

The Android relay app is configured with `Reconnect=true`; it should
re-establish within a few seconds.

### Per-port debugging from the host itself

If you suspect Tailscale routing, on the host:

```bash
ss -lntp | grep 8765           # confirm relay is listening
sudo tcpdump -ni tailscale0 port 8765 -c 50    # see raw frames
```

From the phone's perspective: the relay app's settings screen should
have a "test connection" button that sends a single ping and reports
RTT in ms.

## Tuning knobs that affect the relay

These are in `config.yaml` (shared with the underlying voice-id and
face-id pipelines):

| Knob | Effect on relay |
|------|-----------------|
| `similarity_threshold` | voice-id match strictness |
| `face_similarity_threshold` | face-id match strictness |
| `min_speech_seconds` / `max_speech_seconds` | when speech is "enough" to embed |
| `silence_rms` | speech vs. silence cutoff |
| `face_target_fps` | (relay reads as-many-as-arrive; this is just a hint to the Android side) |
| `rate_limit_seconds` | global TTS rate limit per session |
| `announcement_cooldown_seconds` | per-name cooldown |
| `classroom_mode` | hard interlock — relay refuses to start when true |

## Edge cases

1. **Two Android clients connect** — the second is rejected with WebSocket
   close code 1013. Documented; future enhancement could broadcast.
2. **Android disconnects mid-segment** — the speech aggregator's pending
   buffer is dropped; nothing is announced. Reconnect recreates state.
3. **Piper synthesis times out** — logged at WARNING; the announcement
   is dropped. Cooldown timer for that name is NOT advanced (so the
   next event will re-attempt). This is intentional.
4. **Webcam / mic on the host** — irrelevant to the relay. The relay
   only consumes the WebSocket. The old voice-id-daemon / face-id-daemon
   units should be disabled when the relay is enabled (the install
   script does this).
5. **Tailscale not connected** — the relay still binds and listens; the
   Android client just can't reach it. From the host, `tailscale status`
   confirms reachability.
6. **classroom_mode flipped on while relay is running** — the relay does
   NOT re-check this at runtime. Restart the relay to apply. This is
   intentional: a runtime poll would be a per-frame stat() and the
   safer path is "decide at startup."

## Self-improvement hints

- Spikes in TTS synthesis latency (`synthesize ... in NNNms`) suggest
  Piper is contending for CPU with the face-id pipeline. Lower
  `face_target_fps` if it correlates with face activity.
- Per-segment duration consistently at `max_speech_seconds` means
  speech is being clipped. Raise the cap, or improve VAD.
- Frequent rejections at connect time mean the Android app is
  reconnect-spamming. Check its log for the cause.

## Phase 1.5 limitations the agent should disclose honestly

- One concurrent client. No broadcast / multi-listener support.
- No on-the-fly gallery reload; restart the relay after enrollment.
- No authentication on the WebSocket. Tailscale is the security
  boundary; if Tailscale is misconfigured, anyone on the LAN can
  connect. Document; future enhancement is a shared-secret token.
- The relay assumes the Android side sends 16kHz mono PCM. If the
  glasses produce a different sample rate, the Android adapter must
  resample before sending.
