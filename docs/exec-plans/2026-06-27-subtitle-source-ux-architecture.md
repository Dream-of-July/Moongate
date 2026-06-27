# Subtitle Source UX And Architecture

## Background And Product Intent

The handbook in `/Users/xianjingheng/Downloads/moongate_subtitle_ux_architecture_handbook` identifies a product mismatch in the Ready page: users want to choose the final subtitle output, while the app exposes original language, platform subtitle tracks, local ASR, and translation/burn behavior in one mixed control surface.

The product intent is to let normal users choose a simple subtitle outcome, let Moongate choose the best source by default, and expose the final source decision after download.

## Current Repository Understanding

- Ready page layout and subtitle controls live in `Sources/Moongate/ContentView.swift`.
- Ready page state and request construction live in `Sources/Moongate/ViewModel.swift`.
- User-facing subtitle mode still uses `ChineseSubtitleMode`, and the concrete source still flows through `primarySubtitleTrackID`.
- Core subtitle track identity, `DownloadRequest`, `ResolvedSubtitleSource`, `SubtitleSourceCandidateReport`, and `SongSubtitleSourceArbiter` live in `Sources/MoongateCore/Models.swift` and `Sources/MoongateCore/PlatformSubtitleQualityGate.swift`.
- Post-download auto-caption fallback to local ASR is already implemented in `Sources/Moongate/QueueManager.swift`.
- Existing quality metrics already cover cue count, coverage, CJK/Latin ratios, repetition, bad scalars, sound-effect cues, long cues, and romanized loops.

## Goals

- Reframe the Ready page as `Subtitle output` first, then `Subtitle source` only when subtitles are needed.
- Add explicit Core-level models for `SubtitleIntent`, `SourceLanguageIntent`, and `SubtitleSourcePolicy` without deleting old compatibility state.
- Add a deterministic `SubtitleQualityScorer` and `SubtitleSourceResolver` that can compare manual, platform auto, local ASR, cloud ASR placeholders, and imported candidates.
- Add tests based on the Koopenchan handbook fixtures so bad ASR-like captions do not get high-confidence verdicts.
- Wire local VAD into whisper.cpp command planning when a Silero VAD model is present, with graceful UI downgrade when it is missing.
- Show the final subtitle source, five-level quality verdict, fallback reason, and candidate reports in queue task details.

## Non-Goals

- Do not remove `ChineseSubtitleMode` or `primarySubtitleTrackID` in this iteration.
- Do not bundle or download SenseVoice/faster-whisper models, create a paid account flow, or promote JSON-only cloud models as high-confidence backends without a guide timeline and paid smoke proof. A default-off local sidecar adapter and a Core-level transcript alignment path are allowed so externally installed precise recognizers can plug into the same source-resolution pipeline.
- Do not run a real cloud transcription call without explicit credentials and user-controlled confirmation.
- Do not force-generate local ASR for every usable platform subtitle in default mode. The expensive compare path must remain an explicit advanced policy.

## Approach

- Keep the behavior-compatible request path, but introduce new intent/policy state in the ViewModel as a compatibility layer.
- Use `subtitleIntent` as the Ready page primary control and derive legacy `ChineseSubtitleMode` from it.
- Keep source selection defaulted to `autoBest`; expose fixed-source and explicit local-compare policy choices under an advanced disclosure.
- Build `SubtitleSourceCandidate` values from existing `SubtitleChoice` metadata and downloaded source files.
- Let `SubtitleQualityScorer` wrap `PlatformSubtitleQualityGate` so current metrics stay the source of truth.
- Let `SubtitleSourceResolver` rank scored candidates with policy boosts, but integrate it conservatively around existing queue fallback behavior.
- Treat `cloudASR` as an explicit advanced source policy only: default mode stays local/private, and cloud recognition requires settings, upload/cost consent, and either a direct-SRT backend or a local timing guide for JSON-text alignment.
- Treat `compareLocalASR` as the current usable precise mode: if the selected source is platform auto, generate local ASR too and let the resolver score both files.
- Treat the OpenAI-compatible cloud ASR adapter as direct-SRT first. `whisper-1` can run directly; JSON-only models must use an explicit timed guide SRT from local recognition before they can produce timed subtitles.

## Milestones And Validation

- Phase 1: Core models/scorer/resolver plus tests.
- Phase 2: Ready page UI/state compatibility layer plus boundary tests.
- Phase 3: Queue source reports use resolver-backed reports where safe.
- Phase 4: VAD command wiring and Settings status.
- Phase 5: imported subtitle file path and source-only queue disclosure.
- Phase 6: explicit local compare mode for platform auto-caption versus local ASR.
- Phase 7: OpenAI-compatible cloud ASR explicit policy with settings consent and queue integration.
- Validation: focused Swift tests first, then full `swift test --disable-sandbox`.

## Expected File Changes

