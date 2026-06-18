# 接入 ResegmentForReadability 到翻译主流程（双端）

## 背景与产品意图
ASR 自动字幕（YouTube 等）是逐字、无标点、碎句的，翻译质量差、读起来割裂。
`ResegmentForReadabilityAsync` 把整段转写发给 LLM 断句、严格 token 对齐回原序列、
按 cue 内时间插值重建整句字幕。目前 Windows 已实现该方法但**未接入**主流程；macOS 端**完全没有**该方法。

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

### C. 测试
- macOS：给 `ConfiguredTranslator` 注入假 modelSender，验证
  (1) resegment 算法核心用例（对齐、插值、合并、对齐失败回退）——复刻 Windows 的 9 条；
  (2) 接入：smart 开 + ASR 字幕 → 触发重分段；smart 关 → 不触发；正常字幕 → 不触发。
- Windows：新增接入测试 `Translate_AsrCaption_WhenSmartEnabled_Resegments` /
  `Translate_NormalSubtitle_DoesNotResegment` / `Translate_SmartDisabled_SkipsResegment`。

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
