#!/usr/bin/env python3
"""ElevenLabs Scribe v2 adapter for the Transcribe & Translate app."""

from __future__ import annotations

import argparse
import http.client
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any


API_HOST = "api.elevenlabs.io"
API_PATH = "/v1/speech-to-text"


def configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8", errors="replace")


def log(message: str) -> None:
    print(message, flush=True)


def format_srt_time(seconds: float) -> str:
    milliseconds = max(0, round(float(seconds) * 1000))
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    secs, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{milliseconds:03d}"


def speaker_label(speaker_id: str | None) -> str:
    if not speaker_id:
        return "S01"
    match = re.search(r"(\d+)$", speaker_id)
    if match:
        return f"S{int(match.group(1)) + 1:02d}"
    clean = re.sub(r"[^A-Za-z0-9_-]+", "", speaker_id)
    return clean or "S01"


def append_token(text: str, token: str) -> str:
    token = token.strip()
    if not token:
        return text
    if not text:
        return token
    if re.match(r"^[,.;:!?%)\]}]", token):
        return text + token
    if text.endswith(("(", "[", "{", "—", "-")):
        return text + token
    return text + " " + token


def timed_words(payload: dict[str, Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for item in payload.get("words") or []:
        if item.get("type") != "word":
            continue
        start = item.get("start")
        end = item.get("end")
        text = str(item.get("text") or "").strip()
        if start is None or end is None or not text:
            continue
        result.append(
            {
                "text": text,
                "start": float(start),
                "end": float(end),
                "speaker": speaker_label(item.get("speaker_id")),
            }
        )
    return result


def make_cues(
    words: list[dict[str, Any]],
    *,
    max_chars: int = 84,
    max_duration: float = 7.0,
    max_gap: float = 1.2,
) -> list[dict[str, Any]]:
    cues: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None

    def flush() -> None:
        nonlocal current
        if current and current["text"].strip():
            current["text"] = current["text"].strip()
            current["end"] = max(current["end"], current["start"] + 0.25)
            cues.append(current)
        current = None

    for word in words:
        if current is None:
            current = {
                "start": word["start"],
                "end": word["end"],
                "speaker": word["speaker"],
                "text": word["text"],
            }
            continue

        proposed = append_token(current["text"], word["text"])
        speaker_changed = word["speaker"] != current["speaker"]
        too_long = len(proposed) > max_chars
        too_slow = word["end"] - current["start"] > max_duration
        large_gap = word["start"] - current["end"] > max_gap
        sentence_done = (
            len(current["text"]) >= 36
            and re.search(r"[.!?…][\"')\]]?$", current["text"]) is not None
            and word["start"] - current["end"] >= 0.18
        )
        if speaker_changed or too_long or too_slow or large_gap or sentence_done:
            flush()
            current = {
                "start": word["start"],
                "end": word["end"],
                "speaker": word["speaker"],
                "text": word["text"],
            }
        else:
            current["text"] = proposed
            current["end"] = word["end"]

    flush()
    return cues


def write_outputs(
    payload: dict[str, Any],
    output_dir: Path,
    stem: str,
    show_speakers: bool,
    save_json: bool = False,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    words = timed_words(payload)
    if not words:
        raise RuntimeError("The ElevenLabs response did not contain timed words.")

    cues = make_cues(words)
    srt_blocks = []

    for index, cue in enumerate(cues, 1):
        label = cue["speaker"]
        text = cue["text"]
        cue_text = f"{label}: {text}" if show_speakers else text
        srt_blocks.append(
            f"{index}\n"
            f"{format_srt_time(cue['start'])} --> {format_srt_time(cue['end'])}\n"
            f"{cue_text}"
        )

    (output_dir / f"{stem}.srt").write_text(
        "\n\n".join(srt_blocks) + "\n", encoding="utf-8-sig"
    )
    if save_json:
        (output_dir / f"{stem}.elevenlabs.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )

    log(f"ElevenLabs language: {payload.get('language_code', 'unknown')}")
    log(f"ElevenLabs speakers: {len({word['speaker'] for word in words})}")
    log(f"ElevenLabs cues: {len(cues)}")
    log(f"SRT: {output_dir / f'{stem}.srt'}")
    if save_json:
        log(f"JSON: {output_dir / f'{stem}.elevenlabs.json'}")


def find_ffprobe(ffmpeg: str) -> str | None:
    ffmpeg_path = Path(ffmpeg)
    executable_name = "ffprobe.exe" if os.name == "nt" else "ffprobe"
    if ffmpeg_path.parent != Path("."):
        candidate = ffmpeg_path.with_name(executable_name)
        if candidate.is_file():
            return str(candidate)
    return shutil.which(executable_name)


def select_audio_stream(media: Path, ffmpeg: str, requested_track: int) -> tuple[str, str]:
    ffprobe = find_ffprobe(ffmpeg)
    streams: list[dict[str, Any]] = []
    if ffprobe:
        completed = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-select_streams",
                "a",
                "-show_entries",
                "stream=index:stream_tags=language,title",
                "-of",
                "json",
                str(media),
            ],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if completed.returncode == 0:
            try:
                streams = json.loads(completed.stdout).get("streams", [])
            except (json.JSONDecodeError, AttributeError):
                streams = []

    if streams:
        if requested_track > len(streams):
            raise ValueError(
                f"Audio Track {requested_track} was requested, but the media has only "
                f"{len(streams)} audio track(s)."
            )
        selected_ordinal = requested_track - 1 if requested_track > 0 else 0
        if requested_track == 0:
            english_codes = {"en", "eng", "english"}
            for ordinal, stream in enumerate(streams):
                language = str(stream.get("tags", {}).get("language", "")).lower()
                if language.split("-", 1)[0] in english_codes:
                    selected_ordinal = ordinal
                    break

        selected = streams[selected_ordinal]
        tags = selected.get("tags", {})
        language = str(tags.get("language", "unknown"))
        title = str(tags.get("title", "")).strip()
        details = f", {language}" + (f", {title}" if title else "")
        mode = "Auto selected" if requested_track == 0 else "Selected"
        return f"0:{int(selected['index'])}", f"{mode} Track {selected_ordinal + 1}{details}"

    selected_ordinal = max(0, requested_track - 1)
    mode = "Auto selected" if requested_track == 0 else "Selected"
    return f"0:a:{selected_ordinal}", f"{mode} Track {selected_ordinal + 1} (metadata unavailable)"


def prepare_audio(media: Path, ffmpeg: str, temp_dir: Path, audio_track: int) -> Path:
    output = temp_dir / "elevenlabs-upload.mp3"
    stream_map, selection_message = select_audio_stream(media, ffmpeg, audio_track)
    log(f"Audio track: {selection_message}")
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(media),
        "-map",
        stream_map,
        "-vn",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-b:a",
        "64k",
        str(output),
    ]
    log("Preparing a compact mono audio upload with FFmpeg...")
    completed = subprocess.run(command, check=False)
    if completed.returncode != 0 or not output.exists():
        raise RuntimeError(f"FFmpeg audio preparation failed with exit code {completed.returncode}.")
    log(f"Upload audio size: {output.stat().st_size / (1024 * 1024):.1f} MB")
    return output


def multipart_parts(
    audio: Path,
    model: str,
    language_code: str,
    num_speakers: int,
) -> tuple[bytes, bytes, str]:
    boundary = "----CodexElevenLabs" + uuid.uuid4().hex
    fields = {
        "model_id": model,
        "diarize": "true",
        "tag_audio_events": "false",
        "timestamps_granularity": "word",
    }
    if language_code:
        fields["language_code"] = language_code
    if num_speakers > 0:
        fields["num_speakers"] = str(num_speakers)

    chunks: list[bytes] = []
    for name, value in fields.items():
        chunks.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n"
            ).encode("utf-8")
        )

    content_type = mimetypes.guess_type(audio.name)[0] or "audio/mpeg"
    chunks.append(
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{audio.name}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode("utf-8")
    )
    prefix = b"".join(chunks)
    suffix = f"\r\n--{boundary}--\r\n".encode("ascii")
    return prefix, suffix, boundary


