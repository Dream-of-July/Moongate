from __future__ import annotations

from dataclasses import dataclass
import html
import re
from typing import List, Optional, Tuple

from .srt import Cue, parse_time


VTT_TIME_RE = re.compile(
    r"((?:\d{1,2}:)?\d{2}:\d{2}[\.,]\d{3})\s*-->\s*((?:\d{1,2}:)?\d{2}:\d{2}[\.,]\d{3})"
)
INLINE_TIME_RE = re.compile(r"<((?:\d{1,2}:)?\d{2}:\d{2}[\.,]\d{3})>")
TAG_RE = re.compile(r"<[^>]+>")
UNTIMED_LONG_CUE_SECONDS = 3.5
UNTIMED_MAX_SECONDS_PER_TOKEN = 1.3
HAN_OR_KANA_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff]")
LATIN_RUN_RE = re.compile(r"[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)?")


@dataclass(frozen=True)
class Word:
    start: float
    end: float
    text: str


def parse_vtt_time(value: str) -> float:
    value = value.strip().replace(",", ".")
    if value.count(":") == 1:
        value = "00:" + value
    return parse_time(value)


def strip_vtt_markup(text: str) -> str:
    without_inline_times = INLINE_TIME_RE.sub("", text)
    without_tags = TAG_RE.sub("", without_inline_times)
    return " ".join(html.unescape(without_tags).split())


def timing_tokens(text: str) -> List[str]:
    split_tokens = text.split()
    if len(split_tokens) != 1 or not HAN_OR_KANA_RE.search(text):
        return split_tokens
    tokens: List[str] = []
    index = 0
    while index < len(text):
        match = LATIN_RUN_RE.match(text, index)
        if match:
            tokens.append(match.group(0))
            index = match.end()
            continue
        char = text[index]
        if not char.isspace():
            tokens.append(char)
        index += 1
    return tokens


def iter_vtt_blocks(raw: str) -> List[Tuple[str, float, float, str]]:
    lines = raw.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    anchors = []
    for index, line in enumerate(lines):
        match = VTT_TIME_RE.search(line)
        if not match:
            continue
        anchors.append((index, parse_vtt_time(match.group(1)), parse_vtt_time(match.group(2))))

    blocks: List[Tuple[str, float, float, str]] = []
    for anchor_index, (line_index, cue_start, cue_end) in enumerate(anchors):
        body_start = line_index + 1
        body_end = anchors[anchor_index + 1][0] if anchor_index + 1 < len(anchors) else len(lines)
        body_text = "\n".join(lines[body_start:body_end])
        visible_text = strip_vtt_markup(body_text)
        blocks.append((body_text, cue_start, cue_end, visible_text))
    return blocks


def parse_vtt_cues(raw: str) -> List[Cue]:
    cues: List[Cue] = []
    for body_text, start, end, _visible_text in iter_vtt_blocks(raw):
        text = strip_vtt_markup(body_text)
        if text:
            cues.append(Cue(index=len(cues) + 1, start=start, end=end, text=text))
    return cues


def parse_vtt_word_timestamps(raw: str) -> List[Word]:
    cues = iter_vtt_blocks(raw)

    words: List[Word] = []
    previous_visible = ""
    previous_end: Optional[float] = None

    def remove_rolling_prefix(text: str, cue_start: float, cue_end: float) -> str:
        current_tokens = text.split()
        previous_tokens = previous_visible.split()
        for count in range(min(len(current_tokens), len(previous_tokens)), 0, -1):
            if previous_tokens[-count:] == current_tokens[:count]:
                if count == len(current_tokens):
                    gap = float("inf") if previous_end is None else cue_start - previous_end
                    if gap <= 0.12 or cue_end - cue_start <= 0.2:
                        return ""
                    return text
                return " ".join(current_tokens[count:])
        return text

    def append_timed_text(
        text: str,
        start: float,
        end: float,
        *,
        cap_long_hold: bool = False,
        cap_token_span: bool = False,
    ) -> None:
        tokens = timing_tokens(text)
        if not tokens:
            return
        end = max(start, end)
        duration = end - start
        if cap_long_hold and duration > UNTIMED_LONG_CUE_SECONDS:
            duration = min(duration, len(tokens) * UNTIMED_MAX_SECONDS_PER_TOKEN)
            end = start + duration
        if cap_token_span:
            duration = min(duration, len(tokens) * UNTIMED_MAX_SECONDS_PER_TOKEN)
            end = start + duration
        for index, token in enumerate(tokens):
            token_start = start + duration * index / len(tokens)
            token_end = start + duration * (index + 1) / len(tokens)
            words.append(Word(start=token_start, end=max(token_start, token_end), text=token))

    for body, cue_start, cue_end, visible_text in cues:
        matches = list(INLINE_TIME_RE.finditer(body))
        if not matches:
            new_text = remove_rolling_prefix(visible_text, cue_start, cue_end)
            append_timed_text(new_text, cue_start, cue_end, cap_long_hold=True)
            previous_visible = visible_text
            previous_end = cue_end
            continue
        leading_text = remove_rolling_prefix(strip_vtt_markup(body[:matches[0].start()]), cue_start, cue_end)
        append_timed_text(leading_text, cue_start, parse_vtt_time(matches[0].group(1)))
        for index, match in enumerate(matches):
            text_start = match.end()
            text_end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
            token = strip_vtt_markup(body[text_start:text_end])
            if not token:
                continue
            start = parse_vtt_time(match.group(1))
            end = parse_vtt_time(matches[index + 1].group(1)) if index + 1 < len(matches) else cue_end
            append_timed_text(token, start, end, cap_token_span=(index + 1 == len(matches)))
        previous_visible = visible_text
        previous_end = cue_end
    return words
