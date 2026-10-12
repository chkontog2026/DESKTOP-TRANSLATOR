#!/usr/bin/env python3
"""ElevenLabs Dubbing adapter for the Transcribe & Translate app."""

from __future__ import annotations

import argparse
import bisect
import http.client
import json
import math
import mimetypes
import os
import re
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import quote


API_HOST = "api.elevenlabs.io"
CREATE_PATH = "/v1/dubbing"


def configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8", errors="replace")


def log(message: str) -> None:
    print(message, flush=True)


def error_detail(payload: Any) -> str:
    if isinstance(payload, dict):
        detail = payload.get("detail", payload.get("error", payload))
    else:
        detail = payload
    if isinstance(detail, (dict, list)):
        return json.dumps(detail, ensure_ascii=False)
    return str(detail)


def decode_json(body: bytes, status: int, operation: str) -> Any:
    try:
        return json.loads(body.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        preview = body[:300].decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"ElevenLabs {operation} returned HTTP {status} with an unreadable "
            f"response: {preview or '<empty>'}"
        ) from exc


def request_json(method: str, path: str, api_key: str) -> tuple[int, Any]:
    connection = http.client.HTTPSConnection(API_HOST, timeout=120)
    try:
        connection.request(
            method,
            path,
            headers={
                "xi-api-key": api_key,
                "Accept": "application/json",
            },
        )
        response = connection.getresponse()
        body = response.read()
        payload = decode_json(body, response.status, path)
        return response.status, payload
    finally:
        connection.close()


def multipart_parts(
    media: Path,
    *,
    project_name: str,
    source_language: str,
    target_language: str,
    num_speakers: int,
) -> tuple[bytes, bytes, str]:
    boundary = "----CodexElevenLabsDubbing" + uuid.uuid4().hex
    fields = {
        "name": project_name,
        "source_lang": source_language or "auto",
        "target_lang": target_language,
        "num_speakers": str(num_speakers),
        "mode": "automatic",
        "dubbing_studio": "false",
        "watermark": "true",
    }

    chunks: list[bytes] = []
    for name, value in fields.items():
        chunks.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n"
            ).encode("utf-8")
        )

    filename = media.name.replace('"', "_").replace("\r", "_").replace("\n", "_")
    content_type = mimetypes.guess_type(media.name)[0] or "application/octet-stream"
    chunks.append(
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode("utf-8")
    )
    prefix = b"".join(chunks)
    suffix = f"\r\n--{boundary}--\r\n".encode("ascii")
    return prefix, suffix, boundary


def create_dubbing(
    media: Path,
    api_key: str,
    *,
    project_name: str,
    source_language: str,
    target_language: str,
    num_speakers: int,
) -> dict[str, Any]:
    prefix, suffix, boundary = multipart_parts(
        media,
        project_name=project_name,
        source_language=source_language,
        target_language=target_language,
        num_speakers=num_speakers,
    )
    content_length = len(prefix) + media.stat().st_size + len(suffix)

    connection = http.client.HTTPSConnection(API_HOST, timeout=3600)
    try:
        connection.putrequest("POST", CREATE_PATH)
        connection.putheader("xi-api-key", api_key)
        connection.putheader("Accept", "application/json")
        connection.putheader("Content-Type", f"multipart/form-data; boundary={boundary}")
        connection.putheader("Content-Length", str(content_length))
        connection.endheaders()
        connection.send(prefix)
        with media.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                connection.send(chunk)
        connection.send(suffix)

        log("Media uploaded. Waiting for ElevenLabs to create the dubbing job...")
        response = connection.getresponse()
        body = response.read()
        payload = decode_json(body, response.status, "dubbing creation")
        if not 200 <= response.status < 300:
            raise RuntimeError(
                f"ElevenLabs dubbing API error HTTP {response.status}: "
                f"{error_detail(payload)}"
            )
        if not isinstance(payload, dict) or not payload.get("dubbing_id"):
            raise RuntimeError("ElevenLabs did not return a dubbing_id.")
        return payload
    finally:
        connection.close()


