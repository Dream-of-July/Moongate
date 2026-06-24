import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from subtitle_timing_eval.segmentation import (
    GATE_MIN_F1,
    evaluate_segmentation,
    match_boundaries,
    strong_reference_boundaries,
    summarize_suite,
)
from subtitle_timing_eval.srt import Cue, serialize_srt
from subtitle_timing_eval.pipeline import evaluate_segmentation_files


def _cues(boundaries_with_end):
    """boundaries_with_end: list of (start, end, text)."""
    return [Cue(index=i + 1, start=s, end=e, text=t) for i, (s, e, t) in enumerate(boundaries_with_end)]


def _even_cues(starts, span=2.0, text="x"):
    return [Cue(index=i + 1, start=s, end=s + span, text=text) for i, s in enumerate(starts)]


class MatchBoundariesTests(unittest.TestCase):
    def test_one_to_one_no_double_count(self):
        # Two candidate boundaries near a single reference boundary must only
        # produce ONE true positive (no double counting / inflated recall).
        matches, unmatched_c, unmatched_r = match_boundaries([2.0, 2.1], [2.05], tolerance=0.5)
        self.assertEqual(len(matches), 1)
        self.assertEqual(len(unmatched_c), 1)
        self.assertEqual(len(unmatched_r), 0)

    def test_nearest_wins(self):
        matches, _, _ = match_boundaries([2.0, 2.4], [2.45], tolerance=0.5)
        # 2.4 is nearer to 2.45 than 2.0 -> it should be the matched candidate.
        self.assertEqual(matches[0][0], 1)

    def test_outside_tolerance_unmatched(self):
        matches, unmatched_c, unmatched_r = match_boundaries([5.0], [2.0], tolerance=0.5)
        self.assertEqual(matches, [])
        self.assertEqual(unmatched_c, [0])
        self.assertEqual(unmatched_r, [0])


class EvaluateSegmentationTests(unittest.TestCase):
    def test_perfect_match_passes_gate(self):
        ref = _even_cues([0.0, 2.0, 4.0, 6.0])
        cand = _even_cues([0.0, 2.05, 3.95, 6.0])
        report = evaluate_segmentation(cand, ref, "perfect", window_start=0.0)
        self.assertAlmostEqual(report["boundary_f1"], 1.0)
        self.assertGreaterEqual(report["temporal_coverage"], 0.95)
        self.assertTrue(report["passes_segmentation_gate"])
        self.assertEqual(report["gate_failures"], [])

    def test_over_segmentation_flagged(self):
        ref = _even_cues([0.0, 2.0, 4.0], span=2.0)
        # candidate cuts twice as often -> many false-positive boundaries
        cand = _even_cues([0.0, 1.0, 2.0, 3.0, 4.0, 5.0], span=1.0)
        report = evaluate_segmentation(cand, ref, "over", window_start=0.0)
        self.assertLess(report["boundary_f1"], GATE_MIN_F1)
        self.assertGreater(report["segment_count_ratio"], 1.25)
        self.assertIn("over_segmentation", report["gate_failures"])

    def test_under_segmentation_flagged(self):
        ref = _even_cues([0.0, 2.0, 4.0], span=2.0)
        cand = [Cue(index=1, start=0.0, end=6.0, text="all")]
        report = evaluate_segmentation(cand, ref, "under", window_start=0.0)
        # the two internal reference boundaries (2.0, 4.0) are missed entirely
        self.assertEqual(report["false_negatives"], 2)
        self.assertLess(report["segment_count_ratio"], 0.8)
        self.assertIn("under_segmentation", report["gate_failures"])

    def test_tolerance_window_widens_matches(self):
        ref = _even_cues([0.0, 2.0, 4.0])
        # second boundary off by 0.8s: missed at 0.5s, hit at 1.0s
        cand = _even_cues([0.0, 2.8, 4.0])
        report = evaluate_segmentation(cand, ref, "tol", window_start=0.0)
        self.assertEqual(report["f1_by_tolerance"]["0.5"], report["boundary_f1"])
        self.assertLess(report["f1_by_tolerance"]["0.5"], report["f1_by_tolerance"]["1"])
        self.assertAlmostEqual(report["f1_by_tolerance"]["1"], 1.0)

    def test_coverage_penalizes_dropped_content(self):
        # candidate covers only the first half of reference speech
        ref = [Cue(index=1, start=0.0, end=10.0, text="long")]
        cand = [Cue(index=1, start=0.0, end=5.0, text="half")]
        report = evaluate_segmentation(cand, ref, "coverage", window_start=0.0)
        self.assertAlmostEqual(report["temporal_coverage"], 0.5, places=2)
        self.assertIn("low_text_coverage", report["gate_failures"])

    def test_trivial_window_start_boundary_dropped(self):
        # the onset at the window start is not a segmentation decision
        ref = _even_cues([0.0, 3.0])
        cand = _even_cues([0.0, 3.0])
        report = evaluate_segmentation(cand, ref, "trivial", window_start=0.0)
        # only the 3.0 onset counts as a boundary on each side
        self.assertEqual(report["reference_boundary_count"], 1)
        self.assertEqual(report["candidate_boundary_count"], 1)

    def test_window_clipping(self):
        ref = _even_cues([0.0, 2.0, 4.0, 6.0, 8.0])
        cand = _even_cues([0.0, 2.0, 4.0, 6.0, 8.0])
        report = evaluate_segmentation(cand, ref, "win", window_start=2.0, window_end=6.0)
        # boundaries strictly inside (2, 6] relative to window start 2.0
        self.assertTrue(report["passes_segmentation_gate"])
        self.assertLessEqual(report["reference_boundary_count"], 3)


