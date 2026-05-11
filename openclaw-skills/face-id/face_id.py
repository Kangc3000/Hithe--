#!/usr/bin/env python3
"""Real-time face identification daemon for Vision Companion (Phase 2).

Reads frames from a webcam (or single image for testing), detects faces with
InsightFace, computes 512-dim ArcFace embeddings, matches against the local
face gallery, and emits JSON Lines events on stdout.

Event contract is locked in PROJECT-SPEC.md section 5.2 and IMPLEMENTATION-GUIDE.md
section 3.2:

    {
      "event": "face_identified",
      "name_en": "Sarah",
      "name_zh": "莎拉",
      "distance_estimate_m": 1.8,
      "bearing": "ahead-left",
      "confidence": 0.78,
      "timestamp": "..."
    }

Distance is estimated via pinhole-camera geometry from the detected face
bounding box height; it is best-effort, not measurement-grade. Bearing is
derived from the face center column relative to frame center.

Local-only — no cloud calls. Face embeddings live in
~/.hermes/voice-companion/scripts/gallery/face_gallery.json and must never
be committed or transmitted.

Usage:
  face_id.py --webcam               # open default camera (cv2 device 0)
  face_id.py --webcam 1             # specific camera index
  face_id.py --image one_clip.jpg   # one-shot for testing
"""
from __future__ import annotations

import argparse
import json
import logging
import signal
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

import cv2
import numpy as np
import yaml
from insightface.app import FaceAnalysis

LOG = logging.getLogger("face_id")

DEFAULT_CONFIG = Path("~/.hermes/voice-companion/config.yaml").expanduser()
DEFAULT_GALLERY = Path(
    "~/.hermes/voice-companion/scripts/gallery/face_gallery.json"
).expanduser()
DEFAULT_MODEL_DIR = Path("~/.hermes/voice-companion/models/insightface").expanduser()
DEFAULT_STATE_DIR = Path("~/.hermes/voice-companion/state").expanduser()
ACTIVE_FLAG_NAME = "active.flag"


@dataclass
class DaemonConfig:
    face_similarity_threshold: float
    unknown_face_emit_interval_seconds: float
    target_fps: float
    detection_size: int
    camera_focal_length_px: float
    face_real_height_m: float
    classroom_mode: bool


