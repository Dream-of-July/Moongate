# v0.8 macOS 性能与 Whisper 闭环

## 背景与产品意图
用户实测当前 v0.8 普通下载路径比 v0.7.6 慢。v0.8 可以加入本地 Whisper/ASR，但未启用 Whisper 时，下载、翻译、压制的正常路径不应承担明显额外成本。macOS 是主力平台；Windows 设置 UI 深修延后，只保留不破坏核心编译/测试。

## 当前仓库理解
- macOS ready 页与 onboarding 在 `Sources/Moongate/ContentView.swift`。
- macOS 下载请求组装在 `Sources/Moongate/ViewModel.swift`。
- macOS 队列流水线在 `Sources/Moongate/QueueManager.swift`。
- yt-dlp 命令与下载进度解析在 `Sources/MoongateCore/Engine.swift`。
- 本地 ASR 合约与 whisper.cpp 适配在 `Sources/MoongateCore/ASR.swift`。
- 跨版本性能对比优先看 `v0.7.6` tag 与当前工作树的正常路径差异。

## 目标
- 找出 v0.8 普通路径慢于 v0.7.6 的具体候选原因，先用测试或静态 gate 固定。
- 不选 local ASR / Whisper 时，不进入音频抽取、语音识别、字幕分段等 ASR 阶段。
- 普通下载请求尽量保持 v0.7.6 的 yt-dlp 行为与并发行为，只保留必要的 v0.8 功能差异。
- macOS local Whisper/ASR 在下载页、队列重跑、设置模型/运行时入口上形成可手测闭环。
- macOS onboarding 里选择非本地翻译时，直接给出与设置页一致的 API 配置闭环，不把用户扔到后续设置里猜入口。

## 非目标
- 今晚不做 Windows 设置 UI 深度重绘。
- 不做 Apple/Windows 签名，不发布正式 v0.8。
- 不自动下载 whisper runtime；模型下载只能由用户显式点击触发。
- 不为性能“优化”牺牲字幕来源选择或 4K 修复。

## 里程碑与验证
- M1：只读对比 `v0.7.6` 与当前下载/队列/转码路径，列出证据。
- M2：写红灯测试，证明普通路径不应触发 ASR work plan 或 ASR generator。
- M3：实现最小修复，跑 Swift focused tests、`swift build`、`git diff --check`。
- M4：补 macOS Whisper 闭环缺口，优先确保无字幕视频可选择本地识别，完成项可本地识别重跑。
- M5：只在必要时跑 Python eval 和 Windows core/app build，确保跨平台核心不破。

## 风险与回滚
- 当前工作树包含多批未提交改动，不能回滚无关文件。
- 性能回退可能来自真实网络、yt-dlp 版本、站点限速或 v0.8 路径差异；先找可本地证明的额外工作，不把网络波动当代码结论。
- 回滚策略是按小切片撤回新测试对应的实现，而不是整体回退 v0.8。

## 决策记录
- 2026-06-21：今晚优先 macOS；Windows 设置视觉问题记录为后续专门切片。
- 2026-06-21：普通路径性能是 release gate：未启用 Whisper 时不得触发 ASR 相关阶段或进程。
- 2026-06-21：下载历史清理只允许作用于 App-owned `Downloads/Moongate`，不能扫描整个用户 Downloads。
- 2026-06-21：`ChineseSubtitleMode.off` 在 v0.8 ready 页里表示“仅保存主字幕来源”，不是“不需要字幕”；“不需要字幕”由独立的字幕来源选项表达。
- 2026-06-21：onboarding 的非本地翻译配置复用设置页 `APIConfigEditor`，避免 URL/token/model/拉模型/测试连接出现两套行为。
- 2026-06-21：队列完成项的本地 ASR 快捷重跑按产品语义固定为“重新识别 + 翻译 + 烧录”，不沿用原任务的“仅保存源字幕/无字幕”输出模式。
- 2026-06-21：烧录字幕时，即使不缩放，也要按源视频码率和短边计算码率封顶；macOS VideoToolbox 与 Windows NVENC/QSV/AMF 路径有封顶信息时使用目标码率而不是纯质量模式，避免低码率源被重编码撑大过多。
- 2026-06-21：macOS “更新与关于”只在更新区展示当前版本；关于区保留 App 身份和 GitHub 仓库入口，避免重复版本号。
- 2026-06-21：兼容网关模型列表请求允许第二次无 `limit` query 重试；官方 Anthropic 保留 `limit=1000`，OpenAI-compatible 只发 Bearer 头，不混入 Anthropic 私有头。
- 2026-06-21：macOS 本地语音识别设置按 Apple/HIG 方向收敛：默认界面只展示开关、运行时状态、设备推荐、模型能力和下载/使用/删除；runtime/model 路径属于高级设置，不直接铺满主界面。
- 2026-06-21：更新可用提示只读观察 `UpdateService.updateAvailable`；macOS 侧边栏红色数字 badge 不触发检查、下载或安装。
- 2026-06-22：RC 包可以本地安装做 QA，但仍不是正式发布；没有 Apple notarization、没有 Windows 真实硬件验证，也不创建 tag 或 GitHub Release。

