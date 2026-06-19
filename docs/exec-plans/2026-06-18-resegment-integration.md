# 接入 ResegmentForReadability 到翻译主流程（双端）

## 背景与产品意图
ASR 自动字幕（YouTube 等）是逐字、无标点、碎句的，翻译质量差、读起来割裂。
`ResegmentForReadabilityAsync` 把整段转写发给 LLM 断句、严格 token 对齐回原序列、
按 cue 内时间插值重建整句字幕。目前 Windows 已实现该方法但**未接入**主流程；macOS 端**完全没有**该方法。

2026-06-19 追加发现：YouTube 两行滚动窗口即使清洗成功，也会因为“延续词保护”把自然语速英文合成 10s+
长 cue。用户样本 `/Downloads/I speak English at native speed/...en.srt` 的旧输出为 64 条，平均 8.03s，
48 条超过 6s，16 条超过 10s；这会造成画面已经变化但字幕还停留几秒的体感延迟。

## 决策（已与用户确认）
- **触发方式**：跟随现有「智能翻译提示词」开关（`SmartTranslationPromptsEnabled` / `smartTranslationPromptsEnabled`）。开关开 + 判定为 ASR 字幕时才重分段。不新增 UI。
- **平台范围**：两端都接入，保持翻译行为一致。

## ASR 判定（启发式）
只对真正像 ASR 的字幕重分段，避免对正常字幕烧 token / 破坏已有断句：
- cue 数 ≥ 8（太少没必要）
- 带句末标点（. ! ? 。！？，跳过尾部引号括号）的 cue 比例 < 0.15
满足两者才判定为 ASR。`ResegmentForReadabilityAsync` 内部还有 token 对齐失败回退，是第二道安全网。

## 接入点
两端翻译主流程都是：`parse → cleanCues → (源语言) → makeAdvice → 分块翻译`。
在 `cleanCues` 之后、`makeAdvice` 之前插入：
```
if settings.smart... && looksLikeASR(cues) { cues = await resegment(cues) }
```
重分段在 advice 之前，使后续摘要/分块基于整句。

## 工作项

### A. macOS 端实现 resegmentForReadability（新）
复刻 Windows 算法到 `Sources/MoongateCore/Translator.swift`，适配 macOS：
- 用实例 `sendModelMessage`（带瞬时重试 + modelSender 注入），签名带 `context`。
- 复用 `Self.flattened`、`Self.parseReply`、`srtTimeToSeconds`、`secondsToSRTTime`。
- 同样的：token 归一/对齐、FlatToken、cue 内时间插值、分块（25 cue）、
  输出上限减半重试、长段按时长(6s)拆分、短段合并、对齐失败回退原 cues。
- 私有 `looksLikeAutoCaption(_ cues:)` 启发式。

### B. 两端接入主流程
- macOS `translate(...)`：cleanCues 后插入条件 resegment。
- Windows `TranslateAsync(...)`：CleanCues 后插入条件 resegment（用已实现的 `ResegmentForReadabilityAsync`）。
- Windows 同样加 `LooksLikeAutoCaption` 启发式（与 macOS 同构）。
- 清洗阶段增加确定性可读窗口兜底：`6s` 只作为软目标，`9s` 为正常窗口，`12s` 为应急窗口。
  分段优先句末标点，其次逗号/分号/冒号/破折号后的完整意群，最后才使用词边界；避免切在
  `a/an/the/to/of/and/or/but/that/which/what/is/are/in` 等弱尾词或从明显依赖词开始。
  时间按文本权重分配；两行滚动字幕超过正常窗口时先按语速估算有效可见时长，1-3 个英文短反馈最多 2s，
  避免 `C / op / y.`、`Copy.` 停 12s 或源字幕拖尾几十秒。

### C. 测试
- macOS：给 `ConfiguredTranslator` 注入假 modelSender，验证
  (1) resegment 算法核心用例（对齐、插值、合并、对齐失败回退）——复刻 Windows 的 9 条；
  (2) 接入：smart 开 + ASR 字幕 → 触发重分段；smart 关 → 不触发；正常字幕 → 不触发。
- Windows：新增接入测试 `Translate_AsrCaption_WhenSmartEnabled_Resegments` /
  `Translate_NormalSubtitle_DoesNotResegment` / `Translate_SmartDisabled_SkipsResegment`。
- 双端清洗测试补充 Style B 长滚动字幕与 Starship 结构片段：要求文本不丢、时间单调、
  没有弱语义边界，常规 cue 不超过应急窗口；短异常 cue 不拆成字符碎片。
- Windows 补齐 `MultilineAsrCues()`，修复此前 C# 测试引用 helper 但未定义导致的编译失败。

### D. 验证
- macOS：`swift test`（全量）
- Windows：`dotnet test`（全量）+ `dotnet build Moongate.Win.sln`

## 风险 / 回退
- 误判正常字幕为 ASR → token 对齐通常仍成功并「重分段」，可能改变已有断句。
  用严格阈值（标点比例 <0.15）降低误判；对齐失败回退是兜底。
- 额外 LLM 成本：仅在 smart 开 + ASR 判定时发生，可接受。
- 判定阈值是经验值，先用 0.15 / 8 条，测试覆盖边界。

