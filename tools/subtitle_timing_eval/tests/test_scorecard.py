import unittest
import tempfile
from pathlib import Path

from subtitle_timing_eval.srt import Cue
from subtitle_timing_eval import scorecard as sc
import run_scorecard_baseline as runner


def _cues(texts, *, dur=2.0, gap=0.0):
    cues = []
    t = 0.0
    for i, text in enumerate(texts, start=1):
        cues.append(Cue(index=i, start=t, end=t + dur, text=text))
        t += dur + gap
    return cues


class LevenshteinTests(unittest.TestCase):
    def test_identical(self):
        self.assertEqual(sc.levenshtein("abc", "abc"), 0)

    def test_substitution(self):
        self.assertEqual(sc.levenshtein("abc", "abd"), 1)

    def test_empty(self):
        self.assertEqual(sc.levenshtein("", "abc"), 3)
        self.assertEqual(sc.levenshtein("abc", ""), 3)


class ReferenceSimilarityTests(unittest.TestCase):
    def test_cjk_perfect_ignores_punct(self):
        score = sc.reference_similarity_score("今日はいい天気。", "今日は、いい天気", language_code="ja")
        self.assertEqual(score, 100.0)

    def test_cjk_reference_ignores_romanization_and_translation_lines(self):
        candidate = "鸭子多少钱\n鸭子14块钱\n17\n14\n14\n对对对"
        reference = """Yāzi duōshao qián
鸭子多少钱
How much is the duck?
Yāzi shísì kuài qián
鸭子14块钱
The duck is 14 kuai.
Shíqī?
17？
Shísì
14
Shísì
14
Duì duì duì
对对对
Yes, yes, yes"""

        score = sc.reference_similarity_score(candidate, reference, language_code="zh")

        self.assertEqual(score, 100.0)

    def test_cjk_reference_keeps_sparse_english_code_switch_lines(self):
        candidate = "文化問題\nActually, I am a linguist.\n身份保存問題"
        reference = "文化問題\nActually, I am a linguist.\n身份保存問題"

        score = sc.reference_similarity_score(candidate, reference, language_code="zh")

        self.assertEqual(score, 100.0)

    def test_cjk_partial(self):
        score = sc.reference_similarity_score("今日はいい天気", "今日は悪い天気", language_code="ja")
        self.assertTrue(0 < score < 100)

    def test_latin_word_level(self):
        score = sc.reference_similarity_score("the cat sat", "the cat sat", language_code="en")
        self.assertEqual(score, 100.0)
        worse = sc.reference_similarity_score("the dog ran", "the cat sat", language_code="en")
        self.assertLess(worse, score)

    def test_empty_reference_returns_none(self):
        self.assertIsNone(sc.reference_similarity_score("abc", "", language_code="en"))


class ConfidenceTests(unittest.TestCase):
    def test_too_few_words_returns_none(self):
        words = [{"probability": 0.9}] * 10
        self.assertIsNone(sc.confidence_from_words(words))

    def test_high_confidence_high_score(self):
        words = [{"probability": 0.95}] * 40
        stats = sc.confidence_from_words(words)
        self.assertIsNotNone(stats)
        score = sc._confidence_score(stats)
        self.assertGreaterEqual(score, 90)

    def test_garbled_low_confidence_low_score(self):
        words = [{"probability": 0.3}] * 40
        stats = sc.confidence_from_words(words)
        score = sc._confidence_score(stats)
        self.assertLess(score, 30)

    def test_low_conf_ratio_penalized(self):
        clean = sc._confidence_score(sc.confidence_from_words([{"probability": 0.85}] * 40))
        mixed_words = ([{"probability": 0.85}] * 20) + ([{"probability": 0.2}] * 20)
        mixed = sc._confidence_score(sc.confidence_from_words(mixed_words))
        self.assertLess(mixed, clean)


class RecognitionScoreTests(unittest.TestCase):
    def test_clean_japanese_scores_well(self):
        cues = _cues(["今日はいい天気ですね", "はいそうです", "とても気持ちいい", "散歩しましょう"])
        words = [{"probability": 0.93}] * 40
        result = sc.recognition_score(candidate_cues=cues, language_code="ja", words=words)
        self.assertIsNotNone(result.score)
        self.assertGreaterEqual(result.score, 80)

    def test_components_renormalize_when_absent(self):
        cues = _cues(["hello world", "this is fine"])
        # No words, no reference, no llm → only structural present.
        result = sc.recognition_score(candidate_cues=cues, language_code="en")
        self.assertEqual(result.components["confidence"], None)
        self.assertEqual(result.components["reference"], None)
        self.assertEqual(result.components["llm"], None)
        self.assertAlmostEqual(result.score, result.components["structural"], places=5)
        self.assertFalse(result.verified)
        self.assertIn("unverified:needsReferenceOrLLM", result.notes)

    def test_near_empty_local_asr_scores_as_recognition_failure(self):
        cues = [Cue(index=1, start=0.4, end=1.53, text="あ")]

        result = sc.recognition_score(candidate_cues=cues, language_code="ja")

        self.assertEqual(result.components["structural"], 0.0)
        self.assertEqual(result.score, 0.0)
        self.assertIn("structuralReasons:nearEmptyTranscript", result.notes)

    def test_reference_marks_verified(self):
        cues = _cues(["今日はいい天気"])
        result = sc.recognition_score(candidate_cues=cues, language_code="ja", reference_text="今日はいい天気")
        self.assertTrue(result.verified)

    def test_romaji_loop_japanese_penalized(self):
        clean = _cues(["今日はいい天気ですね", "とても良い一日"])
        garbled = _cues(["nani nani nani nani", "dare dare dare dare"])
        clean_score = sc.recognition_score(candidate_cues=clean, language_code="ja").score
        garbled_score = sc.recognition_score(candidate_cues=garbled, language_code="ja").score
        self.assertLess(garbled_score, clean_score)

    def test_reference_dominates_when_present(self):
        cues = _cues(["今日はいい天気"])
        good_ref = sc.recognition_score(
            candidate_cues=cues, language_code="ja", reference_text="今日はいい天気"
        ).score
        bad_ref = sc.recognition_score(
            candidate_cues=cues, language_code="ja", reference_text="全然違う文章だよこれは"
        ).score
        self.assertGreater(good_ref, bad_ref)

    def test_below_gate_llm_recognition_caps_automatic_components(self):
        cues = _cues(["clean looking subtitle text", "with no structural issues"])
        words = [{"probability": 0.95}] * 40

        result = sc.recognition_score(
            candidate_cues=cues,
            language_code="en",
            words=words,
            llm_accuracy_score=72.0,
        )

        self.assertEqual(result.score, 72.0)
        self.assertTrue(result.verified)
        self.assertFalse(result.passes)
        self.assertIn("llm:semanticCap", result.notes)


class AcousticAgreementTests(unittest.TestCase):
    def test_onsets_on_speech_starts_score_high(self):
        segments = [{"start": 0.0, "end": 2.0}, {"start": 3.0, "end": 5.0}]
        onsets = [0.0, 3.0]
        self.assertEqual(sc.acoustic_boundary_agreement(onsets, segments), 100.0)

    def test_onsets_inside_continuous_speech_are_supported(self):
        segments = [{"start": 0.0, "end": 10.0}]
        onsets = [0.0, 4.0, 6.0]
        self.assertEqual(sc.acoustic_boundary_agreement(onsets, segments), 100.0)

    def test_onsets_outside_speech_score_low(self):
        segments = [{"start": 0.0, "end": 2.0}, {"start": 8.0, "end": 10.0}]
        onsets = [4.0, 6.0]
        self.assertEqual(sc.acoustic_boundary_agreement(onsets, segments), 0.0)

    def test_none_when_no_segments(self):
        self.assertIsNone(sc.acoustic_boundary_agreement([1.0], []))


class FirstOnsetAlignmentTests(unittest.TestCase):
    def test_first_cue_on_first_word_scores_high(self):
        cues = [Cue(index=1, start=0.12, end=2.0, text="hello")]
        words = [{"start": 0.10, "end": 0.42, "text": "hello"}]
        result = sc.first_onset_alignment_score(cues, words=words)
        self.assertEqual(result["score"], 100.0)
        self.assertAlmostEqual(result["error_seconds"], 0.02, places=5)

    def test_late_first_cue_scores_low(self):
        cues = [Cue(index=1, start=1.65, end=3.0, text="hello")]
        words = [
            {"start": 0.10, "end": 0.42, "text": "hello"},
            {"start": 0.55, "end": 0.88, "text": "world"},
        ]
        result = sc.first_onset_alignment_score(cues, words=words)
        self.assertLess(result["score"], 40.0)
        self.assertAlmostEqual(result["error_seconds"], 1.55, places=5)
        self.assertEqual(result["prefix_word_count"], 2)
        self.assertEqual(result["prefix_text_preview"], "hello world")

    def test_bgm_intro_noise_does_not_penalize_first_real_word_onset(self):
        cues = [Cue(index=1, start=20.14, end=23.86, text="逃げ出したい夜のオンライン")]
        words = [
            {"start": 0.22, "end": 6.66, "text": "B"},
            {"start": 6.66, "end": 20.00, "text": "GM"},
            {"start": 20.14, "end": 23.86, "text": "逃げ出したい夜のオンライン"},
        ]
        result = sc.first_onset_alignment_score(cues, words=words)
        self.assertEqual(result["score"], 100.0)
        self.assertEqual(result["prefix_word_count"], 0)
        self.assertEqual(result["ignored_intro_prefix_word_count"], 2)
        self.assertEqual(result["ignored_intro_prefix_text_preview"], "B GM")

    def test_credit_intro_noise_does_not_penalize_first_real_word_onset(self):
        cues = [Cue(index=1, start=31.08, end=33.12, text="鏡よ")]
        words = [
            {"start": 0.20, "end": 2.49, "text": "作"},
            {"start": 2.49, "end": 4.98, "text": "詞"},
            {"start": 7.47, "end": 9.96, "text": "作"},
            {"start": 9.96, "end": 12.45, "text": "曲"},
            {"start": 14.94, "end": 17.43, "text": "編"},
            {"start": 17.43, "end": 19.92, "text": "曲"},
            {"start": 19.92, "end": 22.41, "text": "初"},
            {"start": 22.41, "end": 24.90, "text": "音"},
            {"start": 24.90, "end": 27.38, "text": "ミ"},
            {"start": 27.39, "end": 29.98, "text": "ク"},
            {"start": 31.08, "end": 33.12, "text": "鏡よ"},
        ]
        result = sc.first_onset_alignment_score(cues, words=words)
        self.assertEqual(result["score"], 100.0)
        self.assertEqual(result["prefix_word_count"], 0)
        self.assertEqual(result["ignored_intro_prefix_word_count"], 10)

    def test_short_intro_fragment_before_credit_noise_is_ignored(self):
        cues = [Cue(index=1, start=20.94, end=25.32, text="やっと目を覚ましたかい")]
        words = [
            {"start": 0.00, "end": 0.50, "text": "彼"},
            {"start": 0.50, "end": 1.00, "text": "女"},
            {"start": 1.00, "end": 1.50, "text": "の"},
            {"start": 1.50, "end": 2.00, "text": "曲"},
            {"start": 2.00, "end": 2.50, "text": "作"},
            {"start": 2.50, "end": 3.00, "text": "詞"},
            {"start": 3.00, "end": 3.50, "text": "作"},
            {"start": 3.50, "end": 4.00, "text": "曲"},
            {"start": 4.00, "end": 4.50, "text": "編"},
            {"start": 4.50, "end": 5.00, "text": "曲"},
            {"start": 20.94, "end": 25.32, "text": "やっと目を覚ましたかい"},
        ]
        result = sc.first_onset_alignment_score(cues, words=words)
        self.assertEqual(result["score"], 100.0)
        self.assertEqual(result["prefix_word_count"], 0)
        self.assertEqual(result["ignored_intro_prefix_word_count"], 10)

    def test_repeated_marker_intro_noise_does_not_hide_real_prefix_drops(self):
        marker_words = []
        for offset in range(5):
            start = 0.32 + offset * 2.0
            marker_words.extend([
                {"start": start, "end": start + 0.10, "text": "*"},
                {"start": start + 0.10, "end": start + 0.30, "text": "B"},
                {"start": start + 0.30, "end": start + 0.60, "text": "est"},
                {"start": start + 0.60, "end": start + 1.65, "text": "ime"},
            ])
        cues = [Cue(index=1, start=12.0, end=14.0, text="Cause I'm in the stars tonight")]
        words = marker_words + [
            {"start": 10.75, "end": 10.95, "text": "Cause"},
            {"start": 11.00, "end": 11.25, "text": "I'm"},
            {"start": 12.0, "end": 12.2, "text": "in"},
        ]
        result = sc.first_onset_alignment_score(cues, words=words)
        self.assertLess(result["score"], 40.0)
        self.assertEqual(result["prefix_word_count"], 2)
        self.assertEqual(result["prefix_text_preview"], "Cause I'm")
        self.assertEqual(result["ignored_intro_prefix_word_count"], 20)

    def test_speech_segment_start_is_fallback_reference(self):
        cues = [Cue(index=1, start=0.55, end=2.0, text="hello")]
        speech = [{"start": 0.50, "end": 2.20}]
        result = sc.first_onset_alignment_score(cues, speech_segments=speech)
        self.assertEqual(result["score"], 100.0)

    def test_speech_segment_fallback_does_not_penalize_early_cue_without_words(self):
        cues = [Cue(index=1, start=4.0, end=6.0, text="♪♪♪")]
        speech = [{"start": 9.0, "end": 12.0}]
        result = sc.first_onset_alignment_score(cues, speech_segments=speech)
        self.assertIsNone(result)

    def test_none_without_reference(self):
        cues = [Cue(index=1, start=0.12, end=2.0, text="hello")]
        self.assertIsNone(sc.first_onset_alignment_score(cues))


