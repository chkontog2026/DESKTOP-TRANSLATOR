"""Offline NLLB SRT translation. Setup is explicit; inference never downloads."""
import argparse
import os
from pathlib import Path
import re
import tempfile
import time
import json
try:
    from .nllb_segments import slots_for_cues, groups_for_slots, sentence_parts, distribute, protect, restore
except ImportError:
    from nllb_segments import slots_for_cues, groups_for_slots, sentence_parts, distribute, protect, restore

ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "tools/models/nllb-600m-int8"
MODEL_ID = "facebook/nllb-200-distilled-600M"
LANGUAGES = {
    "english": "eng_Latn", "en": "eng_Latn", "greek": "ell_Grek", "el": "ell_Grek",
    "ελληνικά": "ell_Grek", "αγγλικά": "eng_Latn", "french": "fra_Latn", "fr": "fra_Latn",
    "german": "deu_Latn", "de": "deu_Latn", "spanish": "spa_Latn", "es": "spa_Latn",
    "italian": "ita_Latn", "it": "ita_Latn", "portuguese": "por_Latn", "pt": "por_Latn",
    "russian": "rus_Cyrl", "ru": "rus_Cyrl", "turkish": "tur_Latn", "tr": "tur_Latn",
}

def language(value):
    code = LANGUAGES.get(value.lower(), value)
    if not re.fullmatch(r"[a-z]{3}_[A-Z][a-z]{3}", code):
        raise ValueError(f"Specify a language name or NLLB code, not {value!r}; auto detection is not supported.")
    return code

def read_srt(path):
    raw = path.read_bytes().decode("utf-8-sig")
    newline = "\r\n" if "\r\n" in raw else "\n"
    cues = []
    for block in re.split(r"\r?\n\s*\r?\n", raw.strip()):
        lines = block.splitlines()
        if len(lines) < 3 or not lines[0].isdigit() or not re.fullmatch(
            r"\d{2}:\d{2}:\d{2},\d{3}\s+-->\s+\d{2}:\d{2}:\d{2},\d{3}(?:\s+.*)?", lines[1]
        ):
            raise ValueError("Invalid SRT block; no output written.")
        cues.append((lines[0], lines[1], "\n".join(lines[2:])))
    return cues, newline

def setup():
    from ctranslate2.converters import TransformersConverter
    from transformers import AutoTokenizer
    from filelock import FileLock
    MODEL.parent.mkdir(parents=True, exist_ok=True)
    with FileLock(str(MODEL) + ".lock"):
        if (MODEL / "ready.txt").exists():
            print("NLLB model already installed.", flush=True)
            return
        print("Downloading NLLB 600M and converting to CPU INT8...", flush=True)
        with tempfile.TemporaryDirectory(prefix="nllb-setup-", dir=MODEL.parent) as temp:
            stage = Path(temp) / "model"
            TransformersConverter(MODEL_ID).convert(str(stage), quantization="int8")
            AutoTokenizer.from_pretrained(MODEL_ID).save_pretrained(stage)
            (stage / "ready.txt").write_text(MODEL_ID, encoding="utf-8")
            stage.rename(MODEL)
        print("NLLB ready for offline translation.", flush=True)

