from __future__ import annotations

from dataclasses import dataclass, asdict
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence

from .srt import Cue, parse_srt
from .vtt import parse_vtt_cues


CJK_LANGUAGE_PREFIXES = ("ja", "ko", "zh", "yue", "cmn")
CJK_RE = re.compile(r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7a3]")
LATIN_RE = re.compile(r"[A-Za-z]+")
SAFE_LATIN_TOKENS = {"mv", "live", "music", "video", "cover", "official", "the", "and", "you", "yo"}
ROMANIZED_VOWEL_RE = re.compile(r"[aeiou]")
ROMANIZED_GARBAGE_LEAK_RE = re.compile(r"\b(?:ni|nani|dare|carano|ana|anas|me|ani|car)\b", re.I)
PARENTHETICAL_RE = re.compile(r"[\(（]([^\(\)（）]*)[\)）]")

CJK_LATIN_NOISE_RATIO_THRESHOLD = 0.20
CJK_CONTENT_MISMATCH_LATIN_RATIO_THRESHOLD = 0.55
CJK_CONTENT_MISMATCH_CJK_RATIO_THRESHOLD = 0.15
CJK_LONG_CUE_DURATION_THRESHOLD = 12.0
CJK_LONG_CUE_RATIO_THRESHOLD = 0.08
CJK_LONG_CUE_MIN_COUNT = 2
ROMANIZED_LOOP_TOKEN_RATIO_THRESHOLD = 0.35
ROMANIZED_LOOP_MIN_TOKEN_COUNT = 6
ROMANIZED_LOOP_MIN_MAX_RUN = 3
SOUND_EFFECT_CUE_RATIO_THRESHOLD = 0.10
SOUND_EFFECT_CUE_MIN_COUNT = 4
SOUND_EFFECT_DURATION_RATIO_THRESHOLD = 0.12
SOUND_EFFECT_DURATION_MIN_COUNT = 2
JAPANESE_WEAK_ADJECTIVE_ENDINGS = ("しく", "く")
JAPANESE_WEAK_ADJECTIVE_CONTINUATIONS = ("なる", "なり", "ない")
# 行尾悬空助词门：を/が 是宾格/主格助词，几乎不可能作为一句字幕的自然结尾——它们必然要接后续
# 谓语。一行以它们结尾说明源把「…を | 动词」「…が | 谓语」这类紧密绑定切成了两条（如群青
# 「好きなものを」「朝が」），是机器分段把句子切成半句的高精度信号。刻意不含 に/の/は/も：に（如
# 「日々に」换气）、の（连体）、は/も（主题/兼提）可以合法收尾，纳入会误伤已断好的行。
JAPANESE_DANGLING_CASE_PARTICLES = ("を", "が")
CHINESE_DANGLING_FUNCTION_WORDS = ("把", "被", "让", "讓", "将", "將")
CANTONESE_DANGLING_PARTICLES = ("嘅", "既", "畀", "俾", "喺", "响", "響", "將", "将")
KOREAN_DANGLING_PARTICLES = ("을", "를", "은", "는", "이", "가", "에", "에서", "에게", "와", "과", "도")
HAN_START_RE = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]")
HANGUL_START_RE = re.compile(r"^[\uac00-\ud7a3]")
LYRIC_FILLER_LOOP_TOKENS = {
    "yeah", "yea", "ya", "yah", "ey", "hey", "heyy",
    "oh", "ooh", "uh", "uhh", "ah", "mmm", "mm", "hmm", "hm",
}
LYRIC_FILLER_LOOP_MIN_DURATION_SECONDS = 8.0
LYRIC_FILLER_LOOP_MIN_TOKEN_COUNT = 12
LYRIC_FILLER_LOOP_HIGH_TOKEN_COUNT = 24
LYRIC_FILLER_CUE_MIN_TOKEN_COUNT = 3
LYRIC_FILLER_CUE_MIN_RATIO = 0.75
LYRIC_FILLER_LOOP_MAX_GAP_SECONDS = 1.5
LYRIC_OUTRO_BOILERPLATE_RE = re.compile(
    r"(thanks\s+for\s+watching|thank\s+you\s+for\s+watching|gracias\s+por\s+ver|ご視聴ありがとうございました)",
    re.I,
)