def transcribe(
    audio: Path,
    api_key: str,
    model: str,
    language_code: str,
    num_speakers: int,
) -> dict[str, Any]:
    prefix, suffix, boundary = multipart_parts(audio, model, language_code, num_speakers)
    content_length = len(prefix) + audio.stat().st_size + len(suffix)

    connection = http.client.HTTPSConnection(API_HOST, timeout=3600)
    connection.putrequest("POST", API_PATH)
    connection.putheader("xi-api-key", api_key)
    connection.putheader("Content-Type", f"multipart/form-data; boundary={boundary}")
    connection.putheader("Content-Length", str(content_length))
    connection.endheaders()
    connection.send(prefix)
    with audio.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            connection.send(chunk)
    connection.send(suffix)

    log("Audio uploaded. Waiting for ElevenLabs Scribe v2...")
    response = connection.getresponse()
    body = response.read()
    connection.close()

    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError(
            f"ElevenLabs returned HTTP {response.status} with an unreadable response."
        ) from exc

    if not 200 <= response.status < 300:
        detail = payload.get("detail", payload)
        if isinstance(detail, (dict, list)):
            detail = json.dumps(detail, ensure_ascii=False)
        raise RuntimeError(f"ElevenLabs API error HTTP {response.status}: {detail}")
    return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("media")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--model", default="scribe_v2")
    parser.add_argument("--language-code", default="")
    parser.add_argument("--num-speakers", type=int, default=0)
    parser.add_argument(
        "--audio-track",
        type=int,
        default=0,
        help="1-based audio track number; 0 automatically prefers an English track.",
    )
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--hide-speakers", action="store_true")
    parser.add_argument("--save-json", action="store_true")
    return parser.parse_args()


