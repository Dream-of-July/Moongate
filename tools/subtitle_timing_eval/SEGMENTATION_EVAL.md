# 字幕分段质量评测（Segmentation Eval）

衡量 Moongate 的分段器（`ASRTranscriptMapper.sourceCues` →
`LocalASRSubtitleTimingPlanner`）把语音切成字幕 cue 的**切点是否切在对的位置**。
这与 `metrics.py` 的**时序误差**评测互补：那里问"cue 出现/消失的时刻准不准"，
这里问"该不该在这里断句"。

> 媒体、音频、大字幕原文都**不入库**，只放在 git-ignored 的
> `artifacts/subtitle_timing_eval/` 缓存。仓库只提交脚本、算法、测试、manifest 元数据、汇总报告。

## 两条评测轨

两轨共用同一个 Swift 分段器（`moongate-cli local-asr-srt`），只是喂入的词时间戳来源不同：

- **Track A（人工字幕，目标 50）**：音频 → whisper.cpp → `asr_words.json`
  → `local-asr-srt` → candidate；参考 = 人工/人工校对字幕分段。
- **Track B（自动字幕，目标 50）**：YouTube 自动字幕 VTT → `vtt-words`（抽词）
  → `local-asr-srt`（同一分段器）→ candidate；参考 = 干净的人工抽样校验分段
  （自动 VTT 本身分段不规整，**不能**直接当边界参考）。

## 指标定义（可执行）

在评测窗口 `[W0, W1]` 内，取 candidate / reference 各自的 **cue 起始时间** 作为分段
切点集合 `B_C` / `B_R`（丢弃落在窗口起点 ε=0.2s 内的平凡切点）。

- **边界匹配**：容忍窗 τ（默认 0.5s）内做**一对一最近匹配**（每个参考切点最多匹配一次，
  避免重复计数虚高 recall）。
  - `TP`=匹配对数，`FP=|B_C|-TP`（过分段），`FN=|B_R|-TP`（欠分段）
  - `Precision=TP/|B_C|`，`Recall=TP/|B_R|`，**`F1=2PR/(P+R)`**
- **offset-aligned F1（主 KPI）**：在 ±1.0s 内搜索使 F1 最大的**整体 onset 偏移**后再算 F1。
  理由：Moongate 有意把 onset 整体后移以便阅读（`WhisperCueRetimer.onsetDelaySeconds`），
  这个**恒定显示偏移属于时序问题**（已由 timing eval 覆盖），分段质量应对它不变。
  界定 ±1.0s 防止"偏移作弊"。
- **过/欠分段**：`segment_count_ratio=|B_C|/|B_R|`（理想 1.0）、
  `over_segmentation_ratio=FP/|B_R|`、`under_segmentation_ratio=FN/|B_R|`。
- **文本/时间覆盖率**：`temporal_coverage` = 参考语音总时长中被任一 candidate cue 覆盖的比例。
- 诊断：同时输出 τ∈{0.3,0.5,1.0}s 的 F1（`f1_by_tolerance`）。

**样本通过门槛**（全部满足）：`aligned_boundary_f1 ≥ 0.90`、`temporal_coverage ≥ 0.90`、
`0.80 ≤ segment_count_ratio ≤ 1.25`。

**评测集达标（headline ≥90%）**：平均 `aligned_boundary_f1 ≥ 0.90` **且** 样本通过率 ≥ 0.90，
Track A / Track B 分别统计。

## 运行

单样本（candidate 已生成）：
```bash
PYTHONPATH=tools/subtitle_timing_eval python3 -m subtitle_timing_eval.cli segmentation-metrics \
  --candidate <candidate.srt> --reference <human.srt> --sample-id <id> --track A \
  --candidate-offset-seconds <section_start> \
  --window-start-seconds <W0> --window-end-seconds <W1> \
  --out artifacts/subtitle_timing_eval/segmentation/<id>.segmentation.json
```

生成 candidate（Swift 分段器，需先构建 CLI，见下）：
```bash
.build-seg/debug/moongate-cli local-asr-srt \
  --asr-words <asr_words.json> --language <lang> --out <candidate.srt>
```

离线全量 baseline（自动发现缓存样本、生成 candidate、评分、聚合）：
```bash
PYTHONPATH=tools/subtitle_timing_eval python3 tools/subtitle_timing_eval/run_segmentation_baseline.py \
  --binary .build-seg/debug/moongate-cli
# 产出：artifacts/subtitle_timing_eval/segmentation/{<id>.segmentation.json, suite.summary.json, baseline.report.md}
```

聚合多个报告：
```bash
PYTHONPATH=tools/subtitle_timing_eval python3 -m subtitle_timing_eval.cli segmentation-suite \
  --report <a.json> --report <b.json> --out artifacts/subtitle_timing_eval/segmentation/suite.summary.json
```

测试：
```bash
cd tools/subtitle_timing_eval && python3 -m unittest tests.test_segmentation
```