def wait_for_dubbing(
    dubbing_id: str,
    api_key: str,
    *,
    poll_interval: float,
    timeout_seconds: float,
) -> dict[str, Any]:
    path = f"/v1/dubbing/{quote(dubbing_id, safe='')}"
    deadline = time.monotonic() + timeout_seconds
    previous_status = ""

    while True:
        status_code, payload = request_json("GET", path, api_key)
        if not 200 <= status_code < 300:
            raise RuntimeError(
                f"ElevenLabs dubbing status error HTTP {status_code}: "
                f"{error_detail(payload)}"
            )
        if not isinstance(payload, dict):
            raise RuntimeError("ElevenLabs returned an invalid dubbing status response.")

        status = str(payload.get("status") or "unknown").lower()
        if status != previous_status:
            log(f"Dubbing status: {status}")
            previous_status = status
        if status == "dubbed":
            return payload
        if status == "failed":
            raise RuntimeError(
                f"ElevenLabs dubbing failed: {error_detail(payload.get('error') or payload)}"
            )
        if time.monotonic() >= deadline:
            raise TimeoutError(
                f"ElevenLabs dubbing did not finish within {timeout_seconds / 60:.0f} minutes. "
                f"Dubbing ID: {dubbing_id}"
            )
        time.sleep(poll_interval)


def retrieve_srt(
    dubbing_id: str,
    target_language: str,
    api_key: str,
    *,
    attempts: int = 12,
    retry_interval: float = 5.0,
) -> str:
    path = (
        f"/v1/dubbing/{quote(dubbing_id, safe='')}/transcripts/"
        f"{quote(target_language, safe='')}/format/srt"
    )
    last_error = ""
    for attempt in range(1, attempts + 1):
        status_code, payload = request_json("GET", path, api_key)
        if 200 <= status_code < 300:
            if isinstance(payload, dict):
                srt = payload.get("srt")
            elif isinstance(payload, str):
                srt = payload
            else:
                srt = None
            if isinstance(srt, str) and srt.strip():
                srt = srt.lstrip("\ufeff").strip() + "\n"
                if not re.search(
                    r"(?m)^\d+\s*\r?\n\d{2}:\d{2}:\d{2}[,.]\d{3}\s+-->\s+"
                    r"\d{2}:\d{2}:\d{2}[,.]\d{3}",
                    srt,
                ):
                    raise RuntimeError("ElevenLabs returned text that is not valid SRT.")
                return srt
            last_error = "the response did not contain a non-empty SRT"
        else:
            last_error = f"HTTP {status_code}: {error_detail(payload)}"
            if status_code not in {404, 409, 422}:
                raise RuntimeError(f"ElevenLabs transcript error {last_error}")

        if attempt < attempts:
            if attempt == 1:
                log("The translated transcript is not ready yet; retrying...")
            time.sleep(retry_interval)

    raise RuntimeError(
        f"ElevenLabs transcript was unavailable after {attempts} attempts: {last_error}"
    )


def retrieve_transcript_json(
    dubbing_id: str,
    target_language: str,
    api_key: str,
    *,
    attempts: int = 12,
    retry_interval: float = 5.0,
) -> dict[str, Any]:
    path = (
        f"/v1/dubbing/{quote(dubbing_id, safe='')}/transcripts/"
        f"{quote(target_language, safe='')}/format/json"
    )
    last_error = ""
    for attempt in range(1, attempts + 1):
        status_code, payload = request_json("GET", path, api_key)
        if 200 <= status_code < 300:
            transcript = payload.get("json") if isinstance(payload, dict) else None
            if isinstance(transcript, dict) and isinstance(
                transcript.get("utterances"), list
            ):
                return transcript
            last_error = "the response did not contain a JSON transcript"
        else:
            last_error = f"HTTP {status_code}: {error_detail(payload)}"
            if status_code not in {404, 409, 422}:
                raise RuntimeError(f"ElevenLabs JSON transcript error {last_error}")

        if attempt < attempts:
            if attempt == 1:
                log("The translated JSON transcript is not ready yet; retrying...")
            time.sleep(retry_interval)

    raise RuntimeError(
        f"ElevenLabs JSON transcript was unavailable after {attempts} attempts: "
        f"{last_error}"
    )


SRT_TIME_PATTERN = re.compile(
    r"^(?P<start>\d{2}:\d{2}:\d{2}[,.]\d{3})\s+-->\s+"
    r"(?P<end>\d{2}:\d{2}:\d{2}[,.]\d{3})$"
)
SPEAKER_PATTERN = re.compile(
    r"(?im)^\s*(?:\[?(S\d{1,3})\]?|speaker\s*(\d+))\s*:"
)


