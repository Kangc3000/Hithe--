#!/usr/bin/env python3
"""Voice enrollment CLI for Vision Companion.

Computes ECAPA-TDNN embeddings from one or more audio samples, averages them
into a single 192-dim L2-normalized vector, and writes the result to the
voice gallery (voice_gallery.json) with a consent timestamp.

Two modes:
  --record N          Record N samples of ~min_speech_seconds from the mic.
  --samples a.wav b.wav ...
                      Compute embeddings from existing audio files.

Consent is mandatory. The --consent flag must be set to "yes" or the script
refuses to write. Per PROJECT-SPEC.md section 7 (D-014), this is non-negotiable
and children's data is never enrolled even if --consent yes is passed.

Usage:
  enroll.py --name-en Sarah --name-zh 莎拉 --consent yes --record 3
  enroll.py --name-en Sarah --name-zh 莎拉 --consent yes --samples a.wav b.wav
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

import numpy as np
import sounddevice as sd
import soundfile as sf
import torch
import yaml
from speechbrain.inference.speaker import EncoderClassifier

LOG = logging.getLogger("enroll")

DEFAULT_CONFIG = Path("~/.hermes/voice-companion/config.yaml").expanduser()
DEFAULT_GALLERY = Path(
    "~/.hermes/voice-companion/scripts/gallery/voice_gallery.json"
).expanduser()

ECAPA_MODEL_SOURCE = "speechbrain/spkrec-ecapa-voxceleb"


@dataclass
class EnrollConfig:
    sample_rate: int
    min_speech_seconds: float
    max_speech_seconds: float
    silence_rms: float
    input_device: int | str | None


def load_config(path: Path) -> EnrollConfig:
    with path.open("r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    return EnrollConfig(
        sample_rate=int(raw.get("sample_rate", 16000)),
        min_speech_seconds=float(raw.get("min_speech_seconds", 2.0)),
        max_speech_seconds=float(raw.get("max_speech_seconds", 5.0)),
        silence_rms=float(raw.get("silence_rms", 0.005)),
        input_device=raw.get("input_device"),
    )


def load_model(model_dir: Path) -> EncoderClassifier:
    LOG.info("loading ECAPA-TDNN from %s (first run downloads ~80MB)", ECAPA_MODEL_SOURCE)
    return EncoderClassifier.from_hparams(
        source=ECAPA_MODEL_SOURCE,
        savedir=str(model_dir),
        run_opts={"device": "cpu"},
    )


def compute_embedding(model: EncoderClassifier, audio: np.ndarray, sample_rate: int) -> np.ndarray:
    if sample_rate != 16000:
        raise ValueError(f"ECAPA requires 16kHz; got {sample_rate}")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    audio = audio.astype(np.float32)
    tensor = torch.from_numpy(audio).unsqueeze(0)
    with torch.no_grad():
        emb = model.encode_batch(tensor).squeeze().cpu().numpy()
    return _l2_normalize(emb)


def _l2_normalize(vec: np.ndarray) -> np.ndarray:
    norm = float(np.linalg.norm(vec))
    if norm == 0.0:
        raise ValueError("zero-norm embedding (silent input?)")
    return (vec / norm).astype(np.float32)


def record_sample(cfg: EnrollConfig, duration_seconds: float, prompt: str) -> np.ndarray:
    print(prompt, file=sys.stderr)
    print(f"recording for {duration_seconds:.1f}s...", file=sys.stderr)
    audio = sd.rec(
        int(duration_seconds * cfg.sample_rate),
        samplerate=cfg.sample_rate,
        channels=1,
        dtype="float32",
        device=cfg.input_device,
    )
    sd.wait()
    audio = audio.flatten()
    rms = float(np.sqrt(np.mean(audio**2)))
    print(f"  captured {len(audio)/cfg.sample_rate:.1f}s, rms={rms:.4f}", file=sys.stderr)
    if rms < cfg.silence_rms:
        LOG.warning("sample appears mostly silent (rms=%.4f < %.4f)", rms, cfg.silence_rms)
    return audio


def load_audio_file(path: Path, target_sample_rate: int) -> np.ndarray:
    audio, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != target_sample_rate:
        raise ValueError(
            f"{path} is {sr}Hz; resample to {target_sample_rate}Hz before enrolling"
        )
    return audio


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


DEFAULT_RECORD_SAMPLES = 3


def list_gallery(gallery_path: Path) -> int:
    gallery = load_gallery(gallery_path)
    if not gallery:
        print(f"(empty gallery at {gallery_path})", file=sys.stderr)
        return 0
    print(f"Voice gallery at {gallery_path} ({len(gallery)} enrolled):", file=sys.stderr)
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
        description="Enroll a voice into the Vision Companion gallery, or list enrolled voices."
    )
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--gallery", type=Path, default=DEFAULT_GALLERY)
    parser.add_argument(
        "--model-dir",
        type=Path,
        default=Path("~/.hermes/voice-companion/models/ecapa").expanduser(),
        help="Where to cache the ECAPA model files",
    )

    parser.add_argument(
        "--list",
        action="store_true",
        help="List enrolled voices and exit. All other args ignored.",
    )

    parser.add_argument("--name-en", help="English-language name (e.g. Sarah). Required for enrollment.")
    parser.add_argument("--name-zh", help="Chinese-language name (e.g. 莎拉). Required for enrollment.")
    parser.add_argument(
        "--consent-confirmed",
        action="store_true",
        help=(
            "Required for enrollment. Verbal consent must have been recorded "
            "before this is set. Per PROJECT-SPEC.md section 7 (D-014), this "
            "is non-negotiable; children's voices are never enrolled."
        ),
    )
    parser.add_argument("--key", default=None, help="Gallery key (defaults to slug of --name-en)")
    parser.add_argument("--notes", default="", help="Free-text notes stored alongside the entry")
    parser.add_argument("--overwrite", action="store_true", help="Replace any existing entry for this key")

    parser.add_argument(
        "--record",
        nargs="?",
        const=DEFAULT_RECORD_SAMPLES,
        default=None,
        type=int,
        metavar="N",
        help=f"Record N samples from the mic (default {DEFAULT_RECORD_SAMPLES} if N is omitted)",
    )
    parser.add_argument("--samples", nargs="+", type=Path, help="One or more pre-recorded WAV files")

    parser.add_argument(
        "--sample-seconds",
        type=float,
        default=4.0,
        help="Seconds per recorded sample when using --record (default 4.0)",
    )

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
        parser.error("--consent-confirmed is required for enrollment (verbal consent must be recorded first)")
    if args.record is None and not args.samples:
        parser.error("either --record [N] or --samples FILE [FILE ...] is required")
    if args.record is not None and args.samples:
        parser.error("--record and --samples are mutually exclusive")

    cfg = load_config(args.config)
    key = args.key or slugify(args.name_en)

    gallery = load_gallery(args.gallery)
    if key in gallery and not args.overwrite:
        LOG.error("entry %r already exists; pass --overwrite to replace it", key)
        return 2

    model = load_model(args.model_dir)

    embeddings: list[np.ndarray] = []

    if args.record is not None:
        if args.record < 1:
            LOG.error("--record N must be >= 1")
            return 2
        for i in range(args.record):
            prompt = (
                f"\n[sample {i + 1}/{args.record}] please speak naturally for "
                f"about {args.sample_seconds:.0f} seconds when prompted. "
                "Press Enter to begin."
            )
            try:
                input(prompt)
            except EOFError:
                LOG.error("stdin closed; cannot prompt for samples in non-interactive mode")
                return 2
            audio = record_sample(cfg, args.sample_seconds, "starting in 1...")
            try:
                emb = compute_embedding(model, audio, cfg.sample_rate)
            except ValueError as e:
                LOG.warning("sample %d skipped: %s", i + 1, e)
                continue
            embeddings.append(emb)
    else:
        for path in args.samples or []:
            if not path.exists():
                LOG.error("sample file not found: %s", path)
                return 2
            audio = load_audio_file(path, cfg.sample_rate)
            try:
                emb = compute_embedding(model, audio, cfg.sample_rate)
            except ValueError as e:
                LOG.warning("%s skipped: %s", path, e)
                continue
            embeddings.append(emb)

    if not embeddings:
        LOG.error("no usable samples; nothing written to gallery")
        return 1

    centroid = _l2_normalize(np.mean(np.stack(embeddings), axis=0))

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
        "enrolled key=%s name_en=%s name_zh=%s samples=%d -> %s",
        key,
        args.name_en,
        args.name_zh,
        len(embeddings),
        args.gallery,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