### 构建 moongate-cli（绕开 Sparkle 缓存损坏）

仓库 `.build/` 缓存里残留了别的机器的 Sparkle XCFramework 绝对路径，导致
`swift build --product moongate-cli` 在 planning 阶段报
`XCFramework Info.plist not found at '/Users/henryxian/...'`。用**全新 build-path** 即可绕开：
```bash
swift build --product moongate-cli --build-path .build-seg
```

## 数据卫生（runner 自动跳过）

- ASR 词数 < 30：转写残桩，跳过（例：starship 的探针文件只有 3 词）。
- 滚动/逐词参考（<0.3s 碎 cue 占比 > 15%）：YouTube 逐词滚动字幕不是公平的分段边界目标，跳过。
- translate / proxy 类目：不属于分段轨。

## 当前 baseline（2026-06-24，13 个离线样本）

| 指标 | Track A | Track B | Overall |
|---|---|---|---|
| 样本数 | 12 | 1 | 13 |
| 平均 aligned F1（诊断） | 0.534 | 0.462 | 0.528 |
| **平均 strong-boundary recall（主门槛）** | 0.508 | 0.833 | 0.533 |
| 平均 temporal coverage | 0.895 | 0.851 | 0.891 |
| 样本通过率 | 0% | 0% | 0% |

**距 90% 仍有显著差距。** 关键发现：即便只看"句末标点 / 真实停顿"这类人类必然认可的**强边界**，
分段器也只命中约 **53%**——存在系统性**欠断句**（普遍 `segment_count_ratio` 0.6–0.87、在强边界处不断开）。

### 迭代 1（2026-06-24，方向 B）：largeSpeechGapSeconds 0.65→0.50

把 speech 档无条件断句的停顿阈值从 0.65s 降到 0.50s（三处同步：`Sources/MoongateCore/ASR.swift`、
`windows/MoongateCore/Asr.cs`、`Tests/fixtures/whisper-timing-constants.json`）。

| 指标 | 迭代前 | 迭代 1 |
|---|---|---|
| 平均 strong-boundary recall | 0.498 | **0.644** |
| 样本通过率 | 0% | 8% (1/13) |
| 平均 temporal coverage | 0.891 | 0.881 |

- 回归验证：65 个 Swift `ASRContractsTests` 全过（含跨平台 parity 测试
  `testWhisperTimingConstantsMatchCrossPlatformFixture`）；timing `accepted_ratio` 在完整 asr_words 的
  干净样本上 = 1.000（tedx_nagoya 87/87、tedx_taipei 8/8）——**多断句未损害时序**。
- 代价：`french_talk_public_fr` `segment_count_ratio` 1.23→1.31（轻微过分段）。继续下调阈值会加剧过分段，
  下一步改走标点鲁棒性（见下），不再单纯降 gap。
- ⚠️ C# 单元测试需在 Windows/CI 用 dotnet 跑 `AsrContractsTests`（本机无 dotnet）；常量已与 fixture 同步，parity 断言按构造通过。

### 迭代 2（2026-06-24，方向 B）：CJK 标点提示 —— 公平复测后净正，已落地

失败分析（数据驱动）：失败样本里漏掉的强边界 **92%（44/48）无声学停顿**（gap<0.4s），靠句末标点
才能断；而 whisper.cpp 对 CJK 几乎不产标点——**日语实测 0 个、韩语 6 个**。给 whisper.cpp 一个带标点的
范例 prompt 后：日语标点 0→24、韩语 6→24。

**首次比较口径错误 → 复测纠正**：最初拿"旧缓存非提示 ASR"对比"新跑提示 ASR"，韩语显示 0.50→0.43（假回退），
据此一度回滚。改为**同次重跑 ASR 的公平对比**（cur 与 prompt 都现场重新转写同一音频）后，结论翻转：

| 样本 | strong-recall cur→prompt | aligned F1 |
|---|---|---|
| tedx_nagoya (ja) | 0.444→**0.778** | 0.471→0.703 |
| sebasi (ko) | 0.357→**0.571** | 0.455→0.431 |
| the_do_show (zh-HK) | 0.429→0.429 | 持平 |
| tedx_taipei (zh-TW) | 0.000→0.000 | 持平（该样本强边界识别异常，待查） |
| **CJK aggregate (n=4)** | **0.308→0.444（+0.136）** | 0.408→0.455 |

**无一样本回退**，机制可靠（标点 0→24）。已把产品改动落地：`ASRPromptBuilder.defaultPrompt` 仅对 CJK
前置标点范例（Latin 不变），C# `AsrPromptBuilder` 镜像，Swift 65 测试全过。
注意：whisper.cpp 有 run-to-run 方差；n=4 仍偏小，扩到 100 后需复核 aggregate。tedx_taipei strong-recall=0
是该样本的参考/对齐异常，单列待查。

### 失败分析

