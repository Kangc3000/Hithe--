#!/usr/bin/env python3
"""Real-time voice identification daemon for Vision Companion.

Listens to a microphone (or raw 16kHz mono PCM on stdin), detects speech with
a simple RMS gate, computes ECAPA-TDNN embeddings on speech segments, and
matches against the local gallery. Emits JSON Lines events on stdout.

Event contract is locked in PROJECT-SPEC.md section 5.1 and IMPLEMENTATION-GUIDE.md
section 3.2. Don't add ad-hoc events; update the spec first.

This daemon is local-only. It never calls any cloud service. The voice gallery
file holds biometric data and must never be committed or transmitted.

Usage:
  voice_id.py --listen-mic
  voice_id.py --listen-stdin               # raw 16kHz mono float32 PCM
  voice_id.py --audio one_clip.wav         # one-shot for testing
"""
from __future__ import annotations

import argparse
import json
import logging
import queue
import signal
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

import numpy as np
import sounddevice as sd
import soundfile as sf
import torch
import yaml
from speechbrain.inference.speaker import EncoderClassifier

LOG = logging.getLogger("voice_id")

DEFAULT_CONFIG = Path("~/.hermes/voice-companion/config.yaml").expanduser()
DEFAULT_GALLERY = Path(
    "~/.hermes/voice-companion/scripts/gallery/voice_gallery.json"
).expanduser()
DEFAULT_STATE_DIR = Path("~/.hermes/voice-companion/state").expanduser()
ACTIVE_FLAG_NAME = "active.flag"

ECAPA_MODEL_SOURCE = "speechbrain/spkrec-ecapa-voxceleb"

CHUNK_SECONDS = 0.1  # mic poll granularity


@dataclass
class DaemonConfig:
    similarity_threshold: float
    silence_rms: float
    min_speech_seconds: float
    max_speech_seconds: float
    unknown_speaker_emit_interval_seconds: float
    sample_rate: int
    input_channels: int
    input_device: int | str | None
    classroom_mode: bool


def load_config(path: Path) -> DaemonConfig:
    with path.open("r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    return DaemonConfig(
        similarity_threshold=float(raw.get("similarity_threshold", 0.65)),
        silence_rms=float(raw.get("silence_rms", 0.005)),
        min_speech_seconds=float(raw.get("min_speech_seconds", 2.0)),
        max_speech_seconds=float(raw.get("max_speech_seconds", 5.0)),
        unknown_speaker_emit_interval_seconds=float(
            raw.get("unknown_speaker_emit_interval_seconds", 30.0)
        ),
        sample_rate=int(raw.get("sample_rate", 16000)),
        input_channels=int(raw.get("input_channels", 1)),
        input_device=raw.get("input_device"),
        classroom_mode=bool(raw.get("classroom_mode", False)),
    )


@dataclass
class GalleryEntry:
    key: str
    name_en: str
    name_zh: str
    embedding: np.ndarray


def load_gallery(path: Path) -> list[GalleryEntry]:
    if not path.exists():
        LOG.warning("gallery file not found at %s; nobody is enrolled yet", path)
        return []
    with path.open("r", encoding="utf-8") as f:
        raw = json.load(f)
    entries: list[GalleryEntry] = []
    for key, val in raw.items():
        emb = np.asarray(val["embedding"], dtype=np.float32)
        norm = float(np.linalg.norm(emb))
        if norm == 0.0:
            LOG.warning("gallery entry %r has zero-norm embedding; skipping", key)
            continue
        emb = emb / norm
        entries.append(
            GalleryEntry(
                key=key,
                name_en=val.get("name_en", key),
                name_zh=val.get("name_zh", key),
                embedding=emb,
            )
        )
    LOG.info("gallery loaded: %d enrolled speakers", len(entries))
    return entries


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


_emit_callback = None


def set_emit_callback(callback) -> None:
    """Override the default stdout emitter so an embedding host (e.g. the
    relay_server) can intercept events instead of getting them via JSON Lines
    on stdout. Pass None to restore the default."""
    global _emit_callback
    _emit_callback = callback


def emit(event: dict) -> None:
    if _emit_callback is not None:
        try:
            _emit_callback(event)
        except Exception:  # pragma: no cover
            LOG.exception("emit callback raised; falling back to stdout")
            sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        return
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def emit_status(daemon: str, status: str, message: str = "") -> None:
    emit(
        {
            "event": "daemon_status",
            "daemon": daemon,
            "status": status,
            "message": message,
            "timestamp": now_iso(),
        }
    )