def load_config(path: Path) -> DaemonConfig:
    with path.open("r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    return DaemonConfig(
        face_similarity_threshold=float(raw.get("face_similarity_threshold", 0.55)),
        unknown_face_emit_interval_seconds=float(
            raw.get("unknown_face_emit_interval_seconds", 30.0)
        ),
        target_fps=float(raw.get("face_target_fps", 5.0)),
        detection_size=int(raw.get("face_detection_size", 640)),
        camera_focal_length_px=float(raw.get("face_camera_focal_length_px", 600.0)),
        face_real_height_m=float(raw.get("face_real_height_m", 0.25)),
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
        LOG.warning("face gallery not found at %s; nobody is enrolled yet", path)
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
    LOG.info("face gallery loaded: %d enrolled", len(entries))
    return entries


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


_emit_callback = None


def set_emit_callback(callback) -> None:
    """Override the default stdout emitter so an embedding host can intercept
    events instead of getting them via JSON Lines on stdout. Pass None to
    restore the default."""
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


def load_model(model_dir: Path, det_size: int) -> FaceAnalysis:
    LOG.info("loading InsightFace buffalo_l (cache: %s; first run downloads ~250MB)", model_dir)
    model_dir.mkdir(parents=True, exist_ok=True)
    app = FaceAnalysis(
        name="buffalo_l",
        root=str(model_dir),
        providers=["CPUExecutionProvider"],
    )
    app.prepare(ctx_id=-1, det_size=(det_size, det_size))
    return app


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


def estimate_distance_m(cfg: DaemonConfig, bbox_height_px: float) -> float:
    if bbox_height_px <= 0:
        return 0.0
    # Pinhole camera approximation: distance = (focal_length × real_size) / pixel_size
    return float(cfg.camera_focal_length_px * cfg.face_real_height_m / bbox_height_px)


def estimate_bearing(face_center_x: float, frame_width: int) -> str:
    if frame_width <= 0:
        return "ahead"
    offset = (face_center_x - frame_width / 2.0) / (frame_width / 2.0)
    if offset < -0.30:
        return "left"
    if offset < -0.10:
        return "ahead-left"
    if offset > 0.30:
        return "right"
    if offset > 0.10:
        return "ahead-right"
    return "ahead"


def webcam_frames(device: int | str, target_fps: float, stop: threading.Event) -> Iterable[np.ndarray]:
    cap = cv2.VideoCapture(device if isinstance(device, int) else str(device))
    if not cap.isOpened():
        raise RuntimeError(f"could not open camera device {device!r}")
    period = 1.0 / max(0.5, target_fps)
    next_at = 0.0
    try:
        while not stop.is_set():
            ret, frame = cap.read()
            if not ret:
                LOG.warning("webcam read failed; backing off")
                time.sleep(0.5)
                continue
            now = time.monotonic()
            if now < next_at:
                continue
            next_at = now + period
            yield frame
    finally:
        cap.release()


class FaceIdentifier:
    def __init__(
        self,
        cfg: DaemonConfig,
        model: FaceAnalysis,
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
                "face-id",
                "active" if active else "paused",
                "hithe flag transition",
            )
            self.last_active_seen = active
        return active

    def process_frame(self, frame: np.ndarray) -> None:
        if not self._check_active():
            return
        faces = self.model.get(frame)
        if not faces:
            return
        h, w = frame.shape[:2]
        any_match = False
        for face in faces:
            emb = np.asarray(face.embedding, dtype=np.float32)
            norm = float(np.linalg.norm(emb))
            if norm == 0.0:
                continue
            emb = emb / norm
            entry, score = best_match(emb, self.gallery)
            x1, y1, x2, y2 = face.bbox
            bbox_h = float(y2 - y1)
            face_cx = float((x1 + x2) / 2.0)
            distance = estimate_distance_m(self.cfg, bbox_h)
            bearing = estimate_bearing(face_cx, w)

            if entry is not None and score >= self.cfg.face_similarity_threshold:
                any_match = True
                emit(
                    {
                        "event": "face_identified",
                        "name_en": entry.name_en,
                        "name_zh": entry.name_zh,
                        "distance_estimate_m": round(distance, 2),
                        "bearing": bearing,
                        "confidence": round(score, 4),
                        "timestamp": now_iso(),
                    }
                )

        if not any_match:
            now = time.monotonic()
            if now - self.last_unknown_emit >= self.cfg.unknown_face_emit_interval_seconds:
                # Pick the largest detected face for the unknown report.
                largest = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
                x1, y1, x2, y2 = largest.bbox
                emit(
                    {
                        "event": "unknown_face",
                        "confidence": 0.0,
                        "distance_estimate_m": round(estimate_distance_m(self.cfg, float(y2 - y1)), 2),
                        "bearing": estimate_bearing(float((x1 + x2) / 2.0), w),
                        "timestamp": now_iso(),
                    }
                )
                self.last_unknown_emit = now


def run_one_shot(
    cfg: DaemonConfig,
    model: FaceAnalysis,
    gallery: list[GalleryEntry],
    state_dir: Path,
    image_path: Path,
) -> int:
    img = cv2.imread(str(image_path))
    if img is None:
        LOG.error("could not read %s", image_path)
        return 2
    FaceIdentifier(cfg, model, gallery, state_dir).process_frame(img)
    return 0


def run_stream(
    cfg: DaemonConfig,
    model: FaceAnalysis,
    gallery: list[GalleryEntry],
    state_dir: Path,
    frames: Iterable[np.ndarray],
) -> int:
    state_dir.mkdir(parents=True, exist_ok=True)
    identifier = FaceIdentifier(cfg, model, gallery, state_dir)
    initial_active = (state_dir / ACTIVE_FLAG_NAME).exists()
    emit_status(
        "face-id",
        "active" if initial_active else "paused",
        f"gallery_size={len(gallery)}",
    )
    identifier.last_active_seen = initial_active
    for frame in frames:
        identifier.process_frame(frame)
    emit_status("face-id", "stopped", "frame stream ended")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Vision Companion face-id daemon.")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--webcam", nargs="?", const=0, type=int, help="Capture from webcam (default device 0)")
    src.add_argument("--image", type=Path, help="Process a single image then exit (for testing)")

    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--gallery", type=Path, default=DEFAULT_GALLERY)
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
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
        LOG.error("classroom_mode is true; face-id refuses to run")
        emit_status("face-id", "blocked", "classroom_mode=true")
        return 3

    gallery = load_gallery(args.gallery)
    if not gallery:
        emit_status("face-id", "warning", "face gallery empty; nothing to match against")

    try:
        model = load_model(args.model_dir, cfg.detection_size)
    except Exception as e:  # pragma: no cover - logged for ops
        LOG.exception("face model load failed")
        emit_status("face-id", "error", f"model load failed: {e}")
        return 4

    stop = threading.Event()

    def _handle_signal(signum, _frame):
        LOG.info("signal %d received; shutting down", signum)
        stop.set()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    try:
        if args.image is not None:
            return run_one_shot(cfg, model, gallery, args.state_dir, args.image)
        device = args.webcam if args.webcam is not None else 0
        return run_stream(
            cfg, model, gallery, args.state_dir, webcam_frames(device, cfg.target_fps, stop)
        )
    except Exception as e:  # pragma: no cover - daemon must not crash silently
        LOG.exception("unhandled error in face-id main loop")
        emit_status("face-id", "error", str(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