class SegmentationScoreTests(unittest.TestCase):
    def test_internal_only(self):
        cues = _cues(["これは普通の文です", "もう一つの文です"])
        result = sc.segmentation_score(candidate_cues=cues, language_code="ja")
        self.assertIsNotNone(result.score)
        self.assertEqual(result.components["acoustic"], None)
        self.assertNotIn("reference", result.components)
        self.assertFalse(result.verified)

    def test_acoustic_blends_in(self):
        cues = _cues(["a", "b"], dur=2.0)  # onsets 0.0, 4.0
        segments = [{"start": 0.0, "end": 2.0}, {"start": 4.0, "end": 6.0}]
        result = sc.segmentation_score(candidate_cues=cues, language_code="en", speech_segments=segments)
        self.assertIsNotNone(result.components["acoustic"])

    def test_can_disable_vad_only_first_onset_for_platform_sources(self):
        cues = [Cue(index=1, start=10.0, end=12.0, text="first platform lyric")]
        segments = [{"start": 1.0, "end": 12.0}]

        result = sc.segmentation_score(
            candidate_cues=cues,
            language_code="en",
            speech_segments=segments,
            allow_speech_first_onset=False,
        )

        self.assertIsNone(result.components["first_onset"])
        self.assertIn("firstOnset:speechFallbackDisabled", result.notes)

    def test_reference_report_is_informational_not_scored(self):
        cues = _cues(["hello", "world"])
        ref = {"strong_boundary_recall": 0.5, "aligned_boundary_f1": 0.5, "temporal_coverage": 0.95, "segment_count_ratio": 1.0}
        result = sc.segmentation_score(candidate_cues=cues, language_code="en", reference_report=ref)
        # reference is NOT a scored component (style-capped) and does NOT mark verified
        self.assertNotIn("reference", result.components)
        self.assertFalse(result.verified)
        self.assertTrue(any("refInfo" in n for n in result.notes))

    def test_acoustic_marks_verified(self):
        cues = _cues(["a", "b"], dur=2.0)
        segments = [{"start": 0.0, "end": 2.0}, {"start": 4.0, "end": 6.0}]
        result = sc.segmentation_score(candidate_cues=cues, language_code="en", speech_segments=segments)
        self.assertTrue(result.verified)

    def test_acoustic_uses_timed_word_activity_when_vad_is_sparse(self):
        cues = [
            Cue(index=1, start=0.0, end=1.7, text="first phrase"),
            Cue(index=2, start=2.0, end=3.7, text="second phrase"),
            Cue(index=3, start=4.0, end=5.7, text="third phrase"),
            Cue(index=4, start=6.0, end=7.7, text="fourth phrase"),
            Cue(index=5, start=8.0, end=9.7, text="fifth phrase"),
        ]
        sparse_vad = [{"start": 0.0, "end": 0.35}]
        words = [
            {"start": 0.0, "end": 0.55, "text": "first"},
            {"start": 1.0, "end": 1.55, "text": "phrase"},
            {"start": 2.0, "end": 2.55, "text": "second"},
            {"start": 3.0, "end": 3.55, "text": "phrase"},
            {"start": 4.0, "end": 4.55, "text": "third"},
            {"start": 5.0, "end": 5.55, "text": "phrase"},
            {"start": 6.0, "end": 6.55, "text": "fourth"},
            {"start": 7.0, "end": 7.55, "text": "phrase"},
            {"start": 8.0, "end": 8.55, "text": "fifth"},
            {"start": 9.0, "end": 9.55, "text": "phrase"},
        ]

        result = sc.segmentation_score(
            candidate_cues=cues,
            language_code="en",
            speech_segments=sparse_vad,
            words=words,
        )

        self.assertGreaterEqual(result.components["acoustic"], 90.0)
        self.assertTrue(result.verified)

    def test_first_onset_component_penalizes_late_opening_subtitle(self):
        cues = [Cue(index=1, start=1.65, end=3.0, text="hello")]
        words = [{"start": 0.10, "end": 0.42, "text": "hello"}]
        result = sc.segmentation_score(candidate_cues=cues, language_code="en", words=words)
        self.assertIn("first_onset", result.components)
        self.assertLess(result.components["first_onset"], 40.0)
        self.assertFalse(result.verified)
        self.assertTrue(any("firstOnsetError=1.550s" in note for note in result.notes))


class TranslationScoreTests(unittest.TestCase):
    def test_structural_only_is_capped(self):
        source = _cues(["今日はいい天気", "はいそうです"])
        translated = _cues(["今天天气很好", "是的没错"])
        result = sc.translation_score(source_cues=source, translated_cues=translated)
        self.assertTrue(result.capped)
        self.assertLessEqual(result.score, sc.RUBRIC.translation_structural_only_cap)

    def test_llm_lifts_above_cap(self):
        source = _cues(["今日はいい天気", "はいそうです"])
        translated = _cues(["今天天气很好", "是的没错"])
        result = sc.translation_score(source_cues=source, translated_cues=translated, llm_translation_score=95.0)
        self.assertFalse(result.capped)
        self.assertGreater(result.score, sc.RUBRIC.translation_structural_only_cap)

    def test_repeated_translation_penalized(self):
        source = _cues(["a", "b", "c", "d"])
        repeated = _cues(["同样", "同样", "同样", "同样"])
        clean = _cues(["第一", "第二", "第三", "第四"])
        r = sc.translation_score(source_cues=source, translated_cues=repeated).score
        c = sc.translation_score(source_cues=source, translated_cues=clean).score
        self.assertLess(r, c)

    def test_empty_translation_penalized(self):
        source = _cues(["a", "b", "c", "d"])
        empty = _cues(["译", "", "", ""])
        self.assertLess(sc.translation_score(source_cues=source, translated_cues=empty).score, 60)


class SourceDecisionScoreTests(unittest.TestCase):
    def test_all_correct(self):
        scenarios = [
            {"id": "clean", "platform_available": True, "platform_usable": True, "expected_decision": "platform"},
            {"id": "garbled", "platform_available": True, "platform_usable": False, "local_asr_available": True, "expected_decision": "localASR"},
            {"id": "manual", "manual_available": True, "expected_decision": "manual"},
        ]
        result = sc.source_decision_score(scenarios)
        self.assertEqual(result.score, 100.0)

    def test_partial(self):
        scenarios = [
            {"id": "clean", "platform_available": True, "platform_usable": True, "expected_decision": "platform"},
            {"id": "wrong", "platform_available": True, "platform_usable": False, "local_asr_available": False, "cloud_available": True, "expected_decision": "localASR"},
        ]
        result = sc.source_decision_score(scenarios)
        self.assertEqual(result.score, 50.0)

    def test_reports_scenario_and_correct_counts(self):
        scenarios = [
            {"id": "clean", "platform_available": True, "platform_usable": True, "expected_decision": "platform"},
            {"id": "wrong", "platform_available": True, "platform_usable": False, "local_asr_available": False, "cloud_available": True, "expected_decision": "localASR"},
        ]

        result = sc.source_decision_score(scenarios)

        self.assertEqual(result.components["scenario_count"], 2)
        self.assertEqual(result.components["correct_count"], 1)

    def test_auto_best_regenerates_when_platform_verdict_below_floor(self):
        scenarios = [
            {
                "id": "low-confidence-platform",
                "platform_available": True,
                "platform_usable": True,
                "platform_verdict": "lowConfidence",
                "local_asr_available": True,
                "expected_decision": "localASR",
            }
        ]
        result = sc.source_decision_score(scenarios)
        self.assertEqual(result.score, 100.0)

    def test_auto_best_escalates_when_generated_local_asr_is_below_floor(self):
        scenarios = [
            {
                "id": "bad-platform-and-bad-local",
                "platform_available": True,
                "platform_usable": False,
                "local_asr_available": True,
                "local_asr_verdict": "lowConfidence",
                "cloud_available": True,
                "expected_decision": "cloudASR",
            }
        ]

        result = sc.source_decision_score(scenarios)

        self.assertEqual(result.score, 100.0)

    def test_no_scenarios(self):
        self.assertIsNone(sc.source_decision_score([]).score)