def load_model(model_dir: Path) -> EncoderClassifier:
    LOG.info("loading ECAPA-TDNN (cache: %s)", model_dir)
    return EncoderClassifier.from_hparams(
        source=ECAPA_MODEL_SOURCE,
        savedir=str(model_dir),
        run_opts={"device": "cpu"},
    )


def compute_embedding(model: EncoderClassifier, audio: np.ndarray) -> np.ndarray:
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    audio = audio.astype(np.float32)
    tensor = torch.from_numpy(audio).unsqueeze(0)
    with torch.no_grad():
        emb = model.encode_batch(tensor).squeeze().cpu().numpy()
    norm = float(np.linalg.norm(emb))
    if norm == 0.0:
        raise ValueError("zero-norm embedding")
    return (emb / norm).astype(np.float32)


def best_match(emb: np.ndarray, gallery: Sequence[GalleryEntry]) -> tuple[GalleryEntry | None, float]:
    if not gallery:
        return None, -1.0
    best: GalleryEntry | None = None
    best_score = -1.0
    for entry in gallery:
        score = float(np.dot(emb, entry.embedding))
        if score > best_score:
            best_score = score
            best = entry
    return best, best_score


def mic_chunks(cfg: DaemonConfig, stop: threading.Event) -> Iterable[np.ndarray]:
    """Yield ~CHUNK_SECONDS chunks of mono float32 audio from the default mic."""
    q: queue.Queue[np.ndarray] = queue.Queue(maxsize=64)

    def callback(indata, frames, time_info, status):  # noqa: ARG001
        if status:
            LOG.debug("sounddevice status: %s", status)
        if cfg.input_channels == 1 and indata.ndim > 1:
            data = indata[:, 0].copy()
        else:
            data = indata.copy().reshape(-1)
        try:
            q.put_nowait(data)
        except queue.Full:
            LOG.warning("audio queue full, dropping chunk")

    blocksize = int(cfg.sample_rate * CHUNK_SECONDS)
    with sd.InputStream(
        samplerate=cfg.sample_rate,
        channels=cfg.input_channels,
        dtype="float32",
        blocksize=blocksize,
        device=cfg.input_device,
        callback=callback,
    ):
        while not stop.is_set():
            try:
                yield q.get(timeout=0.5)
            except queue.Empty:
                continue


def stdin_chunks(cfg: DaemonConfig, stop: threading.Event) -> Iterable[np.ndarray]:
    """Yield chunks of float32 PCM read from stdin (16kHz mono assumed)."""
    blocksize = int(cfg.sample_rate * CHUNK_SECONDS)
    bufsize = blocksize * 4  # 4 bytes/sample
    raw = sys.stdin.buffer
    while not stop.is_set():
        chunk = raw.read(bufsize)
        if not chunk:
            return
        yield np.frombuffer(chunk, dtype=np.float32).copy()


class SpeechAggregator:
    """Accumulates speech segments separated by silence, in fixed-size buffers."""

    def __init__(self, cfg: DaemonConfig) -> None:
        self.cfg = cfg
        self.buffer: list[np.ndarray] = []
        self.last_speech_at: float = 0.0
        self.silence_streak_chunks = 0
        self.max_samples = int(cfg.max_speech_seconds * cfg.sample_rate)
        self.min_samples = int(cfg.min_speech_seconds * cfg.sample_rate)
        # ~half-second of silence ends a segment
        self.silence_chunks_to_end = max(1, int(0.5 / CHUNK_SECONDS))

    def feed(self, chunk: np.ndarray) -> np.ndarray | None:
        rms = float(np.sqrt(np.mean(chunk**2))) if chunk.size else 0.0
        is_speech = rms > self.cfg.silence_rms

        if is_speech:
            self.buffer.append(chunk)
            self.silence_streak_chunks = 0
            self.last_speech_at = time.monotonic()
            current = sum(b.size for b in self.buffer)
            if current >= self.max_samples:
                return self._flush()
        else:
            if self.buffer:
                self.silence_streak_chunks += 1
                if self.silence_streak_chunks >= self.silence_chunks_to_end:
                    return self._flush()
        return None

    def _flush(self) -> np.ndarray | None:
        if not self.buffer:
            return None
        segment = np.concatenate(self.buffer)
        self.buffer.clear()
        self.silence_streak_chunks = 0
        if segment.size < self.min_samples:
            return None
        return segment