- `Sources/MoongateCore/SubtitleSourcePolicy.swift`
- `Sources/MoongateCore/SubtitleQualityScorer.swift`
- `Sources/MoongateCore/SubtitleSourceResolver.swift`
- `Sources/MoongateCore/TranslationOutputQualityGate.swift`
- `Sources/MoongateCore/CloudASR.swift`
- `Sources/MoongateCore/ASR.swift`
- `Sources/MoongateCore/Models.swift`
- `Sources/MoongateCore/Translator.swift`
- `Sources/Moongate/ContentView.swift`
- `Sources/Moongate/QueueItemView.swift`
- `Sources/Moongate/QueueManager.swift`
- `Sources/Moongate/SettingsView.swift`
- `Sources/Moongate/ViewModel.swift`
- `Sources/MoongateMobileCore/Localization/LocalizationKeys.swift`
- `Sources/MoongateMobileCore/Localization/Strings.en.swift`
- `Sources/MoongateMobileCore/Localization/Strings.zhHans.swift`
- `Sources/MoongateMobileCore/Localization/Strings.zhHant.swift`
- `windows/MoongateCore/Asr.cs`
- `windows/MoongateCore/CloudAsr.cs`
- `windows/MoongateCore/Models.cs`
- `windows/MoongateCore/PlatformSubtitleQualityGate.cs`
- `windows/MoongateCore/Queue.cs`
- `windows/MoongateCore/SubtitleSourceResolver.cs`
- `windows/MoongateCore/TranslationOutputQualityGate.cs`
- `windows/MoongateCore/Translator.cs`
- `windows/MoongateApp/MainWindow.xaml`
- `windows/MoongateApp/MainViewModel.cs`
- `windows/MoongateApp/QueueItemViewModel.cs`
- `windows/MoongateApp/SettingsWindow.xaml`
- `windows/MoongateApp/SettingsViewModel.cs`
- `windows/MoongateApp/Strings.en.xaml`
- `windows/MoongateApp/Strings.zh.xaml`
- `windows/MoongateApp/Strings.zh-Hant.xaml`
- `Tests/MoongateCoreTests/SubtitleSourceResolverTests.swift`
- `Tests/MoongateCoreTests/CloudASRTests.swift`
- `Tests/MoongateCoreTests/ASRContractsTests.swift`
- `Tests/MoongateCoreTests/ConfiguredTranslatorFallbackTests.swift`
- `Tests/MoongateCoreTests/TranslationSettingsTests.swift`
- `Tests/MoongateCoreTests/MacOSContentBoundaryTests.swift`
- `Tests/MoongateCoreTests/MacOSQueueBoundaryTests.swift`
- `Tests/MoongateCoreTests/MacOSSettingsBoundaryTests.swift`
- `Tests/MoongateCoreTests/MacOSViewModelBoundaryTests.swift`
- `Tests/MoongateCoreTests/LocalizerTests.swift`
- `windows/MoongateCore.Tests/AsrContractsTests.cs`
- `windows/MoongateCore.Tests/EngineParsingTests.cs`
- `windows/MoongateCore.Tests/QueueTests.cs`
- `windows/MoongateCore.Tests/SettingsTests.cs`
- `windows/MoongateCore.Tests/SubtitleSourceResolverTests.cs`
- `windows/MoongateCore.Tests/TranslatorTests.cs`
- `windows/MoongateCore.Tests/WindowsSettingsSurfaceTests.cs`

## Risks And Rollback

- Risk: changing Ready page state could silently change queued request behavior. Mitigation: keep the legacy request fields and derive them from new intent only in one place.
- Risk: scorer thresholds could over-penalize valid lyrics. Mitigation: preserve existing `PlatformSubtitleQualityGate` tests for healthy lyrics and add bad-fixture regressions narrowly.
- Risk: UI boundary tests are string-based and may need updates when helper names change. Mitigation: update tests to assert product structure, not exact line layout.

Rollback is straightforward: remove the new scorer/resolver files and revert the Ready page helper refactor; legacy download request fields remain intact.

## Decision Record

- 2026-06-27: Treat this as a compatibility-layer refactor, not a destructive replacement of `ChineseSubtitleMode` or `primarySubtitleTrackID`.
- 2026-06-27: Cloud ASR should remain opt-in and consent-gated, but the handbook's final precise-mode recommendation is concrete enough to wire as an explicit advanced policy once settings and direct-SRT guardrails exist.
- 2026-06-27: Default resolver integration only generates local ASR after platform auto-caption quality fails. Always generating Whisper to compare against a usable platform subtitle must be opt-in because it adds expensive recognition work.
- 2026-06-27: Importing SRT/VTT must be a real Ready-page path, not just an advanced policy label; imported files are copied into the task output directory before source resolution.
- 2026-06-27: Windows should match Swift VAD behavior at the command-planning layer: emit `--vad --vad-model` only when a Silero model is discoverable, otherwise keep the existing whisper.cpp path.
- 2026-06-27: Windows Ready page should also follow the output-first information architecture. Keep the existing `ChineseSubtitleMode` and `PrimarySubtitleTrackId` compatibility contract, but let non-off output modes auto-select the recommended source and reveal the source section only when subtitles are requested.
- 2026-06-27: Translation output quality needs its own post-generation guard. Source subtitle quality gates do not catch a translator that leaves Japanese/Korean/Latin source text inside a Chinese target SRT.
- 2026-06-27: ASR prompts should carry video title/channel plus conservative character/glossary hints. The Koopenchan fixture exposed that generic Japanese recognition loses proper nouns and food/festival terms.
- 2026-06-27: Expose `cloudASR` only after adding settings, upload/cost consent, direct-SRT model restrictions, and queue-level source reporting. It must not become the default source policy.
- 2026-06-27: Add a visible `compareLocalASR` advanced policy as the real local precise mode. It is not cloud; it reuses configured local Whisper and keeps cloud ASR gated behind future backend/cost work.
- 2026-06-27: For cloud ASR, use an OpenAI-compatible `/v1/audio/transcriptions` adapter. `whisper-1` is the first SRT/VTT-capable backend; `gpt-4o-transcribe` must not be offered as a direct SRT source because it does not provide SRT timing output.
- 2026-06-27: Japanese puns and wordplay need explicit translation guidance, separate from ASR glossary hints. When an equivalent Chinese pun is not safe, keep the source term and add a short natural meaning instead of inventing unrelated text.
- 2026-06-28: Handbook copy replacement is part of completion, not polish. The old "auto captions do not outrank..." explanation must be removed from user-facing resources and replaced with output-first guidance.
- 2026-06-28: Windows parity must be architectural, not only WPF layout parity. `compareLocalASR` must score platform and local candidates through the resolver rather than treating any usable platform auto-caption as final.
- 2026-06-28: Windows should carry `SubtitleIntent` and `SourceLanguageIntent` through `DownloadRequest` so future queue and resolver work does not have to infer product intent from UI-only state.
- 2026-06-28: Windows translation output needs the same target-language leakage guard as Swift before writing final SRT files.
- 2026-06-28: The handbook's "precise local mode" should not remain only as a future note. It is acceptable to keep large model installation external, but Moongate needs a real opt-in local sidecar adapter so faster-whisper, SenseVoice/FunASR, or alignment wrappers can be connected without new bundled dependencies.
- 2026-06-28: JSON-only cloud ASR models should not be presented as direct-timing models, but they can be queue-eligible when local recognition can provide an explicit guide timeline. Paid smoke proof is still required before treating them as a high-confidence backend.

