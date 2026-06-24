# ExecPlan — YouTube 字幕分段质量评测与持续优化

- 分支：`feature/youtube-caption-segmentation-eval`
- 角色：字幕分段算法持续优化专员
- 创建：2026-06-24

## 1. 背景与产品意图

Moongate 的本地 ASR（whisper.cpp）转写后，由 `LocalASRSubtitleTimingPlanner` /
`ASRTranscriptMapper.sourceCues` 把词级时间戳重新分段成字幕 cue。现有
`tools/subtitle_timing_eval` 流水线衡量的是**时序准确率**（边界误差 ms、`accepted_ratio`、
early-cutoff / long-idle-hold 等），但**没有衡量"分段切点本身是否切在对的位置"**。

本任务要建立一个独立、可复现的 **分段质量评测集**，围绕真实 YouTube 视频，对
分段切点做 boundary F1 评估，并持续优化算法直到核心指标达到 90% 以上。

## 2. 当前仓库理解（关键文件）

- `Sources/MoongateCore/ASR.swift`
  - `ASRTranscriptMapper.sourceCues(from:profile:)`（分段入口）
  - `LocalASRSubtitleTimingPlanner.planCues(...)`（分段 heuristic + 阈值）
  - `WhisperCueRetimer`（onset/hold 重定时）
- `Sources/moongate-cli/main.swift` → `local-asr-srt --asr-words <json> --language <l> --out <srt>`
  跑的就是上面的 Swift 分段器：输入词级时间戳 JSON，输出 SRT。这是评测的 **candidate 生成器**。
- `tools/subtitle_timing_eval/subtitle_timing_eval/`
  - `srt.py` / `vtt.py`：cue 解析（`parse_srt` / `parse_vtt_cues` → `Cue(index,start,end,text)`）。
  - `vtt.py: parse_vtt_word_timestamps`：把 YouTube 自动字幕 VTT 的 inline 词时间戳抽成 `Word`。
  - `asr.py`：faster-whisper / whisper.cpp 包装（产 `asr_words.json`）。
  - `metrics.py`：现有时序对齐 + gate。
  - `cli.py`：`prepare`（yt-dlp 下载分段+字幕）、`asr`、`vtt-words`、`metrics`、`status` 等。
- `artifacts/subtitle_timing_eval/`（**git-ignored**）：已缓存 ~30 个样本，其中约 15 个
  同时具备 `asr_words.json` + 参考 `vtt/srt`，可**离线**直接跑 baseline。

两条评测轨共用同一 Swift 分段器：
- **Track A（人工字幕，50 个）**：音频 → whisper.cpp → `asr_words.json` → `local-asr-srt` → candidate；
  参考 = 人工/人工校对字幕的分段。
- **Track B（自动字幕，50 个）**：YouTube 自动字幕 VTT → `vtt-words`（抽词）→ `local-asr-srt` →
  candidate；参考 = 可用参考分段或人工抽样校验。

## 3. 目标与非目标

目标：
1. 可复现的分段评测流水线（下载可断点续跑、限速、保留 manifest；媒体只进 ignored 缓存）。
2. 100 视频 manifest（Track A 50 + Track B 50），优先公开、合法、可研究使用内容。
3. 可执行的"90% 准确率"指标（见 §4），写入文档并在测试/报告中输出。
4. baseline → 失败分析 → 迭代算法 → regression cases，每轮记录指标变化与失败类型。
5. 核心指标 ≥90%，或明确记录未达标的阻塞原因。

非目标：
- 不大重构现有 ASR/分段架构，除非有明确收益。
- 不覆盖 YouTube 全部长尾语言；范围对齐现有 `coverage_goal`（en/zh/yue/ja/ko/es/fr/it 等）。
- 不提交任何音频/视频/大字幕原文/受版权内容到 git。

## 4. 可执行指标定义（"90% 准确率"）

对每个样本，在评测窗口 `[W0, W1]` 内，把 candidate 与 reference 各自的 **cue 起始时间**
作为分段切点集合 `B_C` / `B_R`（丢弃落在窗口起点 ε 内的平凡切点）。