@dataclass(frozen=True)
class SourceQualityReport:
    cue_count: int
    visible_scalar_count: int
    cjk_language: bool
    cjk_scalar_ratio: float
    latin_scalar_ratio: float
    adjacent_identical_ratio: float
    bad_scalar_ratio: float
    unique_cue_text_ratio: float
    dominant_cue_text_ratio: float
    romanized_loop_token_count: int
    romanized_loop_max_run: int
    romanized_loop_token_ratio: float
    sound_effect_cue_count: int
    sound_effect_cue_ratio: float
    sound_effect_duration_ratio: float
    long_cue_count: int
    long_cue_ratio: float
    max_cue_duration: float
    usable: bool
    reasons: List[str]


@dataclass(frozen=True)
class ViewingSampleReport:
    sample_id: str
    title: str
    category: str
    source_language_code: str
    source_path: Optional[str]
    local_asr_path: Optional[str]
    final_source_path: Optional[str]
    final_source_kind: str
    fallback_used: bool
    translated_path: Optional[str]
    source_quality: SourceQualityReport
    local_asr_quality: Optional[SourceQualityReport]
    local_asr_issues: List[str]
    final_source_issues: List[str]
    translated_issues: List[str]
    preview_rows: List[Dict[str, Any]]

    @property
    def blocking_issue_count(self) -> int:
        source_blockers = 0 if self.fallback_used else len(self.source_quality.reasons)
        return source_blockers + len(self.final_source_issues) + len(self.translated_issues)


def normalized_language_code(value: Optional[str]) -> str:
    if not value:
        return ""
    low = value.strip().lower()
    if low.startswith("zh") or low in {"cmn", "zho"}:
        return "zh"
    if low.startswith("yue"):
        return "yue"
    if low.startswith("ja") or low == "jpn":
        return "ja"
    if low.startswith("ko") or low == "kor":
        return "ko"
    return low.split("-")[0]


def is_cjk_language(*codes: Optional[str]) -> bool:
    return any(normalized_language_code(code).startswith(CJK_LANGUAGE_PREFIXES) for code in codes)


def is_romanized_loop_sensitive_language(*codes: Optional[str]) -> bool:
    return any(normalized_language_code(code) in {"ja", "zh", "yue"} for code in codes)


def load_subtitle_cues(path: Path) -> List[Cue]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    return parse_vtt_cues(raw) if path.suffix.lower() == ".vtt" else parse_srt(raw)