class SuiteSummaryTests(unittest.TestCase):
    def _sample(self, rec, seg, tr, *, verified=True):
        return sc.SampleScorecard(
            sample_id="s", language_code="ja", category="test",
            dimensions={
                "recognition": sc.DimensionScore("recognition", rec, verified=verified),
                "segmentation": sc.DimensionScore("segmentation", seg, verified=verified),
                "translation": sc.DimensionScore("translation", tr, verified=verified),
            },
        )

    def test_summary_and_gate(self):
        samples = [self._sample(85, 82, 81), self._sample(90, 84, 83)]
        src = sc.DimensionScore("source_decision", 100.0, verified=True)
        summary = sc.suite_summary(samples, src)
        self.assertTrue(summary["dimensions"]["recognition"]["passes_gate"])
        self.assertTrue(summary["all_dimensions_pass"])

    def test_source_decision_summary_reports_scenario_count(self):
        samples = [self._sample(85, 82, 81), self._sample(90, 84, 83)]
        source_decision = sc.source_decision_score([
            {"id": "manual", "manual_available": True, "expected_decision": "manual"},
            {"id": "platform", "platform_available": True, "platform_usable": True, "expected_decision": "platform"},
            {
                "id": "fallback-local",
                "platform_available": True,
                "platform_usable": False,
                "local_asr_available": True,
                "expected_decision": "localASR",
            },
        ])

        summary = sc.suite_summary(samples, source_decision)

        source = summary["dimensions"]["source_decision"]
        self.assertEqual(source["scored_samples"], 3)
        self.assertEqual(source["verified_samples"], 3)
        self.assertEqual(source["required_verified_samples"], 3)
        self.assertEqual(source["additional_verified_needed"], 0)
        self.assertEqual(source["pass_count"], 3)
        self.assertEqual(source["verified_pass_count"], 3)

    def test_high_but_unverified_does_not_pass_verified_gate(self):
        samples = [self._sample(95, 95, 95, verified=False)]
        summary = sc.suite_summary(samples, None)
        self.assertFalse(summary["all_dimensions_pass"])
        self.assertTrue(summary["all_dimensions_pass_unverified"])
        self.assertEqual(summary["dimensions"]["recognition"]["verified_samples"], 0)

    def test_failing_gate(self):
        samples = [self._sample(50, 40, 60)]
        summary = sc.suite_summary(samples, None)
        self.assertFalse(summary["all_dimensions_pass"])
        self.assertFalse(summary["dimensions"]["recognition"]["passes_gate"])

    def test_summary_reports_verified_coverage_gap(self):
        samples = [self._sample(90, 90, 90, verified=True) for _ in range(5)]
        samples += [self._sample(90, 90, 90, verified=False) for _ in range(5)]

        summary = sc.suite_summary(samples, None)

        recognition = summary["dimensions"]["recognition"]
        self.assertEqual(recognition["scored_samples"], 10)
        self.assertEqual(recognition["verified_samples"], 5)
        self.assertEqual(recognition["required_verified_samples"], 6)
        self.assertEqual(recognition["additional_verified_needed"], 1)
        self.assertFalse(recognition["passes_gate"])

    def test_summary_reports_strict_traceable_evidence_gap_without_changing_gate(self):
        def recognition_sample(sample_id, score, notes):
            return sc.SampleScorecard(
                sample_id=sample_id,
                language_code="en",
                category="music",
                dimensions={
                    "recognition": sc.DimensionScore(
                        "recognition",
                        score,
                        notes=notes,
                        verified=True,
                    ),
                },
            )

        samples = [
            recognition_sample("reference", 90.0, ["reference:human"]),
            recognition_sample("source-url", 88.0, ["judgeEvidence:sourceUrls"]),
            recognition_sample("evidence-url", 86.0, ["judgeEvidence:evidenceUrls"]),
            recognition_sample("missing-url", 84.0, ["judgeEvidence:sourceUrlsMissing"]),
            sc.SampleScorecard(
                sample_id="unverified",
                language_code="en",
                category="music",
                dimensions={"recognition": sc.DimensionScore("recognition", 90.0, verified=False)},
            ),
        ]

        summary = sc.suite_summary(samples, None)

        recognition = summary["dimensions"]["recognition"]
        self.assertTrue(recognition["passes_gate"])
        self.assertEqual(recognition["verified_samples"], 4)
        self.assertEqual(recognition["required_verified_samples"], 3)
        self.assertEqual(recognition["strong_verified_samples"], 3)
        self.assertEqual(recognition["strict_additional_verified_needed"], 0)
        self.assertEqual(
            recognition["evidence_quality"],
            {
                "non_judge_verified_count": 1,
                "traceable_judge_count": 2,
                "untraceable_judge_count": 1,
            },
        )

    def test_render_markdown_smoke(self):
        samples = [self._sample(85, 82, 81)]
        summary = sc.suite_summary(samples, None)
        md = sc.render_markdown(samples, summary)
        self.assertIn("Moongate 字幕质量 Scorecard", md)
        self.assertIn("识别", md)
        self.assertIn("已验证", md)
        self.assertIn("强证缺口", md)


class QualityBacklogTests(unittest.TestCase):
    def test_backlog_prioritizes_first_onset_failures(self):
        sample = sc.SampleScorecard(
            sample_id="late-opening",
            language_code="en",
            category="music",
            dimensions={
                "recognition": sc.DimensionScore("recognition", 92.0, verified=True),
                "segmentation": sc.DimensionScore(
                    "segmentation",
                    74.0,
                    components={
                        "first_onset": 20.0,
                        "first_onset_prefix_words": 5.0,
                        "first_onset_prefix_seconds": 1.2,
                        "internal": 92.0,
                    },
                    notes=[
                        "firstOnsetError=1.200s,source=words",
                        "firstOnsetPrefix=5 words/1.200s:text=I have just arrived",
                    ],
                    verified=False,
                ),
            },
        )

        backlog = sc.quality_backlog([sample], None)

        self.assertEqual(backlog[0]["issue"], "opening_prefix_dropped")
        self.assertEqual(backlog[0]["sample_id"], "late-opening")
        self.assertEqual(backlog[0]["score"], 20.0)
        self.assertIn("firstOnsetError=1.200s", backlog[0]["evidence"])

    def test_backlog_separates_intro_credit_noise_from_dropped_opening(self):
        sample = sc.SampleScorecard(
            sample_id="credit-noise",
            language_code="ja",
            category="music",
            dimensions={
                "segmentation": sc.DimensionScore(
                    "segmentation",
                    58.0,
                    components={
                        "first_onset": 0.0,
                        "first_onset_prefix_words": 8.0,
                        "first_onset_prefix_seconds": 30.0,
                        "internal": 92.0,
                    },
                    notes=[
                        "firstOnsetError=30.000s,source=words",
                        "firstOnsetPrefix=8 words/30.000s:text=作 詞 ・ 作 曲 ・ 編 曲",
                    ],
                    verified=False,
                ),
            },
        )

        backlog = sc.quality_backlog([sample], None)

        self.assertEqual(backlog[0]["issue"], "opening_intro_noise")
        self.assertIn("作 詞", backlog[0]["evidence"])

    def test_backlog_treats_repeated_music_markers_as_intro_noise(self):
        sample = sc.SampleScorecard(
            sample_id="marker-noise",
            language_code="en",
            category="music",
            dimensions={
                "segmentation": sc.DimensionScore(
                    "segmentation",
                    58.0,
                    components={
                        "first_onset": 0.0,
                        "first_onset_prefix_words": 60.0,
                        "first_onset_prefix_seconds": 23.0,
                    },
                    notes=[
                        "firstOnsetError=23.000s,source=words",
                        "firstOnsetPrefix=60 words/23.000s:text=* B est ime * * B est ime *",
                    ],
                    verified=False,
                ),
            },
        )

        backlog = sc.quality_backlog([sample], None)

        self.assertEqual(backlog[0]["issue"], "opening_intro_noise")

    def test_backlog_treats_bgm_prefix_as_intro_noise_even_when_short(self):
        sample = sc.SampleScorecard(
            sample_id="bgm-noise",
            language_code="ja",
            category="music",
            dimensions={
                "segmentation": sc.DimensionScore(
                    "segmentation",
                    58.0,
                    components={
                        "first_onset": 0.0,
                        "first_onset_prefix_words": 2.0,
                        "first_onset_prefix_seconds": 19.0,
                    },
                    notes=[
                        "firstOnsetError=19.000s,source=words",
                        "firstOnsetPrefix=2 words/19.000s:text=B GM",
                    ],
                    verified=False,
                ),
            },
        )

        backlog = sc.quality_backlog([sample], None)

        self.assertEqual(backlog[0]["issue"], "opening_intro_noise")

    def test_backlog_flags_unverified_high_scores_as_evidence_gap(self):
        sample = sc.SampleScorecard(
            sample_id="unverified-clean-looking",
            language_code="ja",
            category="talk",
            dimensions={
                "recognition": sc.DimensionScore(
                    "recognition",
                    94.0,
                    components={"structural": 94.0},
                    notes=["unverified:needsReferenceOrLLM"],
                    verified=False,
                ),
            },
        )

        backlog = sc.quality_backlog([sample], None)

        self.assertEqual(backlog[0]["issue"], "recognition_unverified")
        self.assertEqual(backlog[0]["sample_id"], "unverified-clean-looking")
        self.assertGreater(backlog[0]["severity"], 0)

    def test_backlog_keeps_verified_low_recognition_as_below_gate(self):
        sample = sc.SampleScorecard(
            sample_id="verified-low",
            language_code="zh",
            category="music",
            dimensions={
                "recognition": sc.DimensionScore(
                    "recognition",
                    62.0,
                    components={"llm": 62.0},
                    notes=["llm:semanticCap"],
                    verified=True,
                ),
            },
            scored_source_kind="local-asr",
            scored_source_path="sample/local-asr.zh.srt",
        )

        backlog = sc.quality_backlog([sample], None)

        self.assertEqual(backlog[0]["issue"], "recognition_below_gate")
        self.assertEqual(backlog[0]["source_kind"], "local-asr")
        self.assertEqual(backlog[0]["source_path"], "sample/local-asr.zh.srt")

    def test_backlog_splits_low_unverified_recognition_from_proven_failures(self):
        sample = sc.SampleScorecard(
            sample_id="low-auto-score",
            language_code="ja",
            category="music",
            dimensions={
                "recognition": sc.DimensionScore(
                    "recognition",
                    71.0,
                    components={"confidence": 42.0, "structural": 100.0},
                    notes=["unverified:needsReferenceOrLLM"],
                    verified=False,
                ),
            },
        )

        backlog = sc.quality_backlog([sample], None)

        self.assertEqual(backlog[0]["issue"], "recognition_low_auto_score_unverified")
        self.assertIn("reference", backlog[0]["action"])
        self.assertNotIn("recognition_below_gate", {item["issue"] for item in backlog})