- **边界匹配**：在容忍窗 τ 内做一对一最近匹配（每个参考切点最多匹配一次）。
  - `TP` = 匹配上的切点对数
  - `FP = |B_C| - TP`（多切 → 过分段）
  - `FN = |B_R| - TP`（漏切 → 欠分段）
  - `Precision = TP/|B_C|`，`Recall = TP/|B_R|`，**`F1 = 2PR/(P+R)`**
- **过/欠分段惩罚**：
  - `over_segmentation_ratio = FP / |B_R|`
  - `under_segmentation_ratio = FN / |B_R|`
  - `segment_count_ratio = |B_C| / |B_R|`（理想 1.0）
- **文本/时间覆盖率**：
  - `temporal_coverage` = 参考语音总时长中被任一 candidate cue 时间区间覆盖的比例
    （惩罚漏掉成段内容）。
  - `token_coverage`（诊断用）= 参考文本 token 被 candidate 文本模糊覆盖的比例。
- 默认 τ = 0.5s；同时报告 τ ∈ {0.3, 0.5, 1.0}s 用于诊断。

**样本通过门槛**（全部满足）：
- `F1@0.5s ≥ 0.90`
- `temporal_coverage ≥ 0.90`
- `0.80 ≤ segment_count_ratio ≤ 1.25`

**评测集达标（headline ≥90%）**：
- 平均 `F1@0.5s ≥ 0.90` **且** 样本通过率 ≥ 0.90（Track A、Track B 分别统计）。

## 5. 方案与备选

采用方案：新增 `segmentation.py`（纯 Python，仅依赖 srt/vtt 解析）+ CLI 子命令
`segmentation-metrics`（单样本）与 `segmentation-suite`（批量聚合）。candidate 由
`moongate-cli local-asr-srt` 产出（复用现有 Swift 分段器），不重写分段逻辑。

备选（未采用）：在 Swift 侧直接做评测——跨语言、难批量、与现有 Python 评测割裂。

## 6. 预计改动文件

- 新增 `tools/subtitle_timing_eval/subtitle_timing_eval/segmentation.py`
- 修改 `tools/subtitle_timing_eval/subtitle_timing_eval/cli.py`（加子命令）
- 新增 `tools/subtitle_timing_eval/segmentation_samples.json`（100 视频 manifest）
- 新增 `tools/subtitle_timing_eval/tests/test_segmentation.py`
- 新增 `tools/subtitle_timing_eval/SEGMENTATION_EVAL.md`（评测文档/运行手册）
- 新增 `artifacts/subtitle_timing_eval/segmentation/`（ignored，报告产物）
- 本 ExecPlan

## 7. 风险、回滚、开放问题

- **环境/版权**：100 个真实视频无法在本会话内全部下载（限速/时长/条款）。策略：
  manifest + 可断点续跑脚本，先用本地已缓存 ~15 样本建立 baseline，其余记为分批进度。
- **时间基对齐**：缓存 `asr_words` 多为 section-relative（0 基），参考 VTT 为绝对时间；
  CLI 提供 `--candidate-offset-seconds` 与窗口裁剪。
- **Track B 参考**：自动字幕本身分段不规整，需人工抽样校验作参考；先用"人工校对版/官方字幕"
  作参考，缺失时记为 pending。
- 回滚：纯新增，删除新文件即可还原；不动现有时序评测与 Swift 生产逻辑。

## 8. 决策记录

- 2026-06-24：边界以 **cue 起始切点** 为准（onset 是分段决策点；end 多为 hold 派生）。
- 2026-06-24：时间基边界匹配（text-robust），因 Track A 中 Whisper 文本 ≠ 人工文本。
- 2026-06-24：复用 `local-asr-srt` 作为唯一 candidate 生成器，两轨统一。
- 2026-06-24：**硬门槛改为产品中立指标**——`strong_boundary_recall ≥ 0.90` + `coverage ≥ 0.90`
  + `segment_count_ratio ∈ [0.80,1.25]`；放弃"原始 onset-F1 vs YouTube ≥90%"（会逼迫模仿碎行换行）。
- 2026-06-24：**七月 选定方向 B**（保留语义分段，只补强边界），不向 YouTube 碎行风格靠拢。
- 2026-06-24：**暂不在本会话修改出货 Swift/C# 分段器**——`largeSpeechGapSeconds` 等是
  `Tests/fixtures/whisper-timing-constants.json` 驱动的跨平台 parity 常量，改动需 C# 同步 +
  Swift/C# parity 测试 + 重跑已达标的 timing eval 防回归。按"保护现有可用行为/小而可审查"原则，
  把算法迭代作为下一步带 regression gate 的独立改动交付（见 §11）。