class SuiteSummaryTests(unittest.TestCase):
    def test_suite_gate_requires_mean_and_pass_rate(self):
        def good(i):
            return {"sample_id": "g%d" % i, "track": "A", "boundary_f1": 0.95,
                    "boundary_precision": 0.95, "boundary_recall": 0.95,
                    "temporal_coverage": 0.95, "segment_count_ratio": 1.0,
                    "passes_segmentation_gate": True, "gate_failures": []}
        reports = [good(i) for i in range(10)]
        summary = summarize_suite(reports)
        self.assertTrue(summary["overall"]["passes_suite_gate"])
        self.assertEqual(summary["by_track"]["A"]["sample_count"], 10)

    def test_suite_gate_fails_when_many_samples_fail(self):
        rows = []
        for i in range(10):
            passing = i < 5
            rows.append({"sample_id": "s%d" % i, "track": "B",
                         "boundary_f1": 0.95 if passing else 0.4,
                         "boundary_precision": 0.9, "boundary_recall": 0.9,
                         "temporal_coverage": 0.95, "segment_count_ratio": 1.0,
                         "passes_segmentation_gate": passing,
                         "gate_failures": [] if passing else ["low_boundary_f1"]})
        summary = summarize_suite(rows)
        self.assertFalse(summary["overall"]["passes_suite_gate"])
        self.assertEqual(len(summary["failing_samples"]), 5)


class SegmentationFilesTests(unittest.TestCase):
    def test_offset_aligns_section_relative_candidate(self):
        # candidate is section-relative (0-based); reference is absolute video time.
        with tempfile.TemporaryDirectory() as tmp:
            cand_path = Path(tmp) / "cand.srt"
            ref_path = Path(tmp) / "ref.srt"
            cand_path.write_text(serialize_srt(_even_cues([0.0, 2.0, 4.0])), encoding="utf-8")
            ref_path.write_text(serialize_srt(_even_cues([60.0, 62.0, 64.0])), encoding="utf-8")
            out_path = Path(tmp) / "report.json"
            report = evaluate_segmentation_files(
                str(cand_path), str(ref_path), "offset", str(out_path),
                candidate_offset_seconds=60.0, window_start=60.0, window_end=66.0, track="A",
            )
            self.assertAlmostEqual(report["boundary_f1"], 1.0)
            self.assertTrue(out_path.exists())
            saved = json.loads(out_path.read_text(encoding="utf-8"))
            self.assertEqual(saved["track"], "A")


class StrongBoundaryTests(unittest.TestCase):
    def test_sentence_end_and_gap_are_strong(self):
        ref = [
            Cue(1, 0.0, 2.0, "Hello there"),       # next onset 2.0: prev no punct, no gap -> weak
            Cue(2, 2.0, 4.0, "this is fine."),      # next onset 4.0: prev ends "." -> STRONG
            Cue(3, 4.0, 6.0, "more words"),         # next onset 6.5: gap 0.5 -> STRONG
            Cue(4, 6.5, 8.0, "tail"),
        ]
        strong = strong_reference_boundaries(ref, window_start=0.0)
        self.assertIn(4.0, strong)
        self.assertIn(6.5, strong)
        self.assertNotIn(2.0, strong)

    def test_missed_strong_boundary_fails_gate(self):
        # reference clearly breaks (sentence end + gap) but candidate merges all
        ref = [
            Cue(1, 0.0, 2.0, "First sentence."),
            Cue(2, 2.0, 4.0, "Second sentence."),
            Cue(3, 4.5, 6.0, "Third."),
        ]
        cand = [Cue(1, 0.0, 6.0, "all merged together")]
        report = evaluate_segmentation(cand, ref, "merge", window_start=0.0)
        self.assertLess(report["strong_boundary_recall"], 0.9)
        self.assertIn("missed_strong_boundary", report["gate_failures"])

    def test_no_strong_boundaries_is_vacuously_full_recall(self):
        ref = _even_cues([0.0, 2.0, 4.0], span=2.0)  # contiguous, text "x", no punctuation
        cand = _even_cues([0.0, 2.0, 4.0], span=2.0)
        report = evaluate_segmentation(cand, ref, "nostrong", window_start=0.0)
        self.assertEqual(report["strong_reference_boundary_count"], 0)
        self.assertEqual(report["strong_boundary_recall"], 1.0)
        self.assertNotIn("missed_strong_boundary", report["gate_failures"])