def parse_srt_time(value: str) -> float:
    hours, minutes, seconds_part = value.replace(".", ",").split(":")
    seconds, milliseconds = seconds_part.split(",")
    return (
        int(hours) * 3600
        + int(minutes) * 60
        + int(seconds)
        + int(milliseconds) / 1000
    )


def format_srt_time(seconds: float) -> str:
    milliseconds = max(0, round(seconds * 1000))
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    secs, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{milliseconds:03d}"


def parse_srt(srt: str) -> list[dict[str, Any]]:
    cues: list[dict[str, Any]] = []
    for block in re.split(r"\r?\n\s*\r?\n", srt.lstrip("\ufeff").strip()):
        lines = block.splitlines()
        if len(lines) < 3:
            continue
        time_match = SRT_TIME_PATTERN.match(lines[1].strip())
        if not time_match:
            continue
        start = parse_srt_time(time_match.group("start"))
        end = parse_srt_time(time_match.group("end"))
        text = " ".join(line.strip() for line in lines[2:] if line.strip())
        if end <= start or not text:
            continue
        cues.append(
            {
                "start": start,
                "end": end,
                "text": text,
            }
        )

    cues.sort(key=lambda cue: (cue["start"], cue["end"]))
    if not cues:
        raise RuntimeError("The source SRT did not contain any valid cues.")
    for previous, current in zip(cues, cues[1:]):
        if current["start"] < previous["start"]:
            raise RuntimeError("The source SRT timestamps are not chronological.")
    return cues


def source_speaker_count(cues: list[dict[str, Any]]) -> int:
    speakers: set[str] = set()
    for cue in cues:
        for match in SPEAKER_PATTERN.finditer(cue["text"]):
            speakers.add((match.group(1) or f"speaker_{match.group(2)}").lower())
    return len(speakers) if speakers else 1


def source_word_weight(text: str) -> int:
    text = SPEAKER_PATTERN.sub("", text)
    return max(1, len(re.findall(r"\w+(?:['’]\w+)?", text, flags=re.UNICODE)))


def utterance_parts(
    utterance: dict[str, Any],
) -> list[tuple[float, float, int, str]]:
    timed_parts: list[tuple[float, float, int, str]] = []
    for position, word in enumerate(utterance.get("words") or []):
        text = str(word.get("text") or "")
        if not text:
            text = "".join(
                str(character.get("text") or "")
                for character in (word.get("characters") or [])
            )
        if not text:
            continue
        start = word.get("start_s")
        end = word.get("end_s")
        if start is None or end is None:
            characters = word.get("characters") or []
            starts = [
                float(character["start_s"])
                for character in characters
                if character.get("start_s") is not None
            ]
            ends = [
                float(character["end_s"])
                for character in characters
                if character.get("end_s") is not None
            ]
            start = min(starts) if starts else utterance.get("start_s", 0)
            end = max(ends) if ends else utterance.get("end_s", start)
        timed_parts.append((float(start), float(end), position, text))

    timed_parts.sort(key=lambda item: (item[0], item[1], item[2]))
    return timed_parts


def utterance_text(utterance: dict[str, Any]) -> str:
    timed_parts = utterance_parts(utterance)
    text = (
        "".join(item[3] for item in timed_parts)
        if timed_parts
        else str(utterance.get("text") or "")
    )
    return normalize_subtitle_text(text)


def normalize_subtitle_text(text: str) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s+([,.;:!?%»”’])", r"\1", text)
    text = re.sub(r"([«“])\s+", r"\1", text)
    return text


def dominant_speaker(
    utterances: list[dict[str, Any]],
) -> tuple[str | None, dict[str, int]]:
    counts: dict[str, int] = {}
    for utterance in utterances:
        speaker = str(utterance.get("speaker_id") or "unknown")
        count = sum(
            1
            for word in (utterance.get("words") or [])
            if str(word.get("word_type") or "").lower() == "word"
            and str(word.get("text") or "").strip()
        )
        if count == 0:
            count = len(re.findall(r"\w+", str(utterance.get("text") or "")))
        counts[speaker] = counts.get(speaker, 0) + count
    if not counts:
        return None, counts
    return max(counts, key=counts.get), counts


