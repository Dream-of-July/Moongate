# 月之门字幕来源产品化重构 ExecPlan

## 背景与产品意图

用户不应该理解 `manual`、`auto`、`Whisper` 或质量门阈值，才能完成下载、翻译、压制字幕。月之门需要把“字幕来源”从工程配置改为产品级自动决策：用户选择想要的字幕结果，系统根据视频语言、字幕候选、质量评估和用户显式选择，自动选出最可靠来源，并在 Ready 页和 Queue 中解释“用了什么、为什么、还能怎么改”。

已知反例：

- `QrT4S9i3agE`：yt-dlp `language=en`，存在人工 `en` 字幕和自动 `en/en-orig` 字幕。默认必须使用人工英文字幕，且不得运行本地识别。
- `f32W5BEzWN0`：不能让非原声语言的人工字幕压过英文平台字幕。
- 目标语言字幕，例如中文字幕，不能被自动当成翻译源。

## 设计与产品 Guardrails

本次只改字幕来源决策流，沿用现有视觉系统和组件结构。

引用约束：

- Apple Human Interface Guidelines: [Writing](https://developer.apple.com/design/human-interface-guidelines/writing)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)、[Menus](https://developer.apple.com/design/human-interface-guidelines/menus)、[Disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)。
- Apple-like 落地规则：主流程只保留一个主要决策，复杂选项渐进披露，文案描述用户结果而不是技术机制，标准控件优先，错误状态提供恢复路径。
- Product Design guardrail：不重新发明视觉系统，不扩大到整 App 重绘。
- UI/UX Pro Max guardrail：保留 loading、error、empty states；候选行和按钮要有可访问标签；状态不能只靠颜色表达；小窗口和 Dynamic Type 下文本不能溢出。

## 当前仓库理解

macOS 主要路径：

- `Sources/MoongateCore/Models.swift`：`VideoInfo`、`SubtitleChoice`、`SubtitleSourcePolicy` 等核心模型。
- `Sources/MoongateCore/Engine.swift`：解析 yt-dlp 元数据和字幕列表。
- `Sources/Moongate/ViewModel.swift`：Ready 页语言、字幕输出、入队请求组装。
- `Sources/Moongate/QueueManager.swift`：下载后字幕质量门和本地识别触发。
- `Sources/Moongate/ContentView.swift`、`Sources/Moongate/QueueItemView.swift`：Ready 页和 Queue 展示。
- `Sources/MoongateMobileCore/Localization/*`：中英文和繁中文案。

Windows 主要路径：

- `windows/MoongateCore/Models.cs`、`Engine.cs`、`Queue.cs`：与 Swift 对应的核心模型、解析和队列逻辑。
- `windows/MoongateApp/MainViewModel.cs`、`MainWindow.xaml`、`Strings.*.xaml`：Ready 页和来源展示。
- `windows/MoongateCore.Tests/*`：跨平台决策和 UI surface 边界测试。

## 目标与非目标

目标：

- 新增纯逻辑 `SubtitleSourceDecision` 层，Swift 与 Windows 同构。
- Ready 页合并为一个“字幕”决策区域，高级选项折叠。
- Queue 展示实际来源和原因；候选与质量诊断不进入默认用户界面。
- 默认 Auto 不再因为平台字幕低于 `good` 就运行本地识别。
- `DownloadRequest.subtitleSourcePolicy` 使用当前策略，不在入队时硬编码 `.autoBest`。
- 新规则有 fixture 覆盖，不能只靠手动试。

非目标：

- 不重做整 App 视觉风格。
- 不引入新外部依赖。
- 不改变下载、翻译、压制的 public 行为。
- 不用 LLM 猜测字幕来源。

## 决策模型

所有默认决策必须来自结构化输入：

- 视频元数据：yt-dlp `language` 映射到 `VideoInfo.detectedLanguageCode`。
- 用户显式选择：字幕结果、目标语言、原声语言偏好、来源策略。
- 字幕候选：人工字幕、平台自动字幕、导入字幕、本地识别、云端识别。
- 质量门：平台字幕质量是否 usable、lowConfidence、unusable。

禁止事项：

- 不允许用 LLM 猜字幕来源。
- 不允许因为候选是人工字幕就无条件胜出。
- 不允许在 UI 里写死“将使用”或“原因”，必须来自决策报告。

默认排序：

1. 显式导入字幕优先。
2. 人工字幕语言与视频语言或用户指定原声语言一致时优先。
3. 无同语言人工字幕时，同语言平台自动字幕优先。
4. 人工字幕若是目标语言、翻译字幕、罕见语言或与视频语言冲突，只作为候选，不自动胜出。
5. 无可信平台/人工字幕时，本地识别才作为兜底。
6. 视频语言缺失时，标题脚本只能作为低置信辅助信号。
7. 同时存在 `en` 与 `en-orig` 自动字幕且没有人工字幕时，英文视频优先 `en-orig`。

输出对象：

- `selectedTrack`：实际推荐来源。
- `candidateReports`：每个候选的来源、语言、可用性、使用或不用的原因。
- `asrTrigger`：`never`、`fallbackOnly`、`explicitCompare`、`explicitForce`。
- `userFacingReason`：Ready 页和 Queue 展示的短原因。
- `diagnosticReason`：高级详情使用的结构化原因。

## ASR / Whisper 触发策略

产品默认：本地识别是兜底，不是并行默认流程。

- 人工字幕被选中：`asrTrigger = never`。
- 平台自动字幕为 usable、good、excellent：不运行本地识别。
- 平台自动字幕为 lowConfidence 或 unusable：允许本地识别兜底。
- 无平台/人工字幕：允许本地识别兜底。
- 用户显式选择“使用本地识别”：强制本地识别。
- 用户显式选择“比较平台字幕和本地识别”：才生成本地识别并比较。
- Queue ETA 必须基于真实计划；未触发本地识别时，不计入 ASR 时间。

## UI/UX 方案

Ready 页：

- 保留一个“字幕”区域。
- 主流程只暴露三个用户语义：`自动`、`原字幕`、`AI 增强`。
- `自动` 仍走产品决策树；`原字幕` 映射固定平台字幕；`AI 增强` 映射显式本地识别。
- 原声语言和导入字幕放进“更多选项”，不再把 compare、force、prefer、cloud 等内部策略作为普通用户主流程。
- 主流程文案描述结果，不默认写 “Whisper”；设置和诊断里才写 “Whisper / whisper.cpp”。

Queue：

- 默认只回答“用了什么”和“原因”。
- 不显示孤立“质量：优秀/可用”或候选仲裁表，避免把内部 quality gate 暴露给用户。
- 只有真的运行本地识别时，才显示“本地识别中”。
- 本地识别失败但平台字幕可用时，不阻塞下载，显示已保留平台字幕。

文案规则：

- 不使用孤立质量词，例如只写“优秀”。必须搭配来源和原因。
- 错误状态提供恢复路径，例如“未找到平台字幕，可导入字幕或使用本地识别”。
- 中文文案简洁自然，不暴露不必要工程术语。

## 已实施里程碑

- Swift 新增 `SubtitleSourceDecision` 纯逻辑层。
- Windows 新增同构 `SubtitleSourceDecision` 纯逻辑层。
- `VideoInfo` 扩展 `detectedLanguageCode`，yt-dlp `language` 入模。
- `SubtitleChoice.metadata` 保留 yt-dlp 原始字幕类型、名称、扩展、协议、`orig` 标记。
- Ready 页改为一个“字幕”区域，并通过决策报告展示“将使用”和“原因”。
- Ready 页主流程压缩为 `自动`、`原字幕`、`AI 增强` 三种用户语义；macOS 和 Windows UI 都不再展示内部策略下拉。
- Queue 展示收敛为来源加原因，默认不再展示候选报告或质量词。
- macOS 和 Windows 队列 ASR 触发阈值改为 lowConfidence/unusable。
- macOS batch 入队使用当前 `subtitleSourcePolicy`。
- Windows batch 入队使用当前 `SubtitleSourcePolicy`。
- 中英文和繁中文案覆盖候选状态与结构化原因。

## 预计改动文件

核心：

- `Sources/MoongateCore/SubtitleSourceDecision.swift`
- `Sources/MoongateCore/Models.swift`
- `Sources/MoongateCore/Engine.swift`
- `windows/MoongateCore/SubtitleSourceDecision.cs`
- `windows/MoongateCore/Models.cs`
- `windows/MoongateCore/Engine.cs`

macOS：

- `Sources/Moongate/ViewModel.swift`
- `Sources/Moongate/ContentView.swift`
- `Sources/Moongate/QueueManager.swift`
- `Sources/Moongate/QueueItemView.swift`
- `Sources/MoongateMobileCore/Localization/*`

Windows：

- `windows/MoongateCore/Queue.cs`
- `windows/MoongateApp/MainViewModel.cs`
- `windows/MoongateApp/MainWindow.xaml`
- `windows/MoongateApp/Strings.*.xaml`

测试：

- `Tests/MoongateCoreTests/SubtitleSourceDecisionTests.swift`
- `Tests/MoongateCoreTests/MacOSContentBoundaryTests.swift`
- `Tests/MoongateCoreTests/MacOSViewModelBoundaryTests.swift`
- `Tests/MoongateCoreTests/MacOSQueueBoundaryTests.swift`
- `windows/MoongateCore.Tests/SubtitleSourceDecisionTests.cs`
- `windows/MoongateCore.Tests/WindowsSettingsSurfaceTests.cs`

## 验证计划

Swift：

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/moongate-clang-module-cache swift test --disable-sandbox --filter 'SubtitleSourceDecisionTests|SubtitleLanguageRecommenderTests|SubtitleSourceResolverTests|PlatformSubtitleQualityGateTests|MacOSContentBoundaryTests|MacOSViewModelBoundaryTests|MacOSQueueBoundaryTests|LocalizerTests/testQueueStringsAreLocalized'
```

Windows core：

```bash
dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --no-restore --filter "FullyQualifiedName~SubtitleSourceDecisionTests|FullyQualifiedName~SubtitleLanguageRecommenderTests|FullyQualifiedName~SubtitleSourceResolverTests|FullyQualifiedName~EngineParsingTests|FullyQualifiedName~PlatformSubtitleQualityGateTests|FullyQualifiedName~QueueTests|FullyQualifiedName~WindowsSettingsSurfaceTests"
```

静态回归检查：

```bash
rg -n "platformScore\\.verdict < \\.good|platformScore\\.Verdict < SubtitleQualityVerdict\\.Good|subtitleSourcePolicy: \\.autoBest" Sources Tests windows docs -S
```

2026-06-28 当前验证结果：

- Swift 相关测试：117 passed，0 failed。
- Windows core 全量测试：732 passed，0 failed。
- Windows 测试出现 `NU1900` 漏洞数据联网警告，原因是受限网络无法访问 NuGet vulnerability feed；测试编译和执行均通过。
- 静态回归检查未发现旧的 `< good` ASR 触发阈值或入队硬编码 `.autoBest` 残留。
- 追加回归：强制平台字幕时，即使平台字幕质量门判低质，也不得运行本地识别。Swift `MacOSQueueBoundaryTests` 和 Windows `ForcePlatformLowQualityCaptionDoesNotRunLocalAsr` 均通过。
- 追加 UI/UX 回归：macOS Ready 页三选项、Queue 来源展示、Localizer 三语 key、Windows Ready/Queue surface 均通过目标测试。Swift 77 个相关测试通过；Windows 9 个相关测试通过；`git diff --check` 通过。

手动 QA：

- `QrT4S9i3agE`：Ready 页显示人工英文字幕，下载/翻译过程中不跑本地识别。
- `f32W5BEzWN0`：不把非原声人工字幕当默认来源。
- 无字幕英文视频：提示可用本地识别。
- 平台字幕质量差的视频：允许本地识别兜底，并解释原因。
- 导入字幕：明确显示导入字幕为来源，不被自动策略覆盖。

## 风险、回滚与开放问题

风险：

- 旧的 `SubtitleLanguageRecommender` 仍在部分兼容路径里存在，后续需要继续收窄到只做语言推荐。
- Windows WPF 视觉无法在 macOS 自动完整渲染验证，只能通过资源和 ViewModel surface 测试覆盖。
- 如果 yt-dlp 某些平台缺失 `language` 字段，标题脚本只能作为低置信辅助信号，仍需要 UI 明确“不确定”。

回滚：

- 决策层是纯逻辑新增，可以通过恢复 ViewModel/Queue 调用点回退到旧 recommender/resolver。
- ASR 阈值回滚点集中在 `QueueManager.swift` 和 `Queue.cs`。
- UI 回滚点集中在 Ready 页字幕区域和 Windows XAML 对应块。

开放问题：

- 是否需要把 `SubtitleSourceDecision` fixture 提取成跨 Swift/C# 共用 JSON。
- 是否需要在诊断模式另行展示候选列表；默认用户界面不展示候选列表。
- 是否需要在后续版本把云端识别配置状态接入同一个决策对象。

## 决策记录

- 2026-06-28：选择新增纯逻辑决策层，而不是继续把规则分散在 recommender、resolver、ViewModel 和 Queue。
- 2026-06-28：默认 Auto 不再把本地识别当并行比较流程，只有低置信、不可用、无字幕或用户显式要求时触发。
- 2026-06-28：Ready 页只保留一个字幕主区域，高级诊断折叠，避免把工程配置暴露为主流程。
- 2026-06-28：下载后质量门不得覆盖用户显式平台策略；`forcePlatform`、`preferPlatform`、导入字幕和云端识别策略都不能隐式生成本地识别。
- 2026-06-28：Ready 页主流程收敛为 `自动 / 原字幕 / AI 增强`，Queue 默认隐藏候选报告和质量词；这些信息只应属于诊断，不属于普通用户主流程。

## 最终验证 Checklist

- [x] `QrT4S9i3agE` fixture 默认选择人工 `en`。
- [x] `f32W5BEzWN0` fixture 不让非原声人工字幕胜出。
- [x] 目标语言字幕不被当作翻译源。
- [x] 平台字幕 usable/good/excellent 不运行本地识别。
- [x] 平台字幕 lowConfidence/unusable 允许本地识别兜底。
- [x] 强制平台字幕不会因为质量门低质而运行本地识别。
- [x] 显式 Compare 和 Force Local 保留真实行为。
- [x] Ready 页只有一个字幕决策区域。
- [x] Queue 展示实际来源和原因。
- [x] Swift 与 Windows 测试均通过。
