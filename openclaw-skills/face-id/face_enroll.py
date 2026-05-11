#!/usr/bin/env python3
"""Face enrollment CLI for Vision Companion (Phase 2).

Computes 512-dim ArcFace embeddings from one or more face images, averages
them into a single L2-normalized vector, and writes the result to the face
gallery (face_gallery.json) with a consent timestamp.

Two modes:
  --capture N           Capture N still frames from the webcam.
  --samples a.jpg ...   Compute embeddings from existing image files.

Consent is mandatory. The --consent-confirmed flag must be set or the script
refuses to write. Per PROJECT-SPEC.md section 7 (D-014), this is non-negotiable
and children's faces are never enrolled even with --consent-confirmed.

Usage:
  face_enroll.py --name-en Sarah --name-zh 莎拉 --consent-confirmed --capture
  face_enroll.py --name-en Sarah --name-zh 莎拉 --consent-confirmed --samples a.jpg b.jpg
  face_enroll.py --list
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

import cv2
import numpy as np
import yaml
from insightface.app import FaceAnalysis

LOG = logging.getLogger("face_enroll")

DEFAULT_CONFIG = Path("~/.hermes/voice-companion/config.yaml").expanduser()
DEFAULT_GALLERY = Path(
    "~/.hermes/voice-companion/scripts/gallery/face_gallery.json"
).expanduser()
DEFAULT_MODEL_DIR = Path("~/.hermes/voice-companion/models/insightface").expanduser()
DEFAULT_CAPTURE_SAMPLES = 3


@dataclass
class EnrollConfig:
    detection_size: int


def load_config(path: Path) -> EnrollConfig:
    with path.open("r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    return EnrollConfig(
        detection_size=int(raw.get("face_detection_size", 640)),
    )


def load_model(model_dir: Path, det_size: int) -> FaceAnalysis:
    LOG.info("loading InsightFace buffalo_l (cache: %s)", model_dir)
    model_dir.mkdir(parents=True, exist_ok=True)
    app = FaceAnalysis(
        name="buffalo_l",
        root=str(model_dir),
        providers=["CPUExecutionProvider"],
    )
    app.prepare(ctx_id=-1, det_size=(det_size, det_size))
    return app


def detect_largest_face(model: FaceAnalysis, image: np.ndarray) -> np.ndarray | None:
    faces = model.get(image)
    if not faces:
        return None
    largest = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
    emb = np.asarray(largest.embedding, dtype=np.float32)
    norm = float(np.linalg.norm(emb))
    if norm == 0.0:
        return None
    return emb / norm


def capture_from_webcam(model: FaceAnalysis, count: int, device: int) -> list[np.ndarray]:
    cap = cv2.VideoCapture(device)
    if not cap.isOpened():
        LOG.error("could not open camera device %d", device)
        return []
    embeddings: list[np.ndarray] = []
    try:
        for i in range(count):
            try:
                input(
                    f"\n[sample {i + 1}/{count}] please face the camera, "
                    "neutral expression. Press Enter to capture."
                )
            except EOFError:
                LOG.error("stdin closed; cannot prompt for samples")
                return embeddings
            # Drain a few frames so any auto-exposure/auto-focus stabilizes.
            for _ in range(5):
                cap.read()
                time.sleep(0.05)
            ret, frame = cap.read()
            if not ret:
                LOG.warning("sample %d: webcam read failed; skipping", i + 1)
                continue
            emb = detect_largest_face(model, frame)
            if emb is None:
                LOG.warning("sample %d: no usable face detected; skipping", i + 1)
                continue
            embeddings.append(emb)
            print(f"  captured sample {i + 1}", file=sys.stderr)
    finally:
        cap.release()
    return embeddings


def load_image(path: Path) -> np.ndarray:
    img = cv2.imread(str(path))
    if img is None:
        raise ValueError(f"could not read image: {path}")
    return img


def load_gallery(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_gallery(path: Path, gallery: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(gallery, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


def slugify(name: str) -> str:
    slug = "".join(c.lower() if c.isalnum() else "_" for c in name).strip("_")
    return slug or "person"


def list_gallery(path: Path) -> int:
    gallery = load_gallery(path)
    if not gallery:
        print(f"(empty face gallery at {path})", file=sys.stderr)
        return 0
    print(f"Face gallery at {path} ({len(gallery)} enrolled):", file=sys.stderr)
    print("", file=sys.stderr)
    print(f"{'KEY':<20} {'NAME_EN':<20} {'NAME_ZH':<10} {'SAMPLES':<8} {'ENROLLED_ON':<22} NOTES")
    print("-" * 100)
    for key, entry in sorted(gallery.items()):
        print(
            f"{key:<20} "
            f"{entry.get('name_en', ''):<20} "
            f"{entry.get('name_zh', ''):<10} "
            f"{entry.get('sample_count', 0):<8} "
            f"{entry.get('enrolled_on', ''):<22} "
            f"{entry.get('notes', '')}"
        )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Enroll a face into the Vision Companion gallery, or list enrolled faces."
    )
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--gallery", type=Path, default=DEFAULT_GALLERY)
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)

    parser.add_argument(
        "--list",
        action="store_true",
        help="List enrolled faces and exit. All other args ignored.",
    )

    parser.add_argument("--name-en", help="English-language name. Required for enrollment.")
    parser.add_argument("--name-zh", help="Chinese-language name. Required for enrollment.")
    parser.add_argument(
        "--consent-confirmed",
        action="store_true",
        help=(
            "Required for enrollment. Verbal consent must have been recorded "
            "before this is set. Children's faces are never enrolled regardless."
        ),
    )
    parser.add_argument("--key", default=None, help="Gallery key (defaults to slug of --name-en)")
    parser.add_argument("--notes", default="", help="Free-text notes stored alongside the entry")
    parser.add_argument("--overwrite", action="store_true", help="Replace any existing entry for this key")

    parser.add_argument(
        "--capture",
        nargs="?",
        const=DEFAULT_CAPTURE_SAMPLES,
        default=None,
        type=int,
        metavar="N",
        help=f"Capture N still frames from the webcam (default {DEFAULT_CAPTURE_SAMPLES} if N is omitted)",
    )
    parser.add_argument("--camera", type=int, default=0, help="Webcam device index (default 0)")
    parser.add_argument("--samples", nargs="+", type=Path, help="One or more image files (jpg/png)")

    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="[%(levelname)s] %(name)s: %(message)s",
        stream=sys.stderr,
    )

    if args.list:
        return list_gallery(args.gallery)

    if not args.name_en or not args.name_zh:
        parser.error("--name-en and --name-zh are required for enrollment")
    if not args.consent_confirmed:
        parser.error("--consent-confirmed is required for enrollment")
    if args.capture is None and not args.samples:
        parser.error("either --capture [N] or --samples FILE [FILE ...] is required")
    if args.capture is not None and args.samples:
        parser.error("--capture and --samples are mutually exclusive")

    cfg = load_config(args.config)
    key = args.key or slugify(args.name_en)
    gallery = load_gallery(args.gallery)
    if key in gallery and not args.overwrite:
        LOG.error("entry %r already exists; pass --overwrite to replace it", key)
        return 2

    model = load_model(args.model_dir, cfg.detection_size)

    embeddings: list[np.ndarray] = []

    if args.capture is not None:
        if args.capture < 1:
            LOG.error("--capture N must be >= 1")
            return 2
        embeddings = capture_from_webcam(model, args.capture, args.camera)
    else:
        for path in args.samples or []:
            if not path.exists():
                LOG.error("sample file not found: %s", path)
                return 2
            try:
                img = load_image(path)
            except ValueError as e:
                LOG.error("%s", e)
                return 2
            emb = detect_largest_face(model, img)
            if emb is None:
                LOG.warning("%s: no usable face; skipping", path)
                continue
            embeddings.append(emb)

    if not embeddings:
        LOG.error("no usable samples; nothing written to gallery")
        return 1

    centroid = np.mean(np.stack(embeddings), axis=0)
    norm = float(np.linalg.norm(centroid))
    if norm == 0.0:
        LOG.error("zero-norm centroid; refusing to enroll")
        return 1
    centroid = (centroid / norm).astype(np.float32)

    gallery[key] = {
        "name_en": args.name_en,
        "name_zh": args.name_zh,
        "embedding": centroid.tolist(),
        "enrolled_on": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "consent_recorded": True,
        "sample_count": len(embeddings),
        "notes": args.notes,
    }
    save_gallery(args.gallery, gallery)

    LOG.info(
        "enrolled face key=%s name_en=%s name_zh=%s samples=%d -> %s",
        key,
        args.name_en,
        args.name_zh,
        len(embeddings),
        args.gallery,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