def allocate_words(words: list[str], weights: list[float]) -> list[list[str]]:
    if not weights:
        return []
    if len(weights) == 1:
        return [words]
    if not words:
        return [[] for _ in weights]

    total_weight = sum(weights)
    boundaries: list[int] = []
    previous = 0
    cumulative = 0.0
    for index, weight in enumerate(weights):
        cumulative += weight
        if index == len(weights) - 1:
            boundary = len(words)
        else:
            boundary = round(len(words) * cumulative / total_weight)
            remaining_groups = len(weights) - index - 1
            if len(words) >= len(weights):
                boundary = max(previous + 1, boundary)
                boundary = min(boundary, len(words) - remaining_groups)
            else:
                boundary = max(previous, min(boundary, len(words)))
        if index < len(weights) - 1:
            minimum = previous + (1 if len(words) >= len(weights) else 0)
            maximum = len(words) - (
                len(weights) - index - 1 if len(words) >= len(weights) else 0
            )
            window = max(2, min(6, len(words) // 6))
            candidates = range(
                max(minimum, boundary - window),
                min(maximum, boundary + window) + 1,
            )

            def boundary_score(candidate: int) -> tuple[float, int]:
                previous_word = words[candidate - 1] if candidate > 0 else ""
                next_word = words[candidate] if candidate < len(words) else ""
                punctuation_bonus = 0.0
                if re.search(r"[.!?…][\"'”’)\]]*$", previous_word):
                    punctuation_bonus = 4.0
                elif re.search(r"[;:][\"'”’)\]]*$", previous_word):
                    punctuation_bonus = 2.5
                elif re.search(r",[\”’\"')\]]*$", previous_word):
                    punctuation_bonus = 1.5
                dangling_penalty = (
                    3.0
                    if re.sub(r"[^\wάέήίόύώϊΐϋΰ]+$", "", previous_word.lower())
                    in {
                        "να",
                        "θα",
                        "και",
                        "για",
                        "με",
                        "σε",
                        "από",
                        "που",
                        "το",
                        "τη",
                        "την",
                        "τον",
                        "του",
                        "της",
                        "των",
                        "ο",
                        "η",
                        "οι",
                        "τα",
                    }
                    else 0.0
                )
                leading_punctuation_penalty = (
                    2.0 if re.match(r"^[,.;:!?%)\]}»”’]", next_word) else 0.0
                )
                return (
                    abs(candidate - boundary)
                    + dangling_penalty
                    + leading_punctuation_penalty
                    - punctuation_bonus,
                    candidate,
                )

            boundary = min(candidates, key=boundary_score)
            boundaries.append(boundary)
        previous = boundary

    allocations: list[list[str]] = []
    previous = 0
    for boundary in boundaries + [len(words)]:
        allocations.append(words[previous:boundary])
        previous = boundary
    return allocations


def closest_source_cue(
    source_cues: list[dict[str, Any]],
    candidate_indices: list[int],
    timestamp: float,
) -> int:
    for cue_index in candidate_indices:
        cue = source_cues[cue_index]
        if float(cue["start"]) <= timestamp <= float(cue["end"]):
            return cue_index

    def distance(cue_index: int) -> tuple[float, int]:
        cue = source_cues[cue_index]
        start = float(cue["start"])
        end = float(cue["end"])
        return (min(abs(timestamp - start), abs(timestamp - end)), cue_index)

    return min(candidate_indices, key=distance)


def align_translation_to_source_srt(
    source_srt: str,
    transcript: dict[str, Any],
) -> tuple[str, dict[str, Any]]:
    source_cues = parse_srt(source_srt)
    utterances = [
        utterance
        for utterance in (transcript.get("utterances") or [])
        if isinstance(utterance, dict)
        and utterance.get("start_s") is not None
        and utterance.get("end_s") is not None
        and (
            str(utterance.get("text") or "").strip()
            or bool(utterance.get("words"))
        )
    ]
    utterances.sort(
        key=lambda utterance: (
            float(utterance["start_s"]),
            float(utterance["end_s"]),
        )
    )
    if not utterances:
        raise RuntimeError("The translated JSON transcript contained no utterances.")

    speaker_count = source_speaker_count(source_cues)
    main_speaker, speaker_word_counts = dominant_speaker(utterances)
    main_speaker_words = (
        speaker_word_counts.get(main_speaker, 0) if main_speaker is not None else 0
    )
    secondary_speaker_words = sum(speaker_word_counts.values()) - main_speaker_words
    secondary_word_limit = max(2, math.ceil(main_speaker_words * 0.03))
    filter_short_adlibs = (
        speaker_count <= 1
        and main_speaker is not None
        and secondary_speaker_words <= secondary_word_limit
    )
    if filter_short_adlibs:
        selected_utterances = [
            utterance
            for utterance in utterances
            if str(utterance.get("speaker_id") or "unknown") == main_speaker
        ]
    else:
        selected_utterances = utterances

    cue_fragments: list[list[tuple[float, int, str]]] = [
        [] for _ in source_cues
    ]
    cue_starts = [float(cue["start"]) for cue in source_cues]
    word_timed_utterances = 0
    proportionally_aligned_utterances = 0

    for utterance_position, utterance in enumerate(selected_utterances):
        start = float(utterance["start_s"])
        end = max(start + 0.001, float(utterance["end_s"]))

        candidates: list[int] = []
        overlap_candidates: list[int] = []
        weights: list[float] = []
        for cue_index, cue in enumerate(source_cues):
            overlap = max(
                0.0,
                min(end, float(cue["end"])) - max(start, float(cue["start"])),
            )
            if overlap <= 0:
                continue
            overlap_candidates.append(cue_index)
            cue_duration = float(cue["end"]) - float(cue["start"])
            overlap_fraction = overlap / cue_duration
            if overlap_fraction < 0.10:
                continue
            candidates.append(cue_index)
            weights.append(
                source_word_weight(str(cue["text"])) * overlap_fraction
            )

        timed_parts = utterance_parts(utterance)
        if timed_parts and overlap_candidates:
            candidates = overlap_candidates

        if not candidates:
            midpoint = (start + end) / 2
            insertion = bisect.bisect_right(cue_starts, midpoint) - 1
            insertion = max(0, min(insertion, len(source_cues) - 1))
            candidates = [insertion]
            weights = [1.0]

        if timed_parts:
            word_timed_utterances += 1
            for part_position, (part_start, part_end, _, part_text) in enumerate(
                timed_parts
            ):
                midpoint = (part_start + part_end) / 2
                cue_index = closest_source_cue(
                    source_cues,
                    candidates,
                    midpoint,
                )
                cue_fragments[cue_index].append(
                    (
                        midpoint,
                        utterance_position * 1_000_000 + part_position,
                        part_text,
                    )
                )
            continue

        text = utterance_text(utterance)
        words = re.findall(r"\S+", text)
        if not words:
            continue
        proportionally_aligned_utterances += 1
        for cue_index, word_group in zip(
            candidates,
            allocate_words(words, weights),
        ):
            fragment = normalize_subtitle_text(" ".join(word_group))
            if fragment:
                cue_fragments[cue_index].append(
                    (start, utterance_position, fragment)
                )

    aligned_texts: list[str] = []
    for fragments in cue_fragments:
        fragments.sort(key=lambda item: (item[0], item[1]))
        aligned_texts.append(
            normalize_subtitle_text(" ".join(fragment for _, _, fragment in fragments))
        )

    empty_indices = [
        index for index, text in enumerate(aligned_texts) if not text
    ]
    if len(empty_indices) > max(1, len(source_cues) // 5):
        raise RuntimeError(
            "Too many source cues could not be aligned to the translated transcript: "
            f"{len(empty_indices)}/{len(source_cues)}."
        )

    # Keep the SRT valid if a short source cue falls entirely inside a translated pause.
    for index in empty_indices:
        aligned_texts[index] = "…"

    blocks = []
    for index, (cue, text) in enumerate(zip(source_cues, aligned_texts), 1):
        blocks.append(
            f"{index}\n"
            f"{format_srt_time(float(cue['start']))} --> "
            f"{format_srt_time(float(cue['end']))}\n"
            f"{text}"
        )

    stats = {
        "source_cues": len(source_cues),
        "aligned_cues": len(blocks),
        "empty_cues": len(empty_indices),
        "source_speakers": speaker_count,
        "selected_speaker": main_speaker if filter_short_adlibs else "all",
        "filtered_short_adlibs": filter_short_adlibs,
        "speaker_word_counts": speaker_word_counts,
        "word_timed_utterances": word_timed_utterances,
        "proportionally_aligned_utterances": proportionally_aligned_utterances,
        "first_timestamp": source_cues[0]["start"],
        "last_timestamp": source_cues[-1]["end"],
    }
    return "\n\n".join(blocks) + "\n", stats


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("media")
    parser.add_argument("--output-srt", required=True)
    parser.add_argument("--source-srt", required=True)
    parser.add_argument("--metadata-output", default="")
    parser.add_argument("--target-language", required=True)
    parser.add_argument("--source-language", default="auto")
    parser.add_argument("--num-speakers", type=int, default=0)
    parser.add_argument("--project-name", default="")
    parser.add_argument("--poll-interval", type=float, default=5.0)
    parser.add_argument("--timeout-seconds", type=float, default=14_400.0)
    return parser.parse_args()


def main() -> int:
    configure_stdio()
    args = parse_args()
    media = Path(args.media).resolve()
    output_srt = Path(args.output_srt).resolve()
    source_srt_path = Path(args.source_srt).resolve()
    metadata_path = Path(args.metadata_output).resolve() if args.metadata_output.strip() else None
    api_key = os.environ.get("ELEVENLABS_API_KEY", "").strip()

    if not media.is_file():
        raise FileNotFoundError(f"Input media was not found: {media}")
    if not source_srt_path.is_file():
        raise FileNotFoundError(f"Source SRT was not found: {source_srt_path}")
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
    if not args.target_language.strip():
        raise ValueError("--target-language is required.")
    if args.poll_interval < 1:
        raise ValueError("--poll-interval must be at least 1 second.")
    if args.timeout_seconds <= 0:
        raise ValueError("--timeout-seconds must be greater than zero.")

    project_name = args.project_name.strip() or f"{media.stem} - {args.target_language}"
    log("ElevenLabs dubbing mode: automatic")
    log("Dubbing watermark: enabled for Free-plan compatibility (does not alter SRT text)")
    log(f"Source language: {args.source_language or 'auto'}")
    log(f"Target language: {args.target_language}")
    log(f"Expected speakers: {args.num_speakers or 'automatic detection'}")
    log(f"Upload size: {media.stat().st_size / (1024 * 1024):.1f} MB")

    created = create_dubbing(
        media,
        api_key,
        project_name=project_name,
        source_language=args.source_language.strip() or "auto",
        target_language=args.target_language.strip(),
        num_speakers=args.num_speakers,
    )
    dubbing_id = str(created["dubbing_id"])
    log(f"Dubbing ID: {dubbing_id}")

    completed = wait_for_dubbing(
        dubbing_id,
        api_key,
        poll_interval=args.poll_interval,
        timeout_seconds=args.timeout_seconds,
    )
    transcript = retrieve_transcript_json(
        dubbing_id,
        args.target_language.strip(),
        api_key,
    )
    source_srt = source_srt_path.read_text(encoding="utf-8-sig")
    srt, alignment_stats = align_translation_to_source_srt(
        source_srt,
        transcript,
    )
    log(
        "Scribe timing alignment: "
        f"{alignment_stats['aligned_cues']} cues, "
        f"{alignment_stats['empty_cues']} empty, "
        f"speaker={alignment_stats['selected_speaker']}, "
        f"end={alignment_stats['last_timestamp']:.3f}s"
    )

    output_srt.parent.mkdir(parents=True, exist_ok=True)
    output_srt.write_text(srt, encoding="utf-8-sig")
    if metadata_path is not None:
        metadata_path.parent.mkdir(parents=True, exist_ok=True)
        metadata_path.write_text(
            json.dumps(
                {
                    "dubbing_id": dubbing_id,
                    "target_language": args.target_language.strip(),
                    "source_language": completed.get("source_language"),
                    "status": completed.get("status"),
                    "target_languages": completed.get("target_languages"),
                    "created": created,
                },
                ensure_ascii=False,
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    log(f"Translated SRT aligned to Scribe timings: {output_srt}")
    if metadata_path is not None:
        log(f"Dubbing metadata: {metadata_path}")
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