## 11. 下一步算法迭代计划（方向 B，待执行）

定位（已诊断）：欠分段来自 `LocalASRSubtitleTimingPlanner.planCues` 分组主循环——只在
`endsSentence(词)` 或 `shouldBreak`（gap>`largeSpeechGapSeconds`=0.65 / 超长）时断；参考里 0.4–0.65s
停顿属强边界但被漏断；`mergeShortGroups` 仅并 CJK 短孤儿，不背锅。

拟改（每步独立、可度量、带回归门槛）：
1. ~~新增 `strongGapBreakSeconds`~~ → 已用更简单的 `largeSpeechGapSeconds` 0.65→0.50 实现（迭代 1，已落地验证）。
2. **CJK 标点 prompt（迭代 2，已落地）**：whisper.cpp 带标点范例 prompt 让 CJK 产出句末标点。
   公平同次对比下 CJK aggregate strong-recall 0.31→0.44、无回退，已落地 `ASRPromptBuilder.defaultPrompt`
   （仅 CJK）+ C# 镜像 + 两端测试。**待办**：扩到 100 / 更多 CJK 样本后复核 aggregate（whisper.cpp 有方差，
   n=4 偏小）；排查 tedx_taipei strong-recall=0 的参考/对齐异常。
3. 回归门槛（每步必须满足）：
   - timing eval 不回归：`accepted_ratio` 不下降（迭代 1 实测完整样本 = 1.000）。
   - segmentation：aggregate `strong_boundary_recall` 上升且 `segment_count_ratio` 不超 1.25。
   - Swift `ASRContractsTests`（65）+ C# `AsrContractsTests` 全过。
4. 失败样本补 regression case 到 `tests/test_segmentation.py`。
5. **样本扩到 100 的外部阻塞**：YouTube 新视频下载被机器人检测拦截（需浏览器 cookies，按 req 8 不绕过）。
   方案：在有合法 cookies 的本机/CI 环境跑 `prepare`（可断点续跑、已写 blocker），或换用允许下载的公开数据源。
   当前用 13 个已缓存离线样本建立 baseline 与迭代验证。

## 9. 进度记录

- 2026-06-24：只读摸底完成；建分支；写本计划；开始实现 segmentation 指标模块。
- 2026-06-24（第 1 轮 baseline）：
  - 落地 `segmentation.py`（boundary F1 + offset-aligned F1 + coverage + over/under-seg）、
    CLI `segmentation-metrics` / `segmentation-suite`、`run_segmentation_baseline.py`、
    `tests/test_segmentation.py`（13 用例全过；现有 123 个 timing 测试无回归）。
  - 构建 moongate-cli：发现 `.build/` 缓存残留别机 Sparkle 路径，改用 `--build-path .build-seg` 绕开。
  - **首轮 baseline（13 离线样本）**：平均 raw F1=0.368、aligned F1=0.528、coverage=0.891、通过率 0%。
  - 失败诊断：(1) 系统性 +0.2s onset 偏移（onsetDelaySeconds，属时序）；(2) 系统性欠分段
    （seg_ratio 0.6–0.87，recall 0.25–0.55，我们 cue 更长更少 vs YouTube 阅读速度换行）；
    (3) 个别覆盖率偏低。
  - **阻塞达标的规格问题**：原始 "onset-F1 vs YouTube 人工字幕 ≥90%" 等于要求模仿 YouTube 碎行换行，
    与"更长语义 cue"的产品哲学冲突。详见 `tools/subtitle_timing_eval/SEGMENTATION_EVAL.md`。
  - 数据现实：环境可联网且有 yt-dlp/ffmpeg，但 faster-whisper 未装、whisper.cpp 模型与 100 视频
    全量下载不在本会话内完成；已建 32 样本真实 manifest（A=27/B=5，17 离线就绪）+ 到 100 的分批续跑流程。