## 决策日志
- 2026-06-18：触发跟随 smart 开关、两端接入（用户确认）。
- ASR 判定用「标点比例 + cue 数」启发式，无需下载层 IsAuto 标记（TranslateAsync 只有文件路径）。
- 2026-06-19：保留语义连续合并，但最终可见字幕窗口加 6s 级确定性拆分兜底；样本清洗结果为 425 条源字幕
  → 123 条清洗字幕，平均 4.18s，p90 5.12s，最大 5.99s，超过 6.2s / 10s 均为 0。
- 2026-06-19 验证命令：
  - `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter "FullyQualifiedName~CleanCuesTests|FullyQualifiedName~SrtParsingTests|FullyQualifiedName~ConfiguredTranslatorTests" --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`
  - `swift test --scratch-path /tmp/moongate-swift-build --filter 'TranslationSettingsTests|ConfiguredTranslatorFallbackTests' --disable-sandbox`
  - `/tmp/moongate-swift-build/arm64-apple-macosx/debug/moongate-cli clean-srt /tmp/moongate-native-speed.en.srt`
- 2026-06-19：回退上一轮 `ceil(duration / 6)` 硬切。Starship 样本确认硬切会把完整意群切成
  `this is an`、`The ship is what` 一类残句；最终改为语义优先 planner，并把标点孤岛清理限定在滚动清洗结果，
  避免普通字幕翻译行号被合并。
- 2026-06-19 Starship 样本 `~/Downloads/Starship - Test Like You Fly/Starship - Test Like You Fly [ANe_HW4X8oc].en.srt`：
  845 条源字幕 → 230 条清洗字幕，平均 5.66s，p90 8.47s，最大 12.00s，超过 12.2s 为 0；
  明确残句 `this is an` / `The ship is what` / `take the people or` 为 0，单独标点 cue 为 0。
- 2026-06-19 最终验证命令：
  - `swift test --scratch-path /tmp/moongate-readable-split --filter 'TranslationSettingsTests|ConfiguredTranslatorFallbackTests' --disable-sandbox`
  - `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter "FullyQualifiedName~CleanCuesTests|FullyQualifiedName~ConfiguredTranslatorTests" --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`
  - `swift run --scratch-path /tmp/moongate-readable-split moongate-cli clean-srt ~/Downloads/Starship\ -\ Test\ Like\ You\ Fly/Starship\ -\ Test\ Like\ You\ Fly\ \[ANe_HW4X8oc\].en.srt`
- 2026-06-19：针对用户反馈“字幕出现/消失时机不自然”，增加 speech-aligned timing。短反馈如 `Copy.` / `What heat?`
  从 12s 改为 2s；两行滚动字幕先裁掉异常源拖尾，再语义拆分；普通重叠碎句不套用该裁剪，避免字幕过早消失。
- 2026-06-19 speech-aligned Starship 样本：
  845 条源字幕 → 271 条清洗字幕，平均 3.48s，p90 6.00s，最大 8.87s；
  1-3 词非倒计时短句超过 2s 为 0，普通非倒计时 cue 超过 9s 为 0，明确残句和独立标点 cue 均为 0。
- 2026-06-19 speech-aligned 验证命令：
  - `swift test --scratch-path /tmp/moongate-timing-natural --filter 'TranslationSettingsTests|ConfiguredTranslatorFallbackTests' --disable-sandbox`
  - `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter "FullyQualifiedName~CleanCuesTests|FullyQualifiedName~ConfiguredTranslatorTests" --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`
  - `swift run --scratch-path /tmp/moongate-timing-natural moongate-cli clean-srt ~/Downloads/Starship\ -\ Test\ Like\ You\ Fly/Starship\ -\ Test\ Like\ You\ Fly\ \[ANe_HW4X8oc\].en.srt`
- 2026-06-19：针对用户反馈“字幕还没说完就消失”，修正 speech-aligned 副作用。滚动清洗合并时保留 source fragments，
  分段后按 fragment token timeline 定位 start/end；异常拖尾仍在 fragment 层裁剪，但不再把整个 merged cue 按文本权重
  平均摊时间。多句 cue 优先保留完整句子，只有单个长句才进入语义拆分。
- 2026-06-19 source-anchored Starship 样本：
  845 条源字幕 → 284 条清洗字幕，平均 3.40s，p90 6.63s，最大 10.77s，超过 12.2s 为 0；
  `Why 10 engines instead of all 33?` 为 `00:00:48,960 --> 00:00:51,590`，`It'll be the one that puts humans back on the moon.`
  为 `00:05:09,520 --> 00:05:11,670`，`Copy.` / `What heat?` 均保持 2.0s；
  明确残句 `this is an` / `The ship is what` / `take the people or` / `It'll be the one that puts` / `humans back on the moon.` 为 0，
  独立标点 cue 为 0。
- 2026-06-19 source-anchored 验证命令：
  - `swift test --scratch-path /tmp/moongate-source-anchored-timing --filter 'TranslationSettingsTests|ConfiguredTranslatorFallbackTests' --disable-sandbox`
  - `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter "FullyQualifiedName~CleanCuesTests|FullyQualifiedName~ConfiguredTranslatorTests" --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`
  - `swift run --scratch-path /tmp/moongate-source-anchored-timing moongate-cli clean-srt ~/Downloads/Starship\ -\ Test\ Like\ You\ Fly/Starship\ -\ Test\ Like\ You\ Fly\ \[ANe_HW4X8oc\].en.srt`
