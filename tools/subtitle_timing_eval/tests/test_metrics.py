import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from subtitle_timing_eval import pipeline
from subtitle_timing_eval.asr import parse_whisper_cpp_words, whisper_cpp_language
from subtitle_timing_eval.cli import main as cli_main
from subtitle_timing_eval.comparison import compare_reports, summarize_suite
from subtitle_timing_eval.metrics import cue_tokens, evaluate_cues, evaluate_cues_against_reference_cues, offset_words, summarize_report, weak_boundary
from subtitle_timing_eval.pipeline import (
    audit_manual_caption_suite,
    build_auto_reference_qa_records,
    build_completion_audit,
    build_prepare_commands,
    build_iteration_report,
    build_qa_packet,
    build_suite_runbook,
    build_translation_timing_proxy_srt,
    collect_eval_status,
    collect_manual_suite_status,
    extract_srt_words,
    extract_vtt_words,
    evaluate_reference_files,
    filter_cues_by_window,
    materialize_existing_comparisons,
    render_qa_checklist_markdown,
    render_qa_remaining_queue_markdown,
    render_qa_review_html,
    render_qa_markdown,
    select_manual_caption_suite,
    summarize_qa_verdicts,
    validate_manifest,
)
from subtitle_timing_eval.srt import Cue, parse_srt
from subtitle_timing_eval.vad import detect_speech_segments_from_samples
from subtitle_timing_eval.vtt import parse_vtt_cues, parse_vtt_word_timestamps


class AsrParsingTests(unittest.TestCase):
    def test_parse_whisper_cpp_words_uses_token_offsets_and_filters_markers(self):
        root = {
            "result": {"language": "ja"},
            "transcription": [
                {
                    "offsets": {"from": 0, "to": 1500},
                    "text": "コーペンちゃん 梅",
                    "tokens": [
                        {"text": "[_BEG_]", "offsets": {"from": 0, "to": 0}, "p": 0.9},
                        {"text": "コーペンちゃん", "offsets": {"from": 100, "to": 900}, "p": 0.8},
                        {"text": "[_TT_100]", "offsets": {"from": 900, "to": 900}, "p": 0.2},
                        {"text": "梅", "offsets": {"from": 950, "to": 1300}, "p": 0.7},
                    ],
                }
            ],
        }

        words = parse_whisper_cpp_words(root)

        self.assertEqual([word["text"] for word in words], ["コーペンちゃん", "梅"])
        self.assertAlmostEqual(words[0]["start"], 0.1, places=3)
        self.assertAlmostEqual(words[0]["end"], 0.9, places=3)
        self.assertEqual(words[0]["probability"], 0.8)
        self.assertEqual(whisper_cpp_language(root, "auto"), "ja")

    def test_parse_whisper_cpp_words_falls_back_to_segment_text(self):
        root = {
            "params": {"language": "en"},
            "transcription": [
                {
                    "timestamps": {"from": "00:00:02,500", "to": "00:00:03,750"},
                    "text": "Hello there.",
                    "tokens": [],
                }
            ],
        }

        words = parse_whisper_cpp_words(root)

        self.assertEqual(words, [{"start": 2.5, "end": 3.75, "text": "Hello there."}])
        self.assertEqual(whisper_cpp_language(root, None), "en")


class SrtParsingTests(unittest.TestCase):
    def test_parse_srt_handles_comma_and_dot_milliseconds(self):
        cues = parse_srt(
            "\ufeff1\r\n"
            "00:00:01,000 --> 00:00:02.500\r\n"
            "Hello there.\r\n\r\n"
            "00:00:03.000 --> 00:00:04,250\r\n"
            "Bye now.\r\n"
        )

        self.assertEqual(len(cues), 2)
        self.assertEqual(cues[0].start, 1.0)
        self.assertEqual(cues[0].end, 2.5)
        self.assertEqual(cues[1].index, 2)
        self.assertEqual(cues[1].text, "Bye now.")


class VttParsingTests(unittest.TestCase):
    def test_parse_vtt_word_timestamps_extracts_youtube_inline_tokens(self):
        words = parse_vtt_word_timestamps(
            "WEBVTT\n\n"
            "00:00:01.000 --> 00:00:03.000\n"
            "<00:00:01.120><c>Hello</c> <00:00:01.720><c>there</c> <00:00:02.400><c>friend</c>\n"
        )

        self.assertEqual([w.text for w in words], ["Hello", "there", "friend"])
        self.assertAlmostEqual(words[0].start, 1.120, places=3)
        self.assertAlmostEqual(words[0].end, 1.720, places=3)
        self.assertAlmostEqual(words[-1].end, 3.000, places=3)

    def test_parse_vtt_word_timestamps_keeps_new_leading_text_after_rolling_prefix(self):
        words = parse_vtt_word_timestamps(
            "WEBVTT\n\n"
            "00:01:53.079 --> 00:01:56.310\n"
            "qui sont des pommes Royal Gala au même\n"
            "prix.<00:01:54.159><c> Ici,</c><00:01:54.799><c> il</c><00:01:55.000><c> y</c>"
            "<00:01:55.079><c> a</c><00:01:55.360><c> trois</c><00:01:55.719><c> sortes</c><00:01:56.119><c> de</c>\n\n"
            "00:01:56.320 --> 00:01:59.190\n"
            "prix. Ici, il y a trois sortes de\n"
            "poivrons.<00:01:57.360><c> Des</c><00:01:57.520><c> poivrons</c>\n"
        )

        texts = [word.text for word in words]
        self.assertIn("poivrons.", texts)
        new_word = words[texts.index("poivrons.")]
        self.assertAlmostEqual(new_word.start, 116.320, places=3)
        self.assertAlmostEqual(new_word.end, 117.360, places=3)
        self.assertEqual(texts.count("Ici,"), 1)

    def test_parse_vtt_word_timestamps_keeps_repeated_lyrics_after_gap(self):
        words = parse_vtt_word_timestamps(
            "WEBVTT\n\n"
            "00:01:59.840 --> 00:02:02.960\n"
            "♪ (Ooh, give you up) ♪\n\n"
            "00:02:03.720 --> 00:02:07.360\n"
            "♪ (Ooh, give you up) ♪\n"
        )

        texts = [word.text for word in words]
        self.assertEqual(texts.count("(Ooh,"), 2)
        second = [word for word in words if word.text == "(Ooh,"][1]
        self.assertGreaterEqual(second.start, 123.720)
        self.assertLess(second.start, 127.360)

    def test_parse_vtt_word_timestamps_drops_full_duplicate_transition_cue(self):
        words = parse_vtt_word_timestamps(
            "WEBVTT\n\n"
            "00:00:01.000 --> 00:00:02.000\n"
            "Hello there\n\n"
            "00:00:02.000 --> 00:00:02.010\n"
            "Hello there\n"
        )

        self.assertEqual([word.text for word in words], ["Hello", "there"])


class TokenizationTests(unittest.TestCase):
    def test_cue_tokens_keep_currency_symbols_for_timing(self):
        self.assertEqual(cue_tokens("3 € 4,99€."), ["3", "€", "4", "99", "€"])

    def test_parse_vtt_word_timestamps_distributes_cues_without_inline_markers(self):
        words = parse_vtt_word_timestamps(
            "WEBVTT\n\n"
            "00:00:00.160 --> 00:00:01.350\n"
            "안녕하세요\n\n"
            "00:00:01.350 --> 00:00:01.360\n"
            "안녕하세요\n\n"
            "00:00:01.360 --> 00:00:03.360\n"
            "안녕하세요\n"
            "보세요\n"
        )

        self.assertEqual([w.text for w in words], ["안녕하세요", "보세요"])
        self.assertAlmostEqual(words[0].start, 0.160, places=3)
        self.assertAlmostEqual(words[0].end, 1.350, places=3)
        self.assertAlmostEqual(words[1].start, 1.360, places=3)
        self.assertAlmostEqual(words[1].end, 3.360, places=3)

    def test_parse_vtt_word_timestamps_keeps_body_after_leading_blank_line(self):
        raw = (
            "WEBVTT\n\n"
            "00:00:00.000 --> 00:00:02.670 align:start position:0%\n"
            " \n"
            "당김<00:00:00.359><c> 정상들이</c><00:00:01.460><c> cool</c>\n\n"
            "00:00:02.670 --> 00:00:02.680 align:start position:0%\n"
            "당김 정상들이 cool\n"
        )

        cues = parse_vtt_cues(raw)
        words = parse_vtt_word_timestamps(raw)

        self.assertEqual(cues[0].text, "당김 정상들이 cool")
        self.assertEqual([w.text for w in words[:3]], ["당김", "정상들이", "cool"])
        self.assertAlmostEqual(words[0].start, 0.000, places=3)
        self.assertAlmostEqual(words[0].end, 0.359, places=3)
        self.assertAlmostEqual(words[1].start, 0.359, places=3)
        self.assertAlmostEqual(words[2].end, 2.670, places=3)

    def test_parse_vtt_word_timestamps_caps_untimed_long_idle_hold(self):
        words = parse_vtt_word_timestamps(
            "WEBVTT\n\n"
            "00:01:08.299 --> 00:01:22.830 align:start position:0%\n"
            "미 거죠 사줘서 수업 총력 또 자꾸\n"
            "줍니다\n\n"
        )

        self.assertEqual([word.text for word in words], ["미", "거죠", "사줘서", "수업", "총력", "또", "자꾸", "줍니다"])
        self.assertAlmostEqual(words[0].start, 68.299, places=3)
        self.assertAlmostEqual(words[-1].end, 78.699, places=3)

    def test_parse_vtt_word_timestamps_keeps_no_space_cjk_cue_duration(self):
        words = parse_vtt_word_timestamps(
            "WEBVTT\n\n"
            "00:02:50.176 --> 00:02:53.856\n"
            "希望我哋都有一個好好用嘅廣東話嘅字幕軟件嘅\n\n"
        )

        self.assertGreater(len(words), 10)
        self.assertAlmostEqual(words[0].start, 170.176, places=3)
        self.assertAlmostEqual(words[-1].end, 173.856, places=3)

    def test_parse_vtt_word_timestamps_caps_final_inline_word_hold(self):
        words = parse_vtt_word_timestamps(
            "WEBVTT\n\n"
            "00:01:22.840 --> 00:01:29.090 align:start position:0%\n"
            "으<00:01:24.240><c> 으</c><00:01:25.240><c> 아</c>\n"
        )

        self.assertEqual([word.text for word in words], ["으", "으", "아"])
        self.assertAlmostEqual(words[-1].start, 85.240, places=3)
        self.assertAlmostEqual(words[-1].end, 86.540, places=3)

    def test_parse_vtt_cues_strips_inline_timestamp_markup(self):
        cues = parse_vtt_cues(
            "WEBVTT\n\n"
            "00:00:01.000 --> 00:00:03.000\n"
            "<00:00:01.120><c>Hello</c> <00:00:01.720><c>there</c>\n"
        )

        self.assertEqual(len(cues), 1)
        self.assertEqual(cues[0].text, "Hello there")