## 进度记录
- 2026-06-21：创建本 ExecPlan，开始 M1 性能回退排查。
- 2026-06-21：对比 `v0.7.6` 与当前 `YtDlpEngine.download`，普通 yt-dlp 命令主体未发现默认 Whisper/ASR 参数；差异主要是 v0.8 字幕 stable track 映射、进度聚合和输出目录。
- 2026-06-21：发现一个正常路径额外开销候选：`ViewModel.settings.didSet` 每次设置变化都调用 `queue.syncLocalASRGenerator`，而推荐模型 readiness 会通过 `ASRModelStore.status` 计算模型 SHA-256。下载页“记住上次选项”也会写 settings，可能在不选 Whisper 时反复校验大模型。已改为只有 `localASREnabled/localASRRuntimePath/localASRModelPath/localASRModelID` 变化时才重建 generator。
- 2026-06-21：补充普通路径 gate：平台字幕或未选择 local ASR 时，work plan 不启用音频抽取/语音识别/字幕分段，`prepareLocalASRSourceSubtitleIfNeeded` 在 `localASRLanguageCode` 为空时直接返回。
- 2026-06-21：修正 local ASR 只保存源字幕路径：队列先准备主字幕来源，再判断是否需要翻译/烧录；因此选择本地语音识别 + 仅保存源字幕时会生成 `.local-asr.<lang>.srt`，普通路径仍由 gate 跳过 ASR。
- 2026-06-21：补齐 onboarding 非本地翻译 API 配置：选择 Anthropic/OpenAI compatible 后直接显示复用的 API 编辑器，可填 URL、API key、模型名，并可拉取模型/测试连接；完成 onboarding 时保存模型名到默认 AI 与翻译有效配置。
- 2026-06-21：补齐完成队列项的本地 ASR 快捷入口：只要完成项有视频文件且本地 ASR generator 就绪，就能复用已下载视频创建 `auto` local-ASR 主字幕来源，并把输出模式切到翻译烧录；原本没有平台字幕或原输出为“仅保存源字幕”的任务也可重跑。
- 2026-06-21：修正压制体积膨胀风险：Swift/C# `FFmpegBurner` 现在在不缩放时也用源短边计算 `maxrate`，软件编码保留 CRF 并加封顶，硬件 H.264/HEVC/HDR 在有封顶时改用 `-b:v/-maxrate/-bufsize`。已用 Swift `HDRSupportTests|EngineProgressTests|MacOSQueueBoundaryTests|QueueProgressTests` 验证 68 个 focused tests，并用 Windows `BurnerParameterTests|EncoderSelectionTests|HdrBurnArgsTests` 验证 27 个 tests。
- 2026-06-21：按 roadmap 清理 macOS About 区重复版本号：更新区继续展示当前版本，关于区只保留产品名、来源说明和 GitHub 仓库按钮。
- 2026-06-21：修复兼容网关模型列表脆弱性：非官方 gateway 若拒绝 `/v1/models?limit=1000`，会自动退回 `/v1/models`；Windows/OpenAI-compatible 拉模型也不再发送 `x-api-key` / `anthropic-version`。Swift 3 个模型列表 tests、Windows 5 个 focused tests 通过。
- 2026-06-21：基于 `apple-developer-design` 插件完成 macOS Local Speech Recognition 设置 polish：推荐模型不再只挑未安装项，已安装模型可以直接“使用”，当前模型显示使用中，bad hash / 磁盘不足不再表现为普通下载，模型能力标签完全走三语本地化，并修掉实时保存模式下仍提到 Done/保存步骤的文案。Swift `MacOSSettingsBoundaryTests|LocalizerTests` 通过 36 个 selected tests，`git diff --check` 通过。
- 2026-06-21：补齐 roadmap 里的 macOS 更新红点：设置窗口左侧 Updates & About 行在 Sparkle 发现更新后显示红色数字 `1`，并提供三语可访问性状态。Swift `MacOSSettingsBoundaryTests|LocalizerTests` 通过 37 个 selected tests。
- 2026-06-22：完成当前环境可验证 RC gate 和双端安装：本地 preflight 通过 Python 63、Swift 168、.NET 115；Windows VM preflight 通过 115 tests + WPF build；生成并验证 macOS DMG，生成 Sparkle ZIP，生成 Windows 安装器与 sha256；安装 `/Applications/月之门.app` 并启动成功；在 Windows 11 VM 静默安装 `Moongate-Windows-Setup-v0.8.0-rc.1.exe` 并启动成功。新增 `docs/v0.8-rc-manual-qa.md` 作为用户手动验收路径。

## 最终验证 Checklist
- [x] 普通路径性能候选原因已记录，有测试覆盖。
- [x] macOS focused Swift tests 通过。
- [x] `swift build` 通过。
- [x] `git diff --check` 通过。
- [x] 必要 Windows core/app build 未破坏。
- [x] macOS/Windows 烧录字幕体积封顶行为有 focused tests 覆盖。
- [x] macOS 关于区不重复显示版本号。
- [x] 兼容网关模型列表 fallback 与 header 分支有 Swift/C# focused tests 覆盖。
- [x] macOS 本地语音识别设置的模型推荐/使用/删除/高级设置路径有 boundary test 与三语本地化覆盖。
- [x] macOS 更新与关于侧边栏 badge 有 boundary test 与三语可访问性文案覆盖。
- [x] RC preflight 本机通过。
- [x] RC preflight Windows VM 通过。
- [x] macOS DMG/ZIP 和 Windows 安装器产物已生成。
- [x] macOS 本机和 Windows VM 已安装并启动 RC。