class RecognitionReviewQueueTests(unittest.TestCase):
    def test_queue_prioritizes_low_unverified_recognition_and_includes_prompt_path(self):
        low = sc.SampleScorecard(
            sample_id="low-auto",
            language_code="ja",
            category="music",
            scored_source_kind="local-asr",
            scored_source_path="artifacts/eval/low-auto/local-asr.ja.srt",
            audio_review_paths=["artifacts/eval/low-auto/clip.wav"],
            dimensions={
                "recognition": sc.DimensionScore(
                    "recognition",
                    71.0,
                    components={"confidence": 42.0, "structural": 100.0},
                    notes=["unverified:needsReferenceOrLLM"],
                    verified=False,
                )
            },
        )
        platform = sc.SampleScorecard(
            sample_id="platform-maybe-manual",
            language_code="zh",
            category="music",
            scored_source_kind="platform",
            scored_source_path="artifacts/eval/platform/source.zh.vtt",
            dimensions={
                "recognition": sc.DimensionScore(
                    "recognition",
                    100.0,
                    components={"structural": 100.0},
                    notes=["unverified:needsReferenceOrLLM"],
                    verified=False,
                )
            },
        )
        high = sc.SampleScorecard(
            sample_id="high-auto",
            language_code="it",
            category="music",
            scored_source_kind="local-asr",
            scored_source_path="artifacts/eval/high-auto/local-asr.it.srt",
            dimensions={
                "recognition": sc.DimensionScore(
                    "recognition",
                    94.0,
                    components={"confidence": 88.0, "structural": 100.0},
                    notes=["unverified:needsReferenceOrLLM"],
                    verified=False,
                )
            },
        )
        verified = sc.SampleScorecard(
            sample_id="verified",
            language_code="en",
            category="music",
            dimensions={"recognition": sc.DimensionScore("recognition", 78.0, verified=True)},
        )

        queue = sc.recognition_review_queue([high, verified, platform, low])

        self.assertEqual([item["sample_id"] for item in queue], ["low-auto", "platform-maybe-manual", "high-auto"])
        self.assertEqual(queue[0]["reason"], "low_auto_score_needs_reference")
        self.assertEqual(queue[0]["prompt_path"], "artifacts/eval/low-auto/agent_recognition.prompt.md")
        self.assertEqual(queue[0]["audio_review_paths"], ["artifacts/eval/low-auto/clip.wav"])
        self.assertEqual(queue[1]["reason"], "platform_provenance_or_judge_needed")
        self.assertIn("provenance", queue[1]["action"])
        self.assertEqual(queue[2]["reason"], "semantic_judge_needed")
        markdown = sc.render_recognition_review_queue_markdown(queue)
        self.assertIn("audio", markdown)
        self.assertIn("artifacts/eval/low-auto/clip.wav", markdown)