class TimingMetricTests(unittest.TestCase):
    def test_evaluate_cues_reports_start_end_errors_and_acceptance(self):
        cues = [
            Cue(index=1, start=0.80, end=2.95, text="Hello there"),
            Cue(index=2, start=4.70, end=6.35, text="Copy."),
        ]
        words = [
            {"start": 1.00, "end": 1.45, "text": "Hello"},
            {"start": 1.50, "end": 2.00, "text": "there"},
            {"start": 5.00, "end": 5.50, "text": "Copy"},
        ]

        report = evaluate_cues(cues, words, sample_id="unit")
        rows = report["cues"]

        self.assertAlmostEqual(rows[0]["start_error_ms"], -200.0, places=1)
        self.assertAlmostEqual(rows[0]["end_error_ms"], 950.0, places=1)
        self.assertFalse(rows[0]["accepted"])
        self.assertAlmostEqual(rows[1]["late_hold_ms"], 850.0, places=1)
        self.assertTrue(rows[1]["short_feedback"])

    def test_summarize_report_counts_weak_boundaries_and_cjk_singletons(self):
        cues = [
            Cue(index=1, start=0.00, end=1.00, text="This is the"),
            Cue(index=2, start=1.00, end=2.00, text="thing we need."),
            Cue(index=3, start=2.20, end=3.00, text="你"),
        ]
        words = [
            {"start": 0.10, "end": 0.20, "text": "This"},
            {"start": 0.22, "end": 0.32, "text": "is"},
            {"start": 0.35, "end": 0.45, "text": "the"},
            {"start": 1.05, "end": 1.30, "text": "thing"},
            {"start": 1.32, "end": 1.50, "text": "we"},
            {"start": 1.55, "end": 1.80, "text": "need"},
            {"start": 2.25, "end": 2.45, "text": "你"},
        ]

        summary = summarize_report(evaluate_cues(cues, words, sample_id="weak"))

        self.assertEqual(summary["weak_boundary_count"], 1)
        self.assertEqual(summary["cjk_singleton_count"], 1)

    def test_evaluate_cues_fuzzy_matches_vtt_words_with_missing_function_tokens(self):
        cues = [
            Cue(index=1, start=41.12, end=43.10, text="All right, test all B19 operators."),
        ]
        words = [
            {"start": 41.44, "end": 41.68, "text": "test"},
            {"start": 41.68, "end": 41.92, "text": "all"},
            {"start": 41.92, "end": 42.40, "text": "B19"},
            {"start": 42.40, "end": 42.88, "text": "operators."},
        ]

        report = evaluate_cues(cues, words, sample_id="fuzzy")

        self.assertEqual(report["cues"][0]["match_method"], "text")
        self.assertTrue(report["cues"][0]["accepted"])

    def test_evaluate_cues_matches_joined_latin_words_to_asr_fragments(self):
        cues = [
            Cue(index=1, start=76.56, end=80.20, text="Quando a palestra não é dada em inglês como é o caso"),
        ]
        words = [
            {"start": 76.36, "end": 76.70, "text": "Quando"},
            {"start": 76.70, "end": 76.82, "text": "a"},
            {"start": 76.82, "end": 77.05, "text": "pal"},
            {"start": 77.05, "end": 77.35, "text": "estra"},
            {"start": 77.35, "end": 77.58, "text": "não"},
            {"start": 77.58, "end": 77.70, "text": "é"},
            {"start": 77.70, "end": 77.82, "text": "d"},
            {"start": 77.82, "end": 78.00, "text": "ada"},
            {"start": 78.00, "end": 78.10, "text": "em"},
            {"start": 78.10, "end": 78.34, "text": "ingl"},
            {"start": 78.34, "end": 78.58, "text": "ês"},
            {"start": 78.58, "end": 78.80, "text": "como"},
            {"start": 78.80, "end": 78.92, "text": "é"},
            {"start": 78.92, "end": 79.05, "text": "o"},
            {"start": 79.05, "end": 79.35, "text": "caso"},
        ]

        report = evaluate_cues(cues, words, sample_id="latin_joined_fragments")
        row = report["cues"][0]

        self.assertEqual(cue_tokens("inglês"), ["inglês"])
        self.assertEqual(row["match_method"], "text")
        self.assertAlmostEqual(row["reference_start"], 76.36, places=2)
        self.assertAlmostEqual(row["reference_end"], 79.35, places=2)
        self.assertTrue(row["accepted"])

    def test_evaluate_cues_text_matches_cjk_words_with_multi_character_chunks(self):
        cues = [
            Cue(index=1, start=10.00, end=11.90, text="日本行きたい"),
        ]
        words = [
            {"start": 10.02, "end": 10.30, "text": "日本"},
            {"start": 10.30, "end": 10.72, "text": "行き"},
            {"start": 10.72, "end": 11.10, "text": "たい"},
        ]

        report = evaluate_cues(cues, words, sample_id="cjk")

        self.assertEqual(report["cues"][0]["match_method"], "text")
        self.assertTrue(report["cues"][0]["accepted"])

    def test_evaluate_cues_keeps_cjk_tokens_when_digits_are_present(self):
        cues = [
            Cue(index=1, start=4.36, end=10.90, text="엄합니다 5점 1점 진짜 점"),
        ]
        words = [
            {"start": 4.359, "end": 6.15, "text": "엄합니다"},
            {"start": 6.16, "end": 7.16, "text": "5점"},
            {"start": 7.16, "end": 8.40, "text": "1점"},
            {"start": 8.40, "end": 9.40, "text": "진짜"},
            {"start": 9.40, "end": 10.90, "text": "점"},
        ]

        report = evaluate_cues(cues, words, sample_id="ko_digits")

        row = report["cues"][0]
        self.assertEqual(row["match_method"], "text")
        self.assertAlmostEqual(row["reference_start"], 4.359, places=3)
        self.assertAlmostEqual(row["reference_end"], 10.90, places=3)
        self.assertTrue(row["accepted"])

    def test_evaluate_cues_excludes_parenthetical_visual_annotations_from_speech_gate(self):
        cues = [
            Cue(index=1, start=90.30, end=94.00, text="(前方測速照相速限40公里)"),
            Cue(index=2, start=96.80, end=103.80, text="然後通常臺灣的車都有這個護身符"),
        ]
        words = [
            {"start": 92.71, "end": 94.13, "text": "前方測速照相速限40公里"},
            {"start": 96.75, "end": 102.96, "text": "然後通常臺灣的車都有這個護身符"},
        ]

        report = evaluate_cues(cues, words, sample_id="visual_annotation")
        summary = summarize_report(report)

        self.assertEqual(report["cues"][0]["excluded_reason"], "visual_annotation")
        self.assertIsNone(report["cues"][0]["start_error_ms"])
        self.assertEqual(summary["matched_cue_count"], 1)
        self.assertEqual(summary["accepted_cue_count"], 1)
        self.assertEqual(summary["accepted_ratio"], 1.0)

    def test_evaluate_cues_cjk_partial_match_estimates_missing_leading_tokens(self):
        cues = [
            Cue(index=1, start=75.90, end=77.90, text="どんなイメージです"),
        ]
        words = [
            {"start": 76.41, "end": 76.77, "text": "イメージ"},
            {"start": 76.77, "end": 77.89, "text": "です"},
        ]

        report = evaluate_cues(cues, words, sample_id="cjk_partial")

        self.assertEqual(report["cues"][0]["match_method"], "text")
        self.assertTrue(report["cues"][0]["accepted"])

    def test_evaluate_cues_cjk_tolerates_asr_substitution_near_start(self):
        cues = [
            Cue(index=1, start=128.032, end=131.698, text="家では寡黙で厳しい一面もあるお父さんでした"),
        ]
        words = [
            {"start": 128.19, "end": 128.37, "text": "家"},
            {"start": 128.37, "end": 128.63, "text": "では"},
            {"start": 128.63, "end": 128.83, "text": "科"},
            {"start": 128.83, "end": 128.95, "text": "目"},
            {"start": 128.95, "end": 129.25, "text": "で"},
            {"start": 129.25, "end": 129.97, "text": "厳"},
            {"start": 129.97, "end": 130.25, "text": "しい"},
            {"start": 130.25, "end": 130.45, "text": "一"},
            {"start": 130.45, "end": 130.59, "text": "面"},
            {"start": 130.59, "end": 130.75, "text": "の"},
            {"start": 130.75, "end": 130.87, "text": "ある"},
            {"start": 130.87, "end": 131.03, "text": "お"},
            {"start": 131.03, "end": 131.13, "text": "父"},
            {"start": 131.13, "end": 131.33, "text": "さん"},
            {"start": 131.33, "end": 131.57, "text": "でした"},
        ]

        report = evaluate_cues(cues, words, sample_id="cjk_substitution")

        row = report["cues"][0]
        self.assertEqual(row["match_method"], "text")
        self.assertAlmostEqual(row["reference_start"], 128.19, places=2)
        self.assertTrue(row["accepted"])

    def test_evaluate_cues_cjk_prefers_repeated_prefix_closest_to_cue_start(self):
        cues = [
            Cue(index=1, start=133.865, end=138.348, text="そんなお父さんが教えてくれたことは"),
        ]
        words = [
            {"start": 133.89, "end": 134.25, "text": "そんな"},
            {"start": 134.25, "end": 134.45, "text": "お"},
            {"start": 134.45, "end": 134.55, "text": "父"},
            {"start": 134.55, "end": 134.81, "text": "さん"},
            {"start": 134.81, "end": 134.95, "text": "が"},
            {"start": 134.95, "end": 136.51, "text": "そ"},
            {"start": 136.51, "end": 136.67, "text": "んな"},
            {"start": 136.67, "end": 136.79, "text": "お"},
            {"start": 136.79, "end": 136.87, "text": "父"},
            {"start": 136.87, "end": 137.09, "text": "さん"},
            {"start": 137.09, "end": 137.19, "text": "が"},
            {"start": 137.19, "end": 137.37, "text": "教"},
            {"start": 137.37, "end": 137.51, "text": "えて"},
            {"start": 137.51, "end": 137.71, "text": "く"},
            {"start": 137.71, "end": 137.81, "text": "れた"},
            {"start": 137.81, "end": 137.99, "text": "こと"},
            {"start": 137.99, "end": 138.25, "text": "は"},
        ]

        report = evaluate_cues(cues, words, sample_id="cjk_repeated_prefix")

        row = report["cues"][0]
        self.assertEqual(row["match_method"], "text")
        self.assertAlmostEqual(row["reference_start"], 133.89, places=2)
        self.assertTrue(row["accepted"])

    def test_weak_boundary_allows_question_after_sentence_end(self):
        cue = Cue(index=1, start=0.0, end=1.0, text="A 10 engine static fire.")
        next_cue = Cue(index=2, start=1.0, end=2.0, text="Why 10 engines instead of all 33?")

        self.assertFalse(weak_boundary(cue, next_cue))

    def test_weak_boundary_allows_colon_handoff(self):
        cue = Cue(index=1, start=0.0, end=1.0, text="everybody has had this thought, which is:")
        next_cue = Cue(index=2, start=1.0, end=2.0, text="I am never going to have free time ever again.")

        self.assertFalse(weak_boundary(cue, next_cue))

    def test_summarize_report_handles_unmatched_cues(self):
        report = evaluate_cues(
            [Cue(index=1, start=20.0, end=21.0, text="Unmatched text")],
            [{"start": 1.0, "end": 1.3, "text": "Other"}],
            sample_id="unmatched",
        )

        summary = summarize_report(report)

        self.assertEqual(summary["matched_cue_count"], 0)
        self.assertEqual(summary["late_hold_count"], 0)

    def test_offset_words_shifts_asr_reference_to_original_video_time(self):
        shifted = offset_words(
            [{"start": 0.25, "end": 0.75, "text": "Hello"}],
            offset_seconds=40,
        )

        self.assertAlmostEqual(shifted[0]["start"], 40.25, places=3)
        self.assertAlmostEqual(shifted[0]["end"], 40.75, places=3)

    def test_overlap_alignment_ignores_shared_translation_terms_outside_cue_window(self):
        cues = [
            Cue(index=1, start=10.00, end=12.00, text="Starship 的测试已经准备好了"),
        ]
        words = [
            {"start": 1.00, "end": 1.40, "text": "Starship"},
            {"start": 10.10, "end": 10.30, "text": "the"},
            {"start": 10.35, "end": 10.80, "text": "test"},
            {"start": 10.85, "end": 11.25, "text": "is"},
            {"start": 11.30, "end": 11.70, "text": "ready"},
        ]

        text_report = evaluate_cues(cues, words, sample_id="translated_text")
        overlap_report = evaluate_cues(cues, words, sample_id="translated_overlap", alignment_mode="overlap")

        self.assertEqual(text_report["cues"][0]["match_method"], "overlap")
        self.assertAlmostEqual(text_report["cues"][0]["reference_start"], 10.10, places=2)
        self.assertEqual(overlap_report["alignment_mode"], "overlap")
        self.assertEqual(overlap_report["cues"][0]["match_method"], "overlap")
        self.assertAlmostEqual(overlap_report["cues"][0]["reference_start"], 10.10, places=2)
        self.assertTrue(overlap_report["cues"][0]["accepted"])

    def test_overlap_alignment_does_not_swallow_next_dense_cjk_word(self):
        cues = [
            Cue(index=1, start=0.35, end=4.61, text="现在只17块钱1717对"),
        ]
        words = [
            {"start": 0.15, "end": 0.48, "text": "现在"},
            {"start": 0.48, "end": 0.63, "text": "只"},
            {"start": 0.73, "end": 1.20, "text": "17"},
            {"start": 1.20, "end": 1.44, "text": "块"},
            {"start": 1.44, "end": 1.70, "text": "钱"},
            {"start": 1.85, "end": 2.56, "text": "17"},
            {"start": 2.71, "end": 3.32, "text": "17"},
            {"start": 3.47, "end": 4.54, "text": "对"},
            {"start": 4.69, "end": 6.04, "text": "嗨"},
        ]

        report = evaluate_cues(cues, words, sample_id="dense_cjk_overlap", alignment_mode="overlap")
        row = report["cues"][0]

        self.assertAlmostEqual(row["reference_end"], 4.54, places=2)
        self.assertEqual(row["early_cutoff_ms"], 0.0)
        self.assertTrue(row["accepted"])

    def test_evaluate_cues_prefers_near_partial_latin_match_over_far_exact_repeat(self):
        cues = [
            Cue(index=1, start=10.00, end=12.40, text="Allow me to say, I am a linguist."),
        ]
        words = [
            {"start": 10.80, "end": 10.95, "text": "I"},
            {"start": 10.95, "end": 11.10, "text": "am"},
            {"start": 11.10, "end": 11.25, "text": "a"},
            {"start": 11.25, "end": 11.60, "text": "linguist."},
            {"start": 30.00, "end": 30.22, "text": "Allow"},
            {"start": 30.22, "end": 30.40, "text": "me"},
            {"start": 30.40, "end": 30.60, "text": "to"},
            {"start": 30.60, "end": 30.82, "text": "say,"},
            {"start": 30.82, "end": 31.00, "text": "I"},
            {"start": 31.00, "end": 31.22, "text": "am"},
            {"start": 31.22, "end": 31.36, "text": "a"},
            {"start": 31.36, "end": 31.90, "text": "linguist."},
        ]

        report = evaluate_cues(cues, words, sample_id="near_partial")

        row = report["cues"][0]
        self.assertEqual(row["match_method"], "text")
        self.assertAlmostEqual(row["reference_start"], 10.00, places=2)
        self.assertAlmostEqual(row["reference_end"], 11.60, places=2)
        self.assertTrue(row["accepted"])

    def test_speech_alignment_detects_late_hold_and_early_cutoff_without_text_match(self):
        cues = [
            Cue(index=1, start=0.95, end=2.35, text="跨语言字幕 A"),
            Cue(index=2, start=3.00, end=5.00, text="跨语言字幕 B"),
            Cue(index=3, start=7.30, end=7.90, text="跨语言字幕 C"),
        ]
        speech_segments = [
            {"start": 1.00, "end": 2.00, "text": "__speech__"},
            {"start": 3.10, "end": 3.55, "text": "__speech__"},
            {"start": 7.00, "end": 8.10, "text": "__speech__"},
        ]

        report = evaluate_cues(cues, speech_segments, sample_id="speech", alignment_mode="speech")
        rows = report["cues"]

        self.assertEqual(rows[0]["match_method"], "speech")
        self.assertTrue(rows[0]["accepted"])
        self.assertGreater(rows[1]["long_idle_hold_ms"], 900)
        self.assertFalse(rows[1]["accepted"])
        self.assertGreater(rows[2]["early_cutoff_ms"], 150)
        self.assertFalse(rows[2]["accepted"])

    def test_reference_cue_alignment_scores_candidate_against_human_timing(self):
        reference = [
            Cue(index=1, start=1.00, end=3.00, text="Human translation A"),
            Cue(index=2, start=4.00, end=6.00, text="Human translation B"),
        ]
        candidate = [
            Cue(index=1, start=1.05, end=3.20, text="候选翻译 A"),
            Cue(index=2, start=4.20, end=5.70, text="候选翻译 B"),
        ]

        report = evaluate_cues_against_reference_cues(candidate, reference, sample_id="human_ref")
        summary = summarize_report(report)

        self.assertEqual(report["alignment_mode"], "reference_cue")
        self.assertTrue(report["cues"][0]["accepted"])
        self.assertEqual(report["cues"][0]["match_method"], "reference_overlap")
        self.assertFalse(report["cues"][1]["accepted"])
        self.assertGreater(report["cues"][1]["early_cutoff_ms"], 150)
        self.assertEqual(summary["accepted_ratio"], 0.5)

    def test_reference_cue_alignment_allows_contiguous_split_inside_human_cue(self):
        reference = [
            Cue(index=1, start=10.00, end=20.00, text="Human long translation with an aside"),
        ]
        candidate = [
            Cue(index=1, start=10.00, end=15.00, text="候选翻译上半句"),
            Cue(index=2, start=15.00, end=20.00, text="候选翻译下半句"),
        ]

        report = evaluate_cues_against_reference_cues(candidate, reference, sample_id="human_ref_split")
        summary = summarize_report(report)

        self.assertTrue(report["cues"][0]["accepted"])
        self.assertTrue(report["cues"][1]["accepted"])
        self.assertEqual(report["cues"][0]["reference_end"], 15.0)
        self.assertEqual(report["cues"][1]["reference_start"], 15.0)
        self.assertEqual(summary["accepted_ratio"], 1.0)


class VadTests(unittest.TestCase):
    def test_detect_speech_segments_from_samples_merges_frames_and_splits_long_gaps(self):
        sample_rate = 10
        samples = (
            [0.0] * 5
            + [0.8] * 10
            + [0.0] * 2
            + [0.7] * 8
            + [0.0] * 8
            + [0.9] * 10
            + [0.0] * 5
        )

        segments = detect_speech_segments_from_samples(
            samples,
            sample_rate=sample_rate,
            frame_ms=100,
            threshold_ratio=0.2,
            min_speech_ms=300,
            merge_gap_ms=250,
            pad_ms=0,
        )

        self.assertEqual(len(segments), 2)
        self.assertAlmostEqual(segments[0]["start"], 0.5, places=2)
        self.assertAlmostEqual(segments[0]["end"], 2.5, places=2)
        self.assertAlmostEqual(segments[1]["start"], 3.3, places=2)
        self.assertAlmostEqual(segments[1]["end"], 4.3, places=2)


class ComparisonTests(unittest.TestCase):
    def test_compare_reports_tracks_optimized_gate_and_deltas(self):
        words = [
            {"start": 1.00, "end": 1.30, "text": "Copy"},
            {"start": 3.00, "end": 3.40, "text": "Done"},
        ]
        baseline = evaluate_cues(
            [
                Cue(index=1, start=1.00, end=2.60, text="Copy."),
                Cue(index=2, start=3.00, end=6.00, text="Done."),
            ],
            words,
            sample_id="short_feedback",
        )
        optimized = evaluate_cues(
            [
                Cue(index=1, start=1.02, end=1.80, text="Copy."),
                Cue(index=2, start=3.02, end=3.90, text="Done."),
            ],
            words,
            sample_id="short_feedback",
        )

        comparison = compare_reports(baseline, optimized)

        self.assertFalse(comparison["baseline"]["passes_timing_gate"])
        self.assertTrue(comparison["optimized"]["passes_timing_gate"])
        self.assertGreater(comparison["delta"]["accepted_ratio"], 0)
        self.assertLess(comparison["delta"]["long_idle_hold_count"], 0)
        self.assertIn("avg_reading_speed_chars_per_second", comparison["optimized"]["summary"])

    def test_compare_reports_preservation_gate_allows_manual_captions_that_do_not_regress(self):
        words = [
            {"start": 10.0, "end": 11.0, "text": "你好"},
        ]
        baseline = evaluate_cues(
            [Cue(index=1, start=10.5, end=10.9, text="你好")],
            words,
            sample_id="manual_zh",
        )
        baseline["summary"] = summarize_report(baseline)
        optimized = evaluate_cues(
            [Cue(index=1, start=10.5, end=10.9, text="你好")],
            words,
            sample_id="manual_zh",
        )
        optimized["summary"] = summarize_report(optimized)

        comparison = compare_reports(baseline, optimized, language_group="zh", gate_mode="preserve")

        self.assertEqual(comparison["gate_mode"], "preserve")
        self.assertFalse(comparison["baseline"]["passes_timing_gate"])
        self.assertTrue(comparison["optimized"]["passes_timing_gate"])
        self.assertTrue(comparison["optimized"]["passes_preservation_gate"])

    def test_compare_reports_preservation_gate_rejects_manual_caption_regressions(self):
        words = [
            {"start": 10.0, "end": 11.0, "text": "你好"},
        ]
        baseline = evaluate_cues(
            [Cue(index=1, start=10.0, end=11.0, text="你好")],
            words,
            sample_id="manual_zh",
        )
        baseline["summary"] = summarize_report(baseline)
        optimized = evaluate_cues(
            [
                Cue(index=1, start=10.0, end=10.2, text="你"),
                Cue(index=2, start=10.2, end=10.4, text="好"),
            ],
            words,
            sample_id="manual_zh",
        )
        optimized["summary"] = summarize_report(optimized)

        comparison = compare_reports(baseline, optimized, language_group="zh", gate_mode="preserve")

        self.assertFalse(comparison["optimized"]["passes_timing_gate"])
        self.assertIn("cue_count_regression", comparison["optimized"]["gate_failures"])
        self.assertIn("cjk_singleton_regression", comparison["optimized"]["gate_failures"])

    def test_summarize_suite_requires_each_language_group_to_pass(self):
        passing = {
            "sample_id": "en_ok",
            "language_group": "en",
            "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
        }
        failing = {
            "sample_id": "ja_bad",
            "language_group": "ja-ko-cjk",
            "optimized": {"passes_timing_gate": False, "summary": {"accepted_ratio": 0.5}},
        }

        suite = summarize_suite([passing, failing])

        self.assertFalse(suite["passes_timing_gate"])
        self.assertEqual(suite["language_groups"]["en"]["passes_timing_gate"], True)
        self.assertEqual(suite["language_groups"]["ja-ko-cjk"]["passes_timing_gate"], False)

    def test_summarize_suite_fails_when_required_language_group_is_missing(self):
        passing = {
            "sample_id": "en_ok",
            "language_group": "en",
            "gate_mode": "timing",
            "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
        }

        suite = summarize_suite([passing], required_language_groups=["en", "zh"])

        self.assertFalse(suite["passes_timing_gate"])
        self.assertEqual(suite["missing_language_groups"], ["zh"])

    def test_summarize_suite_distinguishes_timing_from_preservation_evidence(self):
        timing = {
            "sample_id": "en_ok",
            "language_group": "en",
            "gate_mode": "timing",
            "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
        }
        preservation = {
            "sample_id": "zh_preserve",
            "language_group": "zh",
            "gate_mode": "preserve",
            "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 0.4}},
        }

        suite = summarize_suite([timing, preservation], required_language_groups=["en", "zh"])

        self.assertTrue(suite["passes_language_coverage_gate"])
        self.assertFalse(suite["passes_strict_timing_gate"])
        self.assertFalse(suite["passes_timing_gate"])
        self.assertEqual(suite["timing_language_groups"], ["en"])
        self.assertEqual(suite["preservation_language_groups"], ["zh"])
        self.assertEqual(suite["missing_strict_timing_language_groups"], ["zh"])