## Progress

- 2026-06-27: Read GPT 5.6 Pro handbook and mapped it to current Moongate Ready page and Core subtitle pipeline.
- 2026-06-27: Created this ExecPlan.
- 2026-06-27: Added Core `SubtitleIntent`, `SourceLanguageIntent`, `SubtitleSourcePolicy`, `SubtitleQualityScorer`, and `SubtitleSourceResolver` as a compatibility layer.
- 2026-06-27: Added Koopenchan-inspired scorer/resolver tests for low-confidence ASR-like captions and policy-based source selection.
- 2026-06-27: Reworked the macOS Ready page to show subtitle output before subtitle source, hiding source controls when the user chooses no subtitle output.
- 2026-06-27: Added ViewModel intent/policy compatibility helpers while keeping the existing `DownloadRequest` contract.
- 2026-06-27: Added `DownloadRequest.subtitleSourcePolicy` and resolver-backed post-download source resolution in `QueueManager`.
- 2026-06-27: Added VAD model discovery for whisper.cpp command planning, with Settings status for ready/missing VAD model.
- 2026-06-27: Added queue task details for actual source, quality, fallback reason, and candidate reports.
- 2026-06-27: Added Ready-page import subtitle file flow, copied imported SRT/VTT files into the task output directory, and routed source-only downloads through final source disclosure.
- 2026-06-27: Preserved `SubtitleQualityVerdict` through `ResolvedSubtitleSource` and candidate reports so the UI can show excellent/good/usable/low-confidence/unusable instead of collapsing to a boolean.
- 2026-06-27: Ran full Swift test suite successfully with `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch`.
- 2026-06-27: Added Windows `WhisperCppVADModelLocator`, wired C# `WhisperCppCommandPlan` to emit VAD args when the model exists, and covered ready/missing/disabled VAD cases.
- 2026-06-27: Ran Windows ASR contract tests and then full Windows Core tests successfully with `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore` after escalating local test socket access.
- 2026-06-27: Attempted `dotnet test windows/Moongate.Win.sln --no-restore`; Core tests passed and `MoongateApp` compiled, but `MoongateApp.Tests` could not run on macOS because `Microsoft.WindowsDesktop.App 10.0.0` is not installed for arm64.
- 2026-06-27: Reworked Windows Ready page order so `Subtitle output` appears before `Subtitle source`, removed the source-section "no subtitles" radio, hid source controls while output is off, and added a ViewModel compatibility helper that auto-selects the recommended source when a non-off output mode is chosen.
- 2026-06-27: Added Windows surface tests for the output-first layout and ran a static parity check plus `dotnet build windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore` and `dotnet build windows/MoongateApp/MoongateApp.csproj --no-restore`; `dotnet test` remains blocked in the sandbox by local test socket permission.
- 2026-06-27: Added `TranslationOutputQualityGate` and wired `ConfiguredTranslator` to reject target Chinese SRT output that still contains high-confidence source-language leakage before writing the final file.
- 2026-06-27: Added ASR prompt metadata support for title/channel/characters/glossary terms, with Koopenchan-specific conservative hints for `コウペンちゃん`, `邪エナガさん`, `チョコバナナ`, `ソースせんべい`, and `くじ引きやろう`.
- 2026-06-27: Threaded `SourceLanguageIntent` through `DownloadRequest` and queue resolver input so the new intent layer is not only UI state.
- 2026-06-27: Added Windows Settings VAD status text so users can see whether Silero VAD is ready or the app is falling back to ordinary recognition.
- 2026-06-27: Added dormant `cloudASR` source identity in Swift and Windows models, Core scoring/ranking support, localized diagnostic labels, and stable ID parsing tests without exposing a cloud source policy or Ready-page cloud button.
- 2026-06-27: Re-ran focused Swift tests for translation leakage, ASR prompt metadata, SourceLanguageIntent request construction, subtitle source resolver including `cloudASR`, and stable subtitle IDs.
- 2026-06-27: Re-ran Windows builds after VAD/settings/model changes and verified the new stable ID parsing test with unsandboxed local test socket access.
- 2026-06-27: Added low-confidence all-candidates resolver coverage and a queue detail suggestion so bad subtitle sources do not only show a vague "low confidence" label.
- 2026-06-27: Added explicit `compareLocalASR` advanced source policy. For platform auto captions it generates local ASR even when the platform file is usable, then scores both candidates through `SubtitleSourceResolver`.
- 2026-06-27: Added compare-mode labels and unavailable-local-ASR copy across Simplified Chinese, Traditional Chinese, and English.
- 2026-06-27: Added `OpenAICloudASRClient` backend groundwork: multipart transcription request builder, SRT output writer, test transport, and guardrail rejecting `gpt-4o-transcribe` for SRT output.
- 2026-06-27: Re-read the full GPT 5.6 Pro handbook after the latest slice and audited the remaining gaps against the current macOS, Core, and Windows surfaces.
- 2026-06-27: Added Windows `compareLocalASR` advanced policy, Ready-page policy picker, queue source/candidate disclosure, and imported SRT/VTT selection parity with the macOS flow.
- 2026-06-27: Wired Windows imported subtitle files through ViewModel metadata, copied them into the task output directory as `imported-subtitle.<lang>`, selected them before platform/local sources, and reported the final source as `importedFile`.
- 2026-06-27: Added macOS and Windows Cloud ASR settings groundwork: default-off enable flag, explicit upload/cost consent, OpenAI-compatible base URL/model fields, independent credential storage, readiness copy, and localized settings UI.
- 2026-06-27: Re-read all six GPT 5.6 Pro handbook files and re-audited the remaining recommendations. The remaining code-facing gaps were Windows Cloud ASR queue parity and explicit Koopenchan fixture test naming.
- 2026-06-27: Wired Windows Cloud ASR as an explicit advanced source policy. `MainViewModel` now exposes the cloud policy, opens settings when cloud recognition is not configured, and syncs `CloudAsrGeneratorFactory` into `QueueManager`.
- 2026-06-27: Added Windows `CloudAsr.cs` with an OpenAI-compatible direct-SRT generator, settings-gated factory, queue source generation, source ranking, final `CloudAsr` reporting, and candidate reports.
- 2026-06-27: Added focused Koopenchan tests named after the handbook recommendations: short cue fragmentation, CJK hallucination-like phrase penalty, and platform auto sound-effect fallback to local ASR.
- 2026-06-27: Latest validation passed: Swift Ready/Queue/CloudASR/Resolver focused tests (36 tests), full Windows Core tests (708 tests), Windows App build, and `git diff --check`.
- 2026-06-27: Re-ran handbook keyword audit for all six GPT 5.6 Pro files. The last code-facing gap was handbook 05's Japanese pun/wordplay recommendation.
- 2026-06-27: Added Swift and Windows translation prompt guidance for Japanese `谐音梗`/puns: preserve source terms with short meaning when direct Chinese wordplay is not reliable, with Koopenchan terms such as `チョコバナナ`, `ソースせんべい`, and `くじ引きやろう` gated to Japanese-source prompts.
- 2026-06-27: Red-green verified the new prompt requirement with focused Swift and Windows translator tests, then re-ran broad Swift and Windows checks.
- 2026-06-28: Re-read all six handbook files and found one remaining UX copy gap: Simplified Chinese, Traditional Chinese, and English resources still contained the old auto-source explanation and old source-subtitle/audio-language label.
- 2026-06-28: Replaced those macOS and Windows resources with the handbook's clearer "confirm original audio language; Moongate chooses the most reliable source" copy, and added Swift/Windows assertions so the old copy cannot silently return.
- 2026-06-28: Re-audited the implementation against the handbook and a read-only explorer report. The remaining local gaps were Windows-only parity gaps: resolver-backed compare mode, explicit intent models, resolver/scorer tests, ASR metadata/glossary prompts, and translation output leakage guarding.
- 2026-06-28: Added Windows `SubtitleQualityScorer`/`SubtitleSourceResolver` parity and changed `compareLocalASR` so platform auto and local ASR candidates are both scored before final source selection.
- 2026-06-28: Added Windows `SubtitleIntent` and `SourceLanguageIntent` models to `DownloadRequest`, then threaded them from single and batch enqueue paths.
- 2026-06-28: Added Windows ASR prompt metadata support for title/channel/characters/glossary terms, including Koopenchan-specific proper nouns and festival/food terms.
- 2026-06-28: Added Windows translation output leakage detection before final subtitle write, plus focused regression coverage.
- 2026-06-28: Re-ran the current final validation set: Swift full test suite, Windows Core full test suite, Windows App build, `git diff --check`, and old-copy resource scan.
- 2026-06-28: Added an opt-in local precise ASR sidecar adapter on Swift and Windows. When configured, the local ASR factory prefers a user-supplied sidecar process with the fixed `--input/--output/--language/--model/--format srt` contract; otherwise the existing whisper.cpp path remains unchanged.
- 2026-06-28: Added macOS and Windows Settings fields/readiness copy for the local precise sidecar, all default-off. Focused Swift and Windows tests verify settings round-trip, factory selection, Settings surface coverage, and real sidecar-process SRT output.
- 2026-06-28: Extended `tools/local_asr_smoke` so release QA can pass a local Silero VAD model via `MOONGATE_ASR_QA_VAD_MODEL` and defaults to whisper.cpp `--no-gpu` for the deterministic local smoke path.
- 2026-06-28: Ran a real local ASR smoke on a 20-second Koopenchan clip with `/opt/homebrew/bin/whisper-cli`, `ggml-large-v3-turbo-q5_0.bin`, and `ggml-silero-v5.1.2.bin`. whisper.cpp loaded the Silero VAD model, produced non-empty JSON, and wrote `/private/tmp/moongate-local-asr-real-smoke/moongate-koopen-20s.local-asr.ja.srt`.
- 2026-06-28: Added `tools/cloud_asr_smoke` as a strictly manual upload/cost-gated cloud ASR QA path. It validates `whisper-1` direct-SRT output and keeps JSON-only models blocked until the caller provides a guide SRT for local alignment.
- 2026-06-28: Re-checked the current OpenAI transcription API reference: `gpt-4o-transcribe` and `gpt-4o-mini-transcribe` only support `json` response format, while direct `srt`/`vtt` remains inappropriate for those models. The existing direct-SRT guardrail is still correct.
- 2026-06-28: Ran Windows validation inside the Parallels `Windows 11` VM from a copied NTFS temp checkout after shared-folder `obj` writes were denied. Windows Core full tests passed (715/715), Windows WPF App build passed, and `MoongateApp.Tests` passed (2/2).
- 2026-06-28: Re-audited the GPT 5.6 Pro handbook folder after the cloud/sidecar work. Tightened the JSON-only cloud model boundary so Swift and Windows Settings do not report `gpt-4o-transcribe` as a direct-timing model; without local recognition they show an explicit timed-guide-needed message.
- 2026-06-28: Added Swift and Windows `CloudTranscriptAligner` support. `OpenAICloudASRClient`/`OpenAICloudAsrSubtitleGenerator` can request `response_format=json`, extract text, and write a timed SRT by projecting that transcript onto a supplied guide SRT timeline.
- 2026-06-28: Extended `tools/cloud_asr_smoke` so JSON-only cloud models such as `gpt-4o-transcribe` remain blocked without a guide SRT, but can run a manual upload/cost-gated JSON+local-alignment smoke when `MOONGATE_CLOUD_ASR_GUIDE_SRT` is explicitly provided.
- 2026-06-28: Wired the JSON+guide Cloud ASR path into Swift and Windows queue generator factories. When local recognition is configured, JSON-only cloud models can use local ASR as the timing guide; Settings now says that explicitly instead of implying the alignment path is missing.
- 2026-06-28: Re-read the GPT 5.6 Pro handbook folder again and fixed the remaining stale Cloud ASR wording. User-facing Settings copy now says JSON-only models need a timed guide/local recognition rather than claiming Moongate lacks an alignment path.
- 2026-06-28: Tightened Windows Ready-page source IA so the default visible source row says auto-select best source; the recommended language is secondary context, and technical source badges stay in the collapsed language details.
- 2026-06-28: Re-ran Windows VM validation on a fresh NTFS temp copy of the latest checkout: Core full tests passed (718/718), WPF app build passed (0 warnings, 0 errors), App smoke tests passed (2/2), and a VM screenshot confirmed the Windows app launches to a nonblank main window.