1. **系统性 onset 偏移**：候选边界相对参考普遍 +0.2s（`onsetDelaySeconds`，属时序，已由 aligned 抵消）。
2. **系统性欠断句（核心缺陷）**：在句末标点 / 真实静音处常常不断开，把多句合并成一个长 cue。
   `maximumLatinCueSeconds=9.0`、`maximumCJKCueSeconds=4.5` 偏大，且缺少"遇句末标点/长停顿强制断"的规则。
3. **覆盖率个别偏低**（do_show 0.81、cantonese_uk 0.895）：末句 hold/裁剪与窗口边界处理。

### 指标框架决策（已落地 option B 的核心）

> 原始 "onset-F1 vs YouTube 人工字幕 ≥90%" 规格不当：达成它等于模仿 YouTube 阅读速度碎行换行，
> 与 Moongate "更长语义 cue" 的产品哲学冲突。

因此**硬门槛改为产品中立指标**：`strong_boundary_recall ≥ 0.90`（不漏掉必断点）+ `temporal_coverage ≥ 0.90`
+ `segment_count_ratio ∈ [0.80,1.25]`（不过/欠分段）。aligned F1 仅作诊断。

**仍待 七月 决策的方向（影响下一轮优化与跨平台常量）**：
- **A. 向 YouTube 风格靠拢**：调小最大 cue 时长 + 引入阅读速度换行，`segment_count_ratio→1.0`。
- **B. 保留语义分段哲学**：只优化 strong-boundary recall（在句末标点/长停顿处强制断），不追求模仿碎行。
  （当前指标已按 B 设定门槛。）

## 下一轮计划

1. 与产品确认上面 A/B 方向。
2. 若走 B：在 `segmentation.py` 增加"强边界"识别（句末标点 + 语音 gap），输出 strong-boundary
   recall 作为补充 KPI，并据此重设 90% 目标。
3. 扩样本到 100（manifest `segmentation_samples.json`，分批可断点续跑）；Track B 补人工抽样参考。
4. 每轮记录指标变化、失败类型、回归用例（`tests/test_segmentation.py`）。

## 扩充 baseline 与 90% 上限分析（2026-06-24，cookie 采集 + 统一 ASR）

用月之门 YouTube cookie（`prepare --cookies`，临时副本不回写主 jar）解除下载阻塞，扩采集并对
**全部 18 个可评样本统一重跑 whisper.cpp ASR**（词级 + CJK 标点提示），消除了之前缓存的
faster/coarse/残桩混杂。

**扩充 baseline（18 样本）**：strong-boundary recall **0.493**、aligned F1 0.428、coverage 0.887、通过率 0%。

**容忍窗敏感度**（决定性）：

| 容忍窗 τ | strong-recall |
|---|---|
| 0.3s | 0.353 |
| 0.5s（默认门槛） | 0.493 |
| 0.75s | 0.580 |
| 1.0s | 0.645 |

**90% 不可达的根因（已被多容忍窗 + 多样本数据证实，非可修 bug）**：
- 即便放宽到 τ=1.0s，仍有 **35%** 的参考强边界附近无任何候选断点 → 不是计时抖动/门槛太严。
- 失败强边界分类（5 个演讲，n=108）：73% 无声学停顿、25% 候选断了但偏>0.5s、gap 类仅 2。
- 关键反例 tedx_twenty_hours_en：候选断了 **74** 次（多于参考 42 个强边界）却仍 strong-recall 0.28——
  **不是断得少，是断在不同位置**。Whisper 的句子切分 ≠ 人工字幕编辑的切分（同段语音，"句子"边界判断不同）；
  葡语等则是 Whisper 欠标点（5 个句末标点 / 27 参考 cue）。

**结论**：在"我们的 Whisper 分段 vs 独立人工字幕断点、0.5s 容忍"这一指标定义下，strong-recall 的天花板
约 **0.65**（τ=1.0s）。要冲到 90% 必须让分段器**模仿特定人工字幕的断句风格**——这与七月选定的方向 B
（保留语义分段哲学、不模仿 YouTube 风格）直接冲突。即"90% vs 独立人工边界"这个目标本身与产品哲学不自洽。

**realistic 下一步（给七月决策）**：
1. **改参考口径**：Track A 改为"对同一份**人工字幕文本**做我们的分段，与人工换行对齐"（候选与参考共享文本，
   消除 Whisper-vs-human 切分分歧），这样 90% 可作为真实的分段-换行质量目标。
2. **改指标语义**：把 KPI 从"匹配特定参考断点"改为**内生质量**（断点是否落在真实句法/声学边界、是否违反
   阅读速度/最小时长），不绑定单一人工风格。
3. 若坚持现指标，则记录 ~0.65 为该定义下的现实上限，90% 不可达。

已落地的两轮算法改进（gap 0.65→0.50、CJK 标点 prompt）在各自验证口径下均为净正、无回归、跨端 parity 通过；
它们提升了"断在真实停顿/CJK 句末"的能力，但无法消除上述固有的风格分歧。