class PipelineTests(unittest.TestCase):
    def _write_passing_comparison(self, root: Path, sample_id: str, language_group: str, accepted_ratio: float = 1.0) -> None:
        sample_dir = root / sample_id
        sample_dir.mkdir(parents=True)
        (sample_dir / "comparison.json").write_text(json.dumps({
            "sample_id": sample_id,
            "language_group": language_group,
            "gate_mode": "timing",
            "optimized": {
                "passes_timing_gate": True,
                "summary": {"accepted_ratio": accepted_ratio},
                "gate_failures": [],
            },
        }), encoding="utf-8")
        (sample_dir / "baseline.report.json").write_text(json.dumps({
            "window_start_seconds": 0,
            "window_end_seconds": 120,
            "cues": [{"index": 1, "start": 1.0, "end": 3.0, "text": "baseline"}],
        }), encoding="utf-8")
        (sample_dir / "optimized.report.json").write_text(json.dumps({
            "window_start_seconds": 0,
            "window_end_seconds": 120,
            "cues": [{
                "index": 1,
                "start": 1.0,
                "end": 3.0,
                "text": "optimized",
                "accepted": True,
                "start_error_ms": 0,
                "end_error_ms": 0,
            }],
        }), encoding="utf-8")

    def test_prepare_commands_default_to_audio_only_for_eval_smoke(self):
        sample = {
            "id": "sample",
            "source": "https://www.youtube.com/watch?v=example",
            "subtitle_lang": "en",
            "section": {"start_seconds": 10, "duration_seconds": 120},
        }

        commands = build_prepare_commands(sample, output_template="/tmp/%(id)s.%(ext)s")

        self.assertIn("-f", commands[0])
        self.assertIn("ba[ext=m4a]/ba/best", commands[0])
        self.assertIn("--force-overwrites", commands[0])
        self.assertIn("--force-overwrites", commands[1])
        self.assertNotIn("--write-subs", commands[0], "media fetch should not fail because subtitles are rate-limited")
        self.assertNotIn("-f", commands[1], "converted subtitle fetch should not select a media format")
        self.assertIn("--convert-subs", commands[1])
        self.assertIn("--sleep-subtitles", commands[1])
        self.assertNotIn("-f", commands[2], "raw subtitle fetch should not select a media format")
        self.assertNotIn("--convert-subs", commands[2])
        self.assertIn("--sleep-subtitles", commands[2])

    def test_prepare_commands_can_override_duration_for_smoke_runs(self):
        sample = {
            "id": "sample",
            "source": "https://www.youtube.com/watch?v=example",
            "subtitle_lang": "en",
            "section": {"start_seconds": 10, "duration_seconds": 300},
        }

        commands = build_prepare_commands(
            sample,
            output_template="/tmp/%(id)s.%(ext)s",
            duration_override_seconds=30,
        )

        self.assertIn("*10.0-40.0", commands[0])
        self.assertIn("*10.0-40.0", commands[1])
        self.assertIn("*10.0-40.0", commands[2])

    def test_prepare_sample_falls_back_to_full_audio_download_when_section_media_fails(self):
        sample = {
            "id": "sample",
            "source": "https://www.youtube.com/watch?v=example",
            "subtitle_lang": "ja",
            "section": {"start_seconds": 120, "duration_seconds": 300},
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            calls = []

            def fake_run_command(args, dry_run=False):
                calls.append(args)
                if "--download-sections" in args and "-f" in args:
                    raise subprocess.CalledProcessError(187, args)
                if "-o" in args and "full.%(ext)s" in args[args.index("-o") + 1]:
                    Path(args[args.index("-o") + 1].replace("%(ext)s", "m4a")).touch()

            with patch.object(pipeline, "run_command", side_effect=fake_run_command), patch("builtins.print"):
                pipeline.prepare_sample(sample, artifacts_root=temp_dir, duration_override_seconds=30)

        flattened = [" ".join(args) for args in calls]
        self.assertTrue(any("sample.full.%(ext)s" in command for command in flattened))
        self.assertTrue(any(command.startswith("ffmpeg ") and "sample.section.wav" in command for command in flattened))
        self.assertTrue(any("--skip-download" in command and "--convert-subs srt" in command for command in flattened))
        self.assertTrue(any("--skip-download" in command and "--convert-subs" not in command for command in flattened))

    def test_prepare_sample_writes_blocker_when_media_download_is_bot_gated(self):
        sample = {
            "id": "sample",
            "source": "https://www.youtube.com/watch?v=example",
            "subtitle_lang": "pt",
            "section": {"start_seconds": 60, "duration_seconds": 120},
        }
        error = subprocess.CalledProcessError(
            1,
            ["yt-dlp"],
            stderr="Sign in to confirm you’re not a bot",
        )

        with tempfile.TemporaryDirectory() as temp_dir:
            with patch.object(pipeline, "run_command", side_effect=error), patch("builtins.print"):
                with self.assertRaises(subprocess.CalledProcessError):
                    pipeline.prepare_sample(sample, artifacts_root=temp_dir)

            blocker = json.loads((Path(temp_dir) / "sample" / "blocker.prepare.json").read_text(encoding="utf-8"))

        self.assertEqual(blocker["sample_id"], "sample")
        self.assertEqual(blocker["stage"], "prepare")
        self.assertEqual(blocker["reason"], "youtube_bot_gate")
        self.assertIn("Sign in to confirm", blocker["message"])

    def test_filter_cues_by_window_keeps_only_overlapping_sample_section(self):
        cues = [
            Cue(index=1, start=1.0, end=2.0, text="Before"),
            Cue(index=2, start=40.5, end=41.0, text="Inside"),
            Cue(index=3, start=69.8, end=71.0, text="Overlap tail"),
            Cue(index=4, start=72.0, end=73.0, text="After"),
        ]

        filtered = filter_cues_by_window(cues, window_start=40.0, window_end=70.0)

        self.assertEqual([cue.text for cue in filtered], ["Inside"])

    def test_extract_vtt_words_serializes_inline_word_timestamps(self):
        payload = extract_vtt_words(
            "WEBVTT\n\n"
            "00:00:01.000 --> 00:00:03.000\n"
            "<00:00:01.120><c>Hello</c> <00:00:01.720><c>there</c>\n"
        )

        self.assertEqual(payload["words"][0]["text"], "Hello")
        self.assertAlmostEqual(payload["words"][0]["start"], 1.120, places=3)

    def test_extract_srt_words_distributes_tokens_inside_cue_windows(self):
        payload = extract_srt_words(
            "1\n"
            "00:00:10,000 --> 00:00:12,000\n"
            "Hello there.\n\n"
            "2\n"
            "00:00:13,000 --> 00:00:14,500\n"
            "Copy.\n"
        )

        self.assertEqual([word["text"] for word in payload["words"]], ["Hello", "there.", "Copy."])
        self.assertAlmostEqual(payload["words"][0]["start"], 10.0, places=3)
        self.assertAlmostEqual(payload["words"][0]["end"], 11.0, places=3)
        self.assertAlmostEqual(payload["words"][1]["start"], 11.0, places=3)
        self.assertAlmostEqual(payload["words"][1]["end"], 12.0, places=3)
        self.assertAlmostEqual(payload["words"][2]["start"], 13.0, places=3)
        self.assertAlmostEqual(payload["words"][2]["end"], 14.5, places=3)

    def test_srt_words_cli_writes_cue_derived_reference(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "sample.srt"
            output = root / "words.json"
            source.write_text(
                "1\n"
                "00:00:01,000 --> 00:00:03,000\n"
                "Hello there.\n",
                encoding="utf-8",
            )

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "srt-words",
                "--srt",
                str(source),
                "--out",
                str(output),
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual([word["text"] for word in payload["words"]], ["Hello", "there."])
        self.assertAlmostEqual(payload["words"][1]["end"], 3.0, places=3)

    def test_build_translation_timing_proxy_srt_preserves_times_and_replaces_text(self):
        raw = (
            "1\n"
            "00:01:30,100 --> 00:01:32,400\n"
            "This is the original line.\n\n"
            "2\n"
            "00:01:33,000 --> 00:01:34,250\n"
            "OK.\n"
        )

        proxy = build_translation_timing_proxy_srt(raw, target_language="zh-CN")
        cues = parse_srt(proxy)

        self.assertEqual(len(cues), 2)
        self.assertAlmostEqual(cues[0].start, 90.100, places=3)
        self.assertAlmostEqual(cues[0].end, 92.400, places=3)
        self.assertAlmostEqual(cues[1].start, 93.000, places=3)
        self.assertAlmostEqual(cues[1].end, 94.250, places=3)
        self.assertIn("翻译字幕 CUE 0001", cues[0].text)
        self.assertIn("翻译字幕 CUE 0002", cues[1].text)
        self.assertFalse(cues[0].text.startswith("This is"))
        self.assertGreater(len(cues[1].text), 1)

    def test_evaluate_files_can_use_source_text_to_align_translated_candidate_timing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            candidate = root / "translated.srt"
            alignment = root / "source.srt"
            words = root / "words.json"
            report_path = root / "report.json"
            candidate.write_text(
                "1\n"
                "00:00:09,800 --> 00:00:11,200\n"
                "翻译字幕 1。\n",
                encoding="utf-8",
            )
            alignment.write_text(
                "1\n"
                "00:00:09,800 --> 00:00:11,200\n"
                "Hello there.\n",
                encoding="utf-8",
            )
            words.write_text(json.dumps({
                "words": [
                    {"start": 10.00, "end": 10.30, "text": "Hello"},
                    {"start": 10.35, "end": 10.75, "text": "there"},
                ]
            }), encoding="utf-8")

            report = pipeline.evaluate_files(
                str(candidate),
                str(words),
                sample_id="translated_proxy",
                output_path=str(report_path),
                alignment_mode="text",
                alignment_text_path=str(alignment),
            )

        row = report["cues"][0]
        self.assertEqual(row["text"], "翻译字幕 1。")
        self.assertEqual(row["alignment_text"], "Hello there.")
        self.assertEqual(row["match_method"], "text")
        self.assertAlmostEqual(row["reading_speed_chars_per_second"], 6 / 1.4, places=2)
        self.assertFalse(row["weak_boundary"])
        self.assertTrue(row["accepted"])

    def test_reference_metrics_cli_writes_human_reference_report(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            candidate = root / "candidate.srt"
            reference = root / "reference.srt"
            output = root / "reference.report.json"
            reference.write_text(
                "1\n00:00:10,000 --> 00:00:12,000\nHuman line.\n",
                encoding="utf-8",
            )
            candidate.write_text(
                "1\n00:00:10,050 --> 00:00:12,100\nCandidate line.\n",
                encoding="utf-8",
            )

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "reference-metrics",
                "--candidate",
                str(candidate),
                "--reference",
                str(reference),
                "--sample-id",
                "human_reference",
                "--window-start-seconds",
                "10",
                "--window-end-seconds",
                "13",
                "--out",
                str(output),
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(payload["alignment_mode"], "reference_cue")
        self.assertEqual(payload["summary"]["accepted_ratio"], 1.0)
        self.assertEqual(payload["window_start_seconds"], 10.0)
        self.assertEqual(payload["window_end_seconds"], 13.0)

    def test_evaluate_files_can_offset_section_relative_candidate_cues(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            candidate = root / "local-asr.srt"
            words = root / "words.json"
            report_path = root / "report.json"
            candidate.write_text(
                "1\n00:00:00,200 --> 00:00:01,000\nHello there.\n",
                encoding="utf-8",
            )
            words.write_text(json.dumps({
                "words": [
                    {"start": 0.20, "end": 0.55, "text": "Hello"},
                    {"start": 0.56, "end": 1.00, "text": "there"},
                ]
            }), encoding="utf-8")

            report = pipeline.evaluate_files(
                str(candidate),
                str(words),
                sample_id="section-relative",
                output_path=str(report_path),
                asr_offset_seconds=90.0,
                candidate_offset_seconds=90.0,
                window_start=90.0,
                window_end=92.0,
            )

        self.assertEqual(report["cue_count"], 1)
        self.assertEqual(report["cues"][0]["start"], 90.2)
        self.assertTrue(report["cues"][0]["accepted"])

    def test_build_suite_runbook_includes_manifest_coverage_and_overlap_translation(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "translated"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 10, "duration_seconds": 120},
                },
                {
                    "id": "translated",
                    "source": "https://www.youtube.com/watch?v=example2",
                    "category": "auto_translate",
                    "language_group": "translated",
                    "subtitle_lang": "zh-Hans",
                    "alignment_mode": "overlap",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 20, "duration_seconds": 120},
                },
            ],
        }

        runbook = build_suite_runbook(
            manifest,
            artifacts_root="artifacts/subtitle_timing_eval",
            model="small",
            manifest_path="custom/samples.json",
        )

        self.assertEqual(runbook["required_language_groups"], ["en", "translated"])
        self.assertEqual([sample["sample_id"] for sample in runbook["samples"]], ["english", "translated"])
        translated = runbook["samples"][1]
        self.assertEqual(translated["language_group"], "translated")
        english = runbook["samples"][0]
        self.assertIn("local_asr_source_srt", english["artifacts"])
        self.assertIn("local_asr_srt", english["commands"])
        self.assertIn("local-asr-srt", english["commands"]["local_asr_srt"])
        self.assertIn("--asr-words", english["commands"]["local_asr_srt"])
        self.assertIn("local-asr.en.srt", english["artifacts"]["local_asr_source_srt"])
        self.assertIn("local-asr.en.srt", " ".join(english["commands"]["optimized_metrics"]))
        self.assertIn("--candidate-offset-seconds", english["commands"]["optimized_metrics"])
        self.assertIn("10.0", english["commands"]["optimized_metrics"])
        self.assertIn("--alignment-mode", translated["commands"]["baseline_metrics"])
        self.assertIn("overlap", translated["commands"]["baseline_metrics"])
        self.assertIn("--alignment-mode", translated["commands"]["optimized_metrics"])
        self.assertIn("overlap", translated["commands"]["optimized_metrics"])
        self.assertIn("--require-manifest-coverage", runbook["suite_command"])
        self.assertIn("translated/comparison.json", " ".join(runbook["suite_command"]))
        self.assertIn("--require-sample-completion", runbook["status_completion_command"])
        self.assertIn("status", runbook["status_completion_command"])
        self.assertIn("custom/samples.json", runbook["status_completion_command"])
        self.assertIn("artifacts/subtitle_timing_eval/status.current.json", " ".join(runbook["status_completion_command"]))

    def test_build_suite_runbook_can_use_local_whisper_cpp_asr(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["ja"]},
            "samples": [
                {
                    "id": "koupen",
                    "source": "https://www.youtube.com/watch?v=q4Fgq49ivbA",
                    "category": "japanese_animation",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"start_seconds": 0, "duration_seconds": 112},
                },
            ],
        }

        runbook = build_suite_runbook(
            manifest,
            artifacts_root="artifacts/subtitle_timing_eval",
            asr_engine="whisper-cpp",
            whisper_cli="/opt/homebrew/bin/whisper-cli",
            model_path="/Users/xianjingheng/Library/Application Support/月之门/asr/models/ggml-large-v3-turbo-q5_0.bin",
            ffmpeg="/opt/homebrew/bin/ffmpeg",
            whisper_cpp_no_gpu=True,
        )

        command = runbook["samples"][0]["commands"]["asr"]
        self.assertIn("--engine", command)
        self.assertIn("whisper-cpp", command)
        self.assertIn("--whisper-cli", command)
        self.assertIn("/opt/homebrew/bin/whisper-cli", command)
        self.assertIn("--model-path", command)
        self.assertIn("ggml-large-v3-turbo-q5_0.bin", " ".join(command))
        self.assertIn("--ffmpeg", command)
        self.assertIn("--no-gpu", command)

    def test_build_suite_runbook_can_scope_to_manual_selection(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "zh", "ja"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "mandarin_translated",
                    "source": "https://www.youtube.com/watch?v=zh_en",
                    "category": "translated_public_subtitle",
                    "language_group": "translated",
                    "subtitle_lang": "en",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions", "translated_timing"],
                },
                {
                    "id": "unselected_japanese",
                    "source": "https://www.youtube.com/watch?v=ja",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }
        selection = {
            "ready": True,
            "requested_count": 2,
            "selected": [
                {"id": "english", "suite_language": "en"},
                {"id": "mandarin_translated", "suite_language": "zh"},
            ],
        }

        runbook = build_suite_runbook(
            manifest,
            artifacts_root="artifacts/subtitle_timing_eval",
            manifest_path="custom/samples.json",
            selection=selection,
            selection_path="artifacts/subtitle_timing_eval/manual-suite.current.json",
        )

        self.assertEqual(runbook["runbook_scope"], "manual_suite")
        self.assertEqual(runbook["required_language_groups"], ["en", "zh"])
        self.assertEqual([sample["sample_id"] for sample in runbook["samples"]], ["english", "mandarin_translated"])
        self.assertEqual(runbook["samples"][1]["language_group"], "zh")
        self.assertNotIn("unselected_japanese", " ".join(runbook["suite_command"]))
        self.assertIn("manual-suite-status", runbook["status_completion_command"])
        self.assertIn("manual-suite.current.json", " ".join(runbook["status_completion_command"]))

    def test_build_suite_runbook_only_incomplete_filters_selected_suite_status(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "zh", "ja"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "mandarin_translated",
                    "source": "https://www.youtube.com/watch?v=zh_en",
                    "category": "translated_public_subtitle",
                    "language_group": "translated",
                    "subtitle_lang": "en",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions", "translated_timing"],
                },
                {
                    "id": "unselected_japanese",
                    "source": "https://www.youtube.com/watch?v=ja",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }
        selection = {
            "ready": True,
            "requested_count": 2,
            "selected": [
                {"id": "english", "suite_language": "en"},
                {"id": "mandarin_translated", "suite_language": "zh"},
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            english_dir = Path(temp_dir) / "english"
            english_dir.mkdir()
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "preserve",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 1.0},
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            runbook = build_suite_runbook(
                manifest,
                artifacts_root=temp_dir,
                selection=selection,
                only_incomplete=True,
            )

        self.assertEqual(runbook["runbook_scope"], "manual_suite_incomplete")
        self.assertEqual([sample["sample_id"] for sample in runbook["samples"]], ["english", "mandarin_translated"])
        self.assertEqual(runbook["filtered_out_sample_ids"], [])

    def test_runbook_cli_can_scope_to_incomplete_manual_selection(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest_path = root / "samples.json"
            selection_path = root / "manual-suite.json"
            output = root / "runbook.json"
            artifacts = root / "artifacts"
            manifest_path.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en", "zh"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=en",
                        "category": "english_talk",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                        "stressors": ["manual_captions"],
                    },
                    {
                        "id": "mandarin_translated",
                        "source": "https://www.youtube.com/watch?v=zh_en",
                        "category": "translated_public_subtitle",
                        "language_group": "translated",
                        "subtitle_lang": "en",
                        "spoken_languages": ["zh"],
                        "section": {"duration_seconds": 120},
                        "stressors": ["manual_captions", "translated_timing"],
                    },
                    {
                        "id": "mandarin_source",
                        "source": "https://www.youtube.com/watch?v=zh",
                        "category": "mandarin_talk",
                        "language_group": "zh",
                        "subtitle_lang": "zh",
                        "spoken_languages": ["zh"],
                        "section": {"duration_seconds": 120},
                        "stressors": ["manual_captions"],
                    },
                ],
            }), encoding="utf-8")
            selection_path.write_text(json.dumps({
                "ready": True,
                "requested_count": 2,
                "selected": [
                    {"id": "english", "suite_language": "en"},
                    {"id": "mandarin_translated", "suite_language": "zh"},
                ],
            }), encoding="utf-8")
            english_dir = artifacts / "english"
            english_dir.mkdir(parents=True)
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "preserve",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 1.0},
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "runbook",
                "--manifest",
                str(manifest_path),
                "--selection",
                str(selection_path),
                "--artifacts",
                str(artifacts),
                "--only-incomplete",
                "--out",
                str(output),
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(payload["runbook_scope"], "manual_suite_incomplete")
        self.assertEqual([sample["sample_id"] for sample in payload["samples"]], ["english", "mandarin_translated"])
        self.assertIn("manual-suite-status", payload["status_completion_command"])

    def test_collect_eval_status_reports_missing_and_failing_language_groups(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "zh", "translated"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "chinese",
                    "source": "https://www.youtube.com/watch?v=example2",
                    "category": "mandarin_talk",
                    "language_group": "zh",
                    "subtitle_lang": "zh",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "translated",
                    "source": "https://www.youtube.com/watch?v=example3",
                    "category": "auto_translate",
                    "language_group": "translated",
                    "subtitle_lang": "en-zh",
                    "alignment_mode": "overlap",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            english_dir = Path(temp_dir) / "english"
            english_dir.mkdir()
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 0.96}},
            }), encoding="utf-8")
            translated_dir = Path(temp_dir) / "translated"
            translated_dir.mkdir()
            (translated_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "translated",
                "language_group": "translated",
                "optimized": {"passes_timing_gate": False, "summary": {"accepted_ratio": 0.40}},
            }), encoding="utf-8")

            status = collect_eval_status(manifest, temp_dir)

        self.assertFalse(status["passes_timing_gate"])
        self.assertEqual(status["covered_language_groups"], ["en", "translated"])
        self.assertEqual(status["missing_language_groups"], ["zh"])
        self.assertEqual(status["failing_language_groups"], ["translated"])
        self.assertEqual(status["samples"]["english"]["status"], "pass")
        self.assertEqual(status["samples"]["chinese"]["status"], "missing")
        self.assertEqual(status["samples"]["translated"]["status"], "fail")

    def test_collect_eval_status_distinguishes_timing_from_preservation_evidence(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "zh"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "chinese",
                    "source": "https://www.youtube.com/watch?v=example2",
                    "category": "mandarin_talk",
                    "language_group": "zh",
                    "subtitle_lang": "zh",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            english_dir = Path(temp_dir) / "english"
            english_dir.mkdir()
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 0.96}},
            }), encoding="utf-8")
            chinese_dir = Path(temp_dir) / "chinese"
            chinese_dir.mkdir()
            (chinese_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "chinese",
                "language_group": "zh",
                "gate_mode": "preserve",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 0.40}},
            }), encoding="utf-8")

            status = collect_eval_status(manifest, temp_dir)

        self.assertTrue(status["passes_language_coverage_gate"])
        self.assertFalse(status["passes_strict_timing_gate"])
        self.assertEqual(status["timing_language_groups"], ["en"])
        self.assertEqual(status["preservation_language_groups"], ["zh"])
        self.assertEqual(status["missing_strict_timing_language_groups"], ["zh"])
        self.assertEqual(status["samples"]["chinese"]["gate_mode"], "preserve")

    def test_collect_eval_status_reports_blocked_samples_separately_from_missing(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "translated"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "translated_proxy",
                    "source": "https://www.youtube.com/watch?v=example2",
                    "category": "app_translate_proxy",
                    "language_group": "translated",
                    "subtitle_lang": "zh",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "translated_blocked",
                    "source": "https://www.youtube.com/watch?v=example3",
                    "category": "auto_translate",
                    "language_group": "translated",
                    "subtitle_lang": "en-zh",
                    "alignment_mode": "overlap",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            english_dir = Path(temp_dir) / "english"
            english_dir.mkdir()
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            proxy_dir = Path(temp_dir) / "translated_proxy"
            proxy_dir.mkdir()
            (proxy_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "translated_proxy",
                "language_group": "translated",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            blocked_dir = Path(temp_dir) / "translated_blocked"
            blocked_dir.mkdir()
            (blocked_dir / "blocker.prepare.json").write_text(json.dumps({
                "sample_id": "translated_blocked",
                "stage": "prepare",
                "reason": "youtube_timedtext_429",
                "message": "HTTP Error 429: Too Many Requests",
            }), encoding="utf-8")

            status = collect_eval_status(manifest, temp_dir)

        self.assertTrue(status["passes_timing_gate"])
        self.assertFalse(status["passes_sample_completion_gate"])
        self.assertEqual(status["missing_samples"], [])
        self.assertEqual(status["blocked_samples"], ["translated_blocked"])
        self.assertEqual(status["samples"]["translated_blocked"]["status"], "blocked")
        self.assertEqual(status["samples"]["translated_blocked"]["blocker_reason"], "youtube_timedtext_429")
        self.assertEqual(status["timing_language_groups"], ["en", "translated"])

    def test_collect_eval_status_rejects_smoke_comparison_that_does_not_cover_manifest_window(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 60, "duration_seconds": 300},
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            english_dir = Path(temp_dir) / "english"
            english_dir.mkdir()
            (english_dir / "comparison.60-90.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            (english_dir / "optimized.60-90.report.json").write_text(json.dumps({
                "sample_id": "english",
                "window_start_seconds": 60,
                "window_end_seconds": 90,
                "cues": [
                    {"index": 1, "start": 62.0, "end": 64.0, "text": "Short smoke window."}
                ],
            }), encoding="utf-8")

            status = collect_eval_status(manifest, temp_dir)

        self.assertFalse(status["passes_sample_completion_gate"])
        self.assertEqual(status["insufficient_window_samples"], ["english"])
        self.assertEqual(status["samples"]["english"]["status"], "insufficient_window")
        self.assertEqual(status["samples"]["english"]["comparison_window_seconds"], 30.0)
        self.assertEqual(status["samples"]["english"]["manifest_window_seconds"], 300.0)

    def test_collect_eval_status_prefers_sufficient_timing_over_preserve_comparison(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 0, "duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            english_dir = Path(temp_dir) / "english"
            english_dir.mkdir()
            report_window = {
                "sample_id": "english",
                "window_start_seconds": 0,
                "window_end_seconds": 120,
                "cues": [
                    {"index": 1, "start": 1.0, "end": 3.0, "text": "Hello"}
                ],
            }
            for token in ["timing", "preserve"]:
                (english_dir / f"baseline.{token}.report.json").write_text(json.dumps(report_window), encoding="utf-8")
                (english_dir / f"optimized.{token}.report.json").write_text(json.dumps(report_window), encoding="utf-8")
            (english_dir / "comparison.timing.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": False,
                    "summary": {"accepted_ratio": 0.5},
                    "gate_failures": ["accepted_ratio"],
                },
            }), encoding="utf-8")
            (english_dir / "comparison.preserve.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "preserve",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 1.0},
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            status = collect_eval_status(manifest, temp_dir)

        self.assertFalse(status["passes_strict_timing_gate"])
        self.assertFalse(status["passes_sample_completion_gate"])
        self.assertEqual(status["failing_samples"], ["english"])
        self.assertEqual(status["failing_strict_timing_language_groups"], ["en"])
        self.assertEqual(status["samples"]["english"]["gate_mode"], "timing")
        self.assertEqual(status["samples"]["english"]["comparison"].split("/")[-1], "comparison.timing.json")

    def test_status_cli_can_require_sample_completion_gate(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "translated"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "translated_blocked",
                    "source": "https://www.youtube.com/watch?v=example2",
                    "category": "auto_translate",
                    "language_group": "translated",
                    "subtitle_lang": "en-zh",
                    "alignment_mode": "overlap",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "samples.json"
            artifacts_dir = Path(temp_dir) / "artifacts"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            english_dir = artifacts_dir / "english"
            english_dir.mkdir(parents=True)
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            blocked_dir = artifacts_dir / "translated_blocked"
            blocked_dir.mkdir()
            (blocked_dir / "blocker.prepare.json").write_text(json.dumps({
                "sample_id": "translated_blocked",
                "stage": "prepare",
                "reason": "youtube_timedtext_429",
            }), encoding="utf-8")

            status_path = Path(temp_dir) / "status.json"
            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "status",
                "--manifest",
                str(manifest_path),
                "--artifacts",
                str(artifacts_dir),
                "--out",
                str(status_path),
                "--require-sample-completion",
            ]):
                with self.assertRaises(SystemExit) as context:
                    with contextlib.redirect_stdout(io.StringIO()):
                        cli_main()

            self.assertTrue(status_path.exists())
        self.assertIsInstance(context.exception.code, str)
        self.assertIn("sample completion gate failed", context.exception.code)
        self.assertIn("translated_blocked", context.exception.code)

    def test_status_cli_can_require_manifest_window_coverage(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 60, "duration_seconds": 300},
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest_path = root / "samples.json"
            artifacts_dir = root / "artifacts"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            english_dir = artifacts_dir / "english"
            english_dir.mkdir(parents=True)
            (english_dir / "comparison.60-90.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            (english_dir / "optimized.60-90.report.json").write_text(json.dumps({
                "sample_id": "english",
                "window_start_seconds": 60,
                "window_end_seconds": 90,
                "cues": [
                    {"index": 1, "start": 62.0, "end": 64.0, "text": "Short smoke window."}
                ],
            }), encoding="utf-8")
            status_path = root / "status.json"

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "status",
                "--manifest",
                str(manifest_path),
                "--artifacts",
                str(artifacts_dir),
                "--out",
                str(status_path),
                "--require-sample-completion",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as context:
                        cli_main()

            payload = json.loads(status_path.read_text(encoding="utf-8"))

        self.assertIn("insufficient_window_samples", str(context.exception))
        self.assertEqual(payload["insufficient_window_samples"], ["english"])

    def test_build_qa_packet_groups_review_segments_with_timestamp_links(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "title": "English sample",
                    "source": "https://www.youtube.com/watch?v=abc123",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 40, "duration_seconds": 120},
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            sample_dir = Path(temp_dir) / "english"
            sample_dir.mkdir()
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 0.95, "cue_count": 2},
                    "gate_failures": [],
                },
            }), encoding="utf-8")
            (sample_dir / "baseline.report.json").write_text(json.dumps({
                "sample_id": "english",
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "summary": {"accepted_ratio": 0.50, "cue_count": 2},
                "cues": [
                    {"index": 1, "start": 41.0, "end": 42.0, "text": "Original good timing."},
                    {"index": 2, "start": 45.0, "end": 47.0, "text": "Original needs eyes."},
                ],
            }), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps({
                "sample_id": "english",
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "summary": {"accepted_ratio": 0.95, "cue_count": 2},
                "cues": [
                    {
                        "index": 1,
                        "start": 41.0,
                        "end": 42.0,
                        "text": "Good timing.",
                        "accepted": True,
                        "start_error_ms": 100,
                        "end_error_ms": 200,
                        "early_cutoff_ms": 0,
                        "late_hold_ms": 200,
                        "long_idle_hold_ms": 0,
                        "weak_boundary": False,
                    },
                    {
                        "index": 2,
                        "start": 45.0,
                        "end": 46.2,
                        "text": "Needs eyes.",
                        "accepted": False,
                        "start_error_ms": 500,
                        "end_error_ms": 950,
                        "early_cutoff_ms": 0,
                        "late_hold_ms": 950,
                        "long_idle_hold_ms": 0,
                        "weak_boundary": True,
                    },
                ],
            }), encoding="utf-8")

            packet = build_qa_packet(manifest, temp_dir, max_segments_per_group=2)

        group = packet["language_groups"][0]
        self.assertEqual(group["language_group"], "en")
        self.assertEqual(group["sample_count"], 1)
        self.assertEqual(group["segments"][0]["sample_id"], "english")
        self.assertIn("t=45s", group["segments"][0]["url"])
        self.assertEqual(group["segments"][0]["text"], "Needs eyes.")
        self.assertEqual(group["segments"][0]["baseline_text"], "Original needs eyes.")
        self.assertEqual(group["segments"][0]["optimized_text"], "Needs eyes.")

        markdown = render_qa_markdown(packet)

        self.assertIn("# Subtitle Timing QA Packet", markdown)
        self.assertIn("English sample", markdown)
        self.assertIn("Human Verdict", markdown)
        self.assertIn("Original needs eyes.", markdown)
        self.assertIn("Needs eyes.", markdown)
        self.assertIn("https://www.youtube.com/watch?v=abc123&t=45s", markdown)

    def test_build_qa_packet_carries_baseline_and_optimized_windows_for_review_preview(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "title": "English sample",
                    "source": "https://www.youtube.com/watch?v=abc123",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 40, "duration_seconds": 120},
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            sample_dir = Path(temp_dir) / "english"
            sample_dir.mkdir()
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            (sample_dir / "baseline.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {"index": 1, "start": 44.0, "end": 47.0, "text": "Original window"}
                ]
            }), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {
                        "index": 1,
                        "start": 45.0,
                        "end": 46.0,
                        "text": "Optimized window",
                        "accepted": True,
                    }
                ]
            }), encoding="utf-8")

            packet = build_qa_packet(manifest, temp_dir, max_segments_per_group=1)

        segment = packet["language_groups"][0]["segments"][0]
        self.assertEqual(segment["baseline_start"], 44.0)
        self.assertEqual(segment["baseline_end"], 47.0)
        self.assertEqual(segment["optimized_start"], 45.0)
        self.assertEqual(segment["optimized_end"], 46.0)

    def test_build_qa_packet_flags_text_quality_risk_for_machine_accepted_gibberish(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "title": "English sample",
                    "source": "https://www.youtube.com/watch?v=abc123",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 40, "duration_seconds": 120},
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            sample_dir = Path(temp_dir) / "english"
            sample_dir.mkdir()
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 1.0, "cue_count": 1},
                    "gate_failures": [],
                },
            }), encoding="utf-8")
            (sample_dir / "baseline.report.json").write_text(json.dumps({
                "sample_id": "english",
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {"index": 1, "start": 45.0, "end": 47.0, "text": "These are the engine cores"},
                ],
            }), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps({
                "sample_id": "english",
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {
                        "index": 1,
                        "start": 45.0,
                        "end": 47.0,
                        "text": "sand wich zebra xray quantum static",
                        "accepted": True,
                        "start_error_ms": 0,
                        "end_error_ms": 0,
                        "early_cutoff_ms": 0,
                        "late_hold_ms": 0,
                        "long_idle_hold_ms": 0,
                        "weak_boundary": False,
                    },
                ],
            }), encoding="utf-8")

            packet = build_qa_packet(manifest, temp_dir, max_segments_per_group=1, segment_mode="representative")

        segment = packet["language_groups"][0]["segments"][0]
        self.assertIn("low_text_overlap", segment["text_quality_flags"])

        checklist = render_qa_checklist_markdown(packet)

        self.assertIn("Text Risk", checklist)
        self.assertIn("low_text_overlap", checklist)

    def test_build_qa_packet_can_scope_to_manual_suite_selection(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "ja"]},
            "samples": [
                {
                    "id": "english",
                    "title": "English sample",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 0, "duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "japanese",
                    "title": "Japanese sample",
                    "source": "https://www.youtube.com/watch?v=ja",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"start_seconds": 0, "duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }
        selection = {
            "ready": True,
            "requested_count": 1,
            "selected": [{"id": "japanese", "suite_language": "ja"}],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            for sample_id, group in [("english", "en"), ("japanese", "ja")]:
                sample_dir = Path(temp_dir) / sample_id
                sample_dir.mkdir()
                (sample_dir / "comparison.json").write_text(json.dumps({
                    "sample_id": sample_id,
                    "language_group": group,
                    "gate_mode": "timing",
                    "optimized": {
                        "passes_timing_gate": True,
                        "summary": {"accepted_ratio": 1.0},
                        "gate_failures": [],
                    },
                }), encoding="utf-8")
                (sample_dir / "baseline.report.json").write_text(json.dumps({
                    "window_start_seconds": 0,
                    "window_end_seconds": 120,
                    "cues": [{"index": 1, "start": 1.0, "end": 2.0, "text": "%s baseline" % sample_id}],
                }), encoding="utf-8")
                (sample_dir / "optimized.report.json").write_text(json.dumps({
                    "window_start_seconds": 0,
                    "window_end_seconds": 120,
                    "cues": [{"index": 1, "start": 1.0, "end": 2.0, "text": "%s optimized" % sample_id, "accepted": True}],
                }), encoding="utf-8")

            packet = build_qa_packet(manifest, temp_dir, max_segments_per_group=1, selection=selection)

        self.assertEqual(packet["status"]["report_scope"], "manual_suite")
        self.assertEqual(packet["status"]["selected_sample_ids"], ["japanese"])
        self.assertEqual([group["language_group"] for group in packet["language_groups"]], ["ja"])
        self.assertEqual(packet["language_groups"][0]["segments"][0]["sample_id"], "japanese")

    def test_build_qa_packet_representative_mode_prefers_accepted_middle_rows(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "title": "English sample",
                    "source": "https://www.youtube.com/watch?v=abc123",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"start_seconds": 0, "duration_seconds": 120},
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            sample_dir = Path(temp_dir) / "english"
            sample_dir.mkdir()
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 0.9},
                    "gate_failures": [],
                },
            }), encoding="utf-8")
            (sample_dir / "baseline.report.json").write_text(json.dumps({
                "window_start_seconds": 0,
                "window_end_seconds": 120,
                "cues": [
                    {"index": 1, "start": 1.0, "end": 2.0, "text": "bad baseline"},
                    {"index": 2, "start": 4.0, "end": 7.0, "text": "good baseline"},
                ],
            }), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps({
                "window_start_seconds": 0,
                "window_end_seconds": 120,
                "cues": [
                    {
                        "index": 1,
                        "start": 1.0,
                        "end": 2.0,
                        "duration": 1.0,
                        "text": "bad row",
                        "accepted": False,
                        "start_error_ms": -700,
                        "end_error_ms": 950,
                    },
                    {
                        "index": 2,
                        "start": 4.1,
                        "end": 7.0,
                        "duration": 2.9,
                        "text": "good row",
                        "accepted": True,
                        "start_error_ms": 100,
                        "end_error_ms": 0,
                    },
                ],
            }), encoding="utf-8")

            risk_packet = build_qa_packet(manifest, temp_dir, max_segments_per_group=1)
            packet = build_qa_packet(
                manifest,
                temp_dir,
                max_segments_per_group=1,
                segment_mode="representative",
            )

        self.assertEqual(risk_packet["language_groups"][0]["segments"][0]["optimized_text"], "bad row")
        self.assertEqual(packet["language_groups"][0]["segments"][0]["optimized_text"], "good row")

    def test_build_auto_reference_qa_records_marks_source_and_skips_rejected_rows(self):
        packet = {
            "status": {"segment_mode": "representative"},
            "language_groups": [
                {
                    "language_group": "en",
                    "segments": [
                        {"sample_id": "a", "accepted": True, "start_error_ms": 20, "end_error_ms": 40},
                        {"sample_id": "b", "accepted": False, "start_error_ms": 700, "end_error_ms": 20},
                    ],
                }
            ],
        }

        result = build_auto_reference_qa_records(packet)

        self.assertEqual(result["verdict_source"], "auto_reference")
        self.assertEqual(result["record_count"], 1)
        self.assertEqual(result["skipped_count"], 1)
        self.assertEqual(result["records"][0]["human_verdict"], "PASS")
        self.assertEqual(result["records"][0]["verdict_source"], "auto_reference")

    def test_summarize_qa_verdicts_requires_passes_per_language_group(self):
        markdown = (
            "# Subtitle Timing QA Packet\n\n"
            "## en\n\n"
            "| Review Time | Cue | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |\n"
            "| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |\n"
            "| url | sample-a | True | 0 | 0 | 0 | a | a | PASS | looks good |\n"
            "| url | sample-b | True | 0 | 0 | 0 | b | b | PASS | looks good |\n"
            "## zh\n\n"
            "| Review Time | Cue | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |\n"
            "| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |\n"
            "| url | sample-c | True | 0 | 0 | 0 | c | c | PASS | looks good |\n"
            "| url | sample-d | True | 0 | 0 | 0 | d | d | PASS | looks good |\n"
        )

        summary = summarize_qa_verdicts(markdown, required_language_groups=["en", "zh"], min_pass_per_group=2)

        self.assertTrue(summary["passes_qa_gate"])
        self.assertEqual(summary["language_groups"]["en"]["pass_count"], 2)
        self.assertEqual(summary["language_groups"]["zh"]["pass_count"], 2)
        self.assertEqual(summary["failing_language_groups"], [])

    def test_summarize_qa_verdicts_fails_on_missing_or_failed_human_verdicts(self):
        markdown = (
            "# Subtitle Timing QA Packet\n\n"
            "## en\n\n"
            "| Review Time | Cue | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |\n"
            "| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |\n"
            "| url | sample-a | True | 0 | 0 | 0 | a | a | PASS | looks good |\n"
            "| url | sample-b | True | 0 | 0 | 0 | b | b |  | not checked |\n"
            "## zh\n\n"
            "| Review Time | Cue | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |\n"
            "| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |\n"
            "| url | sample-c | True | 0 | 0 | 0 | c | c | FAIL | too late |\n"
            "| url | sample-d | True | 0 | 0 | 0 | d | d | PASS | looks good |\n"
        )

        summary = summarize_qa_verdicts(markdown, required_language_groups=["en", "zh"], min_pass_per_group=2)

        self.assertFalse(summary["passes_qa_gate"])
        self.assertEqual(summary["language_groups"]["en"]["unchecked_count"], 1)
        self.assertEqual(summary["language_groups"]["zh"]["fail_count"], 1)
        self.assertEqual(summary["failing_language_groups"], ["en", "zh"])

    def test_summarize_qa_verdicts_tracks_text_risk_verdicts_and_notes(self):
        markdown = (
            "# Subtitle Timing QA Checklist\n\n"
            "## en\n\n"
            "| Review ID | Review Time | Cue | Suggested | Text Risk | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |\n"
            "| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |\n"
            "| en:english:1 | url | english | auto_reference:PASS | low_text_overlap | True | 0 | 0 | 0 | a | b | PASS |  |\n"
            "| en:english:2 | url | english | auto_reference:PASS | expanded_vs_reference | True | 0 | 0 | 0 | a | b | FAIL | bad text |\n"
            "| en:english:3 | url | english | auto_reference:PASS | low_text_overlap | True | 0 | 0 | 0 | a | b |  |  |\n"
            "| en:english:4 | url | english | auto_reference:PASS |  | True | 0 | 0 | 0 | a | a | PASS | normal |\n"
        )

        summary = summarize_qa_verdicts(markdown, required_language_groups=["en"], min_pass_per_group=2)
        group = summary["language_groups"]["en"]

        self.assertEqual(group["text_risk_count"], 3)
        self.assertEqual(group["text_risk_pass_count"], 1)
        self.assertEqual(group["text_risk_fail_count"], 1)
        self.assertEqual(group["text_risk_unchecked_count"], 1)
        self.assertEqual(group["text_risk_pass_without_notes_count"], 1)
        self.assertEqual(group["text_risk_pass_without_notes"][0]["review_id"], "en:english:1")

    def test_summarize_qa_verdicts_can_require_notes_for_text_risk_passes(self):
        markdown = (
            "# Subtitle Timing QA Checklist\n\n"
            "## en\n\n"
            "| Review ID | Review Time | Cue | Suggested | Text Risk | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |\n"
            "| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |\n"
            "| en:english:1 | url | english | auto_reference:PASS | low_text_overlap | True | 0 | 0 | 0 | a | b | PASS |  |\n"
            "| en:english:2 | url | english | auto_reference:PASS |  | True | 0 | 0 | 0 | a | a | PASS | normal |\n"
        )

        summary = summarize_qa_verdicts(
            markdown,
            required_language_groups=["en"],
            min_pass_per_group=2,
            require_text_risk_notes=True,
        )
        group = summary["language_groups"]["en"]

        self.assertFalse(summary["passes_qa_gate"])
        self.assertTrue(summary["requires_text_risk_notes"])
        self.assertEqual(summary["failing_language_groups"], ["en"])
        self.assertEqual(group["pass_count"], 2)
        self.assertEqual(group["text_risk_pass_without_notes_count"], 1)

    def test_qa_verdicts_cli_writes_summary_before_require_pass_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            qa_report = root / "qa.md"
            output = root / "qa.verdicts.json"
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=example",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            qa_report.write_text(
                "# Subtitle Timing QA Packet\n\n"
                "## en\n\n"
                "| Review Time | Cue | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |\n"
                "| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |\n"
                "| url | sample-a | True | 0 | 0 | 0 | a | a | PASS | checked |\n"
                "| url | sample-b | True | 0 | 0 | 0 | b | b |  | not checked |\n",
                encoding="utf-8",
            )

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-verdicts",
                "--manifest",
                str(manifest),
                "--qa-report",
                str(qa_report),
                "--out",
                str(output),
                "--require-pass",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertIn("qa verdict gate failed", str(failure.exception))
        self.assertFalse(payload["passes_qa_gate"])
        self.assertEqual(payload["language_groups"]["en"]["unchecked_count"], 1)

    def test_qa_verdicts_cli_can_require_text_risk_pass_notes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            qa_report = root / "qa.md"
            output = root / "qa.verdicts.json"
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=example",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            qa_report.write_text(
                "# Subtitle Timing QA Checklist\n\n"
                "## en\n\n"
                "| Review ID | Review Time | Cue | Text Risk | Human Verdict | Notes |\n"
                "| --- | --- | --- | --- | --- | --- |\n"
                "| en:english:1 | url | sample-a | low_text_overlap | PASS |  |\n"
                "| en:english:2 | url | sample-b |  | PASS | checked |\n",
                encoding="utf-8",
            )

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-verdicts",
                "--manifest",
                str(manifest),
                "--qa-report",
                str(qa_report),
                "--out",
                str(output),
                "--require-text-risk-notes",
                "--require-pass",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertIn("qa verdict gate failed", str(failure.exception))
        self.assertFalse(payload["passes_qa_gate"])
        self.assertTrue(payload["requires_text_risk_notes"])
        self.assertEqual(payload["language_groups"]["en"]["text_risk_pass_without_notes_count"], 1)

    def test_qa_verdicts_cli_accepts_review_json_export(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            review_json = root / "qa.verdicts.review.json"
            output = root / "qa.verdicts.json"
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=example",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            review_json.write_text(json.dumps({
                "reviews": [
                    {"language_group": "en", "sample_id": "english", "human_verdict": "PASS"},
                    {"language_group": "en", "sample_id": "english", "human_verdict": "PASS"},
                ]
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-verdicts",
                "--manifest",
                str(manifest),
                "--review-json",
                str(review_json),
                "--out",
                str(output),
                "--require-pass",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertTrue(payload["passes_qa_gate"])
        self.assertEqual(payload["language_groups"]["en"]["pass_count"], 2)

    def test_qa_verdicts_cli_accepts_auto_reference_records_export(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            review_json = root / "qa.autofill.json"
            output = root / "qa.verdicts.json"
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=example",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            review_json.write_text(json.dumps({
                "verdict_source": "auto_reference",
                "records": [
                    {"language_group": "en", "sample_id": "english", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                    {"language_group": "en", "sample_id": "english", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                ],
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-verdicts",
                "--manifest",
                str(manifest),
                "--review-json",
                str(review_json),
                "--out",
                str(output),
                "--require-pass",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertTrue(payload["passes_qa_gate"])
        self.assertEqual(payload["language_groups"]["en"]["pass_count"], 2)

    def test_qa_verdicts_cli_rejects_auto_reference_when_human_source_required(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            review_json = root / "qa.autofill.json"
            output = root / "qa.verdicts.json"
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=example",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            review_json.write_text(json.dumps({
                "verdict_source": "auto_reference",
                "records": [
                    {"language_group": "en", "sample_id": "english", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                    {"language_group": "en", "sample_id": "english", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                ],
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-verdicts",
                "--manifest",
                str(manifest),
                "--review-json",
                str(review_json),
                "--out",
                str(output),
                "--require-human-source",
                "--require-pass",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertIn("qa verdict gate failed", str(failure.exception))
        self.assertFalse(payload["passes_qa_gate"])
        self.assertEqual(payload["language_groups"]["en"]["non_human_source_count"], 2)

    def test_qa_verdicts_cli_accepts_human_review_source_when_required(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            review_json = root / "qa.verdicts.review.json"
            output = root / "qa.verdicts.json"
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=example",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            review_json.write_text(json.dumps({
                "reviews": [
                    {"language_group": "en", "sample_id": "english", "human_verdict": "PASS", "verdict_source": "human_review"},
                    {"language_group": "en", "sample_id": "english", "human_verdict": "PASS", "verdict_source": "human_review"},
                ]
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-verdicts",
                "--manifest",
                str(manifest),
                "--review-json",
                str(review_json),
                "--out",
                str(output),
                "--require-human-source",
                "--require-pass",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertTrue(payload["passes_qa_gate"])
        self.assertEqual(payload["language_groups"]["en"]["non_human_source_count"], 0)

    def test_qa_verdicts_cli_uses_selection_languages_as_required_groups(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            selection = root / "manual-suite.json"
            qa_report = root / "qa.md"
            output = root / "qa.verdicts.json"
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en", "ja"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=en",
                        "category": "english_talk",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    },
                    {
                        "id": "japanese",
                        "source": "https://www.youtube.com/watch?v=ja",
                        "category": "japanese_talk",
                        "language_group": "ja",
                        "subtitle_lang": "ja",
                        "spoken_languages": ["ja"],
                        "section": {"duration_seconds": 120},
                    },
                ],
            }), encoding="utf-8")
            selection.write_text(json.dumps({
                "ready": True,
                "requested_count": 1,
                "selected": [{"id": "japanese", "suite_language": "ja"}],
            }), encoding="utf-8")
            qa_report.write_text(
                "# Subtitle Timing QA Packet\n\n"
                "## ja\n\n"
                "| Review Time | Cue | Accepted | Start ms | End ms | Hold ms | Baseline | Optimized | Human Verdict | Notes |\n"
                "| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- | --- |\n"
                "| url | sample-a | True | 0 | 0 | 0 | a | a | PASS | checked |\n"
                "| url | sample-b | True | 0 | 0 | 0 | b | b | PASS | checked |\n",
                encoding="utf-8",
            )

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-verdicts",
                "--manifest",
                str(manifest),
                "--selection",
                str(selection),
                "--qa-report",
                str(qa_report),
                "--out",
                str(output),
                "--require-pass",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertTrue(payload["passes_qa_gate"])
        self.assertEqual(payload["required_language_groups"], ["ja"])
        self.assertNotIn("en", payload["failing_language_groups"])

    def test_render_qa_checklist_markdown_shows_suggestions_without_counting_as_human_verdicts(self):
        packet = {
            "status": {
                "passes_timing_gate": True,
                "passes_sample_completion_gate": True,
                "sample_count": 1,
                "comparison_count": 1,
                "segment_mode": "representative",
                "timing_language_groups": ["en"],
                "preservation_language_groups": [],
                "missing_samples": [],
                "blocked_samples": [],
                "failing_samples": [],
            },
            "language_groups": [
                {
                    "language_group": "en",
                    "segments": [
                        {
                            "sample_id": "english",
                            "url": "https://www.youtube.com/watch?v=abc123&t=45s",
                            "accepted": True,
                            "start_error_ms": 0,
                            "end_error_ms": 0,
                            "late_hold_ms": 0,
                            "baseline_text": "Original line",
                            "optimized_text": "Optimized line",
                        }
                    ],
                }
            ],
        }

        markdown = render_qa_checklist_markdown(packet, {
            "records": [
                {
                    "review_id": "en:english:1",
                    "human_verdict": "PASS",
                    "verdict_source": "auto_reference",
                }
            ]
        })
        summary = summarize_qa_verdicts(markdown, required_language_groups=["en"], min_pass_per_group=1)

        self.assertIn("Subtitle Timing QA Checklist", markdown)
        self.assertIn("auto_reference:PASS", markdown)
        self.assertIn("Review ID", markdown)
        self.assertIn("en:english:1", markdown)
        self.assertIn("Human Verdict", markdown)
        self.assertFalse(summary["passes_qa_gate"])
        self.assertEqual(summary["language_groups"]["en"]["unchecked_count"], 1)

    def test_render_qa_remaining_queue_skips_human_reviewed_rows_only(self):
        packet = {
            "status": {
                "passes_timing_gate": True,
                "passes_sample_completion_gate": True,
                "sample_count": 1,
                "comparison_count": 1,
                "segment_mode": "representative",
                "timing_language_groups": ["en"],
                "preservation_language_groups": [],
                "missing_samples": [],
                "blocked_samples": [],
                "failing_samples": [],
            },
            "language_groups": [
                {
                    "language_group": "en",
                    "segments": [
                        {
                            "sample_id": "english",
                            "url": "https://www.youtube.com/watch?v=abc123&t=45s",
                            "accepted": True,
                            "start_error_ms": 0,
                            "end_error_ms": 0,
                            "late_hold_ms": 0,
                            "baseline_text": "Original line",
                            "optimized_text": "Optimized line",
                        },
                        {
                            "sample_id": "english",
                            "url": "https://www.youtube.com/watch?v=abc123&t=55s",
                            "accepted": True,
                            "start_error_ms": 100,
                            "end_error_ms": 100,
                            "late_hold_ms": 100,
                            "baseline_text": "Second original",
                            "optimized_text": "Second optimized",
                            "text_quality_flags": ["low_text_overlap"],
                        },
                    ],
                }
            ],
        }

        queue = render_qa_remaining_queue_markdown(
            packet,
            prefill_reviews={
                "records": [
                    {"review_id": "en:english:1", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                    {"review_id": "en:english:2", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                ]
            },
            human_reviews={
                "reviews": [
                    {"review_id": "en:english:1", "human_verdict": "PASS", "verdict_source": "human_review"}
                ]
            },
        )

        self.assertIn("human-reviewed rows: `1`", queue)
        self.assertIn("remaining rows: `1`", queue)
        self.assertIn("text-risk rows: `1`", queue)
        self.assertIn("text-risk review IDs: `en:english:2`", queue)
        self.assertIn("Review ID", queue)
        self.assertIn("en:english:2", queue)
        self.assertNotIn("t=45s", queue)
        self.assertIn("t=55s", queue)
        self.assertIn("auto_reference:PASS", queue)

    def test_render_qa_review_html_embeds_local_media_and_verdict_controls(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            sample_dir = root / "english"
            sample_dir.mkdir()
            media = sample_dir / "english.section.wav"
            media.write_bytes(b"RIFF----WAVE")
            output = root / "review" / "qa.review.html"
            manifest = {
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "title": "English sample",
                        "source": "https://www.youtube.com/watch?v=abc123",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"start_seconds": 40, "duration_seconds": 120},
                    }
                ],
            }
            packet = {
                "status": {
                    "passes_timing_gate": True,
                    "passes_sample_completion_gate": True,
                    "sample_count": 1,
                    "comparison_count": 1,
                    "timing_language_groups": ["en"],
                    "preservation_language_groups": [],
                    "missing_samples": [],
                    "blocked_samples": [],
                    "failing_samples": [],
                },
                "language_groups": [
                    {
                        "language_group": "en",
                        "sample_count": 1,
                        "samples": [
                            {
                                "sample_id": "english",
                                "title": "English sample",
                                "gate_mode": "timing",
                                "accepted_ratio": 1.0,
                                "source": "https://www.youtube.com/watch?v=abc123",
                                "section": {"start_seconds": 40, "duration_seconds": 120},
                            }
                        ],
                        "segments": [
                            {
                                "sample_id": "english",
                                "title": "English sample",
                                "gate_mode": "timing",
                                "url": "https://www.youtube.com/watch?v=abc123&t=45s",
                                "start": 45.0,
                                "end": 47.0,
                                "baseline_start": 44.0,
                                "baseline_end": 47.0,
                                "optimized_start": 45.0,
                                "optimized_end": 46.0,
                                "baseline_text": "Original line",
                                "optimized_text": "Optimized line",
                                "accepted": True,
                                "start_error_ms": 100,
                                "end_error_ms": 200,
                                "late_hold_ms": 200,
                                "score": 200,
                            }
                        ],
                    }
                ],
            }

            html = render_qa_review_html(
                packet,
                manifest,
                str(root),
                str(output),
                prefill_reviews={
                    "records": [
                        {
                            "review_id": "en:english:1",
                            "human_verdict": "PASS",
                            "verdict_source": "auto_reference",
                            "notes": "Auto-reference metrics passed.",
                        }
                    ]
                },
            )

        self.assertIn("english.section.wav#t=3.250,7.750", html)
        self.assertIn("https://www.youtube.com/watch?v=abc123&t=45s", html)
        self.assertIn("caption-preview", html)
        self.assertIn("syncCaptionPreview", html)
        self.assertIn("data-window=\"baseline\"", html)
        self.assertIn("data-window=\"optimized\"", html)
        self.assertIn("data-verdict=\"PASS\"", html)
        self.assertIn("data-verdict=\"FAIL\"", html)
        self.assertIn("Suggested by", html)
        self.assertIn("data-suggested-verdict", html)
        self.assertIn("\"suggested_verdict\": \"PASS\"", html)
        self.assertIn("verdict_source", html)
        self.assertIn("human_review", html)
        self.assertIn("Export JSON", html)

    def test_render_qa_review_html_finds_media_next_to_comparison(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            smoke_dir = root / "smoke" / "english"
            smoke_dir.mkdir(parents=True)
            (smoke_dir / "english.m4a").write_bytes(b"m4a")
            comparison = smoke_dir / "comparison.json"
            comparison.write_text("{}", encoding="utf-8")
            output = root / "qa.review.html"
            manifest = {
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "title": "English sample",
                        "source": "https://www.youtube.com/watch?v=abc123",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"start_seconds": 90, "duration_seconds": 120},
                    }
                ],
            }
            packet = {
                "status": {},
                "language_groups": [
                    {
                        "language_group": "en",
                        "segments": [
                            {
                                "sample_id": "english",
                                "comparison": str(comparison),
                                "url": "https://www.youtube.com/watch?v=abc123&t=95s",
                                "start": 95.0,
                                "end": 97.5,
                            }
                        ],
                    }
                ],
            }

            html = render_qa_review_html(packet, manifest, str(root), str(output))

        self.assertIn("smoke/english/english.m4a#t=4.250,8.250", html)

    def test_qa_review_cli_writes_html_bundle_from_artifacts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            prefill = root / "qa.autofill.json"
            output = root / "qa.review.html"
            sample_dir = root / "english"
            sample_dir.mkdir()
            (sample_dir / "english.section.wav").write_bytes(b"RIFF----WAVE")
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "title": "English sample",
                        "source": "https://www.youtube.com/watch?v=abc123",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"start_seconds": 40, "duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            (sample_dir / "baseline.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {"index": 1, "start": 45.0, "end": 47.0, "text": "Original line"}
                ]
            }), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {
                        "index": 1,
                        "start": 45.0,
                        "end": 47.0,
                        "text": "Optimized line",
                        "accepted": True,
                        "start_error_ms": 100,
                        "end_error_ms": 200,
                        "late_hold_ms": 200,
                    }
                ]
            }), encoding="utf-8")
            prefill.write_text(json.dumps({
                "records": [
                    {
                        "review_id": "en:english:1",
                        "human_verdict": "PASS",
                        "verdict_source": "auto_reference",
                    }
                ]
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-review",
                "--manifest",
                str(manifest),
                "--artifacts",
                str(root),
                "--out",
                str(output),
                "--prefill-json",
                str(prefill),
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            html = output.read_text(encoding="utf-8")

        self.assertIn("Moongate Subtitle Timing QA", html)
        self.assertIn("english.section.wav#t=4.250,7.750", html)
        self.assertIn("Suggested by", html)
        self.assertIn("Export Markdown", html)

    def test_qa_checklist_cli_writes_suggestion_columns_from_artifacts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            prefill = root / "qa.autofill.json"
            output = root / "qa.checklist.md"
            sample_dir = root / "english"
            sample_dir.mkdir()
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "title": "English sample",
                        "source": "https://www.youtube.com/watch?v=abc123",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"start_seconds": 40, "duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            (sample_dir / "baseline.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {"index": 1, "start": 45.0, "end": 47.0, "text": "Original line"}
                ]
            }), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {
                        "index": 1,
                        "start": 45.0,
                        "end": 47.0,
                        "text": "Optimized line",
                        "accepted": True,
                        "start_error_ms": 100,
                        "end_error_ms": 200,
                        "late_hold_ms": 200,
                    }
                ]
            }), encoding="utf-8")
            prefill.write_text(json.dumps({
                "records": [
                    {
                        "review_id": "en:english:1",
                        "human_verdict": "PASS",
                        "verdict_source": "auto_reference",
                    }
                ]
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-checklist",
                "--manifest",
                str(manifest),
                "--artifacts",
                str(root),
                "--out",
                str(output),
                "--prefill-json",
                str(prefill),
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            markdown = output.read_text(encoding="utf-8")

        self.assertIn("Subtitle Timing QA Checklist", markdown)
        self.assertIn("auto_reference:PASS", markdown)
        self.assertIn("Human Verdict", markdown)

    def test_qa_remaining_cli_writes_only_unreviewed_rows(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            prefill = root / "qa.autofill.json"
            human_reviews = root / "qa.review.json"
            output = root / "qa.remaining.md"
            sample_dir = root / "english"
            sample_dir.mkdir()
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "title": "English sample",
                        "source": "https://www.youtube.com/watch?v=abc123",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"start_seconds": 40, "duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            (sample_dir / "baseline.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {"index": 1, "start": 45.0, "end": 47.0, "text": "Original line"},
                    {"index": 2, "start": 55.0, "end": 57.0, "text": "Second original"},
                ]
            }), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {
                        "index": 1,
                        "start": 45.0,
                        "end": 47.0,
                        "text": "Optimized line",
                        "accepted": True,
                        "start_error_ms": 100,
                        "end_error_ms": 200,
                        "late_hold_ms": 200,
                    },
                    {
                        "index": 2,
                        "start": 55.0,
                        "end": 57.0,
                        "text": "Second optimized",
                        "accepted": True,
                        "start_error_ms": 50,
                        "end_error_ms": 50,
                        "late_hold_ms": 50,
                    },
                ]
            }), encoding="utf-8")
            prefill.write_text(json.dumps({
                "records": [
                    {"review_id": "en:english:1", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                    {"review_id": "en:english:2", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                ]
            }), encoding="utf-8")
            human_reviews.write_text(json.dumps({
                "reviews": [
                    {"review_id": "en:english:2", "human_verdict": "PASS", "verdict_source": "human_review"}
                ]
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-remaining",
                "--manifest",
                str(manifest),
                "--artifacts",
                str(root),
                "--out",
                str(output),
                "--prefill-json",
                str(prefill),
                "--human-review-json",
                str(human_reviews),
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            markdown = output.read_text(encoding="utf-8")

        self.assertIn("Subtitle Timing QA Remaining Queue", markdown)
        self.assertIn("human-reviewed rows: `1`", markdown)
        self.assertIn("remaining rows: `1`", markdown)
        self.assertNotIn("Optimized line", markdown)
        self.assertIn("Second optimized", markdown)

    def test_qa_remaining_cli_accepts_human_markdown_report(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            prefill = root / "qa.autofill.json"
            human_report = root / "qa.review.md"
            output = root / "qa.remaining.md"
            sample_dir = root / "english"
            sample_dir.mkdir()
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "title": "English sample",
                        "source": "https://www.youtube.com/watch?v=abc123",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"start_seconds": 40, "duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {"passes_timing_gate": True, "summary": {"accepted_ratio": 1.0}},
            }), encoding="utf-8")
            (sample_dir / "baseline.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {"index": 1, "start": 45.0, "end": 47.0, "text": "Original line"},
                    {"index": 2, "start": 55.0, "end": 57.0, "text": "Second original"},
                ]
            }), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps({
                "window_start_seconds": 40,
                "window_end_seconds": 160,
                "cues": [
                    {
                        "index": 1,
                        "start": 45.0,
                        "end": 47.0,
                        "text": "Optimized line",
                        "accepted": True,
                        "start_error_ms": 100,
                        "end_error_ms": 200,
                        "late_hold_ms": 200,
                    },
                    {
                        "index": 2,
                        "start": 55.0,
                        "end": 57.0,
                        "text": "Second optimized",
                        "accepted": True,
                        "start_error_ms": 50,
                        "end_error_ms": 50,
                        "late_hold_ms": 50,
                    },
                ]
            }), encoding="utf-8")
            prefill.write_text(json.dumps({
                "records": [
                    {"review_id": "en:english:1", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                    {"review_id": "en:english:2", "human_verdict": "PASS", "verdict_source": "auto_reference"},
                ]
            }), encoding="utf-8")
            human_report.write_text(
                "# Subtitle Timing QA Checklist\n\n"
                "## en\n\n"
                "| Review ID | Review Time | Cue | Suggested | Start ms | End ms | Hold ms | Optimized | Human Verdict | Notes |\n"
                "| --- | --- | --- | --- | ---: | ---: | ---: | --- | --- | --- |\n"
                "| en:english:2 | https://www.youtube.com/watch?v=abc123&t=not-the-generated-time | english | auto_reference:PASS | 100 | 200 | 200 | Optimized line | PASS | checked |\n",
                encoding="utf-8",
            )

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "qa-remaining",
                "--manifest",
                str(manifest),
                "--artifacts",
                str(root),
                "--out",
                str(output),
                "--prefill-json",
                str(prefill),
                "--human-qa-report",
                str(human_report),
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            markdown = output.read_text(encoding="utf-8")

        self.assertIn("human-reviewed rows: `1`", markdown)
        self.assertIn("remaining rows: `1`", markdown)
        self.assertNotIn("Optimized line", markdown)
        self.assertIn("Second optimized", markdown)

    def test_materialize_existing_comparisons_pairs_matching_reports(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["zh"]},
            "samples": [
                {
                    "id": "chinese",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "mandarin_talk",
                    "language_group": "zh",
                    "subtitle_lang": "zh",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            sample_dir = Path(temp_dir) / "chinese"
            sample_dir.mkdir()
            baseline = evaluate_cues(
                [Cue(index=1, start=1.0, end=3.0, text="你好")],
                [{"start": 1.1, "end": 2.2, "text": "你好"}],
                sample_id="chinese",
            )
            baseline["summary"] = summarize_report(baseline)
            optimized = evaluate_cues(
                [Cue(index=1, start=1.1, end=2.4, text="你好")],
                [{"start": 1.1, "end": 2.2, "text": "你好"}],
                sample_id="chinese",
            )
            optimized["summary"] = summarize_report(optimized)
            (sample_dir / "baseline.120-150.report.json").write_text(json.dumps(baseline), encoding="utf-8")
            (sample_dir / "optimized.120-150.report.json").write_text(json.dumps(optimized), encoding="utf-8")

            result = materialize_existing_comparisons(manifest, temp_dir)

            comparison_path = sample_dir / "comparison.120-150.json"
            comparison = json.loads(comparison_path.read_text(encoding="utf-8"))

        self.assertEqual(result["written_count"], 1)
        self.assertEqual(result["written"][0]["sample_id"], "chinese")
        self.assertEqual(result["written"][0]["gate_mode"], "preserve")
        self.assertEqual(comparison["language_group"], "zh")
        self.assertEqual(comparison["gate_mode"], "preserve")
        self.assertTrue(comparison["optimized"]["passes_timing_gate"])

    def test_materialize_existing_comparisons_uses_preserve_for_non_auto_human_caption_samples(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["es"]},
            "samples": [
                {
                    "id": "spanish",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "spanish_talk",
                    "language_group": "es",
                    "subtitle_lang": "es",
                    "spoken_languages": ["es"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["dense_speech"],
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            sample_dir = Path(temp_dir) / "spanish"
            sample_dir.mkdir()
            baseline = evaluate_cues(
                [Cue(index=1, start=1.0, end=3.0, text="Hola mundo")],
                [{"start": 1.0, "end": 3.0, "text": "Hola"}, {"start": 3.0, "end": 3.1, "text": "mundo"}],
                sample_id="spanish",
            )
            baseline["summary"] = summarize_report(baseline)
            optimized = evaluate_cues(
                [Cue(index=1, start=1.0, end=3.0, text="Hola mundo")],
                [{"start": 1.0, "end": 3.0, "text": "Hola"}, {"start": 3.0, "end": 3.1, "text": "mundo"}],
                sample_id="spanish",
            )
            optimized["summary"] = summarize_report(optimized)
            (sample_dir / "baseline.report.json").write_text(json.dumps(baseline), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps(optimized), encoding="utf-8")

            materialize_existing_comparisons(manifest, temp_dir)

            comparison = json.loads((sample_dir / "comparison.json").read_text(encoding="utf-8"))

        self.assertEqual(comparison["gate_mode"], "preserve")

    def test_select_manual_caption_suite_uses_seeded_distinct_language_manual_samples(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "ja", "es"]},
            "samples": [
                {
                    "id": "english_manual_a",
                    "source": "https://www.youtube.com/watch?v=en_a",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "english_manual_b",
                    "source": "https://www.youtube.com/watch?v=en_b",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "japanese_manual",
                    "source": "https://www.youtube.com/watch?v=ja",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "spanish_public",
                    "source": "https://www.youtube.com/watch?v=es_public",
                    "category": "spanish_talk",
                    "language_group": "es",
                    "subtitle_lang": "es",
                    "spoken_languages": ["es"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["dense_speech"],
                },
                {
                    "id": "spanish_auto",
                    "source": "https://www.youtube.com/watch?v=es_auto",
                    "category": "spanish_auto",
                    "language_group": "es-auto",
                    "subtitle_lang": "es-orig",
                    "spoken_languages": ["es"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["automatic_captions"],
                },
                {
                    "id": "french_caption_kind_auto",
                    "source": "https://www.youtube.com/watch?v=fr_auto",
                    "category": "french_auto",
                    "language_group": "fr",
                    "subtitle_lang": "fr",
                    "spoken_languages": ["fr"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["dense_speech"],
                    "caption_kind": "automatic",
                },
                {
                    "id": "german_reference_kind_autogenerated",
                    "source": "https://www.youtube.com/watch?v=de_auto",
                    "category": "german_auto",
                    "language_group": "de",
                    "subtitle_lang": "de",
                    "spoken_languages": ["de"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["dense_speech"],
                    "reference_kind": "auto-generated",
                },
            ],
        }

        first = select_manual_caption_suite(manifest, count=3, seed="suite-a")
        second = select_manual_caption_suite(manifest, count=3, seed="suite-a")

        self.assertTrue(first["ready"])
        self.assertEqual(first["selected"], second["selected"])
        self.assertEqual(first["selected_count"], 3)
        self.assertEqual(len({item["language_group"] for item in first["selected"]}), 3)
        self.assertIn("spanish_public", [item["id"] for item in first["selected"]])
        self.assertNotIn("spanish_auto", [item["id"] for item in first["selected"]])
        self.assertNotIn("french_caption_kind_auto", [item["id"] for item in first["selected"]])
        self.assertNotIn("german_reference_kind_autogenerated", [item["id"] for item in first["selected"]])
        self.assertEqual(sorted(first["available_language_groups"]), ["en", "es", "ja"])

    def test_select_manual_caption_suite_reports_shortfall_for_ten_language_goal(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "ja"]},
            "samples": [
                {
                    "id": "english_manual",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "japanese_manual",
                    "source": "https://www.youtube.com/watch?v=ja",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }

        result = select_manual_caption_suite(manifest, count=10, seed="ten-language-smoke")

        self.assertFalse(result["ready"])
        self.assertEqual(result["requested_count"], 10)
        self.assertEqual(result["selected_count"], 2)
        self.assertEqual(result["missing_distinct_language_count"], 8)
        self.assertEqual(result["rejection_reason"], "not_enough_distinct_manual_caption_languages")

    def test_select_manual_caption_suite_can_exclude_blocked_samples(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "ja"]},
            "samples": [
                {
                    "id": "english_manual",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "japanese_blocked",
                    "source": "https://www.youtube.com/watch?v=blocked",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "japanese_backup",
                    "source": "https://www.youtube.com/watch?v=backup",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }

        result = select_manual_caption_suite(
            manifest,
            count=2,
            seed="blocked-ja",
            excluded_sample_ids=["japanese_blocked"],
        )

        self.assertTrue(result["ready"])
        self.assertEqual(result["excluded_sample_ids"], ["japanese_blocked"])
        self.assertEqual({item["suite_language"] for item in result["selected"]}, {"en", "ja"})
        self.assertIn("japanese_backup", [item["id"] for item in result["selected"]])
        self.assertNotIn("japanese_blocked", [item["id"] for item in result["selected"]])

    def test_select_manual_caption_suite_deduplicates_by_spoken_language_not_translated_group(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["zh", "translated"]},
            "samples": [
                {
                    "id": "mandarin_source",
                    "source": "https://www.youtube.com/watch?v=zh",
                    "category": "mandarin_talk",
                    "language_group": "zh",
                    "subtitle_lang": "zh-TW",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "mandarin_translated",
                    "source": "https://www.youtube.com/watch?v=zh_en",
                    "category": "translated_public_subtitle",
                    "language_group": "translated",
                    "subtitle_lang": "en",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions", "translated_timing"],
                },
            ],
        }

        result = select_manual_caption_suite(manifest, count=2, seed="spoken-language")

        self.assertFalse(result["ready"])
        self.assertEqual(result["available_language_groups"], ["zh"])
        self.assertEqual(result["selected_count"], 1)
        self.assertEqual(result["missing_distinct_language_count"], 1)

    def test_select_manual_suite_cli_writes_json_and_can_require_ready(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest_path = root / "samples.json"
            output = root / "manual-suite.json"
            manifest_path.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english_manual",
                        "source": "https://www.youtube.com/watch?v=en",
                        "category": "english_talk",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                        "stressors": ["manual_captions"],
                    }
                ],
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "select-manual-suite",
                "--manifest",
                str(manifest_path),
                "--count",
                "10",
                "--seed",
                "manual-qa",
                "--out",
                str(output),
                "--require-ready",
            ]):
                with self.assertRaises(SystemExit) as context:
                    with contextlib.redirect_stdout(io.StringIO()):
                        cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertIn("manual suite is not ready", str(context.exception))
        self.assertFalse(payload["ready"])
        self.assertEqual(payload["selected_count"], 1)
        self.assertEqual(payload["missing_distinct_language_count"], 9)

    def test_collect_manual_suite_status_filters_to_selected_source_languages(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "zh", "ja"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "mandarin_translated",
                    "source": "https://www.youtube.com/watch?v=zh_en",
                    "category": "translated_public_subtitle",
                    "language_group": "translated",
                    "subtitle_lang": "en",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions", "translated_timing"],
                },
                {
                    "id": "unselected_japanese",
                    "source": "https://www.youtube.com/watch?v=ja",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }
        selection = {
            "ready": True,
            "requested_count": 2,
            "selected": [
                {"id": "english", "suite_language": "en"},
                {"id": "mandarin_translated", "suite_language": "zh"},
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            english_dir = Path(temp_dir) / "english"
            english_dir.mkdir()
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "preserve",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 0.95},
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            status = collect_manual_suite_status(manifest, selection, temp_dir)

        self.assertFalse(status["passes_manual_suite_gate"])
        self.assertEqual(status["required_language_groups"], ["en", "zh"])
        self.assertEqual(status["missing_samples"], ["mandarin_translated"])
        self.assertNotIn("unselected_japanese", status["missing_samples"])
        self.assertEqual(status["samples"]["mandarin_translated"]["language_group"], "zh")

    def test_collect_manual_suite_status_requires_strict_timing_not_only_preserve(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }
        selection = {
            "ready": True,
            "requested_count": 1,
            "selected": [{"id": "english", "suite_language": "en"}],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            english_dir = Path(temp_dir) / "english"
            english_dir.mkdir()
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "preserve",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 1.0},
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            status = collect_manual_suite_status(manifest, selection, temp_dir)

        self.assertTrue(status["passes_language_coverage_gate"])
        self.assertTrue(status["passes_sample_completion_gate"])
        self.assertFalse(status["passes_strict_timing_gate"])
        self.assertFalse(status["passes_manual_suite_gate"])
        self.assertEqual(status["preservation_language_groups"], ["en"])
        self.assertEqual(status["missing_strict_timing_language_groups"], ["en"])

    def test_manual_suite_status_cli_writes_scoped_status_and_can_require_ready(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest_path = root / "samples.json"
            selection_path = root / "manual-suite.json"
            output = root / "manual-suite-status.json"
            artifacts = root / "artifacts"
            manifest_path.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en", "zh"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=en",
                        "category": "english_talk",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                        "stressors": ["manual_captions"],
                    },
                    {
                        "id": "mandarin_translated",
                        "source": "https://www.youtube.com/watch?v=zh_en",
                        "category": "translated_public_subtitle",
                        "language_group": "translated",
                        "subtitle_lang": "en",
                        "spoken_languages": ["zh"],
                        "section": {"duration_seconds": 120},
                        "stressors": ["manual_captions", "translated_timing"],
                    },
                    {
                        "id": "unselected_mandarin",
                        "source": "https://www.youtube.com/watch?v=zh",
                        "category": "mandarin_talk",
                        "language_group": "zh",
                        "subtitle_lang": "zh",
                        "spoken_languages": ["zh"],
                        "section": {"duration_seconds": 120},
                        "stressors": ["manual_captions"],
                    },
                ],
            }), encoding="utf-8")
            selection_path.write_text(json.dumps({
                "ready": True,
                "requested_count": 2,
                "selected": [
                    {"id": "english", "suite_language": "en"},
                    {"id": "mandarin_translated", "suite_language": "zh"},
                ],
            }), encoding="utf-8")
            english_dir = artifacts / "english"
            english_dir.mkdir(parents=True)
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "preserve",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 1.0},
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "manual-suite-status",
                "--manifest",
                str(manifest_path),
                "--selection",
                str(selection_path),
                "--artifacts",
                str(artifacts),
                "--out",
                str(output),
                "--require-ready",
            ]):
                with self.assertRaises(SystemExit) as context:
                    with contextlib.redirect_stdout(io.StringIO()):
                        cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertIn("manual suite gate failed", str(context.exception))
        self.assertFalse(payload["passes_manual_suite_gate"])
        self.assertEqual(payload["required_language_groups"], ["en", "zh"])
        self.assertEqual(payload["missing_samples"], ["mandarin_translated"])
        self.assertNotIn("unselected_mandarin", payload["missing_samples"])
        self.assertEqual(payload["comparison_count"], 1)

    def test_completion_audit_keeps_goal_open_until_human_qa_passes(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "ja"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "japanese",
                    "source": "https://www.youtube.com/watch?v=ja",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                },
            ],
        }
        selection = {
            "ready": True,
            "requested_count": 2,
            "selected_count": 2,
            "requires_human_captions": True,
            "distinct_language_groups_required": True,
            "seed": "unit-seed",
            "selected": [
                {"id": "english", "suite_language": "en"},
                {"id": "japanese", "suite_language": "ja"},
            ],
        }
        passing_qa = {
            "passes_qa_gate": True,
            "failing_language_groups": [],
            "verdict_input_type": "json",
            "requires_human_source": True,
            "language_groups": {
                "en": {"pass_count": 2, "fail_count": 0, "unchecked_count": 0},
                "ja": {"pass_count": 2, "fail_count": 0, "unchecked_count": 0},
            },
        }
        unchecked_human_qa = {
            "passes_qa_gate": False,
            "failing_language_groups": ["en", "ja"],
            "language_groups": {
                "en": {"pass_count": 0, "fail_count": 0, "unchecked_count": 2},
                "ja": {"pass_count": 0, "fail_count": 0, "unchecked_count": 2},
            },
        }
        audit = {"passes_all_seed_gates": True, "passing_seed_count": 3, "seed_count": 3}

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_passing_comparison(root, "english", "en", accepted_ratio=1.0)
            self._write_passing_comparison(root, "japanese", "ja", accepted_ratio=0.95)

            result = build_completion_audit(
                manifest,
                selection,
                temp_dir,
                audit=audit,
                auto_qa=passing_qa,
                human_qa=unchecked_human_qa,
                expected_count=2,
            )

        self.assertTrue(result["machine_ready"])
        self.assertFalse(result["human_verified"])
        self.assertFalse(result["goal_complete"])
        self.assertIn("Finish human side-by-side QA", result["remaining_work"][0])
        self.assertEqual(
            [item["accepted_ratio"] for item in result["sample_results"]],
            [1.0, 0.95],
        )

    def test_completion_audit_completes_when_human_qa_gate_passes(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "ja"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "japanese",
                    "source": "https://www.youtube.com/watch?v=ja",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                },
            ],
        }
        selection = {
            "ready": True,
            "requested_count": 2,
            "selected_count": 2,
            "requires_human_captions": True,
            "distinct_language_groups_required": True,
            "seed": "unit-seed",
            "selected": [
                {"id": "english", "suite_language": "en"},
                {"id": "japanese", "suite_language": "ja"},
            ],
        }
        passing_qa = {
            "passes_qa_gate": True,
            "failing_language_groups": [],
            "verdict_input_type": "json",
            "requires_human_source": True,
            "language_groups": {
                "en": {"pass_count": 2, "fail_count": 0, "unchecked_count": 0},
                "ja": {"pass_count": 2, "fail_count": 0, "unchecked_count": 0},
            },
        }
        audit = {"passes_all_seed_gates": True, "passing_seed_count": 3, "seed_count": 3}

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_passing_comparison(root, "english", "en", accepted_ratio=1.0)
            self._write_passing_comparison(root, "japanese", "ja", accepted_ratio=0.95)

            result = build_completion_audit(
                manifest,
                selection,
                temp_dir,
                audit=audit,
                auto_qa=passing_qa,
                human_qa=passing_qa,
                expected_count=2,
            )

        self.assertTrue(result["machine_ready"])
        self.assertTrue(result["human_verified"])
        self.assertTrue(result["goal_complete"])
        self.assertEqual(result["remaining_work"], [])

    def test_completion_audit_reports_text_quality_risk_rows(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
            ],
        }
        selection = {
            "ready": True,
            "requested_count": 1,
            "selected_count": 1,
            "requires_human_captions": True,
            "distinct_language_groups_required": True,
            "seed": "unit-seed",
            "selected": [
                {"id": "english", "suite_language": "en"},
            ],
        }
        passing_qa = {
            "passes_qa_gate": True,
            "failing_language_groups": [],
            "verdict_input_type": "json",
            "requires_human_source": True,
            "language_groups": {
                "en": {"pass_count": 1, "fail_count": 0, "unchecked_count": 0},
            },
        }
        audit = {"passes_all_seed_gates": True, "passing_seed_count": 3, "seed_count": 3}

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_passing_comparison(root, "english", "en", accepted_ratio=1.0)
            sample_dir = root / "english"
            (sample_dir / "baseline.report.json").write_text(json.dumps({
                "window_start_seconds": 0,
                "window_end_seconds": 120,
                "cues": [{"index": 1, "start": 1.0, "end": 3.0, "text": "These are the engine cores"}],
            }), encoding="utf-8")
            (sample_dir / "optimized.report.json").write_text(json.dumps({
                "window_start_seconds": 0,
                "window_end_seconds": 120,
                "cues": [{
                    "index": 1,
                    "start": 1.0,
                    "end": 3.0,
                    "text": "sand wich zebra xray quantum static",
                    "accepted": True,
                    "start_error_ms": 0,
                    "end_error_ms": 0,
                }],
            }), encoding="utf-8")

            result = build_completion_audit(
                manifest,
                selection,
                temp_dir,
                audit=audit,
                auto_qa=passing_qa,
                human_qa=passing_qa,
                expected_count=1,
                min_pass_per_group=1,
            )

        self.assertEqual(result["text_quality_risk_count"], 1)
        self.assertEqual(result["text_quality_risks"][0]["review_id"], "en:english:1")
        self.assertEqual(result["text_quality_risks"][0]["text_quality_flags"], ["low_text_overlap"])
        self.assertTrue(result["goal_complete"])

    def test_completion_audit_requires_notes_for_human_text_risk_passes(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=en",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
            ],
        }
        selection = {
            "ready": True,
            "requested_count": 1,
            "selected_count": 1,
            "requires_human_captions": True,
            "distinct_language_groups_required": True,
            "seed": "unit-seed",
            "selected": [
                {"id": "english", "suite_language": "en"},
            ],
        }
        passing_qa = {
            "passes_qa_gate": True,
            "failing_language_groups": [],
            "verdict_input_type": "json",
            "requires_human_source": True,
            "language_groups": {
                "en": {"pass_count": 1, "fail_count": 0, "unchecked_count": 0},
            },
        }
        human_qa_with_unnoted_risk = {
            "passes_qa_gate": True,
            "failing_language_groups": [],
            "verdict_input_type": "markdown",
            "requires_text_risk_notes": True,
            "language_groups": {
                "en": {
                    "pass_count": 1,
                    "fail_count": 0,
                    "unchecked_count": 0,
                    "text_risk_pass_without_notes_count": 1,
                },
            },
        }
        audit = {"passes_all_seed_gates": True, "passing_seed_count": 3, "seed_count": 3}

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            self._write_passing_comparison(root, "english", "en", accepted_ratio=1.0)

            result = build_completion_audit(
                manifest,
                selection,
                temp_dir,
                audit=audit,
                auto_qa=passing_qa,
                human_qa=human_qa_with_unnoted_risk,
                expected_count=1,
                min_pass_per_group=1,
                require_text_risk_notes=True,
            )

        self.assertTrue(result["machine_ready"])
        self.assertFalse(result["human_verified"])
        self.assertFalse(result["goal_complete"])
        self.assertIn("Finish human side-by-side QA", result["remaining_work"][0])

    def test_completion_audit_cli_writes_report_before_require_complete_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest_path = root / "samples.json"
            selection_path = root / "selection.json"
            audit_path = root / "audit.json"
            auto_qa_path = root / "auto-qa.json"
            human_qa_path = root / "human-qa.json"
            output = root / "completion.json"
            artifacts = root / "artifacts"
            manifest_path.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en", "ja"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=en",
                        "category": "english_talk",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    },
                    {
                        "id": "japanese",
                        "source": "https://www.youtube.com/watch?v=ja",
                        "category": "japanese_talk",
                        "language_group": "ja",
                        "subtitle_lang": "ja",
                        "spoken_languages": ["ja"],
                        "section": {"duration_seconds": 120},
                    },
                ],
            }), encoding="utf-8")
            selection_path.write_text(json.dumps({
                "ready": True,
                "requested_count": 2,
                "selected_count": 2,
                "requires_human_captions": True,
                "distinct_language_groups_required": True,
                "seed": "unit-seed",
                "selected": [
                    {"id": "english", "suite_language": "en"},
                    {"id": "japanese", "suite_language": "ja"},
                ],
            }), encoding="utf-8")
            audit_path.write_text(json.dumps({"passes_all_seed_gates": True, "passing_seed_count": 3, "seed_count": 3}), encoding="utf-8")
            passing_qa = {
                "passes_qa_gate": True,
                "failing_language_groups": [],
                "language_groups": {
                    "en": {"pass_count": 2, "fail_count": 0, "unchecked_count": 0},
                    "ja": {"pass_count": 2, "fail_count": 0, "unchecked_count": 0},
                },
            }
            auto_qa_path.write_text(json.dumps(passing_qa), encoding="utf-8")
            human_qa_path.write_text(json.dumps({
                "passes_qa_gate": False,
                "failing_language_groups": ["en"],
                "language_groups": {
                    "en": {"pass_count": 1, "fail_count": 0, "unchecked_count": 1},
                    "ja": {"pass_count": 2, "fail_count": 0, "unchecked_count": 0},
                },
            }), encoding="utf-8")
            self._write_passing_comparison(artifacts, "english", "en", accepted_ratio=1.0)
            self._write_passing_comparison(artifacts, "japanese", "ja", accepted_ratio=0.95)

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "completion-audit",
                "--manifest",
                str(manifest_path),
                "--selection",
                str(selection_path),
                "--artifacts",
                str(artifacts),
                "--audit-json",
                str(audit_path),
                "--auto-qa-json",
                str(auto_qa_path),
                "--human-qa-json",
                str(human_qa_path),
                "--expected-count",
                "2",
                "--out",
                str(output),
                "--require-complete",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertIn("completion audit failed", str(failure.exception))
        self.assertTrue(payload["machine_ready"])
        self.assertFalse(payload["goal_complete"])

    def test_completion_audit_cli_accepts_markdown_human_qa_report(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest_path = root / "samples.json"
            selection_path = root / "selection.json"
            audit_path = root / "audit.json"
            auto_qa_path = root / "auto-qa.json"
            human_qa_report = root / "human-qa.md"
            output = root / "completion.json"
            artifacts = root / "artifacts"
            manifest_path.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en", "ja"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=en",
                        "category": "english_talk",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    },
                    {
                        "id": "japanese",
                        "source": "https://www.youtube.com/watch?v=ja",
                        "category": "japanese_talk",
                        "language_group": "ja",
                        "subtitle_lang": "ja",
                        "spoken_languages": ["ja"],
                        "section": {"duration_seconds": 120},
                    },
                ],
            }), encoding="utf-8")
            selection_path.write_text(json.dumps({
                "ready": True,
                "requested_count": 2,
                "selected_count": 2,
                "requires_human_captions": True,
                "distinct_language_groups_required": True,
                "seed": "unit-seed",
                "selected": [
                    {"id": "english", "suite_language": "en"},
                    {"id": "japanese", "suite_language": "ja"},
                ],
            }), encoding="utf-8")
            audit_path.write_text(json.dumps({"passes_all_seed_gates": True, "passing_seed_count": 3, "seed_count": 3}), encoding="utf-8")
            passing_qa = {
                "passes_qa_gate": True,
                "failing_language_groups": [],
                "language_groups": {
                    "en": {"pass_count": 2, "fail_count": 0, "unchecked_count": 0},
                    "ja": {"pass_count": 2, "fail_count": 0, "unchecked_count": 0},
                },
            }
            auto_qa_path.write_text(json.dumps(passing_qa), encoding="utf-8")
            human_qa_report.write_text(
                "\n".join([
                    "# Subtitle Timing QA Checklist",
                    "",
                    "## en",
                    "",
                    "| Review Time | Cue | Human Verdict | Notes |",
                    "| --- | --- | --- | --- |",
                    "| english.section.wav#t=1.000,2.000 | english | PASS | ok |",
                    "| english.section.wav#t=3.000,4.000 | english | PASS | ok |",
                    "",
                    "## ja",
                    "",
                    "| Review Time | Cue | Human Verdict | Notes |",
                    "| --- | --- | --- | --- |",
                    "| japanese.section.wav#t=1.000,2.000 | japanese | PASS | ok |",
                    "| japanese.section.wav#t=3.000,4.000 | japanese | PASS | ok |",
                    "",
                ]),
                encoding="utf-8",
            )
            self._write_passing_comparison(artifacts, "english", "en", accepted_ratio=1.0)
            self._write_passing_comparison(artifacts, "japanese", "ja", accepted_ratio=0.95)

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "completion-audit",
                "--manifest",
                str(manifest_path),
                "--selection",
                str(selection_path),
                "--artifacts",
                str(artifacts),
                "--audit-json",
                str(audit_path),
                "--auto-qa-json",
                str(auto_qa_path),
                "--human-qa-report",
                str(human_qa_report),
                "--expected-count",
                "2",
                "--out",
                str(output),
                "--require-complete",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertTrue(payload["machine_ready"])
        self.assertTrue(payload["human_verified"])
        self.assertTrue(payload["goal_complete"])
        self.assertEqual(payload["remaining_work"], [])

    def test_audit_manual_caption_suite_reports_seed_gates_and_thin_language_groups(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "ja", "zh"]},
            "samples": [
                {
                    "id": "english_a",
                    "source": "https://www.youtube.com/watch?v=en_a",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "english_b",
                    "source": "https://www.youtube.com/watch?v=en_b",
                    "category": "english_talk",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "japanese",
                    "source": "https://www.youtube.com/watch?v=ja",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
                {
                    "id": "mandarin",
                    "source": "https://www.youtube.com/watch?v=zh",
                    "category": "mandarin_talk",
                    "language_group": "zh",
                    "subtitle_lang": "zh",
                    "spoken_languages": ["zh"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions"],
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            for sample_id, language_group in [
                ("english_a", "en"),
                ("english_b", "en"),
                ("japanese", "ja"),
                ("mandarin", "zh"),
            ]:
                sample_dir = Path(temp_dir) / sample_id
                sample_dir.mkdir()
                (sample_dir / "comparison.json").write_text(json.dumps({
                    "sample_id": sample_id,
                    "language_group": language_group,
                    "gate_mode": "timing",
                    "optimized": {
                        "passes_timing_gate": True,
                        "summary": {"accepted_ratio": 1.0},
                        "gate_failures": [],
                    },
                }), encoding="utf-8")

            audit = audit_manual_caption_suite(
                manifest,
                temp_dir,
                seeds=["audit-a", "audit-b", "audit-c"],
                count=3,
            )

        self.assertTrue(audit["passes_all_seed_gates"])
        self.assertEqual(audit["seed_count"], 3)
        self.assertEqual(audit["passing_seed_count"], 3)
        self.assertEqual(audit["language_candidate_counts"], {"en": 2, "ja": 1, "zh": 1})
        self.assertEqual(audit["thin_language_groups"], ["ja", "zh"])
        self.assertEqual(audit["effective_random_language_groups"], ["en"])
        self.assertEqual(len(audit["seed_results"]), 3)

    def test_manual_suite_audit_cli_writes_json_before_require_pass_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest_path = root / "samples.json"
            artifacts = root / "artifacts"
            output = root / "audit.json"
            manifest_path.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en", "ja"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=en",
                        "category": "english_talk",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                        "stressors": ["manual_captions"],
                    },
                    {
                        "id": "japanese",
                        "source": "https://www.youtube.com/watch?v=ja",
                        "category": "japanese_talk",
                        "language_group": "ja",
                        "subtitle_lang": "ja",
                        "spoken_languages": ["ja"],
                        "section": {"duration_seconds": 120},
                        "stressors": ["manual_captions"],
                    },
                ],
            }), encoding="utf-8")
            english_dir = artifacts / "english"
            english_dir.mkdir(parents=True)
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {"accepted_ratio": 1.0},
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "manual-suite-audit",
                "--manifest",
                str(manifest_path),
                "--artifacts",
                str(artifacts),
                "--count",
                "2",
                "--seed",
                "audit-fail",
                "--out",
                str(output),
                "--require-pass",
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertIn("manual suite audit failed", str(failure.exception))
        self.assertFalse(payload["passes_all_seed_gates"])
        self.assertEqual(payload["failing_seed_count"], 1)
        self.assertEqual(payload["seed_results"][0]["missing_samples"], ["japanese"])

    def test_iteration_report_prioritizes_cross_sample_failure_modes(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "ja"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "japanese",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            english_dir = root / "english"
            english_dir.mkdir()
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": False,
                    "summary": {
                        "accepted_ratio": 0.42,
                        "p90_abs_start_error_ms": 760,
                        "p90_abs_end_error_ms": 1200,
                        "early_cutoff_count": 3,
                        "long_idle_hold_count": 0,
                        "weak_boundary_count": 2,
                        "cjk_singleton_count": 0,
                        "p90_reading_speed_chars_per_second": 18,
                    },
                    "gate_failures": ["accepted_ratio", "early_cutoff"],
                },
            }), encoding="utf-8")
            (english_dir / "optimized.report.json").write_text(json.dumps({
                "window_start_seconds": 0,
                "window_end_seconds": 120,
                "cues": [
                    {
                        "index": 1,
                        "start": 1.0,
                        "end": 2.0,
                        "text": "This breaks and",
                        "accepted": False,
                        "start_error_ms": 760,
                        "end_error_ms": -1200,
                        "early_cutoff_ms": 1200,
                        "late_hold_ms": 0,
                        "long_idle_hold_ms": 0,
                        "weak_boundary": True,
                        "cjk_singleton": False,
                    }
                ],
            }), encoding="utf-8")
            japanese_dir = root / "japanese"
            japanese_dir.mkdir()
            (japanese_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "japanese",
                "language_group": "ja",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": False,
                    "summary": {
                        "accepted_ratio": 0.65,
                        "p90_abs_start_error_ms": 300,
                        "p90_abs_end_error_ms": 300,
                        "early_cutoff_count": 0,
                        "long_idle_hold_count": 0,
                        "weak_boundary_count": 0,
                        "cjk_singleton_count": 1,
                        "p90_reading_speed_chars_per_second": 9,
                    },
                    "gate_failures": ["accepted_ratio", "cjk_singleton"],
                },
            }), encoding="utf-8")
            (japanese_dir / "optimized.report.json").write_text(json.dumps({
                "window_start_seconds": 0,
                "window_end_seconds": 120,
                "cues": [
                    {
                        "index": 1,
                        "start": 4.0,
                        "end": 6.5,
                        "text": "ね",
                        "accepted": False,
                        "start_error_ms": 300,
                        "end_error_ms": 300,
                        "early_cutoff_ms": 0,
                        "late_hold_ms": 300,
                        "long_idle_hold_ms": 0,
                        "weak_boundary": False,
                        "cjk_singleton": True,
                    }
                ],
            }), encoding="utf-8")

            report = build_iteration_report(manifest, str(root), max_examples_per_issue=1)

        self.assertFalse(report["ready_for_release"])
        self.assertEqual(report["status"]["failing_samples"], ["english", "japanese"])
        self.assertEqual(report["top_priorities"][0]["issue"], "accepted_ratio")
        self.assertIn("early_cutoff", [item["issue"] for item in report["top_priorities"]])
        self.assertIn("cjk_singleton", [item["issue"] for item in report["top_priorities"]])
        self.assertEqual(report["language_groups"]["en"]["issues"]["early_cutoff"]["sample_count"], 1)
        self.assertEqual(report["language_groups"]["ja"]["issues"]["cjk_singleton"]["sample_count"], 1)
        self.assertEqual(report["examples_by_issue"]["weak_boundary"][0]["text"], "This breaks and")
        self.assertEqual(report["examples_by_issue"]["cjk_singleton"][0]["text"], "ね")

    def test_iteration_report_cli_writes_release_readiness_summary(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            output = root / "iteration.json"
            sample_dir = root / "english"
            sample_dir.mkdir()
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=example",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    }
                ],
            }), encoding="utf-8")
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {
                        "accepted_ratio": 0.95,
                        "p90_abs_start_error_ms": 200,
                        "p90_abs_end_error_ms": 300,
                        "early_cutoff_count": 0,
                        "long_idle_hold_count": 0,
                        "weak_boundary_count": 0,
                        "cjk_singleton_count": 0,
                        "p90_reading_speed_chars_per_second": 12,
                    },
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "iteration-report",
                "--manifest",
                str(manifest),
                "--artifacts",
                str(root),
                "--out",
                str(output),
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertTrue(payload["ready_for_release"])
        self.assertEqual(payload["top_priorities"], [])

    def test_iteration_report_cli_can_scope_to_manual_selection(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            manifest = root / "samples.json"
            selection_path = root / "manual-suite.json"
            output = root / "iteration.json"
            english_dir = root / "english"
            english_dir.mkdir()
            manifest.write_text(json.dumps({
                "coverage_goal": {"required_language_groups": ["en", "ja", "fr"]},
                "samples": [
                    {
                        "id": "english",
                        "source": "https://www.youtube.com/watch?v=en",
                        "category": "english_interview",
                        "language_group": "en",
                        "subtitle_lang": "en",
                        "spoken_languages": ["en"],
                        "section": {"duration_seconds": 120},
                    },
                    {
                        "id": "japanese",
                        "source": "https://www.youtube.com/watch?v=ja",
                        "category": "japanese_talk",
                        "language_group": "ja",
                        "subtitle_lang": "ja",
                        "spoken_languages": ["ja"],
                        "section": {"duration_seconds": 120},
                    },
                    {
                        "id": "french_unselected",
                        "source": "https://www.youtube.com/watch?v=fr",
                        "category": "french_talk",
                        "language_group": "fr",
                        "subtitle_lang": "fr",
                        "spoken_languages": ["fr"],
                        "section": {"duration_seconds": 120},
                    },
                ],
            }), encoding="utf-8")
            selection_path.write_text(json.dumps({
                "ready": True,
                "requested_count": 2,
                "selected_count": 2,
                "selected": [
                    {"id": "english", "suite_language": "en"},
                    {"id": "japanese", "suite_language": "ja"},
                ],
            }), encoding="utf-8")
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {
                        "accepted_ratio": 0.95,
                        "p90_abs_start_error_ms": 200,
                        "p90_abs_end_error_ms": 300,
                        "early_cutoff_count": 0,
                        "long_idle_hold_count": 0,
                        "weak_boundary_count": 0,
                        "cjk_singleton_count": 0,
                        "p90_reading_speed_chars_per_second": 12,
                    },
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            with patch.object(sys, "argv", [
                "subtitle_timing_eval",
                "iteration-report",
                "--manifest",
                str(manifest),
                "--artifacts",
                str(root),
                "--selection",
                str(selection_path),
                "--out",
                str(output),
            ]):
                with contextlib.redirect_stdout(io.StringIO()):
                    cli_main()

            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(payload["report_scope"], "manual_suite")
        self.assertEqual(payload["status"]["sample_count"], 2)
        self.assertEqual(set(payload["language_groups"]), {"en", "ja"})
        self.assertEqual(payload["top_priorities"][0]["issue"], "missing_artifact")
        self.assertEqual(payload["top_priorities"][0]["samples"], ["japanese"])

    def test_iteration_report_does_not_force_strict_ratio_on_passing_preserve_samples(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["translated"]},
            "samples": [
                {
                    "id": "translated",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "auto_translate",
                    "language_group": "translated",
                    "subtitle_lang": "zh-CN",
                    "alignment_mode": "overlap",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                    "stressors": ["manual_captions", "translated_timing"],
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            sample_dir = Path(temp_dir) / "translated"
            sample_dir.mkdir()
            (sample_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "translated",
                "language_group": "translated",
                "gate_mode": "preserve",
                "optimized": {
                    "passes_timing_gate": True,
                    "passes_preservation_gate": True,
                    "summary": {
                        "accepted_ratio": 0.35,
                        "p90_abs_start_error_ms": 1800,
                        "p90_abs_end_error_ms": 1600,
                        "early_cutoff_count": 4,
                        "long_idle_hold_count": 0,
                        "weak_boundary_count": 0,
                        "cjk_singleton_count": 0,
                        "p90_reading_speed_chars_per_second": 12,
                    },
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            report = build_iteration_report(manifest, temp_dir)

        self.assertTrue(report["ready_for_release"])
        self.assertEqual(report["top_priorities"], [])

    def test_iteration_report_prioritizes_missing_evidence_before_algorithm_tuning(self):
        manifest = {
            "coverage_goal": {"required_language_groups": ["en", "ja"]},
            "samples": [
                {
                    "id": "english",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                },
                {
                    "id": "japanese",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "japanese_talk",
                    "language_group": "ja",
                    "subtitle_lang": "ja",
                    "spoken_languages": ["ja"],
                    "section": {"duration_seconds": 120},
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            english_dir = Path(temp_dir) / "english"
            english_dir.mkdir()
            (english_dir / "comparison.json").write_text(json.dumps({
                "sample_id": "english",
                "language_group": "en",
                "gate_mode": "timing",
                "optimized": {
                    "passes_timing_gate": True,
                    "summary": {
                        "accepted_ratio": 0.95,
                        "p90_abs_start_error_ms": 200,
                        "p90_abs_end_error_ms": 300,
                        "early_cutoff_count": 0,
                        "long_idle_hold_count": 0,
                        "weak_boundary_count": 12,
                        "cjk_singleton_count": 0,
                        "p90_reading_speed_chars_per_second": 12,
                    },
                    "gate_failures": [],
                },
            }), encoding="utf-8")

            report = build_iteration_report(manifest, temp_dir)

        self.assertEqual(report["top_priorities"][0]["issue"], "missing_artifact")
        self.assertEqual(report["top_priorities"][1]["issue"], "weak_boundary")


class ManifestTests(unittest.TestCase):
    def test_sample_manifest_has_required_coverage(self):
        manifest_path = Path(__file__).resolve().parents[1] / "samples.json"
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        samples = data["samples"]
        categories = {sample["category"] for sample in samples}
        required_groups = set(data["coverage_goal"]["required_language_groups"])
        language_groups = {sample["language_group"] for sample in samples}

        self.assertGreaterEqual(len(samples), 10)
        self.assertIn("english_interview", categories)
        self.assertIn("japanese_talk", categories)
        self.assertIn("japanese_animation", categories)
        self.assertIn("korean_talk", categories)
        self.assertIn("cantonese_chinese", categories)
        self.assertIn("mandarin_talk", categories)
        self.assertIn("spanish_talk", categories)
        self.assertIn("french_talk", categories)
        self.assertIn("italian_talk", categories)
        self.assertIn("music_lyrics", categories)
        self.assertIn("auto_translate", categories)
        self.assertEqual(
            required_groups,
            {"en", "zh", "yue", "ja", "ko", "es", "fr", "it", "translated"},
        )
        self.assertTrue(required_groups.issubset(language_groups))
        self.assertGreaterEqual(
            sum(1 for sample in samples if "long_pause_short_feedback" in sample.get("stressors", [])),
            2,
        )
        for sample in samples:
            self.assertTrue(sample["id"])
            self.assertTrue(sample["source"])
            self.assertTrue(sample["language_group"])
            self.assertGreaterEqual(sample["section"]["duration_seconds"], 60)
            self.assertLessEqual(sample["section"]["duration_seconds"], 360)
        for sample in samples:
            if sample["category"] == "auto_translate":
                self.assertEqual(sample.get("alignment_mode"), "overlap")

    def test_sample_manifest_can_select_ten_distinct_manual_caption_source_languages(self):
        manifest_path = Path(__file__).resolve().parents[1] / "samples.json"
        data = json.loads(manifest_path.read_text(encoding="utf-8"))

        result = select_manual_caption_suite(
            data,
            count=10,
            seed="manual-caption-suite-2026-06-22",
        )

        self.assertTrue(result["ready"])
        self.assertEqual(result["selected_count"], 10)
        self.assertEqual(len({item["suite_language"] for item in result["selected"]}), 10)

    def test_manifest_validation_rejects_missing_mainstream_language_group(self):
        data = {
            "coverage_goal": {"required_language_groups": ["en", "zh"]},
            "samples": [
                {
                    "id": "en_only",
                    "source": "https://www.youtube.com/watch?v=example",
                    "category": "english_interview",
                    "language_group": "en",
                    "subtitle_lang": "en",
                    "spoken_languages": ["en"],
                    "section": {"duration_seconds": 120},
                }
            ],
        }

        with self.assertRaisesRegex(ValueError, "missing required language groups: zh"):
            validate_manifest(data)


if __name__ == "__main__":
    unittest.main()