## Requirement Audit

| Handbook requirement | Current evidence | Status |
| --- | --- | --- |
| Ready page asks for final subtitle output before source | `ContentView.swift` uses `L.Ready.subtitleOutputSection` before `L.Ready.subtitleSourceSection`; Windows `MainWindow.xaml` has the same section split; macOS and Windows surface tests assert output precedes source. | Complete |
| Hide or de-emphasize source controls when subtitle output is off | `SubtitleIntent.needsSubtitleSource`; macOS Ready state/source section boundary tests; Windows `WindowsReadyPagePutsSubtitleOutputBeforeSourceAndHidesSourceWhenOff`. | Complete |
| Keep default mode simple and put fixed sources/import behind advanced controls | macOS `subtitleSourcePolicyLabel` and advanced source rows; Windows policy picker; advanced policies include `autoBest`, fixed platform/local, compare local, cloud, and imported file. | Complete |
| Add three intent layers without deleting legacy compatibility | Swift and Windows now both carry `SubtitleIntent`, `SourceLanguageIntent`, and `SubtitleSourcePolicy`; ViewModel request-boundary tests keep `ChineseSubtitleMode`/primary track compatibility. | Complete |
| Add candidate scorer/resolver across manual/platform/local/cloud/imported | Swift and Windows both have `SubtitleQualityScorer`, `SubtitleSourceResolver`, `SubtitleSourceCandidate`, resolver tests covering source ranking and low-confidence outcomes. | Complete |
| Score quality with coverage, cue count, density, language/script mismatch, repetition, sound effects, long cues, bad scalars, romanized loops, hallucination-like phrases | `SubtitleQualityScorer` wraps `PlatformSubtitleQualityGate` metrics and adds Koopenchan hallucination/fragment reasons; `SubtitleSourceResolverTests` covers the bad fixtures. | Complete |
| Generate local ASR only when needed by default, but support precise compare mode | Swift `QueueManager` default fallback plus explicit `compareLocalASR`; Windows `Queue.cs` now also scores platform auto and local ASR through `SubtitleSourceResolver`, including `CompareLocalAsrPolicyChoosesHigherScoredLocalAsrEvenWhenPlatformUsable`. | Complete |
| Wire whisper.cpp VAD only when Silero model exists, with graceful missing-model status | Swift and Windows `WhisperCppVADModelLocator`; ASR command-plan tests; macOS/Windows Settings VAD readiness copy. | Complete |
| Inject title/channel/characters/glossary into ASR prompt | Swift and Windows `ASRPromptBuilder` metadata support; Swift `testASRPromptBuilderAddsContextualMetadataAndKoopenchanGlossary`; Windows `DefaultLocalAsrPromptInjectsMetadataGlossaryAndCharacters`; Cloud ASR prompt request test. | Complete |
| Add a precise local sidecar path for faster-whisper/SenseVoice/FunASR/alignment wrappers | Swift and Windows `SidecarLocalASRSubtitleGenerator` run a user-configured local process that writes `.local-asr.<lang>.srt`; Settings store runtime/model paths and readiness; factories prefer the sidecar only when explicitly enabled and configured. The local whisper.cpp + Silero VAD smoke passed with a real Koopenchan clip. | Complete locally; faster-whisper/SenseVoice/FunASR/WhisperX engine smoke remains external because those runtimes are not installed |
| Let users import SRT/VTT and use it as a real source | macOS import panel and request metadata; Windows import file flow; queue tests copy and select imported subtitles. | Complete |
| Show final source, quality verdict, fallback reason, and candidate reports after processing | `ResolvedSubtitleSource` includes `sourceQualityVerdict` and reports; `QueueItemView`/Windows row view model expose selected source, five-level verdicts, and candidates; boundary tests cover queue disclosure. | Complete |
| Add opt-in cloud precise recognition with upload/cost consent and direct-SRT guardrails | Swift `OpenAICloudASRClient`/factory/settings; Windows `OpenAICloudAsrSubtitleGenerator`/factory/settings; queue policy integration; `whisper-1` direct SRT works directly. JSON-only models such as `gpt-4o-transcribe` require local recognition as a timing guide, then Swift/Windows align JSON transcript text onto that guide SRT. `tools/cloud_asr_smoke` exposes the same explicit manual JSON+guide path. | Complete locally; real paid cloud smoke remains external |
| Replace confusing source-language/source explanation copy | macOS and Windows resources now use `Original audio language` / `识别原声语言` and the "Moongate chooses the most reliable subtitle source" explanation; localization tests assert this. | Complete |
| Reject translated SRT output that still contains too much source-language text | Swift `TranslationOutputQualityGate` and Windows `TranslationOutputQualityGate` run before final write; Swift and Windows tests cover source-language leakage. | Complete |
| Add Koopenchan fixture tests including short fragments, hallucination phrases, source-language leakage, platform sound-effect fallback, all-bad low confidence, and pun/wordplay strategy | Swift and Windows `SubtitleSourceResolverTests`, `TranslationSettingsTests`, `ConfiguredTranslatorFallbackTests`, `AsrContractsTests`, and `TranslatorTests` cover these names/fixtures. | Complete |

