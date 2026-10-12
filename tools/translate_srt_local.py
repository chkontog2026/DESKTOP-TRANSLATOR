#!/usr/bin/env python3
"""Translate an SRT locally with a Hugging Face Marian model."""

from __future__ import annotations

import argparse
import re
import textwrap
from pathlib import Path

import torch
from transformers import MarianMTModel, MarianTokenizer


TIMESTAMP_RE = re.compile(
    r"^\d{2}:\d{2}:\d{2},\d{3}\s+-->\s+\d{2}:\d{2}:\d{2},\d{3}$"
)
SPEAKER_RE = re.compile(
    r"(?i)(?<![\w])(?:\[?S\d{1,3}\]?|speaker\s*\d+)\s*:\s*"
)
OUTER_ITALIC_RE = re.compile(r"^\s*<i>(.*)</i>\s*$", re.IGNORECASE | re.DOTALL)
LEADING_OVERRIDE_RE = re.compile(r"^(\s*(?:\{\\[^}]+\}\s*)+)(.*)$", re.DOTALL)


def read_srt(path: Path) -> tuple[list[tuple[str, str, str]], str]:
    raw = path.read_text(encoding="utf-8-sig")
    newline = "\r\n" if "\r\n" in raw else "\n"
    blocks = re.split(r"\r?\n\s*\r?\n", raw.strip())
    cues: list[tuple[str, str, str]] = []
    for position, block in enumerate(blocks, 1):
        lines = block.splitlines()
        if len(lines) < 3 or not lines[0].strip().isdigit() or not TIMESTAMP_RE.match(lines[1].strip()):
            raise ValueError(f"Invalid SRT block at position {position}: {block[:120]!r}")
        cues.append((lines[0].strip(), lines[1].strip(), "\n".join(lines[2:]).strip()))
    return cues, newline


def unwrap_formatting(text: str) -> tuple[str, str, str]:
    prefix = ""
    suffix = ""
    override = LEADING_OVERRIDE_RE.match(text)
    if override:
        prefix += override.group(1)
        text = override.group(2)
    italic = OUTER_ITALIC_RE.match(text)
    if italic:
        prefix += "<i>"
        suffix = "</i>" + suffix
        text = italic.group(1)
    return prefix, text, suffix


def wrap_subtitle(text: str, width: int = 44) -> str:
    text = re.sub(r"[ \t]+", " ", text).strip()
    if len(text) <= width:
        return text
    return "\n".join(
        textwrap.wrap(
            text,
            width=width,
            break_long_words=False,
            break_on_hyphens=False,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--model", default="Helsinki-NLP/opus-mt-en-el")
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--num-beams", type=int, default=1)
    args = parser.parse_args()

    cues, newline = read_srt(args.input)
    tokenizer = MarianTokenizer.from_pretrained(args.model)
    model = MarianMTModel.from_pretrained(args.model)
    model.eval()

    prepared: list[tuple[str, str, str]] = []
    source_units: list[str] = []
    for _, _, cue_text in cues:
        clean = SPEAKER_RE.sub("", cue_text.replace("\n", " ")).strip()
        prefix, unit, suffix = unwrap_formatting(clean)
        prepared.append((prefix, unit, suffix))
        source_units.append(unit)

    translations: list[str] = []
    for start in range(0, len(source_units), args.batch_size):
        batch = source_units[start : start + args.batch_size]
        encoded = tokenizer(
            batch,
            return_tensors="pt",
            padding=True,
            truncation=True,
            max_length=512,
        )
        with torch.inference_mode():
            longest_source = int(encoded["attention_mask"].sum(dim=1).max().item())
            generation_options = {
                "num_beams": args.num_beams,
                "max_new_tokens": min(120, max(20, longest_source * 2 + 8)),
            }
            if args.num_beams > 1:
                generation_options["early_stopping"] = True
            generated = model.generate(**encoded, **generation_options)
        translations.extend(tokenizer.batch_decode(generated, skip_special_tokens=True))
        done = min(start + len(batch), len(source_units))
        print(f"Translated {done}/{len(source_units)} cues", flush=True)

    output_blocks: list[str] = []
    for (number, timestamp, _), (prefix, _, suffix), translated in zip(
        cues, prepared, translations, strict=True
    ):
        clean_translation = SPEAKER_RE.sub("", translated).strip()
        rendered = prefix + wrap_subtitle(clean_translation) + suffix
        output_blocks.append(newline.join((number, timestamp, rendered)))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        (newline + newline).join(output_blocks) + newline,
        encoding="utf-8-sig",
        newline="",
    )
    print(f"Wrote: {args.output}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
