#!/usr/bin/env python3
"""WebSocket relay server for Vision Companion.

This is the production entry point on the Hermes Ubuntu host once the
Android relay app is in play. It replaces the standalone voice-id and
face-id daemons (which were CLI-driven from the host's local mic/webcam).

Architecture:

  [Galaxy S25 relay app]  --Tailscale-->  [Hermes host: relay_server.py]
        ▲                                          │
        │   PCM audio (16k mono int16)             │  voice-id pipeline
        │   JPEG images                            │  face-id pipeline
        │   JSON control                           │  TTS (Piper)
        ▼                                          │
  ─────────── WebSocket  ────────────────  events back to Android
                         (TTS PCM goes back the same way)

Wire format on the WebSocket:

  Uplink (Android → relay):
    BINARY  byte 0x01 + raw PCM:    audio chunk, 16kHz mono int16 LE
    BINARY  byte 0x02 + JPEG bytes: image frame
    TEXT    JSON object:            control msg (e.g. {"type":"ping"})

  Downlink (relay → Android):
    BINARY  byte 0x03 + raw PCM:    TTS audio (Piper output, 22050Hz mono int16 LE)
    TEXT    JSON object:            recognition event or daemon_status

This single process embeds the voice-id Identifier, face-id FaceIdentifier,
and TTS bridge in one Python interpreter with model files loaded once.
Compared to the old daemon-per-skill pipeline this lowers latency and
removes pipe wiring; the cost is that a model crash takes the whole relay
down (mitigated by systemd Restart=on-failure).

Logging: every frame, every embedding, every TTS call is logged at INFO
with a structured key=value tail so a `grep | awk` debug session is easy.
DEBUG level adds per-byte counters and per-segment RMS values.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import logging.handlers
import os
import signal
import sys
import time
from contextlib import suppress
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse, parse_qs

import cv2
import numpy as np
import websockets
from websockets.server import WebSocketServerProtocol

# Sibling module imports — relay_server runs from
# ~/.hermes/voice-companion/scripts/ where all daemons co-locate.
import voice_id as vi
import face_id as fi
import tts_announce as tts


# ---------------------------------------------------------------------------
# Wire-format constants. Keep in sync with the Kotlin client.
# ---------------------------------------------------------------------------
FRAME_TYPE_AUDIO_PCM = 0x01
FRAME_TYPE_IMAGE_JPEG = 0x02
FRAME_TYPE_TTS_PCM = 0x03

# Phone mics typically deliver int16. We convert on the fly to float32 [-1,1]
# for ECAPA. The image side is JPEG-decoded with OpenCV.
INT16_TO_FLOAT_DIVISOR = 32768.0


# ---------------------------------------------------------------------------
# Paths and defaults
# ---------------------------------------------------------------------------
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8765

DEFAULT_CONFIG = Path("~/.hermes/voice-companion/config.yaml").expanduser()
DEFAULT_VOICE_GALLERY = Path(
    "~/.hermes/voice-companion/scripts/gallery/voice_gallery.json"
).expanduser()
DEFAULT_FACE_GALLERY = Path(
    "~/.hermes/voice-companion/scripts/gallery/face_gallery.json"
).expanduser()
DEFAULT_VOICE_MODEL_DIR = Path("~/.hermes/voice-companion/models/ecapa").expanduser()
DEFAULT_FACE_MODEL_DIR = Path("~/.hermes/voice-companion/models/insightface").expanduser()
DEFAULT_STATE_DIR = Path("~/.hermes/voice-companion/state").expanduser()
DEFAULT_EVENTS_LOG = Path("~/.hermes/voice-companion/events.jsonl").expanduser()
DEFAULT_DAEMON_LOG = Path("~/.hermes/voice-companion/relay-daemon.log").expanduser()


# ---------------------------------------------------------------------------
# Logging setup. Two streams:
#   stderr (systemd captures to relay-daemon.log) — human-readable + verbose
#   events.jsonl                                  — recognition events only
# ---------------------------------------------------------------------------
LOG = logging.getLogger("relay")


def configure_logging(level: str, log_file: Path) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter(
        "%(asctime)s.%(msecs)03d %(levelname)-7s %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    root = logging.getLogger()
    root.setLevel(level)
    # systemd captures stderr; we keep that as the primary stream.
    sh = logging.StreamHandler(stream=sys.stderr)
    sh.setFormatter(fmt)
    root.addHandler(sh)
    # Rotating file in case stderr/journald isn't sufficient for forensics.
    fh = logging.handlers.RotatingFileHandler(
        log_file, maxBytes=10 * 1024 * 1024, backupCount=5, encoding="utf-8"
    )
    fh.setFormatter(fmt)
    root.addHandler(fh)
    # websockets is chatty at DEBUG; keep its INFO unless we asked for DEBUG.
    if level != "DEBUG":
        logging.getLogger("websockets").setLevel(logging.WARNING)


# ---------------------------------------------------------------------------
# Per-connection state
# ---------------------------------------------------------------------------
@dataclass
class SessionStats:
    audio_bytes_in: int = 0
    audio_chunks_in: int = 0
    image_bytes_in: int = 0
    image_frames_in: int = 0
    events_out: int = 0
    tts_bytes_out: int = 0
    tts_frames_out: int = 0
    started_at: float = field(default_factory=time.monotonic)

    def summary(self) -> str:
        elapsed = time.monotonic() - self.started_at
        return (
            f"elapsed={elapsed:.1f}s "
            f"audio_in={self.audio_chunks_in}chunks/{self.audio_bytes_in}B "
            f"image_in={self.image_frames_in}frames/{self.image_bytes_in}B "
            f"events_out={self.events_out} "
            f"tts_out={self.tts_frames_out}frames/{self.tts_bytes_out}B"
        )


@dataclass
class Session:
    ws: WebSocketServerProtocol
    peer: str
    voice_aggregator: vi.SpeechAggregator
    voice_identifier: vi.Identifier
    face_identifier: fi.FaceIdentifier
    announcer: tts.TtsAnnouncer
    cfg_tts: tts.TTSConfig
    cfg_voice: vi.DaemonConfig
    cfg_face: fi.DaemonConfig
    state_dir: Path
    voice_gallery_path: Path
    stats: SessionStats = field(default_factory=SessionStats)
    out_queue: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(maxsize=64))
    last_audio_at: float = 0.0
    last_image_at: float = 0.0
    # Voice enrollment state. When enroll_active is True, incoming speech
    # segments are collected as enrollment samples instead of being matched.
    enroll_active: bool = False
    enroll_name_en: str = ""
    enroll_name_zh: str = ""
    enroll_needed: int = 3
    enroll_embeddings: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# Event routing: Identifier emits → enqueue for client + persist to events.jsonl
# + optionally synthesize TTS and enqueue PCM frame.
# ---------------------------------------------------------------------------
class EventRouter:
    def __init__(self, session: Session, events_log: Path, loop: asyncio.AbstractEventLoop) -> None:
        self.session = session
        self.events_log = events_log
        # Capture the main event loop reference up front. __call__ runs in a
        # worker thread (handle_audio_chunk / handle_image_frame are dispatched
        # via run_in_executor), where asyncio.get_event_loop() raises
        # "no current event loop in thread". We must schedule work back onto
        # this captured loop with call_soon_threadsafe.
        self.loop = loop
        events_log.parent.mkdir(parents=True, exist_ok=True)

    def __call__(self, event: dict) -> None:
        """Synchronous emit() callback installed on voice_id and face_id modules.
        Invoked from a worker thread (model processing runs in run_in_executor),
        so all loop interaction must go through self.loop.call_soon_threadsafe."""
        try:
            self.events_log.parent.mkdir(parents=True, exist_ok=True)
            with self.events_log.open("a", encoding="utf-8") as f:
                f.write(json.dumps(event, ensure_ascii=False) + "\n")
        except OSError:
            LOG.exception("could not append to events.jsonl")

        # Forward as text frame to client. Schedule the coroutine on the loop
        # thread (create_task must run there, not in this worker thread).
        payload = json.dumps(event, ensure_ascii=False)
        self.loop.call_soon_threadsafe(self._spawn, self._enqueue_text(payload))
        self.session.stats.events_out += 1

        # Maybe also speak it.
        decision = self.session.announcer.render(event)
        if decision is None:
            return
        lang, text = decision
        evt_type = event.get("event", "?")
        LOG.info("announce %s lang=%s text=%r", evt_type, lang, text)
        # Synthesize off the loop thread so we don't block.
        self.loop.call_soon_threadsafe(
            self._spawn, self._synthesize_and_send(lang, text)
        )

    @staticmethod
    def _spawn(coro) -> None:
        """Runs on the loop thread (via call_soon_threadsafe). Safe to create a
        task here because we are now on the loop's thread."""
        asyncio.create_task(coro)

    async def _enqueue_text(self, payload: str) -> None:
        try:
            self.session.out_queue.put_nowait(("text", payload))
        except asyncio.QueueFull:
            LOG.warning("out_queue full; dropping text event")

    async def _synthesize_and_send(self, lang: str, text: str) -> None:
        # This coroutine runs as a task ON the loop thread, so get_running_loop
        # is valid here (unlike the worker-thread __call__ above).
        loop = asyncio.get_running_loop()
        pcm = await loop.run_in_executor(
            None, tts.synthesize, self.session.cfg_tts, lang, text
        )
        if not pcm:
            LOG.warning("TTS synthesis returned no bytes for %r", text[:60])
            return
        frame = bytes([FRAME_TYPE_TTS_PCM]) + pcm
        try:
            self.session.out_queue.put_nowait(("binary", frame))
        except asyncio.QueueFull:
            LOG.warning("out_queue full; dropping TTS frame (%d bytes)", len(frame))
            return
        self.session.stats.tts_frames_out += 1
        self.session.stats.tts_bytes_out += len(frame)