## Handbook File Completion Audit

| Handbook file | Recommended points | Current evidence | Status |
| --- | --- | --- | --- |
| `README.md` | Follow the sequence: Ready UI, intent/policy models, scorer/resolver, VAD, precise ASR/cloud ASR. | This plan records those phases; Swift and Windows include output-first Ready UI, `SubtitleIntent`/`SourceLanguageIntent`/`SubtitleSourcePolicy`, scorer/resolver, VAD wiring, local sidecar, and Cloud ASR. | Complete locally |
| `01-ux-audit.md` | Separate subtitle output from source, hide source controls when no subtitles, default to auto-best, keep fixed source/imported file in Advanced, disclose final source. | macOS `ContentView.readyState` renders output before source and `autoBestSubtitleSource`; Windows XAML now shows `SubtitleSourcePolicyAutoBest` as the default visible source row; queue rows show selected source, quality, fallback, and candidates. | Complete |
| `02-subtitle-source-architecture.md` | Add three-layer intent model; compare manual/platform/local/imported/cloud candidates after download; keep default local/private; add VAD, prompt glossary, precise sidecar, cloud paid option. | Swift/Windows models and requests carry intent/language/source policy; `SubtitleSourceResolver` and `SubtitleQualityScorer` exist on both platforms; queue integrates default fallback, compare-local mode, imported files, local sidecar, and Cloud ASR with consent. | Complete locally; third-party sidecar quality benchmarks remain external |
| `03-codex-implementation-plan.md` | Implement phases 1-5, keep compatibility with `ChineseSubtitleMode`/`primarySubtitleTrackID`, localize copy, test complex decisions, keep Windows build. | Compatibility state remains; localized resources cover Ready, queue, Settings, VAD, sidecar, and Cloud ASR; full Swift tests, Windows Core tests, Windows App build, and Windows VM validation pass. | Complete |
| `04-swift-reference-snippets.md` | Provide Core models, scorer, resolver, and SwiftUI output/source structure. | Swift implementation matches the reference shape in `SubtitleSourcePolicy.swift`, `SubtitleQualityScorer.swift`, `SubtitleSourceResolver.swift`, and `ContentView.swift`, with tests in `SubtitleSourceResolverTests` and macOS boundary tests. Windows parity is implemented in C#. | Complete |
| `05-test-fixtures-koopenchan.md` | Add tests for short-cue fragmentation, hallucination phrases, source-language leakage, sound-effect fallback, all-bad low confidence, glossary, and pun/wordplay strategy. | Swift tests include the recommended names and fixtures; Windows tests cover equivalent resolver, leakage, ASR prompt glossary, and translator prompt behavior. | Complete |

