import unittest
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from subtitle_timing_eval.srt import Cue
from subtitle_timing_eval.vtt import parse_vtt_cues
from subtitle_timing_eval.viewing_quality import (
    build_pipeline_advice,
    build_quality_judge_prompt,
    build_agent_translation_prompt,
    build_source_candidate_reports,
    build_viewing_sample_report,
    build_quality_judge,
    final_source_quality_issues,
    weak_boundary_candidates,
    source_quality_report,
    translated_quality_issues,
)
from run_viewing_quality_suite import (
    SONG_CATEGORY_GOAL,
    SONG_SAMPLES,
    find_existing_local_asr_source,
    find_existing_subtitle_candidate,
    find_existing_translated_candidate,
    load_agent_quality_judge,
    parse_translated_path_from_cli_output,
    missing_song_categories,
    sample_category_counts,
    sample_timing_profile,
    should_disable_whisper_context,
    summarize_agent_quality_judges,
    whisper_language_code,
)


def cues(texts):
    return [Cue(index=i + 1, start=i * 2.0, end=i * 2.0 + 1.5, text=text) for i, text in enumerate(texts)]


class ViewingQualityTests(unittest.TestCase):
    def test_gunjou_like_japanese_auto_caption_with_romanized_loop_is_unusable(self):
        report = source_quality_report(
            cues([
                "ああいつものようにすぎる一里にあくびが出る",
                "さんざめくよる声今日渋谷街に字買うん",
                "どこか話した",
                "anas あのこれええええええええええ",
                "しらす各 carano",
                "ni nani",
                "ni",
                "ni",
                "dare",
                "dare",
                "ni",
                "ana ni",
                "me ni",
                "ani box",
                "car ni",
                "悔しい気持ちだけ",
                "なくて涙立てる",
                "好きなことを続けること",
                "それは楽しいだけじゃない",
                "本当にできる",
            ]),
            requested_language_code="ja",
            subtitle_language_code="ja",
        )
        self.assertFalse(report.usable)
        self.assertIn("garbledOrRepetitive", report.reasons)

    def test_healthy_japanese_caption_with_some_latin_terms_stays_usable(self):
        report = source_quality_report(
            cues([
                "今日はYOASOBIの曲について話します",
                "まず最初のメロディーを聴いてください",
                "この部分はとても静かに始まります",
                "サビでは声の重なりが強くなります",
                "歌詞のイメージも青い世界を描いています",
                "MVの映像もその雰囲気に合わせています",
                "ここでピアノの音が前に出ます",
                "次にベースのリズムを確認します",
                "英語のタイトルGunjouも紹介されています",
                "全体として青春の迷いを表しています",
            ]),
            requested_language_code="ja",
            subtitle_language_code="ja",
        )
        self.assertTrue(report.usable)
        self.assertEqual([], report.reasons)

    def test_japanese_lyrics_with_parenthetical_romaji_gloss_stays_usable(self):
        report = source_quality_report(
            cues([
                "沈むように溶けていくように (Shizumu you ni tokete yuku you ni)",
                "二人だけの空が広がる夜に (Futari dake no sora ga hirogaru you ni)",
                "さよならだけだった (Sayonara dakedatta)",
                "その一言で全てが分かった (Sono hitokoto de subete ga wakatta)",
                "日が沈み出した空と君の姿 (Higa shizumi dashita sora to kimi no sugata)",
                "フェンス越しに重なっていた (Fensu-goshi ni kasanatte ita)",
                "初めて会った日から (Hajimete atta hi kara)",
                "僕の心の全てを奪った (Boku no kokoro no subete o ubatta)",
                "どこか儚い空気を纏う君は (Doko ka hakanai kuuki o matou kimi wa)",
                "寂しい目をしてたんだ (Sabishii me wo shitetanda)",
            ]),
            requested_language_code="ja",
            subtitle_language_code="ja",
        )
        self.assertTrue(report.usable)
        self.assertEqual([], report.reasons)
        self.assertLess(report.latin_scalar_ratio, 0.10)
        self.assertEqual(0, report.romanized_loop_token_count)

    def test_cjk_auto_caption_with_excessive_long_rolling_cues_is_unusable(self):
        bad_cues = [
            Cue(1, 1.12, 15.75, "私さは愚かさとはそれが何か見せつけて"),
            Cue(2, 15.76, 20.15, "やるちっちゃな頃から言うとせついたら"),
            Cue(3, 20.16, 24.99, "大人になってたナフのような思考会"),
            Cue(4, 25.00, 28.71, "持ち合わせる負けもなくでも遊び足りない"),
            Cue(5, 28.72, 33.59, "何か足りない困っちまうこれは誰かのせも"),
            Cue(6, 36.48, 42.63, "するましか最の流行は当然の白経のど"),
            Cue(7, 42.64, 49.75, "も中な精神でしは社会人は然の"),
            Cue(8, 68.96, 84.39, "メロディは頭の敵が違うので問題は"),
            Cue(9, 84.40, 90.15, "なしずっても私も半人間ったりするのはせ"),
            Cue(10, 90.16, 107.19, "ったら言葉の中をその仲にきつけては"),
        ]
        report = source_quality_report(
            bad_cues,
            requested_language_code="ja",
            subtitle_language_code="ja",
        )

        self.assertFalse(report.usable)
        self.assertIn("garbledOrRepetitive", report.reasons)
        self.assertGreaterEqual(report.long_cue_count, 2)

    def test_korean_lyrics_with_english_hook_stays_usable(self):
        report = source_quality_report(
            cues([
                "이 노래는 It's about you baby",
                "Only you",
                "내가 힘들 때 울 것 같을 때",
                "It's you I got done honey",
                "말 안 해도 돼 boy",
                "멀리든 언제든지 달려와",
                "dreams come true",
                "That's my life",
                "I'll be far away",
                "Be your writer",
                "내일 내게 열리는 건 big stage",
                "You and me",
            ]),
            requested_language_code="ko",
            subtitle_language_code="ko",
        )

        self.assertTrue(report.usable)
        self.assertEqual([], report.reasons)
        self.assertEqual(0, report.romanized_loop_token_count)

    def test_auto_caption_with_many_sound_effect_cues_is_unusable(self):
        report = source_quality_report(
            cues([
                "ルルルル",
                "[拍手]",
                "ルルルルル",
                "[音楽]",
                "君の中にある赤とはせも",
                "[拍手]",
                "[音楽]",
                "それらが結ばれるのは真の像",
                "風の中でも負けないような声で",
                "[拍手]",
                "届ける言葉を今は育ててる",
                "[音楽]",
            ]),
            requested_language_code="ja",
            subtitle_language_code="ja",
        )

        self.assertFalse(report.usable)
        self.assertIn("garbledOrRepetitive", report.reasons)
        self.assertGreaterEqual(report.sound_effect_cue_count, 4)

    def test_auto_caption_with_non_adjacent_repetition_loop_is_unusable(self):
        looped = []
        for index in range(24):
            if index % 2 == 0:
                looped.append("ね")
            else:
                looped.append("同じ短い声")
        report = source_quality_report(
            cues(looped),
            requested_language_code="ja",
            subtitle_language_code="ja",
        )

        self.assertFalse(report.usable)
        self.assertIn("garbledOrRepetitive", report.reasons)
        self.assertGreaterEqual(report.dominant_cue_text_ratio, 0.5)
        self.assertLess(report.unique_cue_text_ratio, 0.20)

    def test_auto_caption_with_long_sound_effect_holds_is_unusable(self):
        sample_cues = [
            Cue(index=1, start=1.0, end=16.0, text="[Musica]"),
            Cue(index=2, start=16.0, end=18.0, text="Marco se n'è andato e non"),
            Cue(index=3, start=18.0, end=23.0, text="ritorna il treno delle sette e trenta"),
            Cue(index=4, start=23.0, end=27.0, text="un cuore di metallo senza l'anima"),
            Cue(index=5, start=27.0, end=31.0, text="nel freddo del mattino grigio di città"),
            Cue(index=6, start=31.0, end=35.0, text="a scuola il banco è vuoto"),
            Cue(index=7, start=35.0, end=39.0, text="dolce il suo respiro"),
            Cue(index=8, start=39.0, end=43.0, text="ma il cuore batte forte"),
            Cue(index=9, start=75.0, end=89.0, text="[Musica]"),
        ]
        report = source_quality_report(
            sample_cues,
            requested_language_code="it",
            subtitle_language_code="it",
        )

        self.assertFalse(report.usable)
        self.assertIn("garbledOrRepetitive", report.reasons)
        self.assertGreaterEqual(report.sound_effect_duration_ratio, 0.12)

    def test_english_lyrics_with_music_note_markers_stays_usable(self):
        report = source_quality_report(
            cues([
                "♪ I WANT YOU TO STAY ♪",
                "'TIL I'M IN THE GRAVE ♪",
                "IF YOU GO, I'M GOING TOO, UH ♪",
                "BIRDS OF A FEATHER, WE SHOULD STICK TOGETHER, I KNOW ♪",
                "I'LL LOVE YOU 'TIL THE DAY THAT I DIE ♪",
                "♪♪♪",
                "TIL THE LIGHT LEAVES MY EYES ♪",
                "CAN'T CHANGE THE WEATHER, MIGHT NOT BE FOREVER ♪",
            ]),
            requested_language_code="en",
            subtitle_language_code="en",
        )

        self.assertTrue(report.usable)
        self.assertEqual([], report.reasons)
        self.assertEqual(1, report.sound_effect_cue_count)

    def test_vtt_cues_drop_rolling_transition_and_display_only_new_text(self):
        cues = parse_vtt_cues(
            "WEBVTT\n\n"
            "00:00:15.760 --> 00:00:20.150 align:start position:0%\n"
            "やる<00:00:16.760><c>ちっちゃ</c><00:00:17.240><c>な</c><00:00:17.400><c>頃</c>\n\n"
            "00:00:20.150 --> 00:00:20.160 align:start position:0%\n"
            "やるちっちゃな頃\n\n"
            "00:00:20.160 --> 00:00:24.990 align:start position:0%\n"
            "やるちっちゃな頃\n"
            "大人<00:00:20.600><c>に</c><00:00:20.800><c>なっ</c><00:00:21.080><c>て</c><00:00:21.320><c>た</c>\n"
        )

        self.assertEqual(["やるちっちゃな頃", "大人になってた"], [cue.text for cue in cues])

    def test_translated_quality_flags_romanized_garbage_leak(self):
        issues = translated_quality_issues(cues(["卡拉诺妮", "ni ni", "dare ni", "青春的蓝色"]))
        self.assertIn("romanizedGarbageLeak", issues)

    def test_local_asr_fallback_clears_platform_source_blocker(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            platform = root / "source.vtt"
            platform.write_text(
                "WEBVTT\n\n"
                "00:00:01.000 --> 00:00:02.000\nni\n\n"
                "00:00:02.000 --> 00:00:03.000\nni\n\n"
                "00:00:03.000 --> 00:00:04.000\ndare ni\n\n",
                encoding="utf-8",
            )
            local_asr = root / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n好きなことを続けること\n\n"
                "2\n00:00:04,000 --> 00:00:06,000\nそれは楽しいだけじゃない\n\n",
                encoding="utf-8",
            )

            report = build_viewing_sample_report(
                sample_id="fallback",
                title="Fallback",
                category="jpop_mv",
                source_path=platform,
                local_asr_path=local_asr,
                translated_path=None,
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=6.0,
            )

        self.assertEqual("local-asr", report.final_source_kind)
        self.assertEqual(str(local_asr), report.final_source_path)
        self.assertTrue(report.fallback_used)
        self.assertEqual(0, report.blocking_issue_count)
        self.assertEqual(["好きなことを続けること", "それは楽しいだけじゃない"],
                         [row["source"] for row in report.preview_rows])

    def test_source_candidate_report_marks_platform_rejected_and_local_selected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            platform = root / "source.vtt"
            platform.write_text(
                "WEBVTT\n\n"
                "00:00:01.000 --> 00:00:02.000\nni\n\n"
                "00:00:02.000 --> 00:00:03.000\nni\n\n"
                "00:00:03.000 --> 00:00:04.000\ndare ni\n\n",
                encoding="utf-8",
            )
            local_asr = root / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n好きなことを続けること\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="fallback",
                title="Fallback",
                category="jpop_mv",
                source_path=platform,
                local_asr_path=local_asr,
                translated_path=None,
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=3.0,
            )

        candidates = build_source_candidate_reports(report)
        platform_candidate = next(candidate for candidate in candidates if candidate["kind"] == "platform")
        local_candidate = next(candidate for candidate in candidates if candidate["kind"] == "local-asr")
        self.assertFalse(platform_candidate["usable"])
        self.assertFalse(platform_candidate["selected"])
        self.assertIn("garbledOrRepetitive", platform_candidate["reasons"])
        self.assertTrue(local_candidate["usable"])
        self.assertTrue(local_candidate["selected"])

    def test_source_candidate_report_marks_selected_low_quality_local_asr(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            platform = root / "source.vtt"
            platform.write_text(
                "WEBVTT\n\n"
                "00:00:01.000 --> 00:00:02.000\nni\n\n"
                "00:00:02.000 --> 00:00:03.000\nni\n\n"
                "00:00:03.000 --> 00:00:04.000\ndare ni\n\n",
                encoding="utf-8",
            )
            local_asr = root / "local-asr.ko.srt"
            local_asr.write_text(
                "1\n00:00:01,900 --> 00:00:05,100\n착\n\n"
                "2\n00:00:05,100 --> 00:00:10,200\n한\n\n"
                "3\n00:00:10,200 --> 00:00:25,600\n얼굴에\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="fallback-low-local",
                title="Fallback Low Local",
                category="kpop_music",
                source_path=platform,
                local_asr_path=local_asr,
                translated_path=None,
                source_language_code="ko",
                target_language_code="zh-Hans",
                preview_seconds=30.0,
            )

        candidates = build_source_candidate_reports(report)
        local_candidate = next(candidate for candidate in candidates if candidate["kind"] == "local-asr")
        self.assertEqual("local-asr", report.final_source_kind)
        self.assertTrue(local_candidate["selected"])
        self.assertFalse(local_candidate["usable"])
        self.assertTrue(any(reason.startswith("longShortCueHold:") for reason in local_candidate["reasons"]))
        self.assertIsNotNone(local_candidate["quality"])

    def test_pipeline_advice_records_fallback_decision_for_bad_japanese_music_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            platform = root / "source.vtt"
            platform.write_text(
                "WEBVTT\n\n"
                "00:00:01.000 --> 00:00:02.000\nni\n\n"
                "00:00:02.000 --> 00:00:03.000\nni\n\n"
                "00:00:03.000 --> 00:00:04.000\ndare ni\n\n",
                encoding="utf-8",
            )
            local_asr = root / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n好きなことを続けること\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="fallback",
                title="Fallback",
                category="jpop_mv",
                source_path=platform,
                local_asr_path=local_asr,
                translated_path=None,
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=3.0,
            )
        advice = build_pipeline_advice(
            sample={"id": "fallback", "title": "Fallback", "category": "jpop_mv", "language": "ja"},
            report=report,
            source_needed_fallback=True,
            local_asr_attempted=True,
            local_asr_available=True,
        )

        self.assertEqual("bad", advice["sourceAssessment"])
        self.assertEqual("useLocalASR", advice["recommendedSourceAction"])
        self.assertEqual("songLyrics", advice["preset"])
        self.assertEqual("japaneseLyrics", advice["timingProfile"])
        self.assertTrue(advice["asrHints"]["disablePromptContext"])

    def test_quality_judge_passes_when_fallback_clears_blockers(self):
        with tempfile.TemporaryDirectory() as temp:
            local_asr = Path(temp) / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n好きなことを続けること\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="fallback",
                title="Fallback",
                category="jpop_mv",
                source_path=None,
                local_asr_path=local_asr,
                translated_path=None,
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=3.0,
            )
        judge = build_quality_judge(report)

        self.assertTrue(judge["pass"])
        self.assertEqual([], judge["blockingIssues"])

    def test_quality_judge_prompt_includes_final_preview_and_json_schema(self):
        with tempfile.TemporaryDirectory() as temp:
            local_asr = Path(temp) / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n好きなことを続けること\n\n",
                encoding="utf-8",
            )
            translated = Path(temp) / "translated.srt"
            translated.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n继续做喜欢的事\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="fallback",
                title="Fallback",
                category="jpop_mv",
                source_path=None,
                local_asr_path=local_asr,
                translated_path=translated,
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=3.0,
            )

        prompt = build_quality_judge_prompt(report)
        self.assertIn("只输出 JSON", prompt)
        self.assertIn("final_source_kind: local-asr", prompt)
        self.assertIn("source=好きなことを続けること", prompt)
        self.assertIn("translated=继续做喜欢的事", prompt)

    def test_final_source_short_preview_coverage_blocks_non_music_report(self):
        with tempfile.TemporaryDirectory() as temp:
            local_asr = Path(temp) / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n好きなことを続けること\n\n"
                "2\n00:01:28,000 --> 00:01:30,000\nそれは楽しいだけじゃない\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="truncated",
                title="Truncated talk",
                category="japanese_talk",
                source_path=None,
                local_asr_path=local_asr,
                translated_path=None,
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=180.0,
            )

        self.assertEqual("local-asr", report.final_source_kind)
        self.assertTrue(any(issue.startswith("finalSourceCoverageShortfall:90.0s/180.0s")
                            for issue in report.final_source_issues))
        self.assertGreater(report.blocking_issue_count, 0)
        judge = build_quality_judge(report)
        self.assertFalse(judge["pass"])
        self.assertIn("finalSourceQuality", {issue["type"] for issue in judge["blockingIssues"]})

    def test_music_preview_shortfall_and_instrumental_gap_do_not_block_report(self):
        issues = final_source_quality_issues(
            [
                Cue(index=1, start=0.8, end=5.6, text="沈むように溶けていくように"),
                Cue(index=2, start=8.5, end=14.9, text="二人だけの空が広がる夜に"),
                Cue(index=3, start=31.0, end=33.5, text="さよならだけだった"),
                Cue(index=4, start=88.0, end=90.0, text="二人でいよう"),
            ],
            preview_seconds=180.0,
            category="jpop_mv",
            source_language_code="ja",
        )

        self.assertEqual([], issues)

    def test_final_source_quality_flags_long_short_song_cue_hold(self):
        issues = final_source_quality_issues(
            [Cue(index=1, start=0.0, end=3.2, text="ほら")],
            preview_seconds=180.0,
            category="jpop_mv",
            source_language_code="ja",
        )

        self.assertTrue(any(issue.startswith("longShortCueHold:1:3.2s") for issue in issues))

    def test_final_source_quality_flags_flash_short_song_cue(self):
        issues = final_source_quality_issues(
            [Cue(index=9, start=16.72, end=17.20, text="ほら")],
            preview_seconds=180.0,
            category="jpop_mv",
            source_language_code="ja",
        )

        self.assertTrue(any(issue.startswith("flashShortCue:9:0.5s") for issue in issues))

    def test_final_source_quality_flags_long_latin_filler_loop(self):
        issues = final_source_quality_issues(
            [
                Cue(index=1, start=0.0, end=2.0, text="Baby no me llames"),
                Cue(index=2, start=125.0, end=130.0, text="mmm mmm mmm yeah yeah yeah yeah"),
                Cue(index=3, start=130.2, end=135.0, text="yeah yeah yeah yeah yeah yeah"),
                Cue(index=4, start=135.2, end=139.0, text="yeah yeah yeah gracias por ver el video"),
            ],
            preview_seconds=180.0,
            category="romance_music",
            source_language_code="es",
        )

        self.assertIn("lyricFillerLoop", issues)

    def test_final_source_quality_flags_japanese_weak_boundary_split(self):
        issues = final_source_quality_issues(
            [
                Cue(index=24, start=93.98, end=99.78, text="情けなくて涙が出る踏み込むほど苦しく"),
                Cue(index=25, start=100.38, end=103.24, text="なる痛くもなる"),
            ],
            preview_seconds=120.0,
            category="jpop_mv",
            source_language_code="ja",
        )

        self.assertIn("weakBoundarySplit:24:adjectiveContinuation", issues)

    def test_final_source_flags_dangling_case_particle_and_clears_when_resegmented(self):
        # 群青原始碎断：cue 以宾格/主格助词悬空结尾（…ものを | …），是机器分段切成半句的信号。
        broken = final_source_quality_issues(
            [
                Cue(index=3, start=11.36, end=15.55, text="越え今日も渋谷の街に朝が"),
                Cue(index=4, start=15.63, end=19.44, text="降るどこか虚しいような"),
                Cue(index=13, start=53.26, end=57.04, text="青い世界好きなものを"),
                Cue(index=14, start=57.12, end=61.58, text="好きだと言う怖くて仕方ない"),
            ],
            preview_seconds=120.0,
            category="jpop_mv",
            source_language_code="ja",
        )
        self.assertTrue(
            any(issue.startswith("weakBoundarySplit:") and "danglingCaseParticle" in issue for issue in broken),
            broken,
        )

        # B-3 重分段把绑定助词与谓语合回完整乐句后，门应放行（に/の 等合法收尾不误伤）。
        resegmented = final_source_quality_issues(
            [
                Cue(index=1, start=2.52, end=7.06, text="いつものように過ぎる日々に"),
                Cue(index=2, start=11.36, end=15.55, text="今日も渋谷の街に朝が降る"),
                Cue(index=3, start=53.26, end=57.04, text="好きなものを好きだと言う"),
                Cue(index=4, start=57.12, end=61.58, text="怖くて仕方ない"),
            ],
            preview_seconds=120.0,
            category="jpop_mv",
            source_language_code="ja",
        )
        self.assertFalse(
            any("danglingCaseParticle" in issue for issue in resegmented),
            resegmented,
        )

    def test_final_source_quality_flags_zh_yue_ko_weak_boundary_splits(self):
        zh = final_source_quality_issues(
            [
                Cue(index=1, start=10.0, end=12.0, text="我想把"),
                Cue(index=2, start=12.1, end=14.0, text="所有故事都唱给你听"),
            ],
            preview_seconds=30.0,
            category="c-pop_music",
            source_language_code="zh",
        )
        self.assertIn("weakBoundarySplit:1:danglingChineseFunctionWord", zh)

        yue = final_source_quality_issues(
            [
                Cue(index=3, start=20.0, end=22.0, text="我哋嘅"),
                Cue(index=4, start=22.1, end=24.0, text="心事未講完"),
            ],
            preview_seconds=30.0,
            category="cantopop_mv",
            source_language_code="yue",
        )
        self.assertIn("weakBoundarySplit:3:danglingCantoneseParticle", yue)

        ko = final_source_quality_issues(
            [
                Cue(index=5, start=30.0, end=32.0, text="너의 마음을"),
                Cue(index=6, start=32.1, end=34.0, text="잡고 싶어"),
            ],
            preview_seconds=40.0,
            category="kpop_music",
            source_language_code="ko",
        )
        self.assertIn("weakBoundarySplit:5:danglingKoreanParticle", ko)

    def test_translation_attempt_without_output_blocks_report(self):
        with tempfile.TemporaryDirectory() as temp:
            local_asr = Path(temp) / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n好きなことを続けること\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="translate-failed",
                title="Translate failed",
                category="jpop_mv",
                source_path=None,
                local_asr_path=local_asr,
                translated_path=None,
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=3.0,
                translation_attempted=True,
            )

        self.assertIn("missingTranslation", report.translated_issues)
        self.assertGreater(report.blocking_issue_count, 0)
        judge = build_quality_judge(report)
        self.assertFalse(judge["pass"])
        self.assertIn("translatedQuality", {issue["type"] for issue in judge["blockingIssues"]})

    def test_missing_translated_path_is_treated_as_missing_translation(self):
        with tempfile.TemporaryDirectory() as temp:
            local_asr = Path(temp) / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n好きなことを続けること\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="missing-translated-file",
                title="Missing translated file",
                category="jpop_mv",
                source_path=None,
                local_asr_path=local_asr,
                translated_path=Path(temp) / "translated.srt",
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=3.0,
                translation_attempted=True,
            )

        self.assertIsNone(report.translated_path)
        self.assertEqual(["missingTranslation"], report.translated_issues)

    def test_quality_judge_prompt_includes_source_language_and_final_source_issues(self):
        with tempfile.TemporaryDirectory() as temp:
            local_asr = Path(temp) / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n情けなくて涙が出る踏み込むほど苦しく\n\n"
                "2\n00:00:04,000 --> 00:00:06,000\nなる痛くもなる\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="prompt",
                title="Prompt",
                category="jpop_mv",
                source_path=None,
                local_asr_path=local_asr,
                translated_path=None,
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=180.0,
            )

        prompt = build_quality_judge_prompt(report)
        self.assertIn("source_language_code: ja", prompt)
        self.assertIn("final_source_issues:", prompt)
        self.assertIn("adjectiveContinuation", prompt)

    def test_agent_translation_prompt_defines_numbered_json_contract(self):
        with tempfile.TemporaryDirectory() as temp:
            local_asr = Path(temp) / "local-asr.ja.srt"
            local_asr.write_text(
                "1\n00:00:01,000 --> 00:00:03,000\n好きなことを続けること\n\n"
                "2\n00:00:04,000 --> 00:00:06,000\nそれは楽しいだけじゃない\n\n",
                encoding="utf-8",
            )
            report = build_viewing_sample_report(
                sample_id="agent-prompt",
                title="Agent Prompt",
                category="jpop_mv",
                source_path=None,
                local_asr_path=local_asr,
                translated_path=None,
                source_language_code="ja",
                target_language_code="zh-Hans",
                preview_seconds=6.0,
            )

        prompt = build_agent_translation_prompt(report, target_language_code="zh-Hans")

        self.assertIn("云端 LLM 翻译层模拟器", prompt)
        self.assertIn("只翻译，不改编号，不改时间轴", prompt)
        self.assertIn("\"translations\"", prompt)
        self.assertIn("\"inputIssues\"", prompt)
        self.assertIn("歌词翻译", prompt)
        self.assertIn("1. 1.00-3.00 | 好きなことを続けること", prompt)

    def test_weak_boundary_candidates_surface_likely_japanese_lyric_splits(self):
        rows = [
            {"index": 1, "start": 93.98, "end": 99.78, "source": "情けなくて涙が出る踏み込むほど苦しく", "translated": ""},
            {"index": 2, "start": 100.38, "end": 103.24, "source": "なる痛くもなる", "translated": ""},
            {"index": 3, "start": 103.32, "end": 107.90, "source": "感じたままに", "translated": ""},
            {"index": 4, "start": 107.98, "end": 112.38, "source": "進む自分で選んだこの道を", "translated": ""},
        ]

        candidates = weak_boundary_candidates(rows, language_code="ja")

        self.assertEqual(1, len(candidates))
        self.assertEqual(1, candidates[0]["cue"])
        self.assertEqual("adjectiveContinuation", candidates[0]["type"])
        self.assertIn("苦しく / なる", candidates[0]["reason"])

    def test_music_like_cjk_fallback_disables_whisper_prompt_context(self):
        self.assertTrue(should_disable_whisper_context({
            "language": "ja",
            "category": "jpop_mv",
        }))
        self.assertTrue(should_disable_whisper_context({
            "language": "ko",
            "category": "korean_music",
        }))
        self.assertFalse(should_disable_whisper_context({
            "language": "en",
            "category": "english_lecture",
        }))

    def test_cantonese_fallback_uses_whisper_zh_language_code(self):
        self.assertEqual("zh", whisper_language_code("yue"))
        self.assertEqual("ja", whisper_language_code("ja"))

    def test_music_like_japanese_fallback_uses_japanese_lyrics_timing_profile(self):
        self.assertEqual("japaneseLyrics", sample_timing_profile({
            "language": "ja",
            "category": "jpop_mv",
        }))
        self.assertEqual("lyrics", sample_timing_profile({
            "language": "ko",
            "category": "korean_music",
        }))
        self.assertEqual("speech", sample_timing_profile({
            "language": "en",
            "category": "english_lecture",
        }))

    def test_parse_translated_path_from_moongate_cli_output(self):
        self.assertEqual(
            Path("/tmp/video.ja.zh-Hans.srt"),
            parse_translated_path_from_cli_output("翻译中 100%\n译文文件：/tmp/video.ja.zh-Hans.srt\n"),
        )
        self.assertIsNone(parse_translated_path_from_cli_output("字幕翻译失败：尚未配置 API 凭证"))

    def test_finds_existing_source_and_local_asr_artifacts_for_report_refresh(self):
        with tempfile.TemporaryDirectory() as temp:
            sample_dir = Path(temp)
            source = sample_dir / "video.ja.vtt"
            source.write_text("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nこんにちは\n", encoding="utf-8")
            local_asr = sample_dir / "local-asr.ja.srt"
            local_asr.write_text("1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n", encoding="utf-8")
            (sample_dir / "translated.srt").write_text("1\n00:00:01,000 --> 00:00:02,000\n你好\n", encoding="utf-8")

            sample = {"language": "ja"}

            self.assertEqual(source, find_existing_subtitle_candidate(sample, sample_dir))
            self.assertEqual(local_asr, find_existing_local_asr_source(sample, sample_dir))
            self.assertEqual(sample_dir / "translated.srt", find_existing_translated_candidate(sample_dir))

    def test_song_suite_manifest_has_thirty_songs_and_required_category_coverage(self):
        self.assertEqual(30, len(SONG_SAMPLES))
        ids = [sample["id"] for sample in SONG_SAMPLES]
        self.assertEqual(len(ids), len(set(ids)))
        counts = sample_category_counts(SONG_SAMPLES)

        self.assertEqual([], missing_song_categories(counts))
        for category, required in SONG_CATEGORY_GOAL.items():
            self.assertGreaterEqual(counts.get(category, 0), required, category)

    def test_song_suite_uses_music_categories_and_declared_languages(self):
        allowed_languages = {"ja", "ko", "zh", "yue", "en", "fr", "es", "it"}
        for sample in SONG_SAMPLES:
            self.assertIn(sample["language"], allowed_languages)
            self.assertRegex(sample["category"], r"(music|jpop|song|live)")
            self.assertTrue(sample["source"].startswith(("https://www.youtube.com/watch?v=", "ytsearch1:")))

    def test_agent_quality_judge_summary_counts_pass_blocking_minor_and_invalid(self):
        summary = summarize_agent_quality_judges(
            {
                "good": {"pass": True, "blockingIssues": [], "minorIssues": [{"cue": 3}]},
                "bad": {"pass": False, "blockingIssues": [{"cue": 1}], "minorIssues": []},
            },
            ["broken"],
        )

        self.assertEqual(2, summary["agent_quality_judge_count"])
        self.assertEqual(1, summary["agent_quality_pass_count"])
        self.assertEqual(["good"], summary["agent_quality_pass_samples"])
        self.assertEqual(["bad"], summary["agent_quality_blocking_samples"])
        self.assertEqual(["good"], summary["agent_quality_minor_samples"])
        self.assertEqual(["broken"], summary["agent_quality_invalid_samples"])

    def test_load_agent_quality_judge_accepts_valid_shape_and_rejects_invalid(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "agent_quality_judge.json").write_text(
                "{\"pass\": true, \"blockingIssues\": [], \"minorIssues\": []}",
                encoding="utf-8",
            )
            payload, error = load_agent_quality_judge(root)
            self.assertIsNone(error)
            self.assertEqual(True, payload["pass"])

            (root / "agent_quality_judge.json").write_text("[]", encoding="utf-8")
            payload, error = load_agent_quality_judge(root)
            self.assertIsNone(payload)
            self.assertIsNotNone(error)


if __name__ == "__main__":
    unittest.main()