# ---------------------------------------------------------------------------
# Frame parsing
# ---------------------------------------------------------------------------
def parse_audio_pcm_int16(payload: bytes) -> np.ndarray | None:
    """Convert raw int16 LE PCM payload to float32 [-1, 1]."""
    if len(payload) < 2:
        return None
    if len(payload) % 2 != 0:
        LOG.warning("PCM payload not aligned to int16 (%d bytes); truncating", len(payload))
        payload = payload[: len(payload) - (len(payload) % 2)]
    arr = np.frombuffer(payload, dtype="<i2").astype(np.float32) / INT16_TO_FLOAT_DIVISOR
    return arr


def parse_jpeg(payload: bytes) -> np.ndarray | None:
    arr = np.frombuffer(payload, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if img is None:
        LOG.warning("JPEG decode failed (%d bytes)", len(payload))
    return img


# ---------------------------------------------------------------------------
# Per-frame handlers
# ---------------------------------------------------------------------------
def feed_audio_chunk(session: Session, chunk: np.ndarray) -> "np.ndarray | None":
    """Fast path: log RMS and feed the VAD aggregator. Returns a completed
    speech segment or None. Cheap enough to run inline in the read loop (numpy
    concat), which keeps chunk ordering correct for the aggregator."""
    rms = float(np.sqrt(np.mean(chunk**2))) if chunk.size else 0.0
    LOG.debug("audio chunk samples=%d rms=%.4f", chunk.size, rms)
    return session.voice_aggregator.feed(chunk)


def process_voice_segment(session: Session, segment: np.ndarray) -> None:
    """Heavy path: ECAPA embedding + identify-or-enroll. Runs in an executor
    thread so it NEVER blocks the WebSocket read loop — if it did, the loop
    couldn't answer the client's keepalive pings during the ~hundreds-of-ms
    inference and the phone would drop the connection mid-utterance."""
    duration = segment.size / session.cfg_voice.sample_rate
    LOG.info("speech segment duration=%.2fs samples=%d", duration, segment.size)
    if session.enroll_active:
        _handle_enroll_segment(session, segment)
        return
    t0 = time.monotonic()
    session.voice_identifier.process(segment)
    LOG.debug("voice_identifier.process took %.0fms", (time.monotonic() - t0) * 1000)


def _handle_enroll_segment(session: Session, segment: np.ndarray) -> None:
    """Collect one enrollment sample from a speech segment. When enough samples
    are gathered, average them, write to the gallery, and reload the live
    identifier. Emits enroll_progress / enroll_done events back to the client."""
    try:
        emb = vi.compute_embedding(session.voice_identifier.model, segment)
    except ValueError as e:
        LOG.warning("enroll: skipped segment: %s", e)
        return
    session.enroll_embeddings.append(emb)
    collected = len(session.enroll_embeddings)
    LOG.info("enroll: collected sample %d/%d for %s", collected, session.enroll_needed, session.enroll_name_en)
    vi.emit(
        {
            "event": "enroll_progress",
            "name_en": session.enroll_name_en,
            "name_zh": session.enroll_name_zh,
            "collected": collected,
            "needed": session.enroll_needed,
            "timestamp": vi.now_iso(),
        }
    )
    if collected < session.enroll_needed:
        return

    # Enough samples — average, normalize, write to gallery.
    import numpy as _np
    centroid = _np.mean(_np.stack(session.enroll_embeddings), axis=0)
    norm = float(_np.linalg.norm(centroid))
    if norm == 0.0:
        LOG.error("enroll: zero-norm centroid; aborting")
        session.enroll_active = False
        session.enroll_embeddings = []
        return
    centroid = (centroid / norm).astype(_np.float32)

    key = "".join(c.lower() if c.isalnum() else "_" for c in session.enroll_name_en).strip("_") or "person"
    gallery_path = session.voice_gallery_path
    try:
        gallery = json.loads(gallery_path.read_text(encoding="utf-8")) if gallery_path.exists() else {}
    except Exception:
        gallery = {}
    gallery[key] = {
        "name_en": session.enroll_name_en,
        "name_zh": session.enroll_name_zh,
        "embedding": centroid.tolist(),
        "enrolled_on": vi.now_iso(),
        "consent_recorded": True,
        "sample_count": collected,
        "notes": "enrolled via relay",
    }
    gallery_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = gallery_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(gallery, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(gallery_path)
    try:
        gallery_path.chmod(0o600)
    except OSError:
        pass

    # Reload the live identifier's gallery so the new voice matches immediately.
    session.voice_identifier.gallery = vi.load_gallery(gallery_path)
    LOG.info("enroll: wrote %s to gallery; identifier now has %d enrolled",
             key, len(session.voice_identifier.gallery))

    name_en = session.enroll_name_en
    name_zh = session.enroll_name_zh
    session.enroll_active = False
    session.enroll_embeddings = []
    vi.emit(
        {
            "event": "enroll_done",
            "name_en": name_en,
            "name_zh": name_zh,
            "samples": collected,
            "timestamp": vi.now_iso(),
        }
    )


def handle_image_frame(session: Session, image: np.ndarray) -> None:
    h, w = image.shape[:2]
    LOG.info("image frame %dx%d", w, h)
    t0 = time.monotonic()
    session.face_identifier.process_frame(image)
    LOG.debug("face_identifier.process_frame took %.0fms", (time.monotonic() - t0) * 1000)


# ---------------------------------------------------------------------------
# Connection lifecycle
# ---------------------------------------------------------------------------
ACTIVE_CLIENT_LOCK = asyncio.Lock()
ACTIVE_CLIENT: WebSocketServerProtocol | None = None

# WebSocket close code reserved for "token missing/invalid". 4000-4999 is
# the application-defined range per RFC 6455.
CLOSE_CODE_INVALID_TOKEN = 4401


def extract_token(ws_path: str) -> str:
    """Pull the `token` query-string parameter out of the WebSocket path.
    Returns empty string if not present. The path arrives with the query
    string intact, e.g. '/?token=vcr_abc' (after Apache strips '/vc-relay/')."""
    try:
        parsed = urlparse(ws_path)
        qs = parse_qs(parsed.query)
        values = qs.get("token") or []
        return values[0] if values else ""
    except Exception:
        return ""


async def writer_task(session: Session) -> None:
    """Drain the out_queue and forward to the WebSocket. Separated from the
    reader so a slow synth doesn't stall the read side."""
    while True:
        kind, payload = await session.out_queue.get()
        try:
            if kind == "text":
                await session.ws.send(payload)
            elif kind == "binary":
                await session.ws.send(payload)
        except websockets.ConnectionClosed:
            LOG.info("writer: connection closed; exiting")
            return
        except Exception:
            LOG.exception("writer: send failed")
            return


async def handle_connection(
    ws: WebSocketServerProtocol,
    cfg_voice: vi.DaemonConfig,
    cfg_face: fi.DaemonConfig,
    cfg_tts: tts.TTSConfig,
    voice_model,
    face_model,
    voice_gallery: list[vi.GalleryEntry],
    face_gallery: list[fi.GalleryEntry],
    state_dir: Path,
    events_log: Path,
    expected_token: str,
    voice_gallery_path: Path,
) -> None:
    global ACTIVE_CLIENT

    peer = f"{ws.remote_address[0]}:{ws.remote_address[1]}"
    LOG.info("client connecting peer=%s path=%r", peer, ws.path)

    # ---- token auth (only enforced if a token is configured) ----
    if expected_token:
        client_token = extract_token(ws.path)
        if not client_token:
            LOG.warning("rejecting %s: no token in query string", peer)
            await ws.close(code=CLOSE_CODE_INVALID_TOKEN, reason="missing token")
            return
        # Constant-time comparison to avoid timing attacks.
        from hmac import compare_digest
        if not compare_digest(client_token, expected_token):
            LOG.warning(
                "rejecting %s: token mismatch (client sent %d chars)",
                peer, len(client_token),
            )
            await ws.close(code=CLOSE_CODE_INVALID_TOKEN, reason="invalid token")
            return
        LOG.info("token validated for peer=%s", peer)
    else:
        LOG.debug("no token configured; skipping auth for peer=%s", peer)

    async with ACTIVE_CLIENT_LOCK:
        if ACTIVE_CLIENT is not None and not ACTIVE_CLIENT.closed:
            LOG.warning("rejecting %s: another client is active", peer)
            await ws.close(code=1013, reason="another client is active")
            return
        ACTIVE_CLIENT = ws

    # Reload galleries from disk on every connection so that a voice enrolled
    # in a previous session is immediately matchable after a reconnect. The
    # startup-loaded `voice_gallery`/`face_gallery` lists go stale the moment
    # an enrollment writes to disk.
    fresh_voice_gallery = vi.load_gallery(voice_gallery_path)
    aggregator = vi.SpeechAggregator(cfg_voice)
    voice_id = vi.Identifier(cfg_voice, voice_model, fresh_voice_gallery, state_dir)
    face_id = fi.FaceIdentifier(cfg_face, face_model, face_gallery, state_dir)
    announcer = tts.TtsAnnouncer(cfg_tts)
    session = Session(
        ws=ws,
        peer=peer,
        voice_aggregator=aggregator,
        voice_identifier=voice_id,
        face_identifier=face_id,
        announcer=announcer,
        cfg_tts=cfg_tts,
        cfg_voice=cfg_voice,
        cfg_face=cfg_face,
        state_dir=state_dir,
        voice_gallery_path=voice_gallery_path,
    )

    # Install the emit callback so events from voice_id/face_id flow into our
    # router. The callback is module-global, but we only allow ONE concurrent
    # client so this is safe in Phase 1. Capture the running loop here (we're
    # on the loop thread) so the router can schedule work back from worker
    # threads via call_soon_threadsafe.
    router = EventRouter(session, events_log, asyncio.get_running_loop())
    vi.set_emit_callback(router)
    fi.set_emit_callback(router)

    LOG.info("session opened peer=%s", peer)
    initial_active = (state_dir / vi.ACTIVE_FLAG_NAME).exists()
    welcome = {
        "event": "session_started",
        "peer": peer,
        "voice_gallery_size": len(fresh_voice_gallery),
        "face_gallery_size": len(face_gallery),
        "active": initial_active,
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    try:
        await ws.send(json.dumps(welcome, ensure_ascii=False))
    except Exception:
        LOG.exception("welcome send failed")

    writer = asyncio.create_task(writer_task(session))

    loop = asyncio.get_event_loop()

    try:
        async for raw in ws:
            if isinstance(raw, str):
                # Text control frame.
                LOG.debug("text frame in: %s", raw[:120])
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    LOG.warning("non-JSON text frame from %s: %r", peer, raw[:120])
                    continue
                msg_type = msg.get("type")
                if msg_type == "ping":
                    await ws.send(
                        json.dumps({"type": "pong", "echo": msg.get("nonce")})
                    )
                elif msg_type == "hello":
                    LOG.info(
                        "client hello version=%s transport=%s",
                        msg.get("version"), msg.get("transport"),
                    )
                elif msg_type == "enroll":
                    name_en = str(msg.get("name_en", "")).strip()
                    name_zh = str(msg.get("name_zh", "")).strip()
                    if not name_en or not name_zh:
                        LOG.warning("enroll request missing name_en/name_zh")
                        await ws.send(json.dumps({
                            "event": "enroll_error",
                            "message": "name_en and name_zh are required",
                        }, ensure_ascii=False))
                    elif session.enroll_active and session.enroll_embeddings:
                        LOG.info("enroll already in progress (%d collected); ignoring re-tap",
                                 len(session.enroll_embeddings))
                    else:
                        session.enroll_active = True
                        session.enroll_name_en = name_en
                        session.enroll_name_zh = name_zh
                        # Phase 1: 1 segment is enough for a usable embedding and
                        # keeps the flow robust without on-screen progress UI.
                        # Raise once the app shows enroll progress.
                        session.enroll_needed = 1
                        session.enroll_embeddings = []
                        LOG.info("enroll START name_en=%s name_zh=%s needed=%d",
                                 name_en, name_zh, session.enroll_needed)
                        await ws.send(json.dumps({
                            "event": "enroll_started",
                            "name_en": name_en,
                            "name_zh": name_zh,
                            "needed": session.enroll_needed,
                        }, ensure_ascii=False))
                elif msg_type == "enroll_cancel":
                    session.enroll_active = False
                    session.enroll_embeddings = []
                    LOG.info("enroll cancelled by client")
                elif msg_type == "shutdown":
                    LOG.info("client requested shutdown")
                    break
                else:
                    LOG.info("unknown control type=%r from %s", msg_type, peer)
                continue

            # Binary frame.
            if not raw:
                continue
            ftype = raw[0]
            payload = raw[1:]
            if ftype == FRAME_TYPE_AUDIO_PCM:
                session.stats.audio_chunks_in += 1
                session.stats.audio_bytes_in += len(payload)
                session.last_audio_at = time.monotonic()
                chunk = parse_audio_pcm_int16(payload)
                if chunk is not None:
                    # Feed the VAD inline (fast, ordered); when a full speech
                    # segment is ready, offload the heavy ECAPA work WITHOUT
                    # awaiting so the read loop stays responsive to pings.
                    segment = feed_audio_chunk(session, chunk)
                    if segment is not None:
                        loop.run_in_executor(None, process_voice_segment, session, segment)
            elif ftype == FRAME_TYPE_IMAGE_JPEG:
                session.stats.image_frames_in += 1
                session.stats.image_bytes_in += len(payload)
                session.last_image_at = time.monotonic()
                image = parse_jpeg(payload)
                if image is not None:
                    # Offload face inference without awaiting (same reasoning).
                    loop.run_in_executor(None, handle_image_frame, session, image)
            else:
                LOG.warning("unknown binary frame type=0x%02x len=%d from %s", ftype, len(payload), peer)
    except websockets.ConnectionClosed as e:
        LOG.info("client closed peer=%s code=%s reason=%r", peer, e.code, e.reason)
    except Exception:
        LOG.exception("connection handler crashed for peer=%s", peer)
    finally:
        writer.cancel()
        with suppress(asyncio.CancelledError):
            await writer
        # Detach callbacks before another client (might never happen, but be safe).
        vi.set_emit_callback(None)
        fi.set_emit_callback(None)
        async with ACTIVE_CLIENT_LOCK:
            if ACTIVE_CLIENT is ws:
                ACTIVE_CLIENT = None
        LOG.info("session closed peer=%s %s", peer, session.stats.summary())


# ---------------------------------------------------------------------------
# Server entry point
# ---------------------------------------------------------------------------
async def serve(args: argparse.Namespace) -> None:
    cfg_voice = vi.load_config(args.config)
    cfg_face = fi.load_config(args.config)
    cfg_tts = tts.load_config(args.config)

    if cfg_voice.classroom_mode or cfg_face.classroom_mode:
        LOG.error("classroom_mode is true; relay refuses to run")
        sys.exit(3)

    LOG.info("loading voice-id model from %s", args.voice_model_dir)
    voice_model = vi.load_model(args.voice_model_dir)
    LOG.info("loading face-id model from %s", args.face_model_dir)
    face_model = fi.load_model(args.face_model_dir, cfg_face.detection_size)

    voice_gallery = vi.load_gallery(args.voice_gallery)
    face_gallery = fi.load_gallery(args.face_gallery)

    args.state_dir.mkdir(parents=True, exist_ok=True)
    args.events_log.parent.mkdir(parents=True, exist_ok=True)

    # Token may be passed via --token or RELAY_TOKEN env var. Empty = no auth.
    expected_token = (args.token or os.environ.get("RELAY_TOKEN") or "").strip()
    if expected_token:
        LOG.info("token auth enabled (token length=%d)", len(expected_token))
    else:
        LOG.warning(
            "no relay token configured (--token / RELAY_TOKEN both empty); "
            "ANY client that can reach this port can connect"
        )

    LOG.info(
        "starting WebSocket server on %s:%d (voice=%d enrolled, face=%d enrolled)",
        args.host, args.port, len(voice_gallery), len(face_gallery),
    )

    async def handler(ws: WebSocketServerProtocol) -> None:
        await handle_connection(
            ws,
            cfg_voice=cfg_voice,
            cfg_face=cfg_face,
            cfg_tts=cfg_tts,
            voice_model=voice_model,
            face_model=face_model,
            voice_gallery=voice_gallery,
            face_gallery=face_gallery,
            state_dir=args.state_dir,
            events_log=args.events_log,
            expected_token=expected_token,
            voice_gallery_path=args.voice_gallery,
        )

    stop = asyncio.Event()

    def _signal(_signum, _frame):
        LOG.info("signal received; stopping server")
        stop.set()

    signal.signal(signal.SIGTERM, _signal)
    signal.signal(signal.SIGINT, _signal)

    async with websockets.serve(
        handler,
        args.host,
        args.port,
        max_size=8 * 1024 * 1024,  # allow up to 8MB JPEGs
        # Keepalive: ping every 20s but tolerate up to 60s without a pong.
        # The EC2<->Mac-Mini Tailscale link can fall back to a DERP relay
        # (higher, spikier latency), so a tight 20s pong deadline caused
        # spurious drops. 60s is forgiving without leaving dead sockets long.
        ping_interval=20,
        ping_timeout=60,
    ):
        await stop.wait()

    LOG.info("server stopped")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Vision Companion WebSocket relay server.")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Bind address (default {DEFAULT_HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"TCP port (default {DEFAULT_PORT})")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--voice-gallery", type=Path, default=DEFAULT_VOICE_GALLERY)
    parser.add_argument("--face-gallery", type=Path, default=DEFAULT_FACE_GALLERY)
    parser.add_argument("--voice-model-dir", type=Path, default=DEFAULT_VOICE_MODEL_DIR)
    parser.add_argument("--face-model-dir", type=Path, default=DEFAULT_FACE_MODEL_DIR)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser.add_argument("--events-log", type=Path, default=DEFAULT_EVENTS_LOG)
    parser.add_argument("--log-file", type=Path, default=DEFAULT_DAEMON_LOG)
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity (default INFO; DEBUG dumps per-chunk stats)",
    )
    parser.add_argument(
        "--token",
        default="",
        help=(
            "Shared secret. If non-empty, incoming WebSocket connections must "
            "carry ?token=<value> in the URL or they are rejected with close "
            f"code {CLOSE_CODE_INVALID_TOKEN}. Falls back to the RELAY_TOKEN "
            "env var if --token is not provided."
        ),
    )
    args = parser.parse_args(argv)

    configure_logging(args.log_level, args.log_file)
    LOG.info("relay_server starting (PID %d)", __import__("os").getpid())

    try:
        asyncio.run(serve(args))
    except KeyboardInterrupt:
        LOG.info("interrupted; shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(main())