## Remaining Gap Audit

- **No remaining local code-facing handbook gap is known after the 2026-06-28 re-audit, copy fix, sidecar adapter slice, and Cloud transcript alignment core.** The remaining items below are external validation, model-quality proof, or product exposure decisions.
- **Real cloud ASR smoke test is still external.** macOS and Windows now have explicit Cloud ASR policy/queue integration, fake-transport tests, and a manual upload/cost-gated smoke script, but no real `/v1/audio/transcriptions` call was run because this plan must not consume credentials or paid quota without explicit confirmation.
- **Real local whisper.cpp + Silero VAD smoke is now verified.** The remaining precise-local gap is narrower: faster-whisper, SenseVoice/FunASR, and WhisperX sidecar engines are not installed on this machine, so those specific wrappers were not benchmarked.
- **Windows VM test/build validation is now verified.** The VM has `Microsoft.WindowsDesktop.App 10.0.9`, Core tests pass, WPF app build passes, App smoke tests pass, and the app launches to a nonblank main window screenshot. Ready-page structure is covered by XAML/ViewModel boundary tests; a human click-through with real URLs remains optional release QA.
- **Higher-quality cloud text models still need paid validation before being promoted as reliable.** `whisper-1` is the first direct SRT/VTT backend. JSON-only models such as `gpt-4o-transcribe` now have explicit local-guide readiness/factory/smoke-script gating, user copy, and queue generation through JSON-text-to-guide-SRT alignment, but Moongate still needs a real paid smoke before claiming model quality.

## Final Validation Checklist

