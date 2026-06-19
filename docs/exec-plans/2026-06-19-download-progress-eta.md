# 下载进度与整体倒计时修复

## 背景与产品意图
下载队列之前把下载、转码、翻译、烧录的阶段百分比都写进同一个 `progress` 字段。
这会让进度条在阶段切换时回退，也让 macOS 折叠队列的整体圆环只是“当前阶段百分比平均值”，
不是整条任务真实进度。yt-dlp 已经提供下载速度和 ETA，但队列项没有保存这些信息，UI 也没有展示。

目标是让用户看到更可信的进度：
- 单行进度条表示整条任务整体进度，跨阶段保持单调。
- 状态文案仍显示当前阶段百分比，并追加速度 / 剩余时间。
- 队列摘要显示 best-effort 整体剩余时间；没有可靠信号时显示“正在估算…”，不伪造精确倒计时。

## 当前仓库理解
- macOS 下载队列在 `Sources/Moongate/QueueManager.swift`，行 UI 在 `QueueItemView.swift`，折叠摘要在 `QueueOverlayView.swift`。
- Windows 队列核心在 `windows/MoongateCore/Queue.cs`，WPF 行展示在 `windows/MoongateApp/QueueItemViewModel.cs`，摘要栏在 `MainViewModel.cs`。
- 双端下载引擎都会解析 yt-dlp 的 `%(progress._percent_str)s`、speed 和 ETA；此前 Swift engine 额外做了 high-water，Windows 则保留 raw percent。

## 方案
- 在 Core 增加双端同构的 `QueueProgressPlan`、`TaskProgressSnapshot`、`QueueProgressSnapshot`、`QueueProgressEstimator`。
- 保留现有阶段字段：Swift `QueueItem.progress` / Windows `QueueItem.Progress` 仍表示当前阶段百分比。
- 新增 `overallProgress` / `OverallProgress` 给进度条使用；用 estimator 做阶段权重映射和单调保护。
- 新增 speed、remaining、estimating 字段；下载阶段优先使用 yt-dlp ETA，转码 / 翻译 / 烧录用 elapsed/progress slope 估算。
- Swift `YtDlpEngine.DownloadProgressTracker` 改为 raw percent，整体单调只在队列层处理。

## 非目标
- 不改设置 UI。
- 不改下载、翻译、烧录输出格式。
- 不改移动端 `MobileTaskProgress`。
- 不发 release、不改 API 凭证或外部服务配置。

## 风险与回滚
- 阶段权重目前按任务计划阶段等权切分，优先保证单调和可解释；真实耗时权重后续可用更多样本继续校准。
- 队列整体 ETA 是 best-effort：未知大块会显示“正在估算…”，不会给不可靠的精确时间。
- 回滚可删除新增 estimator 字段并把 UI 绑定恢复到阶段 progress；该改动不影响文件输出。

## 决策记录
- 2026-06-19：采用“当前阶段百分比用于文案，整体进度用于进度条”的双轨模型。
- 2026-06-19：Swift 下载进度源改为 raw percent，与 Windows 保持一致；多流下载回落由状态文案反映，整体进度由队列层单调保护。
- 2026-06-19：倒计时文案使用“剩 / 剩约 / 正在估算…”，避免没有依据时显示过度精确值。
- 2026-06-19：失败 / 取消项在整体进度中算作无剩余工作，但终态摘要只在全部成功时显示“全部完成”；混有失败或取消时显示“全部已结束”。
- 2026-06-19：队列整体 ETA 使用本会话已完成阶段的滚动中位数和当前并发槽位估算；缺阶段样本时显示“正在估算…”，不只拿正在下载的当前 ETA 冒充整队剩余。

## 验证记录
- 2026-06-19 已通过：
  - `swift test --scratch-path /tmp/moongate-progress-eta --filter 'EngineProgressTests|QueueProgressTests|MacOSQueueBoundaryTests|LocalizerTests' --disable-sandbox`，29 tests passed。
  - `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter "FullyQualifiedName~QueueTests|FullyQualifiedName~EngineParsingTests|FullyQualifiedName~WindowsCoreI18nTests" --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`，7 tests passed。该过滤器未覆盖实际队列类 `QueueManagerTests`，因此保留下一条修正过滤器验证。
  - `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter "FullyQualifiedName~QueueManagerTests|FullyQualifiedName~EngineParsingTests|FullyQualifiedName~WindowsCoreI18nTests" --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`，39 tests passed。
  - `dotnet build windows/Moongate.Win.sln --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`，0 warnings, 0 errors。
  - `git diff --check`
- 2026-06-19 早期开发验证：
  - `swift test --scratch-path /tmp/moongate-progress-eta-swift-ui --filter 'EngineProgressTests|QueueProgressTests|MacOSQueueBoundaryTests|LocalizerTests' --disable-sandbox`
  - `dotnet test windows/MoongateCore.Tests/MoongateCore.Tests.csproj --filter "FullyQualifiedName~QueueManagerTests|FullyQualifiedName~EngineParsingTests|FullyQualifiedName~WindowsCoreI18nTests" --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`
  - `dotnet build windows/Moongate.Win.sln --nologo -v quiet -m:1 -nr:false /p:UseSharedCompilation=false`

## 最终验证 Checklist
- [x] 用户指定的 Swift 验证命令通过。
- [x] 用户指定的 Windows 验证命令通过；`QueueTests` filter 未匹配实际队列类名，已额外跑 `QueueManagerTests` filter。
- [x] `git diff --check` 通过。