def source_quality_report(
    cues: Sequence[Cue],
    *,
    requested_language_code: Optional[str] = None,
    subtitle_language_code: Optional[str] = None,
) -> SourceQualityReport:
    cjk_language = is_cjk_language(requested_language_code, subtitle_language_code)
    if not cues:
        return SourceQualityReport(
            0, 0, cjk_language, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, False, ["tooFewCues"]
        )

    visible = 0
    cjk = 0
    latin = 0
    bad = 0
    identical = 0
    comparable = 0
    previous: Optional[str] = None
    unique_texts = set()
    text_counts: Dict[str, int] = {}
    latin_tokens: List[str] = []
    sound_effect_cues = 0
    sound_effect_duration = 0.0
    subtitle_duration = 0.0
    long_cues = 0
    max_cue_duration = 0.0

    for cue in cues:
        text = cue.text.strip()
        duration = max(0.0, cue.end - cue.start)
        subtitle_duration += duration
        max_cue_duration = max(max_cue_duration, duration)
        if duration >= CJK_LONG_CUE_DURATION_THRESHOLD:
            long_cues += 1
        if previous is not None:
            comparable += 1
            if text and text == previous:
                identical += 1
        previous = text
        if text:
            unique_texts.add(text)
            text_counts[text] = text_counts.get(text, 0) + 1
        if is_sound_effect_cue_text(text):
            sound_effect_cues += 1
            sound_effect_duration += duration
        quality_text = remove_parenthetical_latin_glosses(cue.text) if cjk_language else cue.text
        latin_tokens.extend(token.lower() for token in LATIN_RE.findall(quality_text))
        for ch in quality_text:
            if ch.isspace():
                continue
            visible += 1
            if ch == "\ufffd" or (ord(ch) < 0x20 and ch not in "\t\n\r"):
                bad += 1
            if CJK_RE.match(ch):
                cjk += 1
            if ("A" <= ch <= "Z") or ("a" <= ch <= "z"):
                latin += 1

    romanized_loop_sensitive = is_romanized_loop_sensitive_language(requested_language_code, subtitle_language_code)
    suspicious = [
        token for token in latin_tokens if _is_suspicious_romanized_loop_token(token)
    ] if romanized_loop_sensitive else []
    counts: Dict[str, int] = {}
    for token in suspicious:
        counts[token] = counts.get(token, 0) + 1
    romanized_loop_token_count = sum(count for count in counts.values() if count >= 2)
    romanized_loop_max_run = max(counts.values(), default=0)
    romanized_loop_token_ratio = romanized_loop_token_count / len(latin_tokens) if latin_tokens else 0.0

    adjacent_identical_ratio = identical / comparable if comparable else 0.0
    bad_scalar_ratio = bad / visible if visible else 0.0
    cjk_scalar_ratio = cjk / visible if visible else 0.0
    latin_scalar_ratio = latin / visible if visible else 0.0
    unique_cue_text_ratio = len(unique_texts) / len(cues) if cues else 0.0
    dominant_cue_text_ratio = max(text_counts.values(), default=0) / len(cues) if cues else 0.0
    sound_effect_cue_ratio = sound_effect_cues / len(cues) if cues else 0.0
    sound_effect_duration_ratio = sound_effect_duration / subtitle_duration if subtitle_duration > 0 else 0.0
    long_cue_ratio = long_cues / len(cues) if cues else 0.0

    reasons: List[str] = []
    if adjacent_identical_ratio >= 0.50:
        reasons.append("garbledOrRepetitive")
    if len(cues) >= 12 and (
        (dominant_cue_text_ratio >= 0.45 and unique_cue_text_ratio <= 0.25)
        or unique_cue_text_ratio <= 0.12
    ):
        reasons.append("garbledOrRepetitive")
    if bad_scalar_ratio >= 0.05:
        reasons.append("garbledOrRepetitive")
    if (
        cjk_language
        and visible >= 6
        and latin_scalar_ratio >= CJK_CONTENT_MISMATCH_LATIN_RATIO_THRESHOLD
        and cjk_scalar_ratio <= CJK_CONTENT_MISMATCH_CJK_RATIO_THRESHOLD
    ):
        reasons.append("garbledOrRepetitive")
    romanized_loop = (
        romanized_loop_token_count >= ROMANIZED_LOOP_MIN_TOKEN_COUNT
        and romanized_loop_max_run >= ROMANIZED_LOOP_MIN_MAX_RUN
        and romanized_loop_token_ratio >= ROMANIZED_LOOP_TOKEN_RATIO_THRESHOLD
    )
    if cjk_language and visible >= 80 and latin_scalar_ratio >= CJK_LATIN_NOISE_RATIO_THRESHOLD and romanized_loop:
        reasons.append("garbledOrRepetitive")
    if (
        cjk_language
        and long_cues >= CJK_LONG_CUE_MIN_COUNT
        and long_cue_ratio >= CJK_LONG_CUE_RATIO_THRESHOLD
    ):
        reasons.append("garbledOrRepetitive")
    if sound_effect_cues >= SOUND_EFFECT_CUE_MIN_COUNT and sound_effect_cue_ratio >= SOUND_EFFECT_CUE_RATIO_THRESHOLD:
        reasons.append("garbledOrRepetitive")
    if (
        sound_effect_cues >= SOUND_EFFECT_DURATION_MIN_COUNT
        and sound_effect_duration_ratio >= SOUND_EFFECT_DURATION_RATIO_THRESHOLD
    ):
        reasons.append("garbledOrRepetitive")

    return SourceQualityReport(
        cue_count=len(cues),
        visible_scalar_count=visible,
        cjk_language=cjk_language,
        cjk_scalar_ratio=cjk_scalar_ratio,
        latin_scalar_ratio=latin_scalar_ratio,
        adjacent_identical_ratio=adjacent_identical_ratio,
        bad_scalar_ratio=bad_scalar_ratio,
        unique_cue_text_ratio=unique_cue_text_ratio,
        dominant_cue_text_ratio=dominant_cue_text_ratio,
        romanized_loop_token_count=romanized_loop_token_count,
        romanized_loop_max_run=romanized_loop_max_run,
        romanized_loop_token_ratio=romanized_loop_token_ratio,
        sound_effect_cue_count=sound_effect_cues,
        sound_effect_cue_ratio=sound_effect_cue_ratio,
        sound_effect_duration_ratio=sound_effect_duration_ratio,
        long_cue_count=long_cues,
        long_cue_ratio=long_cue_ratio,
        max_cue_duration=max_cue_duration,
        usable=not reasons,
        reasons=sorted(set(reasons)),
    )


def is_sound_effect_cue_text(text: str) -> bool:
    compact = re.sub(r"\s+", "", text.strip()).lower()
    if not compact:
        return False
    markers = (
        "[音楽]", "［音楽］", "[拍手]", "［拍手］",
        "[music]", "[applause]", "(music)", "(applause)",
        "[musica]", "[música]", "[musique]", "[musik]",
        "(musica)", "(música)", "(musique)", "(musik)",
    )
    if any(marker in compact for marker in markers):
        return True
    if compact and set(compact) <= {"♪", "♫"}:
        return True
    return compact in {"音楽", "拍手", "music", "applause", "musica", "música", "musique", "musik"}


