from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path


MODEL_CONTEXT_TOKENS = 131_072
ESTIMATED_AUDIO_TOKENS_PER_SECOND = 17.5
OUTPUT_TOKENS_PER_SECOND = 8.0
CONTEXT_MARGIN_TOKENS = 2_048
MIN_OUTPUT_TOKENS = 2_048
MAX_OUTPUT_TOKENS = 65_536


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run MOSS-Transcribe-Diarize and export app-compatible files."
    )
    parser.add_argument("input", type=Path, help="Input audio or video file.")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--model",
        default="OpenMOSS-Team/MOSS-Transcribe-Diarize",
        help="Hugging Face model id or local model path.",
    )
    parser.add_argument(
        "--device",
        choices=("auto", "cpu", "cuda"),
        default="auto",
    )
    parser.add_argument(
        "--max-new-tokens",
        type=int,
        default=0,
        help="0 chooses a duration-aware token budget.",
    )
    parser.add_argument(
        "--hotwords",
        default="",
        help="Optional comma-separated names or terms to append to the MOSS prompt.",
    )
    return parser.parse_args()


def media_duration_seconds(path: Path) -> float | None:
    try:
        import av

        with av.open(str(path)) as container:
            if container.duration is not None:
                return float(container.duration / av.time_base)

            durations = [
                float(stream.duration * stream.time_base)
                for stream in container.streams
                if stream.duration is not None and stream.time_base is not None
            ]
            return max(durations) if durations else None
    except Exception:
        return None


def automatic_token_budget(duration_seconds: float | None) -> int:
    if not duration_seconds or duration_seconds <= 0:
        return 8_192

    desired = max(
        MIN_OUTPUT_TOKENS,
        math.ceil(duration_seconds * OUTPUT_TOKENS_PER_SECOND),
    )
    available_context = math.floor(
        MODEL_CONTEXT_TOKENS
        - CONTEXT_MARGIN_TOKENS
        - duration_seconds * ESTIMATED_AUDIO_TOKENS_PER_SECOND
    )
    if available_context < 512:
        raise ValueError(
            "The media is too long for the MOSS context window. "
            "Split it into shorter files and try again."
        )

    return max(512, min(desired, available_context, MAX_OUTPUT_TOKENS))


def main() -> int:
    args = parse_args()
    input_path = args.input.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    if not input_path.is_file():
        raise FileNotFoundError(f"Input media does not exist: {input_path}")
    if not 0 <= args.max_new_tokens <= MAX_OUTPUT_TOKENS:
        raise ValueError(
            f"--max-new-tokens must be between 0 and {MAX_OUTPUT_TOKENS}."
        )

    output_dir.mkdir(parents=True, exist_ok=True)
    duration = media_duration_seconds(input_path)
    max_new_tokens = (
        args.max_new_tokens
        if args.max_new_tokens > 0
        else automatic_token_budget(duration)
    )

    print(f"MOSS model: {args.model}", flush=True)
    print(f"MOSS device: {args.device}", flush=True)
    if duration:
        print(f"Media duration: {duration:.1f} seconds", flush=True)
    print(f"MOSS max new tokens: {max_new_tokens}", flush=True)
    print("Loading MOSS model (the first run also downloads its weights)...", flush=True)

    try:
        import torch
        from transformers import AutoModelForCausalLM, AutoProcessor

        from moss_transcribe_diarize.inference_utils import (
            DEFAULT_PROMPT,
            build_transcription_messages,
            generate_transcription,
            resolve_device,
        )
        from moss_transcribe_diarize.subtitle import (
            export_json,
            export_srt,
            subtitle_segments_from_transcript,
            write_text,
        )
    except ImportError as exc:
        raise RuntimeError(
            "The MOSS runtime is not installed. Run Setup-MOSS.bat first."
        ) from exc

    device = resolve_device(args.device)
    dtype = torch.bfloat16 if device.type == "cuda" else torch.float32
    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        trust_remote_code=True,
        dtype="auto",
    ).to(dtype=dtype).to(device).eval()
    processor = AutoProcessor.from_pretrained(
        args.model,
        trust_remote_code=True,
        fix_mistral_regex=True,
    )

    prompt = DEFAULT_PROMPT
    if args.hotwords.strip():
        prompt = f"{prompt.rstrip()} 热词提示：{args.hotwords.strip()}"

    print("Transcribing with MOSS...", flush=True)
    started = time.perf_counter()
    result = generate_transcription(
        model,
        processor,
        build_transcription_messages(input_path, prompt),
        max_length=MODEL_CONTEXT_TOKENS,
        max_new_tokens=max_new_tokens,
        do_sample=False,
        device=device,
        dtype=dtype,
    )
    elapsed = time.perf_counter() - started

    segments = subtitle_segments_from_transcript(result["text"], postprocess=False)
    if not segments:
        raise RuntimeError(
            "MOSS returned no valid timestamped segments. "
            "Try a larger max-new-tokens value or a shorter media file."
        )

    stem = input_path.stem
    srt_path = write_text(
        output_dir / f"{stem}.srt",
        export_srt(segments, show_speaker=True),
        encoding="utf-8-sig",
    )
    segments_path = write_text(
        output_dir / f"{stem}.moss.json",
        export_json(segments),
    )
    metadata = {
        "engine": "MOSS",
        "model": args.model,
        "device": str(device),
        "input": str(input_path),
        "duration_seconds": duration,
        "elapsed_seconds": elapsed,
        "max_new_tokens": max_new_tokens,
        "generated_tokens": int(result["generated_tokens"]),
        "prompt_tokens": int(result["prompt_len"]),
        "segment_count": len(segments),
        "files": {
            "srt": str(srt_path),
            "segments": str(segments_path),
        },
    }
    metadata_path = output_dir / f"{stem}.moss.meta.json"
    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"MOSS segments: {len(segments)}", flush=True)
    print(f"MOSS transcription time: {elapsed:.1f} seconds", flush=True)
    print(f"MOSS source SRT: {srt_path}", flush=True)
    print(json.dumps(metadata, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("MOSS transcription cancelled.", file=sys.stderr, flush=True)
        raise SystemExit(130)
    except Exception as exc:
        print(f"MOSS transcription failed: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