class RecognitionEvidencePlanTests(unittest.TestCase):
    def _recognition_sample(
        self,
        sample_id,
        *,
        score,
        verified=False,
        language_code="en",
        source_kind="local-asr",
        evidence_risks=None,
        notes=None,
    ):
        recognition_notes = (
            list(notes)
            if notes is not None
            else (["unverified:needsReferenceOrLLM"] if not verified else ["humanReference"])
        )
        return sc.SampleScorecard(
            sample_id=sample_id,
            language_code=language_code,
            category="music",
            scored_source_kind=source_kind,
            scored_source_path=f"artifacts/eval/{sample_id}/source.srt",
            audio_review_paths=[f"artifacts/eval/{sample_id}/clip.wav"],
            dimensions={
                "recognition": sc.DimensionScore(
                    "recognition",
                    score,
                    components={"structural": score},
                    notes=recognition_notes,
                    verified=verified,
                )
            },
            evidence_risks=list(evidence_risks or []),
        )

    def test_plan_recommends_minimum_high_confidence_items_before_low_auto_scores(self):
        samples = [
            self._recognition_sample("verified-a", score=86.0, verified=True),
            self._recognition_sample("verified-b", score=84.0, verified=True),
            self._recognition_sample("verified-c", score=82.0, verified=True),
            self._recognition_sample("verified-d", score=81.0, verified=True),
            self._recognition_sample("low-auto", score=71.0, language_code="ja"),
            self._recognition_sample("platform-clean", score=100.0, language_code="zh", source_kind="platform"),
            self._recognition_sample("semantic-high", score=95.0, language_code="it"),
            self._recognition_sample("semantic-mid", score=88.0, language_code="fr"),
            self._recognition_sample("semantic-pass", score=84.0, language_code="ko"),
            self._recognition_sample("semantic-edge", score=80.0, language_code="es"),
        ]

        plan = sc.recognition_evidence_plan(samples)

        self.assertEqual(plan["scored_samples"], 10)
        self.assertEqual(plan["verified_samples"], 4)
        self.assertEqual(plan["required_verified_samples"], 6)
        self.assertEqual(plan["additional_verified_needed"], 2)
        self.assertEqual(plan["recommended_count"], 2)
        self.assertEqual(
            [item["sample_id"] for item in plan["recommended"]],
            ["platform-clean", "semantic-high"],
        )
        self.assertEqual(plan["recommended"][0]["audio_review_paths"], ["artifacts/eval/platform-clean/clip.wav"])
        self.assertNotIn("low-auto", {item["sample_id"] for item in plan["recommended"]})
        self.assertIn("low-auto", {item["sample_id"] for item in plan["deferred_low_auto_score"]})
        self.assertGreaterEqual(plan["projected_verified_mean_if_recommended_score_80"], 80.0)
        self.assertTrue(plan["projected_passes_gate_if_recommended_score_80"])

    def test_plan_prefers_clean_high_confidence_items_before_risky_items(self):
        samples = [
            self._recognition_sample("verified-a", score=86.0, verified=True),
            self._recognition_sample("verified-b", score=84.0, verified=True),
            self._recognition_sample("verified-c", score=82.0, verified=True),
            self._recognition_sample("verified-d", score=81.0, verified=True),
            self._recognition_sample(
                "semantic-high-risk",
                score=98.0,
                evidence_risks=["sourceReport:sourceQualityUnusable:tooFewCues"],
            ),
            self._recognition_sample(
                "low-auto-risk",
                score=71.0,
                evidence_risks=["sourceReport:sourceQualityUnusable:tooFewCues"],
            ),
            self._recognition_sample("semantic-high-clean", score=96.0),
            self._recognition_sample("semantic-pass", score=84.0),
            self._recognition_sample("semantic-extra-a", score=83.0),
            self._recognition_sample("semantic-extra-b", score=82.0),
        ]

        plan = sc.recognition_evidence_plan(samples)

        self.assertEqual(
            [item["sample_id"] for item in plan["recommended"]],
            ["semantic-high-clean", "semantic-pass"],
        )
        self.assertEqual(
            next(item for item in plan["candidates_with_review_risks"] if item["sample_id"] == "semantic-high-risk")["review_risks"],
            ["sourceReport:sourceQualityUnusable:tooFewCues"],
        )
        self.assertNotIn("low-auto-risk", {item["sample_id"] for item in plan["candidates_with_review_risks"]})
        self.assertIn("low-auto-risk", {item["sample_id"] for item in plan["deferred_low_auto_score"]})

    def test_plan_warns_when_recommended_batch_contains_evidence_risks(self):
        samples = [
            self._recognition_sample("verified-a", score=86.0, verified=True),
            self._recognition_sample("verified-b", score=84.0, verified=True),
            self._recognition_sample("verified-c", score=82.0, verified=True),
            self._recognition_sample("verified-d", score=81.0, verified=True),
            self._recognition_sample("semantic-clean", score=96.0),
            self._recognition_sample(
                "semantic-risk",
                score=95.0,
                evidence_risks=["referenceAcquisition:translated_subtitles_only"],
            ),
            self._recognition_sample("low-auto", score=72.0),
            self._recognition_sample("extra-low-auto", score=71.0),
            self._recognition_sample("more-low-auto", score=70.0),
            self._recognition_sample("last-low-auto", score=69.0),
        ]

        plan = sc.recognition_evidence_plan(samples)

        self.assertEqual(
            [item["sample_id"] for item in plan["recommended"]],
            ["semantic-clean", "semantic-risk"],
        )
        self.assertIn("recommendedEvidenceRisks:1", plan["coverage_warnings"])

    def test_plan_reports_language_coverage_and_single_language_warning(self):
        samples = [
            self._recognition_sample("verified-en-a", score=86.0, verified=True, language_code="en"),
            self._recognition_sample("verified-en-b", score=84.0, verified=True, language_code="en"),
            self._recognition_sample("verified-zh-a", score=82.0, verified=True, language_code="zh"),
            self._recognition_sample("verified-ko-a", score=81.0, verified=True, language_code="ko"),
            self._recognition_sample("ja-clean-a", score=98.0, language_code="ja"),
            self._recognition_sample("ja-clean-b", score=96.0, language_code="ja"),
            self._recognition_sample("ja-clean-c", score=95.0, language_code="ja"),
            self._recognition_sample("it-risky", score=93.0, language_code="it", evidence_risks=["sourceReport:localFallbackUsed"]),
            self._recognition_sample("es-low", score=72.0, language_code="es"),
        ]

        plan = sc.recognition_evidence_plan(samples)

        self.assertEqual(plan["recommended_count"], 1)
        self.assertEqual(plan["recommended"][0]["language_code"], "ja")
        self.assertEqual(plan["recommended_language_count"], 1)
        self.assertEqual(plan["language_coverage"]["ja"]["recommended_count"], 1)
        self.assertEqual(plan["language_coverage"]["it"]["risky_candidate_count"], 1)
        self.assertEqual(plan["language_coverage"]["es"]["deferred_low_auto_count"], 1)
        self.assertIn("recommendedSingleLanguage:ja", plan["coverage_warnings"])
        self.assertEqual(
            [item["sample_id"] for item in plan["multilingual_follow_up"]],
            ["it-risky", "es-low"],
        )
        self.assertEqual(
            [item["language_code"] for item in plan["multilingual_follow_up"]],
            ["it", "es"],
        )

    def test_plan_adds_balanced_batch_when_fastest_recommendations_are_single_language(self):
        samples = [
            self._recognition_sample("verified-en-a", score=86.0, verified=True, language_code="en"),
            self._recognition_sample("verified-en-b", score=84.0, verified=True, language_code="en"),
            self._recognition_sample("verified-zh-a", score=82.0, verified=True, language_code="zh"),
            self._recognition_sample("verified-ko-a", score=81.0, verified=True, language_code="ko"),
            self._recognition_sample("ja-clean-a", score=98.0, language_code="ja"),
            self._recognition_sample("ja-clean-b", score=96.0, language_code="ja"),
            self._recognition_sample("ja-clean-c", score=95.0, language_code="ja"),
            self._recognition_sample("it-risky", score=93.0, language_code="it", evidence_risks=["sourceReport:localFallbackUsed"]),
            self._recognition_sample("es-low", score=72.0, language_code="es"),
            self._recognition_sample("zh-risky", score=91.0, language_code="zh", evidence_risks=["platform:manualProvenanceMissing"]),
        ]

        plan = sc.recognition_evidence_plan(samples)

        self.assertEqual(
            [item["sample_id"] for item in plan["recommended"]],
            ["ja-clean-a", "ja-clean-b"],
        )
        self.assertEqual(
            [item["sample_id"] for item in plan["balanced_recommended"]],
            ["ja-clean-a", "it-risky"],
        )
        self.assertEqual(plan["balanced_recommended_language_count"], 2)
        self.assertNotIn("es-low", {item["sample_id"] for item in plan["balanced_recommended"]})

    def test_plan_is_empty_when_recognition_coverage_gap_is_filled(self):
        samples = [
            self._recognition_sample("verified-a", score=86.0, verified=True),
            self._recognition_sample("verified-b", score=84.0, verified=True),
            self._recognition_sample("verified-c", score=82.0, verified=True),
            self._recognition_sample("unverified-clean", score=95.0),
        ]

        plan = sc.recognition_evidence_plan(samples)

        self.assertEqual(plan["additional_verified_needed"], 0)
        self.assertEqual(plan["recommended"], [])
        self.assertEqual(plan["recommended_count"], 0)

    def test_plan_reports_strict_traceable_gap_and_source_url_backfill_candidates(self):
        samples = [
            self._recognition_sample("verified-human-a", score=90.0, verified=True, notes=["humanReference"]),
            self._recognition_sample("verified-human-b", score=88.0, verified=True, notes=["humanReference"]),
            self._recognition_sample("verified-source-url", score=86.0, verified=True, notes=["judgeEvidence:sourceUrls"]),
            self._recognition_sample("verified-missing-url-a", score=84.0, verified=True, notes=["judgeEvidence:sourceUrlsMissing"]),
            self._recognition_sample("verified-missing-url-b", score=82.0, verified=True, notes=["judgeEvidence:sourceUrlsMissing"]),
            self._recognition_sample("semantic-high-a", score=96.0, language_code="ja"),
            self._recognition_sample("semantic-high-b", score=94.0, language_code="ja"),
            self._recognition_sample("semantic-high-c", score=92.0, language_code="ja"),
            self._recognition_sample("semantic-high-d", score=90.0, language_code="ja"),
            self._recognition_sample("semantic-high-e", score=89.0, language_code="ja"),
        ]

        plan = sc.recognition_evidence_plan(samples)

        self.assertEqual(plan["verified_samples"], 5)
        self.assertEqual(plan["required_verified_samples"], 6)
        self.assertEqual(plan["additional_verified_needed"], 1)
        self.assertEqual(plan["strong_verified_samples"], 3)
        self.assertEqual(plan["strict_additional_verified_needed"], 3)
        self.assertEqual(plan["source_url_backfill_count"], 2)
        self.assertEqual(
            [item["sample_id"] for item in plan["source_url_backfill_candidates"]],
            ["verified-missing-url-a", "verified-missing-url-b"],
        )
        self.assertEqual(
            plan["evidence_quality"],
            {
                "non_judge_verified_count": 2,
                "traceable_judge_count": 1,
                "untraceable_judge_count": 2,
            },
        )

    def test_render_plan_markdown_keeps_planning_artifact_warning_visible(self):
        plan = {
            "additional_verified_needed": 1,
            "strict_additional_verified_needed": 2,
            "strong_verified_samples": 0,
            "source_url_backfill_count": 1,
            "recommended_count": 1,
            "recommended_language_count": 1,
            "evidence_quality": {
                "non_judge_verified_count": 0,
                "traceable_judge_count": 0,
                "untraceable_judge_count": 1,
            },
            "projected_verified_mean_if_recommended_score_80": 83.0,
            "projected_passes_gate_if_recommended_score_80": True,
            "language_coverage": {
                "zh": {
                    "scored_samples": 1,
                    "verified_samples": 0,
                    "verified_pass_count": 0,
                    "unverified_pass_count": 1,
                    "recommended_count": 1,
                    "risky_candidate_count": 0,
                    "deferred_low_auto_count": 0,
                },
                "ja": {
                    "scored_samples": 1,
                    "verified_samples": 0,
                    "verified_pass_count": 0,
                    "unverified_pass_count": 1,
                    "recommended_count": 0,
                    "risky_candidate_count": 1,
                    "deferred_low_auto_count": 0,
                },
            },
            "coverage_warnings": ["recommendedSingleLanguage:zh"],
            "note": "Planning artifact only.",
            "recommended": [
                {
                    "sample_id": "platform-clean",
                    "language_code": "zh",
                    "score": 100.0,
                    "source_kind": "platform",
                    "prompt_path": "artifacts/eval/platform-clean/agent_recognition.prompt.md",
                    "audio_review_paths": ["artifacts/eval/platform-clean/clip.wav"],
                    "reason": "platform_provenance_or_judge_needed",
                    "minimum_accuracy_score": 80.0,
                    "action": "Add platform manual-caption provenance.",
                    "review_risks": ["sourceReport:sourceQualityUnusable:tooFewCues"],
                }
            ],
            "balanced_recommended": [
                {
                    "sample_id": "platform-clean",
                    "language_code": "zh",
                    "score": 100.0,
                    "source_kind": "platform",
                    "prompt_path": "artifacts/eval/platform-clean/agent_recognition.prompt.md",
                    "audio_review_paths": ["artifacts/eval/platform-clean/clip.wav"],
                    "reason": "platform_provenance_or_judge_needed",
                    "minimum_accuracy_score": 80.0,
                    "review_risks": ["sourceReport:sourceQualityUnusable:tooFewCues"],
                    "action": "Add platform manual-caption provenance.",
                },
                {
                    "sample_id": "it-risky",
                    "language_code": "it",
                    "score": 93.0,
                    "source_kind": "local-asr",
                    "prompt_path": "artifacts/eval/it-risky/agent_recognition.prompt.md",
                    "audio_review_paths": ["artifacts/eval/it-risky/clip.wav"],
                    "reason": "semantic_judge_needed",
                    "minimum_accuracy_score": 80.0,
                    "review_risks": ["sourceReport:localFallbackUsed"],
                    "action": "Add a numeric agent recognition judge.",
                },
            ],
            "candidates_with_review_risks": [
                {
                    "sample_id": "risky-clean-looking",
                    "language_code": "ja",
                    "score": 98.0,
                    "source_kind": "local-asr",
                    "prompt_path": "artifacts/eval/risky-clean-looking/agent_recognition.prompt.md",
                    "audio_review_paths": ["artifacts/eval/risky-clean-looking/clip.wav"],
                    "reason": "semantic_judge_needed",
                    "minimum_accuracy_score": 80.0,
                    "review_risks": ["sourceReport:sourceQualityUnusable:tooFewCues"],
                    "action": "Add a numeric agent recognition judge.",
                }
            ],
            "deferred_low_auto_score": [],
            "multilingual_follow_up": [
                {
                    "sample_id": "it-risky",
                    "language_code": "it",
                    "score": 93.0,
                    "source_kind": "local-asr",
                    "prompt_path": "artifacts/eval/it-risky/agent_recognition.prompt.md",
                    "audio_review_paths": ["artifacts/eval/it-risky/clip.wav"],
                    "reason": "semantic_judge_needed",
                    "minimum_accuracy_score": 80.0,
                    "review_risks": ["sourceReport:localFallbackUsed"],
                    "action": "Add a numeric agent recognition judge.",
                }
            ],
            "source_url_backfill_candidates": [
                {
                    "sample_id": "historical-judge",
                    "language_code": "en",
                    "score": 88.0,
                    "source_kind": "local-asr",
                    "source_path": "artifacts/eval/historical/source.srt",
                    "action": "Backfill sourceUrls.",
                }
            ],
        }

        markdown = sc.render_recognition_evidence_plan_markdown(plan)

        self.assertIn("# Recognition Evidence Plan", markdown)
        self.assertIn("Planning artifact only", markdown)
        self.assertIn("platform-clean", markdown)
        self.assertIn("projected", markdown.lower())
        self.assertIn("sourceQualityUnusable", markdown)
        self.assertIn("Risky Candidates", markdown)
        self.assertIn("risky-clean-looking", markdown)
        self.assertIn("Language Coverage", markdown)
        self.assertIn("recommendedSingleLanguage:zh", markdown)
        self.assertIn("Strict traceable evidence", markdown)
        self.assertIn("historical-judge", markdown)
        self.assertIn("artifacts/eval/platform-clean/clip.wav", markdown)
        self.assertIn("Multilingual Follow-up", markdown)
        self.assertIn("it-risky", markdown)
        self.assertIn("Balanced Coverage Batch", markdown)
        self.assertIn("same coverage gap while adding language diversity", markdown)

    def test_render_plan_markdown_shows_reference_acquisition_attempts(self):
        plan = {
            "scored_samples": 2,
            "verified_samples": 1,
            "required_verified_samples": 2,
            "additional_verified_needed": 1,
            "strong_verified_samples": 1,
            "strict_additional_verified_needed": 1,
            "source_url_backfill_count": 0,
            "reference_acquisition_attempts": [
                {
                    "sample_id": "higedan-pretender",
                    "language_code": "ja",
                    "status": "translated_subtitles_only",
                    "sourceUrl": "https://www.youtube.com/watch?v=TQ8WlA2GXbk",
                    "checkedAt": "2026-07-01",
                    "nextAction": "Needs original-language reference or audio review.",
                },
                {
                    "sample_id": "aimyon-marigold",
                    "language_code": "ja",
                    "status": "bot_gate",
                    "sourceUrl": "https://www.youtube.com/watch?v=0xSiBpUdW4E",
                    "checkedAt": "2026-07-01",
                    "nextAction": "Do not use browser cookies without explicit approval.",
                },
            ],
            "recommended": [],
            "note": "Planning artifact only.",
        }

        markdown = sc.render_recognition_evidence_plan_markdown(plan)

        self.assertIn("## Reference Acquisition Attempts", markdown)
        self.assertIn("higedan-pretender", markdown)
        self.assertIn("translated_subtitles_only", markdown)
        self.assertIn("aimyon-marigold", markdown)
        self.assertIn("bot_gate", markdown)

    def test_render_review_packet_lists_recommended_audio_and_judge_contract(self):
        plan = {
            "scored_samples": 10,
            "verified_samples": 4,
            "required_verified_samples": 6,
            "additional_verified_needed": 2,
            "strict_additional_verified_needed": 2,
            "recommended": [
                {
                    "sample_id": "semantic-clean",
                    "language_code": "ja",
                    "score": 98.0,
                    "source_kind": "local-asr",
                    "source_path": "artifacts/eval/semantic-clean/local-asr.ja.srt",
                    "prompt_path": "artifacts/eval/semantic-clean/agent_recognition.prompt.md",
                    "audio_review_paths": [
                        "artifacts/eval/semantic-clean/clip.wav",
                        "artifacts/eval/semantic-clean/source/video.webm",
                    ],
                    "reason": "semantic_judge_needed",
                    "minimum_accuracy_score": 80.0,
                    "action": "Add a numeric agent recognition judge.",
                    "review_risks": [],
                }
            ],
            "balanced_recommended": [
                {
                    "sample_id": "zh-platform",
                    "language_code": "zh",
                    "score": 100.0,
                    "source_kind": "platform",
                    "source_path": "artifacts/eval/zh-platform/source.zh.vtt",
                    "prompt_path": "artifacts/eval/zh-platform/agent_recognition.prompt.md",
                    "audio_review_paths": ["artifacts/eval/zh-platform/clip.wav"],
                    "reason": "platform_provenance_or_judge_needed",
                    "minimum_accuracy_score": 80.0,
                    "action": "Add platform manual-caption provenance.",
                    "review_risks": ["platform:manualProvenanceMissing"],
                }
            ],
        }

        markdown = sc.render_recognition_review_packet_markdown(plan)

        self.assertIn("# Recognition Review Packet", markdown)
        self.assertIn("Recognition verified coverage: 4/10; required 6; gap 2.", markdown)
        self.assertIn("semantic-clean", markdown)
        self.assertIn("artifacts/eval/semantic-clean/clip.wav", markdown)
        self.assertIn("artifacts/eval/semantic-clean/agent_recognition_judge.json", markdown)
        self.assertIn('"accuracyScore": null', markdown)
        self.assertNotIn('"accuracyScore": 0', markdown)
        self.assertIn("accuracyScore", markdown)
        self.assertIn("sourceUrls", markdown)
        self.assertIn("Audio paths are access paths, not proof", markdown)
        self.assertIn("Balanced Coverage Batch", markdown)
        self.assertIn("zh-platform", markdown)
        self.assertIn("platform:manualProvenanceMissing", markdown)
        self.assertIn("artifacts/eval/zh-platform/agent_recognition_judge.json", markdown)

    def test_render_review_packet_html_embeds_local_media_without_source_cues(self):
        plan = {
            "scored_samples": 10,
            "verified_samples": 4,
            "required_verified_samples": 6,
            "additional_verified_needed": 2,
            "strict_additional_verified_needed": 2,
            "recommended": [
                {
                    "sample_id": "semantic-clean",
                    "language_code": "ja",
                    "score": 98.0,
                    "source_kind": "local-asr",
                    "source_path": "/Users/example/Moongate Eval/semantic-clean/local-asr.ja.srt",
                    "prompt_path": "/Users/example/Moongate Eval/semantic-clean/agent_recognition.prompt.md",
                    "audio_review_paths": [
                        "/Users/example/Moongate Eval/semantic-clean/clip.wav",
                        "/Users/example/Moongate Eval/semantic-clean/source/video.webm",
                    ],
                    "reason": "semantic_judge_needed",
                    "minimum_accuracy_score": 80.0,
                    "action": "Add a numeric agent recognition judge.",
                    "review_risks": [],
                }
            ],
            "balanced_recommended": [
                {
                    "sample_id": "zh-platform",
                    "language_code": "zh",
                    "score": 100.0,
                    "source_kind": "platform",
                    "source_path": "/Users/example/Moongate Eval/zh-platform/source.zh.vtt",
                    "prompt_path": "/Users/example/Moongate Eval/zh-platform/agent_recognition.prompt.md",
                    "audio_review_paths": [
                        "/Users/example/Moongate Eval/zh-platform/clip.wav",
                    ],
                    "reason": "platform_provenance_or_judge_needed",
                    "minimum_accuracy_score": 80.0,
                    "action": "Add platform manual-caption provenance.",
                    "review_risks": ["platform:manualProvenanceMissing"],
                }
            ],
        }

        html = sc.render_recognition_review_packet_html(plan)

        self.assertIn("<h1>Recognition Review Packet</h1>", html)
        self.assertIn("Recognition verified coverage: 4/10; required 6; gap 2.", html)
        self.assertIn("semantic-clean", html)
        self.assertIn("<audio controls", html)
        self.assertIn("<video controls", html)
        self.assertIn("file:///Users/example/Moongate%20Eval/semantic-clean/clip.wav", html)
        self.assertIn("agent_recognition_judge.json", html)
        self.assertIn("Balanced Coverage Batch", html)
        self.assertIn("zh-platform", html)
        self.assertIn("platform:manualProvenanceMissing", html)
        self.assertIn("&quot;accuracyScore&quot;: null", html)
        self.assertNotIn("&quot;accuracyScore&quot;: 0", html)
        self.assertIn("Audio controls are access paths, not proof", html)
        self.assertNotIn("source_cues", html)

    def test_recognition_review_judge_templates_default_to_unscored(self):
        plan = {
            "recommended": [
                {
                    "sample_id": "semantic-clean",
                    "language_code": "ja",
                    "prompt_path": "artifacts/eval/semantic-clean/agent_recognition.prompt.md",
                    "audio_review_paths": ["artifacts/eval/semantic-clean/clip.wav"],
                    "minimum_accuracy_score": 80.0,
                    "reason": "semantic_judge_needed",
                }
            ],
            "balanced_recommended": [
                {
                    "sample_id": "zh-platform",
                    "language_code": "zh",
                    "prompt_path": "artifacts/eval/zh-platform/agent_recognition.prompt.md",
                    "audio_review_paths": ["artifacts/eval/zh-platform/clip.wav"],
                    "minimum_accuracy_score": 80.0,
                    "reason": "platform_provenance_or_judge_needed",
                }
            ],
            "multilingual_follow_up": [
                {
                    "sample_id": "it-risky",
                    "language_code": "it",
                    "prompt_path": "artifacts/eval/it-risky/agent_recognition.prompt.md",
                    "audio_review_paths": ["artifacts/eval/it-risky/clip.wav"],
                    "minimum_accuracy_score": 80.0,
                    "reason": "semantic_judge_needed",
                }
            ],
        }

        templates = sc.recognition_review_judge_templates(plan)

        self.assertEqual(templates[0]["sample_id"], "semantic-clean")
        self.assertEqual(templates[0]["review_group"], "recommended")
        self.assertEqual(templates[0]["judge_output_path"], "artifacts/eval/semantic-clean/agent_recognition_judge.json")
        self.assertIsNone(templates[0]["template"]["accuracyScore"])
        self.assertEqual(templates[0]["template"]["sourceUrls"], [])
        self.assertIn("insufficient", templates[0]["template"]["notes"])
        self.assertEqual(templates[0]["minimum_accuracy_score"], 80.0)
        self.assertEqual(templates[1]["sample_id"], "zh-platform")
        self.assertEqual(templates[1]["review_group"], "balanced_recommended")
        self.assertEqual(templates[1]["judge_output_path"], "artifacts/eval/zh-platform/agent_recognition_judge.json")
        self.assertEqual(templates[2]["sample_id"], "it-risky")
        self.assertEqual(templates[2]["review_group"], "multilingual_follow_up")
        self.assertEqual(templates[2]["judge_output_path"], "artifacts/eval/it-risky/agent_recognition_judge.json")


