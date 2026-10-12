"""Sentence grouping and lossless SRT metadata handling (no model dependencies)."""
from dataclasses import dataclass
import re

@dataclass
class Slot:
    cue: int
    text: str
    prefix: str = ""
    suffix: str = ""
    boundary: bool = False
    output: str = ""

def milliseconds(stamp):
    h, m, s, ms = map(int, re.findall(r"\d+", stamp)[:4])
    return ((h * 60 + m) * 60 + s) * 1000 + ms

def slots_for_cues(cues, show_labels=False):
    slots = []
    for index, (_, _, raw) in enumerate(cues):
        # Only explicit dialogue/speaker starts create separate turns. Visual line wraps do not.
        turns = re.split(r"\n(?=\s*(?:[-–—]\s|\[?S\d+\]?\s*:|Speaker\s+\d+\s*:))", raw, flags=re.I)
        for turn_index, turn in enumerate(turns):
            prefix = "\n" if turn_index else ""
            suffix = ""
            text = turn.strip()
            marker = re.match(r"(?:[-–—]\s+|(?:\[?S\d+\]?|Speaker\s+\d+)\s*:\s*)", text, re.I)
            boundary = len(turns) > 1 or bool(marker)
            if marker:
                token = marker.group()
                if show_labels or not re.search(r"\d", token):
                    prefix += token
                text = text[marker.end():]
            while True:
                override = re.match(r"^\{\\[^}]+\}", text)
                outer = re.fullmatch(r"(<(i|b|u)>)(.*)(</\2>)", text, flags=re.S | re.I)
                if override:
                    prefix += override.group()
                    text = text[override.end():]
                elif outer:
                    prefix += outer[1]
                    suffix = outer[4] + suffix
                    text = outer[3]
                else:
                    break
            # Preserve complex inline markup exactly; its spans remain separate.
            pieces = re.split(r"(<[^>]+>|\{\\[^}]+\})", text)
            if len(pieces) > 1:
                first_slot = len(slots)
                for i, part in enumerate(pieces):
                    if i % 2:
                        slots.append(Slot(index, "", prefix=part, boundary=True))
                    elif part:
                        slots.append(Slot(index, re.sub(r"\s+", " ", part),
                                          prefix=" " if part[0].isspace() else "",
                                          suffix=" " if part[-1].isspace() else "", boundary=True))
                slots[first_slot].prefix = prefix + slots[first_slot].prefix
                slots[-1].suffix += suffix
            else:
                slots.append(Slot(index, re.sub(r"\s+", " ", text), prefix, suffix, boundary))
    return slots

def sentence_parts(text):
    # Keep abbreviations and decimal numbers inside their sentences.
    pieces, start = [], 0
    for match in re.finditer(r"[.!?]+[\"'’”)]*\s+", text):
        prior = text[start:match.end()].strip()
        if re.search(r"\b(?:Mr|Mrs|Ms|Dr|St|Jr|Sr|Prof)\.$", prior, re.I) or re.search(r"\b[A-Z]\.$", prior):
            continue
        pieces.append(prior)
        start = match.end()
    if text[start:].strip():
        pieces.append(text[start:].strip())
    return pieces

def groups_for_slots(slots, cues):
    groups = []
    for slot in slots:
        if not groups:
            groups.append([slot])
            continue
        group = groups[-1]
        previous = group[-1]
        gap = milliseconds(cues[slot.cue][1].split('-->')[0]) - milliseconds(cues[previous.cue][1].split('-->')[1])
        can_join = (not previous.boundary and not slot.boundary and previous.text and slot.text
                    and not re.search(r"[.!?…][\"'’”)]*$|[-–—]$", previous.text)
                    and not re.fullmatch(r"[\d\W]+", previous.text)
                    and previous.prefix == slot.prefix and previous.suffix == slot.suffix
                    and slot.cue == previous.cue + 1 and -500 <= gap <= 1500
                    and len(group) < 4 and sum(len(s.text) for s in group) + len(slot.text) <= 600)
        if can_join:
            group.append(slot)
        else:
            groups.append([slot])
    return groups

def distribute(text, group):
    """Redistribute complete words; never cut words, drop text, or create empty cues."""
    words = text.split()
    if len(words) < len(group):
        return False
    weight = sum(max(1, len(slot.text.split())) for slot in group)
    begin, total = 0, 0
    for index, slot in enumerate(group):
        total += max(1, len(slot.text.split()))
        end = len(words) if index == len(group)-1 else max(begin+1, min(len(words)-(len(group)-index-1), round(len(words)*total/weight)))
        slot.output = " ".join(words[begin:end])
        begin = end
    return True

def protect(text, glossary):
    terms = sorted(glossary, key=len, reverse=True)
    pattern = r"(?<!\w)(?:" + "|".join(re.escape(term) for term in terms) + r")(?!\w)" if terms else r"(?!)"
    pattern += r"|(?<!\w)\d+(?:[.,:]\d+)*(?!\w)"
    values = []
    lowered = {k.casefold(): v for k, v in glossary.items()}
    def replace(match):
        token = str(980000000 + len(values))
        while token in text:
            token = '9' + token
        values.append((token, lowered.get(match.group().casefold(), match.group())))
        return token
    return re.sub(pattern, replace, text, flags=re.I), values

def restore(text, values):
    expected = [token for token, _ in values]
    found = re.findall(r"(?<!\d)(?:" + "|".join(map(re.escape, expected)) + r")(?!\d)", text) if expected else []
    if found != expected:
        raise ValueError("Protected terms were omitted, duplicated or reordered")
    for token, value in values:
        text = re.sub(r"(?<!\d)" + re.escape(token) + r"(?!\d)", lambda _: value, text)
    return text
