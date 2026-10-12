import argparse
import array
import math
import re
import statistics
import wave


TIMESTAMP_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2}),(\d{3})\s+-->\s+(\d{2}):(\d{2}):(\d{2}),(\d{3})"
)


def timestamp_to_seconds(match, offset):
    hours = int(match.group(offset))
    minutes = int(match.group(offset + 1))
    seconds = int(match.group(offset + 2))
    millis = int(match.group(offset + 3))
    return hours * 3600 + minutes * 60 + seconds + millis / 1000.0


def read_srt_cues(path):
    text = open(path, "r", encoding="utf-8-sig", errors="replace").read()
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    blocks = [block.strip() for block in re.split(r"\n{2,}", text.strip()) if block.strip()]
    cues = []
    for block in blocks:
        lines = block.split("\n")
        timestamp_index = next((i for i, line in enumerate(lines) if TIMESTAMP_RE.search(line)), -1)
        if timestamp_index < 0:
            continue
        match = TIMESTAMP_RE.search(lines[timestamp_index])
        number = lines[timestamp_index - 1].strip() if timestamp_index > 0 else str(len(cues) + 1)
        cues.append(
            {
                "number": number,
                "start": timestamp_to_seconds(match, 1),
                "end": timestamp_to_seconds(match, 5),
            }
        )
    return cues


def read_wav(path):
    with wave.open(path, "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())

    if sample_width != 2:
        raise RuntimeError("Expected 16-bit PCM WAV")

    samples = array.array("h")
    samples.frombytes(frames)
    if channels > 1:
        samples = array.array("h", samples[::channels])
    return sample_rate, samples


def rms(frame):
    if not frame:
        return 0.0
    return math.sqrt(sum(sample * sample for sample in frame) / len(frame))


def estimate_f0(frame, sample_rate):
    energy = rms(frame)
    if energy < 250:
        return None

    frame = [sample - (sum(frame) / len(frame)) for sample in frame]
    min_lag = int(sample_rate / 350.0)
    max_lag = int(sample_rate / 70.0)
    best_lag = None
    best_score = 0.0
    zero_lag = sum(sample * sample for sample in frame)
    if zero_lag <= 0:
        return None

    for lag in range(min_lag, max_lag + 1):
        score = 0.0
        for i in range(0, len(frame) - lag, 2):
            score += frame[i] * frame[i + lag]
        normalized = score / zero_lag
        if normalized > best_score:
            best_score = normalized
            best_lag = lag

    if best_lag is None or best_score < 0.28:
        return None
    return sample_rate / best_lag


def cue_pitch(sample_rate, samples, start, end):
    start_index = max(0, int(start * sample_rate))
    end_index = min(len(samples), int(end * sample_rate))
    if end_index - start_index < int(0.35 * sample_rate):
        return None

    frame_size = int(0.04 * sample_rate)
    step = int(0.16 * sample_rate)
    max_frames = 10
    f0_values = []
    cursor = start_index
    while cursor + frame_size <= end_index and len(f0_values) < max_frames:
        frame = samples[cursor : cursor + frame_size]
        f0 = estimate_f0(frame, sample_rate)
        if f0:
            f0_values.append(f0)
        cursor += step

    if len(f0_values) < 3:
        return None
    return statistics.median(f0_values)


def classify_pitch(f0):
    if f0 is None:
        return "unknown", 0.0
    if f0 < 145:
        confidence = min(0.92, 0.58 + (145 - f0) / 120)
        return "likely male voice", confidence
    if f0 > 185:
        confidence = min(0.92, 0.58 + (f0 - 185) / 140)
        return "likely female voice", confidence
    if f0 < 160:
        return "possibly male voice", 0.52
    if f0 > 170:
        return "possibly female voice", 0.52
    return "unknown", 0.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wav", required=True)
    parser.add_argument("--srt", required=True)
    parser.add_argument("--min-confidence", type=float, default=0.56)
    parser.add_argument("--max-lines", type=int, default=450)
    args = parser.parse_args()

    sample_rate, samples = read_wav(args.wav)
    cues = read_srt_cues(args.srt)

    lines = []
    counts = {}
    for cue in cues:
        f0 = cue_pitch(sample_rate, samples, cue["start"], cue["end"])
        label, confidence = classify_pitch(f0)
        if confidence < args.min_confidence or label == "unknown":
            continue
        counts[label] = counts.get(label, 0) + 1
        lines.append(f'Cue {cue["number"]}: {label}, confidence {confidence:.2f}.')
        if len(lines) >= args.max_lines:
            break

    if not lines:
        print("No reliable cue-level voice gender hints were detected.")
        return

    print("Cue-level voice gender hints estimated from audio pitch. Use only when consistent with source context; do not override clear textual evidence.")
    for label, count in sorted(counts.items()):
        print(f"Summary: {label}: {count} cues.")
    print("")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