class BatchRecognitionJudgeTests(unittest.TestCase):
    def test_load_batch_recognition_judges_accepts_list_and_mapping_forms(self):
        with tempfile.TemporaryDirectory() as td:
            list_path = Path(td) / "list.json"
            list_path.write_text(
                '{"judges":[{"sample_id":"a","accuracyScore":91},{"sampleId":"b","accuracyScore":88}]}\n',
                encoding="utf-8",
            )
            mapping_path = Path(td) / "mapping.json"
            mapping_path.write_text('{"c":{"accuracyScore":84}}\n', encoding="utf-8")

            list_judges = runner.load_batch_recognition_judges(list_path)
            mapping_judges = runner.load_batch_recognition_judges(mapping_path)

        self.assertEqual(list_judges["a"]["accuracyScore"], 91)
        self.assertEqual(list_judges["b"]["accuracyScore"], 88)
        self.assertEqual(mapping_judges["c"]["accuracyScore"], 84)

    def test_load_recognition_judge_source_backfills_accepts_source_only_entries(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "source_backfills.json"
            path.write_text(
                '{"backfills":[{"sample_id":"a","sourceUrls":["https://example.com/a"]},'
                '{"sampleId":"b","sourceUrls":["https://example.com/b"]}]}\n',
                encoding="utf-8",
            )

            backfills = runner.load_recognition_judge_source_backfills(path)

        self.assertEqual(backfills["a"]["sourceUrls"], ["https://example.com/a"])
        self.assertEqual(backfills["b"]["sourceUrls"], ["https://example.com/b"])

    def test_load_recognition_reference_acquisition_accepts_attempts_without_scores(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "reference_acquisition.json"
            path.write_text(
                '{"attempts":[{"sample_id":"higedan-pretender","status":"translated_subtitles_only",'
                '"sourceUrl":"https://www.youtube.com/watch?v=TQ8WlA2GXbk"},'
                '{"sampleId":"aimyon-marigold","status":"bot_gate",'
                '"sourceUrl":"https://www.youtube.com/watch?v=0xSiBpUdW4E",'
                '"accuracyScore":100}]}\n',
                encoding="utf-8",
            )

            attempts = runner.load_recognition_reference_acquisition(path)

        self.assertEqual(attempts[0]["sample_id"], "higedan-pretender")
        self.assertEqual(attempts[0]["status"], "translated_subtitles_only")
        self.assertNotIn("accuracyScore", attempts[1])
        self.assertEqual(attempts[1]["sample_id"], "aimyon-marigold")

    def test_load_platform_caption_provenance_backfills_accepts_uploaded_source_entries(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "platform_provenance.json"
            path.write_text(
                '{"backfills":[{"sample_id":"mayday-stubborn","sourcePath":"R2s-H_crYkc.zh.vtt",'
                '"captionKind":"uploaded","sourceUrls":["https://www.youtube.com/watch?v=R2s-H_crYkc"]},'
                '{"sample_id":"ignored-auto","sourcePath":"auto.en.vtt","captionKind":"automatic",'
                '"sourceUrls":["https://www.youtube.com/watch?v=example"]}]}\n',
                encoding="utf-8",
            )

            backfills = runner.load_platform_caption_provenance_backfills(path)

        self.assertEqual(["mayday-stubborn"], list(backfills))
        self.assertEqual("uploaded", backfills["mayday-stubborn"]["captionKind"])


class ScorecardRunnerTests(unittest.TestCase):
    def test_timing_only_local_asr_words_feed_first_onset_component_without_verifying_segmentation(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,120 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "local-asr.words.json").write_text(
                '{"words":[{"start":0.1,"end":0.4,"text":"hello"}]}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        segmentation = result.dimensions["segmentation"]
        self.assertIn("first_onset", segmentation.components)
        self.assertEqual(segmentation.components["first_onset"], 100.0)
        self.assertFalse(segmentation.verified)

    def test_asr_words_json_feeds_first_onset_component(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,120 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "asr_words.json").write_text(
                '{"words":[{"start":0.1,"end":0.4,"text":"hello"}]}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        self.assertEqual(result.dimensions["segmentation"].components["first_onset"], 100.0)

    def test_human_reference_marks_recognition_verified(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "reference.en.clean.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertEqual(recognition.components["reference"], 100.0)
        self.assertTrue(recognition.verified)

    def test_section_relative_local_asr_reference_is_aligned_to_absolute_window(self):
        """Regression: a section-relative local-ASR candidate (starts at 00:00:00)
        whose filename encodes an absolute window (e.g. `.90-390.`) must be aligned
        to absolute time before comparing against an absolute-time human reference.

        Before the fix the candidate text (section-relative, covering abs 90-210)
        was compared against the reference clipped to the full nominal window
        (abs 90-390), so the texts were misaligned and reference similarity was
        pushed near zero even for a near-perfect transcript. The candidate here is
        an exact copy of the reference spoken over abs 90-210; after alignment the
        reference similarity must be high."""
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "section_relative_talk_es"
            sample.mkdir()
            # Human reference: absolute time. Content over abs 90-102, plus later
            # content (abs 300-312) that lies inside the nominal window but is NOT
            # covered by the candidate — it must not be compared against.
            (sample / "reference.es.clean.srt").write_text(
                "1\n00:01:30,000 --> 00:01:33,000\nla empatia es ponerse en los zapatos del otro\n\n"
                "2\n00:01:33,000 --> 00:01:36,000\ny entender los corazones de las personas\n\n"
                "3\n00:05:00,000 --> 00:05:03,000\ntexto muy posterior que el candidato no cubre\n\n"
                "4\n00:05:03,000 --> 00:05:06,000\notra frase lejana fuera de la cobertura\n\n",
                encoding="utf-8",
            )
            # Candidate: section-relative (starts at 0), covers section 0-6s which
            # maps to absolute 90-96s given the .90-390. window in the filename.
            (sample / "local-asr.90-390.es.srt").write_text(
                "1\n00:00:00,000 --> 00:00:03,000\nla empatia es ponerse en los zapatos del otro\n\n"
                "2\n00:00:03,000 --> 00:00:06,000\ny entender los corazones de las personas\n\n",
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertIsNotNone(recognition.components["reference"])
        self.assertGreaterEqual(
            recognition.components["reference"],
            90.0,
            "section-relative candidate should align to absolute reference span "
            f"(got {recognition.components['reference']})",
        )
        self.assertTrue(recognition.verified)

    def test_runner_scores_selected_platform_source_when_source_candidates_exist(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            platform = sample / "manual.en.vtt"
            platform.write_text(
                "WEBVTT\n\n"
                "00:00:00.000 --> 00:00:02.000\n"
                "human platform caption\n\n",
                encoding="utf-8",
            )
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nwrong whisper caption\n\n",
                encoding="utf-8",
            )
            (sample / "reference.en.clean.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhuman platform caption\n\n",
                encoding="utf-8",
            )
            (sample / "source_candidates.json").write_text(
                '[{"kind":"platform","available":true,"selected":true,'
                '"usable":true,"reasons":[],"path":"manual.en.vtt"},'
                '{"kind":"local-asr","available":true,"selected":false,'
                '"usable":true,"reasons":[],"path":"local-asr.en.srt"}]\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        self.assertEqual("en", result.language_code)
        self.assertEqual("platform", result.scored_source_kind)
        recognition = result.dimensions["recognition"]
        self.assertEqual(100.0, recognition.components["reference"])
        self.assertTrue(recognition.verified)

    def test_runner_does_not_use_local_asr_confidence_for_selected_platform_source(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "manual.en.vtt").write_text(
                "WEBVTT\n\n"
                "00:00:00.000 --> 00:00:02.000\n"
                "human platform caption\n\n",
                encoding="utf-8",
            )
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nwrong whisper caption\n\n",
                encoding="utf-8",
            )
            words = [
                f'{{"start":{i * 0.1:.1f},"end":{i * 0.1 + 0.05:.2f},"text":"wrong{i}","probability":0.01}}'
                for i in range(30)
            ]
            (sample / "local-asr.words.json").write_text('{"words":[' + ",".join(words) + "]}\n", encoding="utf-8")
            (sample / "reference.en.clean.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhuman platform caption\n\n",
                encoding="utf-8",
            )
            (sample / "source_candidates.json").write_text(
                '[{"kind":"platform","available":true,"selected":true,'
                '"usable":true,"reasons":[],"path":"manual.en.vtt"}]\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertIsNone(recognition.components["confidence"])
        self.assertEqual(100.0, recognition.score)

    def test_runner_verifies_selected_platform_source_only_with_explicit_manual_provenance(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "manual.en.vtt").write_text(
                "WEBVTT\n\n"
                "Kind: captions\n"
                "Language: en\n\n"
                "00:00:00.000 --> 00:00:02.000\n"
                "human platform caption\n\n",
                encoding="utf-8",
            )
            (sample / "source_candidates.json").write_text(
                '[{"kind":"platform","available":true,"selected":true,'
                '"usable":true,"isManual":true,"reasons":[],"path":"manual.en.vtt"}]\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertEqual(100.0, recognition.components["reference"])
        self.assertTrue(recognition.verified)
        self.assertIn("reference:manualPlatformSource", recognition.notes)

    def test_runner_does_not_verify_platform_source_from_vtt_header_alone(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "captions.en.vtt").write_text(
                "WEBVTT\n\n"
                "Kind: captions\n"
                "Language: en\n\n"
                "00:00:00.000 --> 00:00:02.000\n"
                "maybe platform caption\n\n",
                encoding="utf-8",
            )
            (sample / "source_candidates.json").write_text(
                '[{"kind":"platform","available":true,"selected":true,'
                '"usable":true,"reasons":[],"path":"captions.en.vtt"}]\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertFalse(recognition.verified)
        self.assertIn("unverified:needsReferenceOrLLM", recognition.notes)
        self.assertNotIn("reference:manualPlatformSource", recognition.notes)

    def test_runner_verifies_selected_platform_source_with_provenance_backfill(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "uploaded.en.vtt").write_text(
                "WEBVTT\n\n"
                "Kind: captions\n"
                "Language: en\n\n"
                "00:00:00.000 --> 00:00:02.000\n"
                "uploaded platform caption\n\n",
                encoding="utf-8",
            )
            (sample / "source_candidates.json").write_text(
                '[{"kind":"platform","available":true,"selected":true,'
                '"usable":true,"reasons":[],"path":"uploaded.en.vtt"}]\n',
                encoding="utf-8",
            )

            result = runner.score_sample(
                sample,
                acoustic=False,
                platform_caption_provenance_backfills={
                    "sample_en": {
                        "sourcePath": "uploaded.en.vtt",
                        "captionKind": "uploaded",
                        "sourceUrls": ["https://www.youtube.com/watch?v=example"],
                    }
                },
            )

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertTrue(recognition.verified)
        self.assertEqual(100.0, recognition.components["reference"])
        self.assertIn("reference:manualPlatformSource", recognition.notes)
        self.assertNotIn("platform:manualProvenanceMissing", result.evidence_risks)

    def test_runner_ignores_platform_provenance_backfill_for_mismatched_path(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "selected.en.vtt").write_text(
                "WEBVTT\n\n"
                "Kind: captions\n"
                "Language: en\n\n"
                "00:00:00.000 --> 00:00:02.000\n"
                "selected platform caption\n\n",
                encoding="utf-8",
            )
            (sample / "source_candidates.json").write_text(
                '[{"kind":"platform","available":true,"selected":true,'
                '"usable":true,"reasons":[],"path":"selected.en.vtt"}]\n',
                encoding="utf-8",
            )

            result = runner.score_sample(
                sample,
                acoustic=False,
                platform_caption_provenance_backfills={
                    "sample_en": {
                        "sourcePath": "other.en.vtt",
                        "captionKind": "uploaded",
                        "sourceUrls": ["https://www.youtube.com/watch?v=example"],
                    }
                },
            )

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertFalse(recognition.verified)
        self.assertNotIn("reference:manualPlatformSource", recognition.notes)
        self.assertIn("platform:manualProvenanceMissing", result.evidence_risks)

    def test_runner_does_not_use_local_asr_words_for_selected_platform_segmentation(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "manual.en.vtt").write_text(
                "WEBVTT\n\n"
                "00:00:10.000 --> 00:00:12.000\n"
                "human platform caption\n\n",
                encoding="utf-8",
            )
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nwrong whisper caption\n\n",
                encoding="utf-8",
            )
            (sample / "local-asr.words.json").write_text(
                '{"words":[{"start":0.0,"end":0.5,"text":"wrong","probability":0.9}]}\n',
                encoding="utf-8",
            )
            (sample / "source_candidates.json").write_text(
                '[{"kind":"platform","available":true,"selected":true,'
                '"usable":true,"reasons":[],"path":"manual.en.vtt"}]\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        segmentation = result.dimensions["segmentation"]
        self.assertIsNone(segmentation.components["first_onset"])
        self.assertFalse(any(note.startswith("firstOnset") for note in segmentation.notes))

    def test_runner_uses_native_platform_vtt_word_times_for_selected_platform_segmentation(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "manual.en.vtt").write_text(
                "WEBVTT\n\n"
                "00:00:10.000 --> 00:00:12.000\n"
                "hello<00:00:10.500><c> world</c>\n\n",
                encoding="utf-8",
            )
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nwrong whisper caption\n\n",
                encoding="utf-8",
            )
            (sample / "local-asr.words.json").write_text(
                '{"words":[{"start":0.0,"end":0.5,"text":"wrong","probability":0.9}]}\n',
                encoding="utf-8",
            )
            (sample / "source_candidates.json").write_text(
                '[{"kind":"platform","available":true,"selected":true,'
                '"usable":true,"reasons":[],"path":"manual.en.vtt"}]\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        segmentation = result.dimensions["segmentation"]
        self.assertEqual(100.0, segmentation.components["first_onset"])
        self.assertFalse(any(note == "firstOnset:speechFallbackDisabled" for note in segmentation.notes))

    def test_silencedetect_activity_fills_sparse_vad_for_platform_segmentation(self):
        sparse_vad = [{"start": 61.6, "end": 62.0}]
        silencedetect_log = """
Input #0, wav, from 'local-asr.wav':
  Duration: 00:03:00.00, bitrate: 256 kb/s
[Parsed_silencedetect_0] silence_start: 0
[Parsed_silencedetect_0] silence_end: 19.393875 | silence_duration: 19.393875
[Parsed_silencedetect_0] silence_start: 28.807375
[Parsed_silencedetect_0] silence_end: 29.05225 | silence_duration: 0.244875
"""
        speech_segments = runner.merge_speech_segments(
            sparse_vad,
            runner.speech_segments_from_silencedetect_log(silencedetect_log),
        )
        cues = [
            Cue(index=1, start=19.439, end=20.870, text="I just got here"),
            Cue(index=2, start=23.080, end=30.150, text="hello can you hear me now"),
        ]

        result = sc.segmentation_score(
            candidate_cues=cues,
            language_code="en",
            speech_segments=speech_segments,
            allow_speech_first_onset=False,
        )

        self.assertGreaterEqual(result.components["acoustic"], 90.0)
        self.assertTrue(result.verified)

    def test_human_word_reference_marks_recognition_verified_and_clips_window(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.10-20.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nreal speech\n\n",
                encoding="utf-8",
            )
            (sample / "srt_words.10-20.human.json").write_text(
                '{"words":['
                '{"start":0.0,"end":1.0,"text":"credit"},'
                '{"start":10.1,"end":10.5,"text":"real"},'
                '{"start":10.6,"end":11.0,"text":"speech"},'
                '{"start":21.0,"end":22.0,"text":"outro"}'
                ']}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertEqual(recognition.components["reference"], 100.0)
        self.assertTrue(recognition.verified)

    def test_agent_recognition_judge_marks_recognition_verified(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "agent_recognition_judge.json").write_text(
                '{"accuracyScore":88,"issues":[],"judgedBy":"agent"}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertEqual(recognition.components["llm"], 88.0)
        self.assertTrue(recognition.verified)
        self.assertIn("judgeEvidence:sourceUrlsMissing", recognition.notes)

    def test_stale_recognition_judge_older_than_source_is_dropped(self):
        import os

        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            judge = sample / "agent_recognition_judge.json"
            judge.write_text(
                '{"accuracyScore":88,"issues":[],"judgedBy":"agent"}\n',
                encoding="utf-8",
            )
            srt = sample / "local-asr.en.srt"
            srt.write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            # Judge predates the (re)generated source: must not count as verified.
            os.utime(judge, (1_000_000, 1_000_000))
            os.utime(srt, (2_000_000, 2_000_000))

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertIsNone(recognition.components.get("llm"))
        self.assertFalse(recognition.verified)

    def test_judge_score_is_clamped_to_valid_range(self):
        # A typo'd 880 (meant 88) must not inflate the aggregate above 100.
        self.assertEqual(runner._judge_score({"score": 880}, "score"), 100.0)
        self.assertEqual(runner._judge_score({"score": -5}, "score"), 0.0)
        self.assertEqual(runner._judge_score({"score": 88}, "score"), 88.0)
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "agent_recognition_judge.json").write_text(
                '{"accuracyScore":88,"issues":[],"judgedBy":"agent",'
                '"sourceUrls":["https://example.com/manual-transcript"]}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertEqual(recognition.components["llm"], 88.0)
        self.assertTrue(recognition.verified)
        self.assertIn("judgeEvidence:sourceUrls", recognition.notes)

    def test_source_backfill_makes_existing_file_recognition_judge_traceable_without_overriding_score(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "agent_recognition_judge.json").write_text(
                '{"accuracyScore":88,"issues":[],"judgedBy":"agent"}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(
                sample,
                acoustic=False,
                recognition_judge_source_backfills={
                    "sample_en": {"sourceUrls": ["https://example.com/manual-transcript"], "accuracyScore": 100}
                },
            )

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertEqual(recognition.components["llm"], 88.0)
        self.assertTrue(recognition.verified)
        self.assertIn("judgeEvidence:sourceUrls", recognition.notes)
        self.assertNotIn("judgeEvidence:sourceUrlsMissing", recognition.notes)

    def test_source_backfill_without_existing_numeric_judge_does_not_verify_recognition(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )

            result = runner.score_sample(
                sample,
                acoustic=False,
                recognition_judge_source_backfills={
                    "sample_en": {"sourceUrls": ["https://example.com/manual-transcript"]}
                },
            )

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertIsNone(recognition.components["llm"])
        self.assertFalse(recognition.verified)
        self.assertNotIn("judgeEvidence:sourceUrls", recognition.notes)

    def test_source_report_risks_are_attached_to_sample_scorecard(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "source_report.json").write_text(
                '{"fallback_used":true,'
                '"source_quality":{"usable":false,"reasons":["tooFewCues"]},'
                '"final_source_issues":["visible anomaly"]}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        self.assertIn("sourceReport:localFallbackUsed", result.evidence_risks)
        self.assertIn("sourceReport:sourceQualityUnusable:tooFewCues", result.evidence_risks)
        self.assertIn("sourceReport:finalSourceIssues", result.evidence_risks)

    def test_reference_acquisition_risks_do_not_verify_recognition(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )

            result = runner.score_sample(
                sample,
                acoustic=False,
                recognition_reference_acquisition_risks={
                    "sample_en": ["referenceAcquisition:automatic_captions_only"]
                },
            )

        self.assertIsNotNone(result)
        self.assertIn("referenceAcquisition:automatic_captions_only", result.evidence_risks)
        self.assertFalse(result.dimensions["recognition"].verified)

    def test_batch_recognition_judge_marks_recognition_verified(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )

            result = runner.score_sample(
                sample,
                acoustic=False,
                batch_recognition_judges={
                    "sample_en": {
                        "accuracyScore": 91,
                        "judgedBy": "batch",
                        "evidence": ["source: https://example.com/transcript"],
                    }
                },
            )

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertEqual(recognition.components["llm"], 91.0)
        self.assertTrue(recognition.verified)
        self.assertIn("judge:batch", recognition.notes)
        self.assertIn("judgeEvidence:evidenceUrls", recognition.notes)

    def test_unscored_batch_recognition_judge_stays_unverified(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )

            result = runner.score_sample(
                sample,
                acoustic=False,
                batch_recognition_judges={"sample_en": {"pass": True, "blockingIssues": []}},
            )

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertIsNone(recognition.components["llm"])
        self.assertFalse(recognition.verified)
        self.assertIn("ignored:batch_recognition_judge:unscored", recognition.notes)

    def test_file_recognition_judge_takes_precedence_over_batch_judge(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "agent_recognition_judge.json").write_text(
                '{"accuracyScore":83,"judgedBy":"sample-file"}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(
                sample,
                acoustic=False,
                batch_recognition_judges={"sample_en": {"accuracyScore": 91, "judgedBy": "batch"}},
            )

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertEqual(recognition.components["llm"], 83.0)
        self.assertTrue(recognition.verified)
        self.assertNotIn("judge:batch", recognition.notes)

    def test_unscored_agent_recognition_judge_stays_unverified_with_note(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "agent_recognition_judge.json").write_text(
                '{"accuracyScore":null,"issues":["insufficient evidence"],"judgedBy":"agent"}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertIsNone(recognition.components["llm"])
        self.assertFalse(recognition.verified)
        self.assertIn("ignored:agent_recognition_judge:unscored", recognition.notes)

    def test_pass_only_agent_recognition_judge_stays_unverified(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "agent_recognition_judge.json").write_text(
                '{"pass":true,"blockingIssues":[],"suggestedAction":"accept"}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertIsNone(recognition.components["llm"])
        self.assertFalse(recognition.verified)
        self.assertIn("ignored:agent_recognition_judge:unscored", recognition.notes)

    def test_holistic_llm_quality_judge_is_reported_but_not_used_for_recognition(self):
        with tempfile.TemporaryDirectory() as td:
            sample = Path(td) / "sample_en"
            sample.mkdir()
            (sample / "local-asr.en.srt").write_text(
                "1\n00:00:00,000 --> 00:00:02,000\nhello world\n\n",
                encoding="utf-8",
            )
            (sample / "llm_quality_judge.json").write_text(
                '{"pass":true,"blockingIssues":[],"suggestedAction":"accept"}\n',
                encoding="utf-8",
            )

            result = runner.score_sample(sample, acoustic=False)

        self.assertIsNotNone(result)
        recognition = result.dimensions["recognition"]
        self.assertIsNone(recognition.components["llm"])
        self.assertFalse(recognition.verified)
        self.assertIn("ignored:llm_quality_judge:holistic", recognition.notes)

    def test_agent_recognition_prompt_contains_schema_and_source_preview(self):
        sample = sc.SampleScorecard(
            sample_id="sample_en",
            language_code="en",
            category="music",
            scored_source_kind="local-asr",
            scored_source_path="/tmp/sample/local-asr.en.srt",
            dimensions={
                "recognition": sc.DimensionScore(
                    "recognition",
                    87.0,
                    {"confidence": 84.0, "structural": 90.0, "reference": None, "llm": None},
                    ["unverified:needsReferenceOrLLM"],
                    verified=False,
                )
            },
        )
        cues = [
            Cue(index=1, start=0.0, end=2.0, text="hello world"),
            Cue(index=2, start=2.1, end=4.0, text="this is a caption"),
        ]

        with tempfile.TemporaryDirectory() as td:
            sample_dir = Path(td) / "sample_en"
            sample_dir.mkdir()
            (sample_dir / "local-asr.wav").write_bytes(b"fake wav")
            (sample_dir / "clip.wav").write_bytes(b"fake clip")
            (sample_dir / "source").mkdir()
            (sample_dir / "source" / "video.webm").write_bytes(b"fake media")
            sample = sc.SampleScorecard(
                sample_id=sample.sample_id,
                language_code=sample.language_code,
                category=sample.category,
                scored_source_kind=sample.scored_source_kind,
                scored_source_path=str(sample_dir / "local-asr.en.srt"),
                dimensions=sample.dimensions,
            )

            prompt = runner.build_agent_recognition_prompt(sample, cues, max_cues=1)

        self.assertIn("agent_recognition_judge.json", prompt)
        self.assertIn('"accuracyScore": number|null', prompt)
        self.assertIn("sample_id: sample_en", prompt)
        self.assertIn("source_kind: local-asr", prompt)
        self.assertIn("recognition_components:", prompt)
        self.assertIn("reference_acquisition_checklist", prompt)
        self.assertIn("sourceUrls", prompt)
        self.assertIn("audio_review_paths:", prompt)
        self.assertIn("local-asr.wav", prompt)
        self.assertIn("clip.wav", prompt)
        self.assertIn("video.webm", prompt)
        self.assertIn("没有可靠参考或音频复核时 accuracyScore 必须为 null", prompt)
        self.assertIn("1. 0.00-2.00 | hello world", prompt)
        self.assertNotIn("this is a caption", prompt)


if __name__ == "__main__":
    unittest.main()