def remove_parenthetical_latin_glosses(text: str) -> str:
    if not CJK_RE.search(text):
        return text

    def replace(match: re.Match[str]) -> str:
        inner = match.group(1)
        if LATIN_RE.search(inner) and not CJK_RE.search(inner):
            return ""
        return match.group(0)

    return PARENTHETICAL_RE.sub(replace, text)


def _is_suspicious_romanized_loop_token(token: str) -> bool:
    return (
        2 <= len(token) <= 6
        and token.isascii()
        and token.isalpha()
        and ROMANIZED_VOWEL_RE.search(token) is not None
        and token not in SAFE_LATIN_TOKENS
    )


def translated_quality_issues(cues: Sequence[Cue], *, target_language_code: Optional[str] = None) -> List[str]:
    if not cues:
        return ["missingTranslation"]
    issues: List[str] = []
    texts = [cue.text.strip() for cue in cues if cue.text.strip()]
    latin_garbage = sum(1 for text in texts if re.fullmatch(r"(?:[A-Za-z]{1,8}\s*){1,4}", text))
    romanized_leaks = sum(1 for text in texts if ROMANIZED_GARBAGE_LEAK_RE.search(text))
    if texts and (latin_garbage / len(texts) >= 0.10 or romanized_leaks / len(texts) >= 0.05):
        issues.append("romanizedGarbageLeak")
    adjacent_repeats = 0
    for prev, cur in zip(texts, texts[1:]):
        if prev and prev == cur:
            adjacent_repeats += 1
    if len(texts) > 1 and adjacent_repeats / (len(texts) - 1) >= 0.20:
        issues.append("repeatedTranslation")
    return issues


def final_source_quality_issues(
    cues: Sequence[Cue],
    *,
    preview_seconds: float,
    category: str,
    source_language_code: Optional[str] = None,
) -> List[str]:
    if not cues:
        return []
    issues: List[str] = []
    last_end = max(cue.end for cue in cues)
    music_like = any(token in category.lower() for token in ["music", "song", "jpop", "mv", "live"])
    if not music_like and preview_seconds >= 30 and last_end + 3.0 < preview_seconds:
        issues.append(f"finalSourceCoverageShortfall:{last_end:.1f}s/{preview_seconds:.1f}s")

    if music_like:
        final_report = source_quality_report(
            cues,
            requested_language_code=source_language_code,
            subtitle_language_code=source_language_code,
        )
        for reason in final_report.reasons:
            if reason != "tooFewCues":
                issues.append(f"finalSource{reason[0].upper()}{reason[1:]}")

        if has_lyric_filler_loop(cues, preview_seconds=preview_seconds):
            issues.append("lyricFillerLoop")

        for cue in cues:
            if cue.start > preview_seconds:
                break
            text = _normalized_cue_text(cue.text)
            duration = cue.end - cue.start
            visible = _visible_scalar_count(text)
            if visible <= 2 and duration < 0.65:
                issues.append(f"flashShortCue:{cue.index}:{duration:.1f}s")
                break
            if visible <= 2 and duration >= 2.5:
                issues.append(f"longShortCueHold:{cue.index}:{duration:.1f}s")
                break
        weak_boundaries = weak_boundary_candidates(
            preview_rows(cues, [], preview_seconds=preview_seconds),
            language_code=source_language_code,
        )
        if weak_boundaries:
            issues.append(f"weakBoundarySplit:{weak_boundaries[0]['cue']}:{weak_boundaries[0]['type']}")
    return issues


def has_lyric_filler_loop(cues: Sequence[Cue], *, preview_seconds: float) -> bool:
    index = 0
    while index < len(cues):
        cue = cues[index]
        if cue.start > preview_seconds:
            return False
        if not is_lyric_filler_cue(cue.text):
            index += 1
            continue
        end = index + 1
        filler_count = lyric_filler_stats(cue.text)[1]
        while end < len(cues):
            next_cue = cues[end]
            if next_cue.start > preview_seconds:
                break
            if next_cue.start - cues[end - 1].end > LYRIC_FILLER_LOOP_MAX_GAP_SECONDS:
                break
            if not is_lyric_filler_cue(next_cue.text):
                break
            filler_count += lyric_filler_stats(next_cue.text)[1]
            end += 1
        duration = cues[end - 1].end - cues[index].start
        if (
            duration >= LYRIC_FILLER_LOOP_MIN_DURATION_SECONDS
            and filler_count >= LYRIC_FILLER_LOOP_MIN_TOKEN_COUNT
        ) or filler_count >= LYRIC_FILLER_LOOP_HIGH_TOKEN_COUNT:
            return True
        index = end
    return False