class Identifier:
    def __init__(
        self,
        cfg: DaemonConfig,
        model: EncoderClassifier,
        gallery: list[GalleryEntry],
        state_dir: Path,
    ) -> None:
        self.cfg = cfg
        self.model = model
        self.gallery = gallery
        self.state_dir = state_dir
        self.last_unknown_emit = 0.0
        self.last_active_seen: bool | None = None

    def _check_active(self) -> bool:
        active = (self.state_dir / ACTIVE_FLAG_NAME).exists()
        if active != self.last_active_seen:
            emit_status(
                "voice-id",
                "active" if active else "paused",
                "hithe flag transition",
            )
            self.last_active_seen = active
        return active

    def process(self, segment: np.ndarray) -> None:
        if not self._check_active():
            return
        try:
            emb = compute_embedding(self.model, segment)
        except ValueError as e:
            LOG.warning("skipped segment: %s", e)
            return

        entry, score = best_match(emb, self.gallery)
        if entry is not None and score >= self.cfg.similarity_threshold:
            emit(
                {
                    "event": "speaker_identified",
                    "name_en": entry.name_en,
                    "name_zh": entry.name_zh,
                    "confidence": round(score, 4),
                    "timestamp": now_iso(),
                }
            )
            return

        # Not a match. Maybe emit unknown_speaker, rate-limited.
        now = time.monotonic()
        if now - self.last_unknown_emit >= self.cfg.unknown_speaker_emit_interval_seconds:
            emit(
                {
                    "event": "unknown_speaker",
                    "confidence": round(max(score, 0.0), 4),
                    "timestamp": now_iso(),
                }
            )
            self.last_unknown_emit = now


def run_one_shot(
    cfg: DaemonConfig,
    model: EncoderClassifier,
    gallery: list[GalleryEntry],
    state_dir: Path,
    audio_path: Path,
) -> int:
    audio, sr = sf.read(str(audio_path), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != cfg.sample_rate:
        LOG.error("audio sample rate %d != configured %d", sr, cfg.sample_rate)
        return 2
    Identifier(cfg, model, gallery, state_dir).process(audio)
    return 0


def run_stream(
    cfg: DaemonConfig,
    model: EncoderClassifier,
    gallery: list[GalleryEntry],
    state_dir: Path,
    chunks: Iterable[np.ndarray],
) -> int:
    state_dir.mkdir(parents=True, exist_ok=True)
    aggregator = SpeechAggregator(cfg)
    identifier = Identifier(cfg, model, gallery, state_dir)
    initial_active = (state_dir / ACTIVE_FLAG_NAME).exists()
    emit_status(
        "voice-id",
        "active" if initial_active else "paused",
        f"gallery_size={len(gallery)}",
    )
    identifier.last_active_seen = initial_active
    for chunk in chunks:
        segment = aggregator.feed(chunk)
        if segment is not None:
            identifier.process(segment)
    emit_status("voice-id", "stopped", "input stream ended")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Vision Companion voice-id daemon.")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--listen-mic", action="store_true", help="Capture from default microphone")
    src.add_argument("--listen-stdin", action="store_true", help="Read 16kHz mono float32 PCM from stdin")
    src.add_argument("--audio", type=Path, help="Process a single WAV file then exit (for testing)")

    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--gallery", type=Path, default=DEFAULT_GALLERY)
    parser.add_argument(
        "--model-dir",
        type=Path,
        default=Path("~/.hermes/voice-companion/models/ecapa").expanduser(),
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=DEFAULT_STATE_DIR,
        help="Directory holding the active.flag (managed by `hithe`)",
    )

    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="[%(levelname)s] %(name)s: %(message)s",
        stream=sys.stderr,
    )

    cfg = load_config(args.config)

    if cfg.classroom_mode:
        LOG.error("classroom_mode is true; voice-id refuses to run")
        emit_status("voice-id", "blocked", "classroom_mode=true")
        return 3

    gallery = load_gallery(args.gallery)
    if not gallery:
        emit_status("voice-id", "warning", "gallery empty; nothing to match against")

    try:
        model = load_model(args.model_dir)
    except Exception as e:  # pragma: no cover - logged for ops
        LOG.exception("model load failed")
        emit_status("voice-id", "error", f"model load failed: {e}")
        return 4

    stop = threading.Event()

    def _handle_signal(signum, _frame):
        LOG.info("signal %d received; shutting down", signum)
        stop.set()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    try:
        if args.audio is not None:
            return run_one_shot(cfg, model, gallery, args.state_dir, args.audio)
        if args.listen_mic:
            return run_stream(cfg, model, gallery, args.state_dir, mic_chunks(cfg, stop))
        if args.listen_stdin:
            return run_stream(cfg, model, gallery, args.state_dir, stdin_chunks(cfg, stop))
    except Exception as e:  # pragma: no cover - daemon must never crash silently
        LOG.exception("unhandled error in voice-id main loop")
        emit_status("voice-id", "error", str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