def translate(args):
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    import ctranslate2
    from transformers import AutoTokenizer
    if not (MODEL / "ready.txt").exists():
        raise RuntimeError("Run Setup-NLLB.bat once before selecting Local NLLB.")
    if args.input.resolve() == args.output.resolve():
        raise ValueError("Input and output must be different files.")
    cues, newline = read_srt(args.input)
    src, tgt = language(args.source_language), language(args.target_language)
    tokenizer = AutoTokenizer.from_pretrained(str(MODEL), src_lang=src, local_files_only=True, use_fast=False)
    for code in (src, tgt):
        if tokenizer.convert_tokens_to_ids(code) == tokenizer.unk_token_id:
            raise ValueError(f"Unsupported NLLB language: {code}")
    translator = ctranslate2.Translator(str(MODEL), device="cpu", compute_type="int8", intra_threads=4, inter_threads=1)
    started = time.monotonic()
    glossary_path = getattr(args, "glossary", None) or args.input.with_suffix(".nllb-glossary.json")
    glossary = {}
    if glossary_path.is_file():
        config = json.loads(glossary_path.read_text(encoding="utf-8-sig"))
        if config.get("source_language") != src or config.get("target_language") != tgt:
            raise ValueError("Glossary language pair does not match the translation.")
        glossary = config["terms"]
        if not isinstance(glossary, dict) or any(not isinstance(k, str) or not k.strip() or not isinstance(v, str) or not v.strip() for k, v in glossary.items()):
            raise ValueError("Glossary must contain nonempty text pairs.")
        print(f"Loaded {len(glossary)} protected terms from {glossary_path}", flush=True)
    elif getattr(args, "glossary", None):
        raise ValueError(f"Glossary not found: {glossary_path}")
    warnings = []
    cache = {}
    short_greek = {"what?": "Τι;", "yeah.": "Ναι.", "yeah?": "Ναι;", "yes.": "Ναι.",
                   "no.": "Όχι.", "okay.": "Εντάξει.", "okay?": "Εντάξει;", "thanks.": "Ευχαριστώ.",
                   "thank you.": "Ευχαριστώ.", "hi.": "Γεια.", "oh.": "Ω.", "really?": "Αλήθεια;",
                   "i don't know.": "Δεν ξέρω.", "i'm sorry.": "Συγγνώμη.", "well,": "Λοιπόν,"}
    def raw_translation(text):
        if not text.strip():
            return text
        if not re.search(r"[^\d\W]", text, flags=re.UNICODE):
            return text
        key = text.strip().casefold()
        if src == "eng_Latn" and tgt == "ell_Grek" and key in short_greek:
            return short_greek[key]
        if text in cache:
            return cache[text]
        ids = tokenizer.encode(text)
        if len(ids) > 240:
            words = text.split()
            if len(words) < 2:
                raise ValueError("Single subtitle word exceeds token limit.")
            middle = len(words) // 2
            warnings.append({"source": text, "reason": "Long sentence split at token limit"})
            return raw_translation(" ".join(words[:middle])) + " " + raw_translation(" ".join(words[middle:]))
        result = translator.translate_batch([tokenizer.convert_ids_to_tokens(ids)], target_prefix=[[tgt]], beam_size=4,
            max_input_length=0, max_decoding_length=512)[0].hypotheses[0]
        if len(result) >= 512:
            raise RuntimeError("Translation reached output limit; no partial file written.")
        out = tokenizer.decode(tokenizer.convert_tokens_to_ids(result[1:]), skip_special_tokens=True).strip()
        if not out:
            raise RuntimeError("Empty translation; no output written.")
        cache[text] = out
        return out

    def sentence_translation(text):
        encoded, values = protect(text, glossary)
        if not values:
            out = raw_translation(text)
        else:
            try:
                # Prefer natural text when all protected items survive, retaining grammar around names.
                natural = raw_translation(text)
                targets = [value for _, value in values]
                positions = []
                for value in set(targets):
                    matches = list(re.finditer(r"(?<!\w)" + re.escape(value) + r"(?!\w)", natural, re.I))
                    if len(matches) != targets.count(value):
                        raise ValueError("Retry with placeholders")
                    positions.extend((match.start(), value) for match in matches)
                if [value for _, value in sorted(positions)] != targets:
                    raise ValueError("Retry with placeholders")
                out = natural
            except ValueError:
                out = None
            try:
                if out is None:
                    out = restore(raw_translation(encoded), values)
                expected_numbers = re.findall(r"\d+(?:[.,:]\d+)*", " ".join(v for _, v in values))
                if re.findall(r"\d+(?:[.,:]\d+)*", out) != expected_numbers:
                    raise ValueError("Protected numbers changed")
            except ValueError:
                # Never accept corrupted placeholders. Translate surrounding spans and insert exact values.
                warnings.append({"source": text, "reason": "Protected-term fallback; review fluency"})
                pattern = "(" + "|".join(re.escape(k) for k, _ in values) + ")"
                mapping = dict(values)
                out = " ".join(mapping[part] if part in mapping else raw_translation(part.strip())
                               for part in re.split(pattern, encoded) if part.strip())
                out = re.sub(r"\s+([.,!?;:])", r"\1", out)
        if len(text.split()) >= 8 and len(out.split()) < len(text.split()) * .45:
            warnings.append({"source": text, "translation": out, "reason": "Unusually short translation; possible omission"})
        if tgt == "ell_Grek":
            out = out.replace("?", ";")
        return out

    def text_translation(text):
        return " ".join(sentence_translation(part) for part in sentence_parts(text))

    slots = slots_for_cues(cues, args.show_speaker_labels)
    groups = groups_for_slots(slots, cues)
    joined_groups = sum(len(group) > 1 for group in groups)
    print(f"Sentence-aware translation: {len(groups)} groups, {joined_groups} across cue boundaries", flush=True)
    for index, group in enumerate(groups, 1):
        warning_start = len(warnings)
        text = " ".join(slot.text.strip() for slot in group if slot.text.strip())
        if text:
            out = text_translation(text)
            if len(group) == 1:
                group[0].output = out
            elif not distribute(out, group):
                warnings.append({"source": text, "reason": "Too few translated words to redistribute; separate cue fallback"})
                for slot in group:
                    slot.output = text_translation(slot.text)
        for warning in warnings[warning_start:]:
            warning["cue_ids"] = [cues[slot.cue][0] for slot in group]
        if index % 10 == 0 or index == len(groups):
            print(f"Translated {index}/{len(groups)} sentence groups", flush=True)
    contents = [""] * len(cues)
    for slot in slots:
        contents[slot.cue] += slot.prefix + slot.output + slot.suffix
    rendered = []
    for (number, timing, _), content in zip(cues, contents):
        if not re.sub(r"<[^>]+>|\{\\[^}]+\}", "", content).strip():
            raise ValueError(f"Empty translated cue {number}; no output written")
        rendered.append(newline.join((number, timing, content.replace("\n", newline))))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=args.output.parent, suffix=".tmp", delete=False) as stream:
        temp = Path(stream.name)
        stream.write(((newline * 2).join(rendered) + newline).encode("utf-8-sig"))
    try:
        temp.replace(args.output)
    finally:
        temp.unlink(missing_ok=True)
    report = {"source": str(args.input), "output": str(args.output), "cues": len(cues),
              "joined_groups": joined_groups, "sentence_groups": len(groups), "warnings": warnings,
              "elapsed_seconds": round(time.monotonic() - started, 2)}
    args.output.with_suffix(".qa.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Review warnings: {len(warnings)}; report: {args.output.with_suffix('.qa.json')}", flush=True)
    print(f"Wrote {args.output} ({time.monotonic() - started:.1f}s translation)", flush=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, nargs="?")
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--setup", action="store_true")
    parser.add_argument("--source-language", default="English")
    parser.add_argument("--target-language", default="Greek")
    parser.add_argument("--show-speaker-labels", action="store_true")
    parser.add_argument("--glossary", type=Path, help="JSON glossary; defaults to <input stem>.nllb-glossary.json")
    options = parser.parse_args()
    if options.setup:
        setup()
    elif options.input and options.output:
        translate(options)
    else:
        parser.error("input and output are required")