def is_lyric_filler_cue(text: str) -> bool:
    token_count, filler_count, has_outro = lyric_filler_stats(text)
    if has_outro:
        return True
    if token_count > 0 and filler_count == token_count:
        return True
    return (
        token_count >= LYRIC_FILLER_CUE_MIN_TOKEN_COUNT
        and filler_count / token_count >= LYRIC_FILLER_CUE_MIN_RATIO
    )


def lyric_filler_stats(text: str) -> tuple[int, int, bool]:
    tokens = [token.lower() for token in LATIN_RE.findall(text)]
    filler_count = sum(1 for token in tokens if token in LYRIC_FILLER_LOOP_TOKENS)
    return len(tokens), filler_count, LYRIC_OUTRO_BOILERPLATE_RE.search(text) is not None


def build_pipeline_advice(
    *,
    sample: Dict[str, Any],
    report: ViewingSampleReport,
    source_needed_fallback: bool,
    local_asr_attempted: bool,
    local_asr_available: bool,
) -> Dict[str, Any]:
    language = normalized_language_code(sample.get("language"))
    category = str(sample.get("category") or "")
    music_like = any(token in category.lower() for token in ["music", "song", "jpop", "mv", "live"])
    anime_like = "anime" in category.lower() or "animation" in category.lower()
    if music_like:
        preset = "songLyrics"
    elif anime_like:
        preset = "anime"
    else:
        preset = "general"
    if music_like and language == "ja":
        timing_profile = "japaneseLyrics"
    elif music_like:
        timing_profile = "lyrics"
    elif anime_like:
        timing_profile = "anime"
    else:
        timing_profile = "speech"

    if report.final_source_kind == "missing":
        source_assessment = "missing"
    elif report.fallback_used or source_needed_fallback:
        source_assessment = "bad"
    elif report.source_quality.usable:
        source_assessment = "usable"
    else:
        source_assessment = "unknown"

    if report.fallback_used:
        action = "useLocalASR"
    elif source_needed_fallback and local_asr_attempted and not local_asr_available:
        action = "failWithNote"
    elif source_needed_fallback:
        action = "useLocalASR"
    else:
        action = "keepPlatform"

    risks = list(report.source_quality.reasons)
    if music_like:
        risks.append("lyricsContext")
    if report.source_quality.romanized_loop_token_count > 0:
        risks.append("romajiLoop")

    return {
        "summary": f"{sample.get('title', report.title)} subtitle pipeline plan",
        "context": f"category={category}; finalSource={report.final_source_kind}",
        "sourceLanguageCode": language or "unknown",
        "preset": preset,
        "terms": [],
        "characters": [],
        "translationNotes": ["先通读上下文再逐编号翻译"] if preset == "songLyrics" else [],
        "sourceAssessment": source_assessment,
        "recommendedSourceAction": action,
        "timingProfile": timing_profile,
        "asrHints": {
            "disablePromptContext": music_like and language in {"ja", "zh", "yue", "ko"},
            "preferVAD": music_like or report.fallback_used,
            "suppressIntroHallucination": music_like and language == "ja",
        },
        "qualityRisks": sorted(set(risks)),
    }


def build_source_candidate_reports(report: ViewingSampleReport) -> List[Dict[str, Any]]:
    platform_available = report.source_path is not None
    local_available = report.local_asr_path is not None
    platform_usable = platform_available and report.source_quality.usable
    local_reasons: List[str]
    if local_available:
        local_reasons = []
        if report.local_asr_quality is not None:
            local_reasons.extend(report.local_asr_quality.reasons)
        local_reasons.extend(report.local_asr_issues)
    else:
        local_reasons = ["unavailable"]
    local_usable = (
        local_available
        and report.local_asr_quality is not None
        and report.local_asr_quality.usable
        and not report.local_asr_issues
    )
    return [
        {
            "kind": "platform",
            "available": platform_available,
            "selected": report.final_source_kind == "platform",
            "usable": platform_usable,
            "reasons": list(report.source_quality.reasons) if platform_available else ["missing"],
            "path": report.source_path,
            "quality": asdict(report.source_quality) if platform_available else None,
        },
        {
            "kind": "local-asr",
            "available": local_available,
            "selected": report.final_source_kind == "local-asr",
            "usable": local_usable,
            "reasons": local_reasons,
            "path": report.local_asr_path,
            "quality": asdict(report.local_asr_quality) if report.local_asr_quality is not None else None,
        },
    ]