- [x] Core scorer/resolver tests pass.
- [x] macOS Ready page boundary tests pass.
- [x] VAD command-plan and Settings boundary tests pass.
- [x] Queue source disclosure and ViewModel request-boundary tests pass.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch` passes after final prompt/wordplay changes: 619 tests, 0 failures.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore` passes after final prompt/wordplay changes: 708 tests, 0 failures.
- [ ] Windows App tests on a real WindowsDesktop runtime remain a manual follow-up; macOS lacks `Microsoft.WindowsDesktop.App 10.0.0`.
- [x] Windows Ready page static parity check passes: subtitle output precedes source, source controls are hidden while output is off, and output options are no longer disabled by source selection.
- [x] `dotnet build windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore` passes after Windows Ready-page parity changes.
- [x] `dotnet build windows/MoongateApp/MoongateApp.csproj --no-restore` passes after Windows Ready-page parity changes.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter SubtitleSourceResolverTests` passes after adding dormant `cloudASR`.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter TranslationSettingsTests/testSubtitleTrackIDsDistinguishSameLanguageSources` passes after adding `cloudASR` stable IDs.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter SubtitleSourceResolverTests/testResolverReportsLowConfidenceWhenAllCandidatesAreBad` passes.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter MacOSViewModelBoundaryTests/testReadySubtitleIntentCompatibilityLayerDoesNotReplaceRequestContract` passes after adding `compareLocalASR`.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter MacOSQueueBoundaryTests/testQueueManagerWiresPostDownloadQualityGateFallback` passes after adding `compareLocalASR`.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter LocalizerTests/testQueueStringsAreLocalized` passes after adding low-confidence and compare-mode copy.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter CloudASRTests` passes: 3 tests, 0 failures.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-build --filter FullyQualifiedName~SubtitleTrackIdsDistinguishSameLanguageSources` passes with unsandboxed local socket access after adding Windows `CloudAsr`.
- [x] Re-run `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter FullyQualifiedName~WindowsReadyPagePutsSubtitleOutputBeforeSourceAndHidesSourceWhenOff` with unsandboxed local socket access.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter "FullyQualifiedName~WindowsReadyPageExposesImportedSubtitleFileFlow|FullyQualifiedName~ImportedSubtitleFileIsCopiedAndUsedAsSource|FullyQualifiedName~WindowsReadyPageExposesAdvancedSubtitleSourcePolicy|FullyQualifiedName~WindowsQueueRowsExposeResolvedSubtitleSourceDetails|FullyQualifiedName~CompareLocalAsrPolicyGeneratesLocalAsrEvenWhenAutoCaptionIsUsable"` passes: 5 tests, 0 failures.
- [x] `dotnet build windows/MoongateApp/MoongateApp.csproj --no-restore` passes after Windows imported subtitle UI changes.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore` passes: 704 tests, 0 failures.
- [x] `git diff --check` passes.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter "TranslationSettingsTests/testCloudASRSettingsDefaultOffRequireConsentAndRoundTrip|MacOSSettingsBoundaryTests/testSettingsViewUsesSplitNavigationHubWithLocalASRAndNotifications|LocalizerTests/testSettingsSecondarySectionsAreLocalized"` passes after Cloud ASR settings.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter "FullyQualifiedName~CloudAsrSettings_DefaultOffRequireConsentAndUseCredentialStore|FullyQualifiedName~WindowsSettingsExposePrivacySafeCloudAsrConfiguration"` passes: 2 tests, 0 failures.
- [x] `dotnet build windows/MoongateApp/MoongateApp.csproj --no-restore` passes after Windows Cloud ASR settings UI changes.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore` passes after Windows Cloud ASR settings: 706 tests, 0 failures.
- [x] `git diff --check` passes after Windows Cloud ASR settings.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter "FullyQualifiedName~CloudAsrPolicyGeneratesCloudSubtitleAndUsesItAsSource|FullyQualifiedName~CloudAsrGeneratorFactoryRequiresExplicitConfiguration|FullyQualifiedName~WindowsReadyPageExposesAdvancedSubtitleSourcePolicy"` passes after Windows Cloud ASR queue wiring: 3 tests, 0 failures.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter SubtitleSourceResolverTests` passes after Koopenchan test tightening: 11 tests, 0 failures.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore` passes after Windows Cloud ASR queue wiring: 708 tests, 0 failures.
- [x] `dotnet build windows/MoongateApp/MoongateApp.csproj --no-restore` passes after Windows Cloud ASR queue wiring.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter "CloudASRTests|SubtitleSourceResolverTests|LocalizerTests/testQueueStringsAreLocalized|MacOSViewModelBoundaryTests/testReadySubtitleIntentCompatibilityLayerDoesNotReplaceRequestContract|MacOSContentBoundaryTests|MacOSQueueBoundaryTests/testQueueManagerWiresPostDownloadQualityGateFallback"` passes: 36 tests, 0 failures.
- [x] `git diff --check` passes after the final handbook-gap pass.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter "TranslationSettingsTests/testSystemPromptSourceLanguageAndJapaneseExamplesGating|TranslationSettingsTests/testSmartTranslationAdviceParsesLyricsAndChangesPrompt"` passes after adding Japanese pun/wordplay prompt guidance: 2 tests, 0 failures.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter "FullyQualifiedName~SystemPrompt_JapaneseSourceNamesLanguageAndAddsReorderExamples|FullyQualifiedName~SystemPrompt_NonJapaneseSourceOmitsJapaneseFewShot"` passes after adding Windows prompt parity: 2 tests, 0 failures.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter "TranslationSettingsTests|ConfiguredTranslatorFallbackTests|SubtitleSourceResolverTests|CloudASRTests|ASRContractsTests/testASRPromptBuilderAddsContextualMetadataAndKoopenchanGlossary"` passes: 192 tests, 0 failures.
- [x] `dotnet build windows/MoongateApp/MoongateApp.csproj --no-restore` passes after final prompt/wordplay changes.
- [x] `swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch --filter LocalizerTests/testReadyPageFormatAndSubtitleStringsAreLocalized` passes after replacing old Ready-page source explanation copy: 1 test, 0 failures.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter FullyQualifiedName~WindowsReadyPagePutsSubtitleOutputBeforeSourceAndHidesSourceWhenOff` passes after replacing old Windows Ready-page source explanation copy: 1 test, 0 failures.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter FullyQualifiedName~CompareLocalAsrPolicyChoosesHigherScoredLocalAsrEvenWhenPlatformUsable` passes after Windows resolver-backed compare mode: 1 test, 0 failures.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter FullyQualifiedName~SubtitleSourceResolverTests` passes after adding Windows scorer/resolver parity: 2 tests, 0 failures.
- [x] `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter "FullyQualifiedName~CompareLocalAsrPolicyChoosesHigherScoredLocalAsrEvenWhenPlatformUsable|FullyQualifiedName~DefaultLocalAsrPromptInjectsMetadataGlossaryAndCharacters|FullyQualifiedName~Translate_RejectsSourceLanguageLeakageBeforeWritingOutput|FullyQualifiedName~WindowsReadyPagePutsSubtitleOutputBeforeSourceAndHidesSourceWhenOff|FullyQualifiedName~WindowsQueueRowsExposeResolvedSubtitleSourceDetails"` passes after the final Windows parity slice: 5 tests, 0 failures.
- [x] Current final Swift validation: `env CLANG_MODULE_CACHE_PATH=/private/tmp/moongate-cloud-asr-module-cache swift test --disable-sandbox --scratch-path /private/tmp/moongate-subtitle-source-tests-scratch` passes: 624 tests, 0 failures.
- [x] Current final Windows Core validation: `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore` passes with unsandboxed local test socket access: 718 tests, 0 failures.
- [x] Current final Windows App validation: `dotnet build windows/MoongateApp/MoongateApp.csproj --no-restore` passes after the Windows auto-best source row update: 0 warnings, 0 errors.
- [x] Current final patch hygiene: `git diff --check` passes.
- [x] Current final old-copy scan: `rg` finds the old source-selection copy only in this ExecPlan note and negative assertions, not in user-facing resources.
- [x] Local precise sidecar focused Swift validation: `swift test --filter "ASRContractsTests/testSidecarLocalASRSubtitleGeneratorRunsLocalProcessAndWritesSourceSRT|ASRContractsTests/testLocalASRGeneratorFactoryUsesPreciseSidecarWhenEnabled|TranslationSettingsTests/testLocalASRSettingsDefaultOffAndRoundTripThroughJSON|MacOSSettingsBoundaryTests/testSettingsViewUsesSplitNavigationHubWithLocalASRAndNotifications"` passes: 4 tests, 0 failures.
- [x] Local precise sidecar focused Windows validation: `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter "FullyQualifiedName~SidecarLocalAsrSubtitleGeneratorRunsLocalProcessAndWritesSourceSrt|FullyQualifiedName~LocalAsrGeneratorFactoryUsesPreciseSidecarWhenEnabled|FullyQualifiedName~LocalAsrSettings_DefaultOffAndRoundTripThroughJson|FullyQualifiedName~WindowsSettingsExposeLocalSpeechModelCatalogWithExplicitDownloadAction"` passes: 4 tests, 0 failures.
- [x] Windows App build passes after local precise sidecar Settings UI changes.
- [x] `zsh -n tools/local_asr_smoke/run-local-asr-smoke.sh` passes after adding VAD/no-GPU smoke options.
- [x] Real local ASR smoke passes on `/private/tmp/moongate-koopen-20s.wav`: `MOONGATE_ASR_QA_RUN=1 MOONGATE_ASR_QA_WHISPER_CLI=/opt/homebrew/bin/whisper-cli MOONGATE_ASR_QA_MODEL=.../ggml-large-v3-turbo-q5_0.bin MOONGATE_ASR_QA_VAD_MODEL=.../ggml-silero-v5.1.2.bin MOONGATE_ASR_QA_LANGUAGE=ja zsh tools/local_asr_smoke/run-local-asr-smoke.sh`; output SRT `/private/tmp/moongate-local-asr-real-smoke/moongate-koopen-20s.local-asr.ja.srt` is non-empty.
- [x] `zsh -n tools/cloud_asr_smoke/run-cloud-asr-smoke.sh` passes.
- [x] `zsh tools/cloud_asr_smoke/run-cloud-asr-smoke.sh` exits at the upload/cost gate with status 66.
- [x] `MOONGATE_CLOUD_ASR_QA_RUN=I_UNDERSTAND_THIS_UPLOADS_AUDIO_AND_MAY_COST_MONEY MOONGATE_CLOUD_ASR_API_KEY=sk-test MOONGATE_CLOUD_ASR_AUDIO=/private/tmp/moongate-koopen-20s.wav MOONGATE_CLOUD_ASR_MODEL=gpt-4o-transcribe zsh tools/cloud_asr_smoke/run-cloud-asr-smoke.sh` rejects JSON-only models before any network request.
- [x] Parallels `Windows 11` VM has .NET SDK 10.0.301 and `Microsoft.WindowsDesktop.App 10.0.9`.
- [x] Windows VM Core full validation from an NTFS temp checkout passes: `dotnet test windows\MoongateCore.Tests\MoongateCore.Tests.csproj -v minimal` -> 715 passed, 0 failed.
- [x] Windows VM WPF build passes: `dotnet build windows\MoongateApp\MoongateApp.csproj -v minimal` -> 0 warnings, 0 errors.
- [x] Windows VM App smoke tests pass: `dotnet test windows\MoongateApp.Tests\MoongateApp.Tests.csproj -v minimal` -> 2 passed, 0 failed.
- [x] Current Windows VM Core validation from a fresh NTFS temp checkout passes after the Windows auto-best source row update: `dotnet test windows\MoongateCore.Tests\MoongateCore.Tests.csproj -v minimal` -> 718 passed, 0 failed.
- [x] Current Windows VM WPF build passes after shutting down a stale locked build server: `dotnet build windows\MoongateApp\MoongateApp.csproj -v minimal` -> 0 warnings, 0 errors.
- [x] Current Windows VM App smoke tests pass: `dotnet test windows\MoongateApp.Tests\MoongateApp.Tests.csproj -v minimal` -> 2 passed, 0 failed.
- [x] Windows VM visual launch smoke captured `/private/tmp/moongate-vm-ready-ui.png`; the app opens to a nonblank main window.
- [x] JSON-only cloud model readiness guard focused Swift validation: `swift test --filter "CloudASRTests|TranslationSettingsTests/testCloudASRSettingsDefaultOffRequireConsentAndRoundTrip|LocalizerTests/testSettingsSecondarySectionsAreLocalized|MacOSSettingsBoundaryTests/testSettingsViewUsesSplitNavigationHubWithLocalASRAndNotifications"` passes: 9 tests, 0 failures.
- [x] JSON-only cloud model readiness guard focused Windows validation: `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter "FullyQualifiedName~CloudAsrSettings_DefaultOffRequireConsentAndUseCredentialStore|FullyQualifiedName~CloudAsrGeneratorFactoryRequiresExplicitConfiguration|FullyQualifiedName~WindowsSettingsExposePrivacySafeCloudAsrConfiguration"` passes: 3 tests, 0 failures.
- [x] Cloud transcript alignment focused Swift validation: `swift test --filter CloudASRTests` passes: 8 tests, 0 failures.
- [x] Cloud transcript alignment focused Windows validation: `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter FullyQualifiedName~CloudAsrTests` passes: 2 tests, 0 failures.
- [x] Cloud ASR smoke script syntax and local gates pass after JSON+guide support: `zsh -n tools/cloud_asr_smoke/run-cloud-asr-smoke.sh`, no-gate status 66, and JSON-only model without guide status 2.