if __name__ == "__main__":
    unittest.main()


from subtitle_timing_eval.readability import (
    evaluate_readability,
    render_readability_review_markdown,
    summarize_readability_suite,
    is_cjk_language,
)


def _cue(i, s, e, t):
    return Cue(index=i, start=s, end=e, text=t)


class ReadabilityTests(unittest.TestCase):
    def test_clean_latin_cue_passes(self):
        cues = [_cue(1, 0.0, 2.5, "This is a perfectly readable line."),
                _cue(2, 2.6, 5.0, "And here is the second one.")]
        r = evaluate_readability(cues, "ok", language="en")
        self.assertEqual(r["flag_counts"], {})
        self.assertEqual(r["clean_ratio"], 1.0)

    def test_two_line_budget_not_flagged(self):
        # ~70 chars wraps to two ~35-char lines — within the 2-line budget, not flagged.
        text = "this is a fairly long subtitle line that still fits two display lines"
        r = evaluate_readability([_cue(1, 0.0, 4.0, text)], "ok", language="en")
        self.assertNotIn("too_long_to_fit", r["cues"][0]["flags"])

    def test_over_two_line_budget_flagged(self):
        text = "x" * 90  # 90 chars > 2*42
        r = evaluate_readability([_cue(1, 0.0, 5.0, text)], "ok", language="en")
        self.assertIn("too_long_to_fit", r["cues"][0]["flags"])

    def test_ends_on_weak_word_flagged_but_next_start_is_not(self):
        ends_weak = evaluate_readability([_cue(1, 0.0, 2.0, "I went to the")], "w", language="en")
        self.assertIn("weak_boundary", ends_weak["cues"][0]["flags"])
        # ending cleanly, even if the NEXT line would start with a function word, is fine
        clean = evaluate_readability(
            [_cue(1, 0.0, 2.0, "I went home."), _cue(2, 2.1, 4.0, "And then I slept.")],
            "c", language="en")
        self.assertNotIn("weak_boundary", clean["cues"][0]["flags"])

    def test_flash_and_linger(self):
        flash = evaluate_readability([_cue(1, 0.0, 0.4, "Hi there now")], "f", language="en")
        self.assertIn("flash_too_short", flash["cues"][0]["flags"])
        linger = evaluate_readability([_cue(1, 0.0, 9.0, "A short sentence held far too long.")], "l", language="en")
        self.assertIn("lingers_too_long", linger["cues"][0]["flags"])

    def test_cjk_detection_and_budget(self):
        self.assertTrue(is_cjk_language("ja", []))
        self.assertTrue(is_cjk_language(None, [_cue(1, 0.0, 2.0, "今日はいい天気")]))
        self.assertFalse(is_cjk_language("en", [_cue(1, 0.0, 2.0, "hello world")]))

    def test_suite_gate(self):
        good = [evaluate_readability([_cue(1, 0.0, 2.5, "Clean readable line here.")], "s%d" % i, language="en")
                for i in range(10)]
        summary = summarize_readability_suite(good)
        self.assertTrue(summary["overall"]["passes_suite_gate"])

    def test_review_markdown_shows_flagged_subtitle_text(self):
        report = evaluate_readability([
            _cue(1, 0.0, 0.4, "Too fast"),
            _cue(2, 0.5, 3.0, "Clean readable line here."),
        ], "clip", language="en", track="A")

        markdown = render_readability_review_markdown([report], max_samples=1, max_cues_per_sample=2)

        self.assertIn("# Human Readability Review", markdown)
        self.assertIn("clip", markdown)
        self.assertIn("00:00:00,000 --> 00:00:00,400", markdown)
        self.assertIn("flash_too_short", markdown)
        self.assertIn("Too fast", markdown)

    def test_readability_duration_threshold_uses_float_tolerance(self):
        report = evaluate_readability([
            _cue(1, 4.0, 4.9, "梅だ"),
        ], "clip", language="ja", track="A")

        self.assertNotIn("flash_too_short", report["cues"][0]["flags"])