def build_quality_judge(report: ViewingSampleReport) -> Dict[str, Any]:
    issues: List[Dict[str, Any]] = []
    if report.final_source_kind == "missing":
        issues.append({
            "type": "missingSource",
            "reason": "No platform or local-ASR source was available.",
        })
    if not report.fallback_used:
        for reason in report.source_quality.reasons:
            issues.append({
                "type": "badPlatformSource",
                "reason": reason,
            })
    for reason in report.final_source_issues:
        issues.append({
            "type": "finalSourceQuality",
            "reason": reason,
        })
    for reason in report.translated_issues:
        issues.append({
            "type": "translatedQuality",
            "reason": reason,
        })
    return {
        "pass": not issues,
        "blockingIssues": issues,
        "suggestedAction": "accept" if not issues else "reviewOrRetry",
    }


def build_quality_judge_prompt(report: ViewingSampleReport) -> str:
    candidates = weak_boundary_candidates(report.preview_rows, language_code=report.source_language_code)
    rows = "\n".join(
        f"{row['index']}. {row['start']:.2f}-{row['end']:.2f} | source={row['source']} | translated={row['translated']}"
        for row in report.preview_rows[:40]
    )
    candidate_lines = "\n".join(
        f"- cue {candidate['cue']}: {candidate['type']} - {candidate['reason']}"
        for candidate in candidates[:12]
    ) or "- none"
    return (
        "你是 Moongate 字幕观看质量评审。只判断用户最终会看到的字幕是否可读、可理解。\n"
        "请特别检查：错源、乱码/罗马音泄漏、歌词断词、字幕明显早/晚、重复字幕、译文不连贯、编号/行数错乱。\n"
        "如果只是 ASR 个别字听错但不影响理解，标为 minor；如果会阻断理解，标为 blocking。\n"
        "只输出 JSON：{\"pass\": boolean, \"blockingIssues\": [{\"type\": string, \"reason\": string, \"cue\": number}], "
        "\"minorIssues\": [{\"type\": string, \"reason\": string, \"cue\": number}], \"suggestedAction\": string}。\n\n"
        f"sample_id: {report.sample_id}\n"
        f"title: {report.title}\n"
        f"category: {report.category}\n"
        f"final_source_kind: {report.final_source_kind}\n"
        f"fallback_used: {report.fallback_used}\n"
        f"source_language_code: {report.source_language_code}\n"
        f"platform_source_quality_reasons: {report.source_quality.reasons}\n"
        f"final_source_issues: {report.final_source_issues}\n"
        f"translated_issues: {report.translated_issues}\n\n"
        "deterministic_candidate_issues:\n"
        f"{candidate_lines}\n\n"
        "preview:\n"
        f"{rows}\n"
    )


def build_agent_translation_prompt(
    report: ViewingSampleReport,
    *,
    target_language_code: str = "zh-Hans",
    max_rows: int = 40,
) -> str:
    rows = "\n".join(
        f"{row['index']}. {row['start']:.2f}-{row['end']:.2f} | {row['source']}"
        for row in report.preview_rows[:max_rows]
    )
    if not rows:
        rows = "(no usable source cues)"
    style = _agent_translation_style(report.category)
    return (
        "你是 Moongate 的云端 LLM 翻译层模拟器。请把下面的最终源字幕翻译成目标语言，用于端到端质量评测。\n"
        "重要约束：\n"
        "- 只翻译，不改编号，不改时间轴，不新增或删除 cue。\n"
        "- 先通读所有 cue，再逐编号输出；不要被坏断句牵着逐字硬翻。\n"
        "- 如果源文疑似 ASR 乱码、罗马音泄漏、重复幻觉或语义不可恢复，请在 inputIssues 标出，并给出尽量保守可理解的译文；无法可靠翻译时译文留空字符串。\n"
        "- 不要输出 API key、路径以外的本机隐私信息、解释性长文或 Markdown。\n"
        "- 只输出 JSON，schema 固定为："
        "{\"sample_id\": string, \"target_language_code\": string, "
        "\"translations\": [{\"index\": number, \"text\": string}], "
        "\"inputIssues\": [{\"index\": number, \"reason\": string}], "
        "\"notes\": [string]}。\n\n"
        f"sample_id: {report.sample_id}\n"
        f"title: {report.title}\n"
        f"category: {report.category}\n"
        f"source_language_code: {report.source_language_code}\n"
        f"target_language_code: {target_language_code}\n"
        f"final_source_kind: {report.final_source_kind}\n"
        f"known_source_issues: {report.final_source_issues}\n"
        f"style_guidance: {style}\n\n"
        "source_cues:\n"
        f"{rows}\n"
    )