- 2026-06-24（第 2 轮 / 迭代 1，方向 B）：
  - 七月选定方向 B 后，执行第 1 步：speech `largeSpeechGapSeconds` 0.65→0.50（Swift + C# + fixture 三处同步）。
  - 结果：**strong-boundary recall 0.498→0.644**，通过率 0→8%；timing accepted_ratio 在完整 asr 样本 = 1.000（无回归）；
    65 个 Swift ASRContractsTests 全过（含 parity）。代价：french seg_ratio 1.23→1.31（轻微过分段）。
  - 仍未到 0.90；继续降 gap 会加剧过分段，下一步改走句末标点鲁棒性 + 统一 ASR 重跑 + 扩样本（见 §11）。
- 2026-06-24（第 3 轮 / 迭代 2，方向 B — 复测后落地）：
  - 数据驱动失败分析：失败样本漏掉的强边界 92%（44/48）无声学停顿，靠标点才能断；whisper.cpp 对 CJK
    几乎不产标点（日语 0、韩语 6）。给 whisper.cpp 带标点范例 prompt → 标点 0→24。
  - 比较口径纠错：最初拿"旧缓存非提示"对比"新跑提示"，韩语假回退 0.50→0.43，一度回滚。改为**同次重跑的
    公平对比**后翻转：CJK aggregate strong-recall **0.308→0.444（+0.136），无样本回退**（nagoya 0.44→0.78、
    sebasi 0.36→0.57、do_show 持平、taipei 0=0 异常待查）。
  - 据此把 CJK 标点 prompt **落地**：`ASRPromptBuilder.defaultPrompt`（仅 CJK）+ C# 镜像 + 两端测试；Swift 65 全过。
    注意 whisper.cpp run-to-run 方差 + n=4 偏小，扩到 100 后需复核。
  - 外部阻塞：YouTube 新视频下载被 "Sign in to confirm you're not a bot" 拦截（需浏览器 cookies，按 req 8
    不绕过）→ 100 视频全量采集在本环境不可行，pipeline 已正确写 blocker 并跳过。
- 2026-06-24（第 4 轮，七月授权用月之门 cookie 下载）：
  - 把 `--cookies` 接入 `prepare`（临时副本，不回写月之门主 jar）；新增 `collect_segmentation_eval.py`
    端到端采集+统一 ASR（带 cookie 下载、CJK 标点提示、断点续跑、限速、失败写 blocker 不绕过）。
  - 批量 processed=29：下载缺失样本 + 对全部样本统一重跑 whisper.cpp 词级 ASR（CJK 带标点）。
  - **扩充 baseline（18 样本）**：strong-recall 0.493、aligned F1 0.428、coverage 0.887。修了"窗口取实际 ASR 时长"
    的覆盖率 artifact。
  - **90% 上限分析（决定性）**：容忍窗 0.3/0.5/0.75/1.0s → strong-recall 0.353/0.493/0.580/**0.645**。
    即便 τ=1.0s 仍 35% 参考强边界无候选断点。反例 tedx_twenty：候选断 74 次>参考 42 强边界却仍 0.28——
    **Whisper 句子切分 ≠ 人工字幕切分**（风格分歧），非可修 bug。结论：现指标定义下 strong-recall 天花板 ~0.65，
    冲 90% 须模仿特定人工风格，与方向 B 冲突。realistic 选项见 `SEGMENTATION_EVAL.md` 文末（改参考口径 / 改指标语义 / 接受 ~0.65 上限）。

## 10. 最终验证 checklist

- [x] `segmentation.py` 单元测试通过（perfect/over/under/tolerance/coverage/一对一/窗口/offset）
- [x] `segmentation-metrics` / `segmentation-suite` CLI 可跑通缓存样本
- [x] baseline 报告产出（13 离线样本，Track A 为主）→ `artifacts/.../segmentation/baseline.report.md`
- [x] 100 视频 manifest 脚手架 + 清晰分批进度（`segmentation_samples.json`，32 真实样本）
- [ ] 算法迭代到指标 ≥90%（**进行中**：迭代 1 把 strong-recall 0.50→0.64，无时序回归；未达 0.90，路径见 §11）
- [x] 现有 Python 测试无回归（123 timing + 13 segmentation）；Swift build 受 Sparkle 缓存影响，CLI 用 `.build-seg` 单独构建成功