def main() -> int:
    configure_stdio()
    args = parse_args()
    media = Path(args.media).resolve()
    output_dir = Path(args.output_dir).resolve()
    api_key = os.environ.get("ELEVENLABS_API_KEY", "").strip()

    if not media.is_file():
        raise FileNotFoundError(f"Input media was not found: {media}")
    if not api_key:
        raise RuntimeError("ELEVENLABS_API_KEY is not set.")
    if len(api_key) < 20 or any(character.isspace() for character in api_key):
        raise RuntimeError(
            "ELEVENLABS_API_KEY is invalid. Paste only the key value, without spaces."
        )
    try:
        api_key.encode("ascii")
    except UnicodeEncodeError as exc:
        raise RuntimeError(
            "ELEVENLABS_API_KEY contains non-ASCII text. Paste only the key value "
            "from the ElevenLabs API Keys page."
        ) from exc
    if not 0 <= args.num_speakers <= 32:
        raise ValueError("--num-speakers must be between 0 and 32.")
    if not 0 <= args.audio_track <= 32:
        raise ValueError("--audio-track must be between 0 (Auto) and 32.")

    log(f"ElevenLabs model: {args.model}")
    log(f"Source language: {args.language_code or 'automatic detection'}")
    log(f"Expected speakers: {args.num_speakers or 'automatic detection'}")

    with tempfile.TemporaryDirectory(prefix="elevenlabs-scribe-") as temp_name:
        prepared = prepare_audio(media, args.ffmpeg, Path(temp_name), args.audio_track)
        payload = transcribe(
            prepared,
            api_key,
            args.model,
            args.language_code,
            args.num_speakers,
        )
        write_outputs(
            payload,
            output_dir,
            media.stem,
            show_speakers=not args.hide_speakers,
            save_json=args.save_json,
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