def _agent_translation_style(category: str) -> str:
    low = category.lower()
    if any(token in low for token in ["music", "song", "jpop", "mv", "live"]):
        return "歌词翻译：保留意象、情绪和节奏；中文要自然、有诗意，但不要编造原文没有的剧情。"
    if "anime" in low or "animation" in low:
        return "动漫对白：保留角色口吻、称呼、语气词和短反馈节奏；中文要像自然对白。"
    if any(token in low for token in ["lecture", "tutorial", "news", "documentary"]):
        return "信息类视频：术语、数字、因果关系优先；中文要专业、清楚、克制。"
    if any(token in low for token in ["vlog", "interview", "talk"]):
        return "口语视频：保留真实交流感和上下文承接；中文自然，不要改成书面稿。"
    return "通用视频：准确、自然、保守使用上下文。"


def weak_boundary_candidates(rows: Sequence[Dict[str, Any]], *, language_code: Optional[str] = None) -> List[Dict[str, Any]]:
    language = normalized_language_code(language_code)
    if language not in {"ja", "zh", "yue", "ko"}:
        return []
    candidates: List[Dict[str, Any]] = []
    for current, next_row in zip(rows, rows[1:]):
        source = str(current.get("source") or "").strip()
        next_source = str(next_row.get("source") or "").strip()
        if not source or not next_source:
            continue
        if language == "zh":
            if source.endswith(CHINESE_DANGLING_FUNCTION_WORDS) and HAN_START_RE.search(next_source):
                candidates.append({
                    "cue": current.get("index"),
                    "type": "danglingChineseFunctionWord",
                    "reason": f"{source[-min(8, len(source)):]} / {next_source[:min(8, len(next_source))]}",
                })
            continue
        if language == "yue":
            if source.endswith(CANTONESE_DANGLING_PARTICLES) and HAN_START_RE.search(next_source):
                candidates.append({
                    "cue": current.get("index"),
                    "type": "danglingCantoneseParticle",
                    "reason": f"{source[-min(8, len(source)):]} / {next_source[:min(8, len(next_source))]}",
                })
            continue
        if language == "ko":
            if source.endswith(KOREAN_DANGLING_PARTICLES) and HANGUL_START_RE.search(next_source):
                candidates.append({
                    "cue": current.get("index"),
                    "type": "danglingKoreanParticle",
                    "reason": f"{source[-min(8, len(source)):]} / {next_source[:min(8, len(next_source))]}",
                })
            continue
        for ending in JAPANESE_WEAK_ADJECTIVE_ENDINGS:
            if source.endswith(ending) and any(next_source.startswith(start) for start in JAPANESE_WEAK_ADJECTIVE_CONTINUATIONS):
                candidates.append({
                    "cue": current.get("index"),
                    "type": "adjectiveContinuation",
                    "reason": f"{source[-min(8, len(source)):]} / {next_source[:min(8, len(next_source))]}",
                })
                break
        else:
            # 行尾悬空宾格/主格助词：源把绑定到后续谓语的助词甩成了行尾（半句）。
            if source.endswith(JAPANESE_DANGLING_CASE_PARTICLES):
                candidates.append({
                    "cue": current.get("index"),
                    "type": "danglingCaseParticle",
                    "reason": f"{source[-min(8, len(source)):]} / {next_source[:min(8, len(next_source))]}",
                })
    return candidates


