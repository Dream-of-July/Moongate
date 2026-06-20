from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Iterable, List


TIME_LINE_RE = re.compile(
    r"(\d{1,2}:\d{2}:\d{2}[\.,]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[\.,]\d{1,3})"
)


@dataclass(frozen=True)
class Cue:
    index: int
    start: float
    end: float
    text: str


def parse_time(value: str) -> float:
    normalized = value.strip().replace(",", ".")
    parts = normalized.split(":")
    if len(parts) != 3:
        raise ValueError("invalid subtitle timestamp: %s" % value)
    hours = int(parts[0])
    minutes = int(parts[1])
    seconds = float(parts[2])
    return hours * 3600.0 + minutes * 60.0 + seconds


def format_time(seconds: float) -> str:
    millis = int(round(max(0.0, seconds) * 1000.0))
    ms = millis % 1000
    total_seconds = millis // 1000
    sec = total_seconds % 60
    minutes = (total_seconds // 60) % 60
    hours = total_seconds // 3600
    return "%02d:%02d:%02d,%03d" % (hours, minutes, sec, ms)


def parse_srt(raw: str) -> List[Cue]:
    text = raw.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    anchors = []
    for line_index, line in enumerate(lines):
        match = TIME_LINE_RE.search(line)
        if not match:
            continue
        explicit_index = None
        if line_index > 0:
            previous = lines[line_index - 1].strip()
            if previous.isdigit():
                explicit_index = int(previous)
        anchors.append((line_index, match.group(1), match.group(2), explicit_index))

    cues: List[Cue] = []
    next_index = 1
    for anchor_index, (line_index, start, end, explicit_index) in enumerate(anchors):
        text_start = line_index + 1
        if anchor_index + 1 < len(anchors):
            next_line = anchors[anchor_index + 1][0]
            next_has_index = next_line > 0 and lines[next_line - 1].strip().isdigit()
            text_end = next_line - 1 if next_has_index else next_line
        else:
            text_end = len(lines)
        body = [line.strip() for line in lines[text_start:text_end] if line.strip()]
        if not body:
            continue
        index = explicit_index or next_index
        cues.append(Cue(index=index, start=parse_time(start), end=parse_time(end), text="\n".join(body)))
        next_index = index + 1
    return cues


def serialize_srt(cues: Iterable[Cue]) -> str:
    chunks = []
    for index, cue in enumerate(cues, start=1):
        chunks.append("%d\n%s --> %s\n%s" % (index, format_time(cue.start), format_time(cue.end), cue.text))
    return "\n\n".join(chunks) + "\n"
