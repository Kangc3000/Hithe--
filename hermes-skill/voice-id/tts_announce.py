#!/usr/bin/env python3
"""TTS bridge for Vision Companion daemons.

Reads JSON Lines events from stdin (emitted by voice_id.py or face_id.py),
formats an announcement based on language hint + per-name cooldown + global
rate limit, synthesizes via Piper, and plays through the configured audio
player (aplay by default).

Currently handles two event types:
  - speaker_identified  -> {name_zh} / {name_en}
  - face_identified     -> {name_zh}, distance, bearing (Phase 2)

Other event types (daemon_status, unknown_speaker, mode_changed, etc.) are
not spoken aloud.

The language hint comes from --last-input-lang at startup. Phase 1 has no
STT, so this is effectively the language picked by the orchestrator (Hermes)
when it starts the pipeline. Phase 2+ will replace this with a control
channel that updates the hint as the conversational language shifts.

Usage:
  voice_id.py --listen-mic | tts_announce.py --last-input-lang zh
  face_id.py  --webcam     | tts_announce.py --last-input-lang zh
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

import yaml

LOG = logging.getLogger("tts_announce")

DEFAULT_CONFIG = Path("~/.hermes/voice-companion/config.yaml").expanduser()


@dataclass
class TTSConfig:
    piper_binary: str
    voices_dir: Path
    voice_zh: str
    voice_en: str
    audio_player: str
    audio_player_args: list[str]
    announcement_template_zh: str
    announcement_template_en: str
    face_announcement_template_zh: str
    face_announcement_template_en: str
    language_mode: str
    preferred_language: str
    rate_limit_seconds: float
    announcement_cooldown_seconds: float


def load_config(path: Path) -> TTSConfig:
    with path.open("r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    voices_dir = Path(str(raw.get("voices_dir", "~/.local/share/piper/voices"))).expanduser()
    return TTSConfig(
        piper_binary=str(raw.get("piper_binary", "piper")),
        voices_dir=voices_dir,
        voice_zh=str(raw.get("voice_zh", "zh_CN-huayan-medium.onnx")),
        voice_en=str(raw.get("voice_en", "en_US-amy-medium.onnx")),
        audio_player=str(raw.get("audio_player", "aplay")),
        audio_player_args=list(raw.get("audio_player_args", ["-q"])),
        announcement_template_zh=str(raw.get("announcement_template_zh", "{name_zh}")),
        announcement_template_en=str(raw.get("announcement_template_en", "{name_en}")),
        face_announcement_template_zh=str(
            raw.get("face_announcement_template_zh", "{name_zh}, 距離大約{distance_m}公尺")
        ),
        face_announcement_template_en=str(
            raw.get("face_announcement_template_en", "{name_en}, about {distance_m} meters")
        ),
        language_mode=str(raw.get("language_mode", "mirror")),
        preferred_language=str(raw.get("preferred_language", "zh")).lower(),
        rate_limit_seconds=float(raw.get("rate_limit_seconds", 3.0)),
        announcement_cooldown_seconds=float(raw.get("announcement_cooldown_seconds", 8.0)),
    )


def resolve_language(cfg: TTSConfig, hint: str | None) -> str:
    """Decide which language to speak based on config and the runtime hint."""
    if cfg.language_mode == "preferred_zh":
        return "zh"
    if cfg.language_mode == "preferred_en":
        return "en"
    # mirror: trust the hint, fall back to preferred_language
    if hint:
        h = hint.lower()
        if h.startswith("zh"):
            return "zh"
        if h.startswith("en"):
            return "en"
    return "zh" if cfg.preferred_language.startswith("zh") else "en"


def render_text(cfg: TTSConfig, lang: str, event: dict) -> str:
    """Format the announcement text for an event. Returns empty string for
    event types that should not be spoken."""
    evt_type = event.get("event")
    if evt_type == "speaker_identified":
        template = cfg.announcement_template_zh if lang == "zh" else cfg.announcement_template_en
        return template.format(
            name_en=event.get("name_en", ""),
            name_zh=event.get("name_zh", ""),
            confidence=event.get("confidence", 0.0),
        )
    if evt_type == "face_identified":
        template = (
            cfg.face_announcement_template_zh
            if lang == "zh"
            else cfg.face_announcement_template_en
        )
        distance = event.get("distance_estimate_m", 0.0)
        return template.format(
            name_en=event.get("name_en", ""),
            name_zh=event.get("name_zh", ""),
            confidence=event.get("confidence", 0.0),
            distance_m=f"{float(distance):.1f}",
            bearing=event.get("bearing", ""),
        )
    return ""


SPOKEN_EVENT_TYPES = {"speaker_identified", "face_identified"}


# Piper --output_raw produces this format. Hardcoded so callers can stream
# the bytes to AudioTrack on Android without negotiating a container.
PIPER_OUTPUT_SAMPLE_RATE = 22050
PIPER_OUTPUT_CHANNELS = 1
PIPER_OUTPUT_SAMPLE_WIDTH_BYTES = 2  # S16_LE


def synthesize(cfg: TTSConfig, lang: str, text: str) -> bytes:
    """Run Piper to synthesize text; return raw PCM bytes
    (22050 Hz, S16_LE, mono). Returns b'' on failure (logged)."""
    voice = cfg.voice_zh if lang == "zh" else cfg.voice_en
    voice_path = cfg.voices_dir / voice
    if not voice_path.exists():
        LOG.error("piper voice not found at %s", voice_path)
        return b""
    piper_cmd = [cfg.piper_binary, "--model", str(voice_path), "--output_raw"]
    LOG.debug("synthesize lang=%s len=%d cmd=%s", lang, len(text), " ".join(map(shlex.quote, piper_cmd)))
    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            piper_cmd,
            input=text.encode("utf-8"),
            capture_output=True,
            timeout=15,
            check=False,
        )
    except FileNotFoundError as e:
        LOG.error("piper binary not found: %s (is the venv active and piper-tts installed?)", e)
        return b""
    except subprocess.TimeoutExpired:
        LOG.error("piper timed out synthesizing: %r", text[:80])
        return b""
    elapsed_ms = (time.monotonic() - t0) * 1000.0
    if proc.returncode != 0:
        LOG.warning(
            "piper exit %d in %.0fms: %s",
            proc.returncode,
            elapsed_ms,
            proc.stderr.decode(errors="replace")[:400],
        )
        return b""
    LOG.info(
        "synthesize lang=%s text=%r bytes=%d in %.0fms",
        lang,
        text[:60],
        len(proc.stdout),
        elapsed_ms,
    )
    return proc.stdout


def play_pcm(cfg: TTSConfig, pcm: bytes) -> None:
    """Pipe raw PCM through the configured audio player (CLI mode)."""
    if not pcm:
        return
    player_cmd = [
        cfg.audio_player,
        *cfg.audio_player_args,
        "-r", str(PIPER_OUTPUT_SAMPLE_RATE),
        "-f", "S16_LE",
        "-c", str(PIPER_OUTPUT_CHANNELS),
        "-",
    ]
    try:
        proc = subprocess.run(player_cmd, input=pcm, capture_output=True, timeout=30, check=False)
    except FileNotFoundError as e:
        LOG.error("audio player not found: %s", e)
        return
    except subprocess.TimeoutExpired:
        LOG.error("audio player timed out")
        return
    if proc.returncode != 0:
        LOG.warning(
            "audio player exit %d: %s",
            proc.returncode,
            proc.stderr.decode(errors="replace")[:400],
        )


def speak(cfg: TTSConfig, lang: str, text: str) -> None:
    """Synthesize and play. CLI-mode convenience wrapper."""
    pcm = synthesize(cfg, lang, text)
    play_pcm(cfg, pcm)


class TtsAnnouncer:
    """Encapsulates the spoken-event dispatch logic (cooldown, rate limit,
    language resolution, render) so both the CLI main() and the relay_server
    can reuse it without duplicating state."""

    def __init__(self, cfg: TTSConfig, lang_hint: str | None = None) -> None:
        self.cfg = cfg
        self.lang_hint = lang_hint
        self._last_global = 0.0
        self._last_per_name: dict[str, float] = {}

    def render(self, event: dict) -> tuple[str, str] | None:
        """Decide whether and how to announce. Returns (lang, text), or None
        if the event is not spoken (wrong type, rate-limited, cooldown, empty)."""
        evt_type = event.get("event")
        if evt_type not in SPOKEN_EVENT_TYPES:
            LOG.debug("render: ignoring non-spoken event %r", evt_type)
            return None

        name_key = event.get("name_en") or event.get("name_zh") or "?"
        now = time.monotonic()
        if now - self._last_global < self.cfg.rate_limit_seconds:
            LOG.info("render: rate-limited (global), skipping %s", name_key)
            return None
        if now - self._last_per_name.get(name_key, 0.0) < self.cfg.announcement_cooldown_seconds:
            LOG.info("render: cooldown active for %s, skipping", name_key)
            return None

        lang = resolve_language(self.cfg, self.lang_hint)
        text = render_text(self.cfg, lang, event).strip()
        if not text:
            LOG.warning("render: empty text for %s in %s", name_key, lang)
            return None

        self._last_global = now
        self._last_per_name[name_key] = now
        return lang, text


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Vision Companion TTS bridge.")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument(
        "--last-input-lang",
        default=None,
        help="Language hint for mirror mode: 'zh' or 'en'. Falls back to config.preferred_language.",
    )
    parser.add_argument("--quiet", action="store_true", help="Skip TTS, just log what would be said")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="[%(levelname)s] %(name)s: %(message)s",
        stream=sys.stderr,
    )

    cfg = load_config(args.config)
    announcer = TtsAnnouncer(cfg, lang_hint=args.last_input_lang)

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            LOG.warning("non-JSON input dropped: %s", line[:120])
            continue

        decision = announcer.render(event)
        if decision is None:
            continue
        lang, text = decision
        evt_type = event.get("event", "?")
        LOG.info("announce[%s/%s]: %s", evt_type, lang, text)
        if not args.quiet:
            speak(cfg, lang, text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