def build_viewing_sample_report(
    *,
    sample_id: str,
    title: str,
    category: str,
    source_path: Optional[Path],
    local_asr_path: Optional[Path] = None,
    translated_path: Optional[Path],
    source_language_code: Optional[str],
    target_language_code: Optional[str],
    preview_seconds: float = 180.0,
    translation_attempted: bool = False,
) -> ViewingSampleReport:
    source_path = _existing_path(source_path)
    local_asr_path = _existing_path(local_asr_path)
    translated_path = _existing_path(translated_path)
    source_cues = load_subtitle_cues(source_path) if source_path else []
    local_asr_cues = load_subtitle_cues(local_asr_path) if local_asr_path else []
    translated_cues = load_subtitle_cues(translated_path) if translated_path else []
    source_report = source_quality_report(
        source_cues,
        requested_language_code=source_language_code,
        subtitle_language_code=source_language_code,
    )
    local_asr_report = (
        source_quality_report(
            local_asr_cues,
            requested_language_code=source_language_code,
            subtitle_language_code=source_language_code,
        )
        if local_asr_path else None
    )
    local_asr_issues = (
        final_source_quality_issues(
            local_asr_cues,
            preview_seconds=preview_seconds,
            category=category,
            source_language_code=source_language_code,
        )
        if local_asr_path else []
    )
    fallback_used = bool(local_asr_path and local_asr_cues and not source_report.usable)
    if fallback_used:
        final_source_path = local_asr_path
        final_source_kind = "local-asr"
        final_cues = local_asr_cues
    elif source_path and source_cues:
        final_source_path = source_path
        final_source_kind = "platform"
        final_cues = source_cues
    else:
        final_source_path = None
        final_source_kind = "missing"
        final_cues = []
    final_source_issues = final_source_quality_issues(
        final_cues,
        preview_seconds=preview_seconds,
        category=category,
        source_language_code=source_language_code,
    )
    translated_issues = (
        translated_quality_issues(translated_cues, target_language_code=target_language_code)
        if translated_path or translation_attempted else []
    )
    rows = preview_rows(final_cues, translated_cues, preview_seconds=preview_seconds)
    return ViewingSampleReport(
        sample_id=sample_id,
        title=title,
        category=category,
        source_language_code=normalized_language_code(source_language_code) or "unknown",
        source_path=str(source_path) if source_path else None,
        local_asr_path=str(local_asr_path) if local_asr_path else None,
        final_source_path=str(final_source_path) if final_source_path else None,
        final_source_kind=final_source_kind,
        fallback_used=fallback_used,
        translated_path=str(translated_path) if translated_path else None,
        source_quality=source_report,
        local_asr_quality=local_asr_report,
        local_asr_issues=local_asr_issues,
        final_source_issues=final_source_issues,
        translated_issues=translated_issues,
        preview_rows=rows,
    )


def preview_rows(source_cues: Sequence[Cue], translated_cues: Sequence[Cue], *, preview_seconds: float) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for index, source in enumerate(source_cues):
        if source.start > preview_seconds:
            break
        translated = translated_cues[index].text if index < len(translated_cues) else ""
        rows.append({
            "index": source.index,
            "start": source.start,
            "end": source.end,
            "source": source.text,
            "translated": translated,
        })
        if len(rows) >= 40:
            break
    return rows


def _existing_path(path: Optional[Path]) -> Optional[Path]:
    return path if path and path.is_file() else None


def _visible_scalar_count(text: str) -> int:
    return sum(1 for ch in text if not ch.isspace())


def _normalized_cue_text(text: str) -> str:
    return re.sub(r"\s+", "", text.strip())


def render_human_review(reports: Iterable[ViewingSampleReport]) -> str:
    lines = ["# Viewing Quality Review", ""]
    for report in reports:
        status = "BLOCKED" if report.blocking_issue_count else "OK"
        lines.append(f"## {report.sample_id} · {status}")
        lines.append(f"- title: {report.title}")
        lines.append(f"- category: {report.category}")
        lines.append(f"- platform_source: {report.source_path or 'missing'}")
        lines.append(f"- local_asr_source: {report.local_asr_path or 'missing'}")
        lines.append(f"- final_source: {report.final_source_path or 'missing'} ({report.final_source_kind})")
        lines.append(f"- translated: {report.translated_path or 'missing'}")
        lines.append(f"- platform_source_quality: {report.source_quality.reasons or ['usable']}")
        if report.final_source_issues:
            lines.append(f"- final_source_issues: {report.final_source_issues}")
        if report.fallback_used:
            lines.append("- fallback: local-ASR")
        if report.translated_issues:
            lines.append(f"- translated_issues: {report.translated_issues}")
        lines.append("")
        lines.append("| # | time | source | translated |")
        lines.append("|---:|---|---|---|")
        for row in report.preview_rows:
            source = _md_cell(str(row["source"]))
            translated = _md_cell(str(row["translated"]))
            lines.append(f"| {row['index']} | {row['start']:.2f}-{row['end']:.2f} | {source} | {translated} |")
        lines.append("")
    return "\n".join(lines) + "\n"


def report_to_jsonable(report: ViewingSampleReport) -> Dict[str, Any]:
    data = asdict(report)
    data["source_quality"] = asdict(report.source_quality)
    return data


def _md_cell(value: str) -> str:
    return value.replace("\n", "<br>").replace("|", "\\|")
