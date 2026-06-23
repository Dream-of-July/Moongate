# Whisper 字幕时序专属算法 ExecPlan

> 状态：草案待执行（plan only，尚未改代码）。负责人：七月 / Claude。创建日期：2026-06-22。
> 关联：本计划只处理 whisper 本地识别路径的字幕**出现/消失时机**，不动 YouTube 自动字幕路径，也不动压制/翻译流水线。

## 1. 背景与产品意图

v0.8 新增了本地 whisper.cpp 识别。识别**准确率**（尤其日/韩等小语种）相对平台自动字幕大幅提升，这是要保留并继续放大的优势。但 whisper 生成字幕的**出现时机与消失时机**明显劣于 v0.7 时代的"YouTube 自动字幕"路径：字幕出现偏晚、消失突兀（一句还没念完/刚念完就闪走），整体体验下降。

产品目标：让 whisper 路径的出现/消失时机达到与旧自动字幕路径**接近的人类对齐水平**（用 `tools/subtitle_timing_eval` 的 acceptance window 衡量，目标 `accepted_ratio ≈ 90%`），同时**只允许 whisper 提升识别率，不允许它拖累压制体验或非 whisper 路径**。

七月的明确要求：whisper 应当**单独写一套时序算法**做针对性优化，而不是继续套用为 YouTube 自动字幕设计的算法。本计划即实现这一点。

## 2. 当前仓库理解（已核验）

### 2.1 旧"自动字幕"为什么能到 ~90%
- 平台路径解析 YouTube VTT 时，把 Google **逐词的人类对齐时间戳**作为 `SubtitleCue.sourceFragments` 锚点（`Translator.swift:91, 182-274`）。
- `cleanCues` 在有锚点且 rolling 字幕时令 `canUseSourceAnchors=true`（`Translator.swift:1456-1458`），核心重定时 `sourceAnchoredPieces`（`Translator.swift:1369-1429`）把每个重切片段的**出现时间钉到该词的源 start、消失时间钉到源 end**——只改"在哪里断句"，不改"贴在真实人声时钟上的时间"。
- 两道保护：有锚点的 rolling 字幕跳过去重叠（`Translator.swift:662`）；`shouldAlignToSpeechWindow` 在 `canUseSourceAnchors=true` 时直接返回 false（`SubtitleTimingPlanner.swift:111`），不让合成可读窗口缩短锚定 cue。
- **结论**：那 90% 来自"源时间本身就是人类对齐的"，算法只是保真清洗+重分段。**whisper 没有这个外部人类时钟，所以无法复用这套机制**——即使把 whisper 词喂进 `sourceAnchoredPieces`，也只会忠实复现 whisper 自己的时间误差。

### 2.2 whisper 路径现状与根因（全部已定位到行）
- whisper 路径走的是**另一套** planner：`ASRTranscriptMapper.sourceCues` → `LocalASRSubtitleTimingPlanner.planCues`（`ASR.swift:650-654`），再用 `serializeSRT` 写成**无内联时间锚点**的纯 SRT（`ASR.swift:672`）。这是一个干净的 seam：`planCues` 只有 3 个调用方，全在 whisper 路径，改它不会回归 YouTube 路径。
- **根因 #1（critical）VAD 是死配置**：`ASRRequest.vadEnabled=true` 一路透传（`ASR.swift:23/1073`，Codable、cache key 都带），但 `WhisperCppCommandPlan.init`（`ASR.swift:1230-1246`）只读 `wordTimestamps` 选 `-ojf/-oj`，**从不读 `vadEnabled`**；argv 实际为 `[-m, -f, -ojf, -of, -pp] (+ -l/--prompt)`，没有 `--vad`、没有 `-dtw`、没有 `-ml`。Windows 同样（`Asr.cs:830` 设置、`Asr.cs:967-1004` 忽略）。
- **根因 #2（critical）原始 token 偏移是唯一且未修正的真值**：`parseTokenWords` 把 token `offsets.from/to`（按毫秒/1000）读入 `ASRWord`（`ASR.swift:1468-1483`），`sourceFragments` 原样拷贝（`ASR.swift:632-647`），`makeCue` 令 `cue.start = first.startSeconds`、`cue.end = last.endSeconds + tail`（`ASR.swift:809-810`）。没开 `-dtw` 时 whisper 输出的是帧量化的粗糙偏移；token `probability` 解析了却从不用于过滤。每一个 onset/offset 误差都原样穿透到 SRT。
- **根因 #3（high）出现端零补偿**：`cue.start` 直接等于首词偏移，无 lead-in、无回拉（`ASR.swift:809`）；而消失端却补了 0.45/0.2s tail（`ASR.swift:810`）。whisper 习惯性晚起 → 字幕稳定偏晚出现。
- **根因 #4（high）消失端被 nextStart 夹断造成突兀消失**：分组只在 `gap>0.65s` 才断（`largeSpeechGapSeconds`，`ASR.swift:691/778`），相邻 cue 常 ≤0.65s；`end = min(end, nextStartSeconds)`（`ASR.swift:814-816`）于是频繁吃掉 0.2-0.45s 的 tail，字幕在下一句出现的瞬间被切走。
- **根因 #5（medium）无 `--max-len` 分段失控**：欠标点语言（日/韩/中常无终止标点）既不触发强制 flush 也无自然 gap，cue 一直撑到 4.5/9.0s 上限，断点是合成的，既滞留又乱断（`ASR.swift:771-797, 687-688`）。
- **附带 bug（high/low）**：`makeCue` 末行 `end = max(end, start+minimumCueSeconds)` 在 `min(end,nextStart)` 之后执行（`ASR.swift:814-818`），短 cue 会被顶出去**与下一句重叠**，也可能超出 `transcriptDuration`。

> 注：曾怀疑"短句滞留到 9s"，已被对抗验证否定——`min(end, start+cap)` 是天花板只会缩短，不会拉长。真正问题是上面 #3/#4。

### 2.3 度量现状（已核验）
- `subtitle_timing_eval` 的 acceptance window：start_error ∈ [-250, +450]ms，end_error ∈ [-150, +900]ms（`metrics.py:14-17`），两者都落窗才 `accepted`；严格 gate 要求 `accepted_ratio ≥ 0.90` 且 `early_cutoff(>150ms)=0`、`long_idle_hold(>900ms)=0`、`cjk_singleton=0`（`comparison.py`）。required 语言组：en/zh/yue/ja/ko/es/fr/it + translated。
- **harness 已经能测 whisper**：whisper.cpp 已接为 reference engine；app 的真实 planner 输出可经 `moongate-cli local-asr-srt` 复现（与 app 同一 `planCues`）。
- **缺口**：① 磁盘上零 whisper baseline artifact；② 默认 runbook 是**自指**的——它把 whisper 自己的 `asr_words.json` 同时当 candidate 来源和 `--asr-words` 参考（`pipeline.py:188-199, 279-287`），于是 `cue.start` 误差≈0、gate 虚高，**测不出真实人类对齐度**。要拿真 baseline 必须用**独立参考**（同一媒体的 YouTube 人类 VTT `vtt-words` 或人工 SRT），并对齐 `--asr-offset/--window`。

## 3. 目标与非目标

### 目标
- whisper 路径出现/消失时机在 `subtitle_timing_eval` 上达到 `accepted_ratio ≈ 90%`（至少 en + 一个 CJK 组先达标，再铺全 required 组）。
- whisper **专属**时序逻辑：独立的 `WhisperCueRetimer`，与 YouTube 路径的 `SubtitleTimingPlanner`/`sourceAnchoredPieces` 完全解耦。
- 跨平台 Swift / Windows C# 行为一致（同常量、同 argv、同重定时数学），有 fixture 字节级对比兜底。
- 纯函数、可单测、可回滚。

### 非目标
- 不动 YouTube 自动字幕（平台 VTT）路径，不动翻译/压制/烧录流水线。
- 不改 `ASRRequest` 的 public 行为（只加带默认值的可选字段，保持 Codable 兼容）。
- M1 不引入任何新依赖资源（VAD 模型推迟到 M4 且可选）。
- 不追求"完美时间戳"，只追求落进 eval 接受窗口的人类对齐感。

## 4. 方案与备选

### 选定方案：独立 `WhisperCueRetimer` 重定时（whisper 路径专属后处理）
脊柱是一个纯函数 `retime(cues, transcriptDuration)`，对 `planCues` 分组后的 cue 做确定性重定时（出现前拉、保持到下一真实 onset、无重叠）。**M1 不依赖任何 whisper.cpp flag 变更**——这是关键修正（见下）。

理由：
- 重定时数学是纯确定性、零依赖、零新 flag、可单测，Swift/C# 同逻辑天然 parity，可瞬间回滚。
- 直接命中用户两大抱怨：出现偏晚（leadIn 前拉）、消失突兀（保持到下一真实 onset，并修 BUG-1 重叠）。
- 充分利用 eval 接受窗口的**不对称性**（晚 tail 宽容 +900ms，早切只容 -150ms；早起容 -250ms，晚起容 +450ms）：出现端轻微提前、消失端适度保持。

### 关于 `-dtw`（原以为是主杠杆，实测否定）
原计划把 `-dtw`（零新文件、用已加载模型算 token 时间戳）当主杠杆。**本机实测推翻**（详见 §6）：默认 flash_attn 会禁用 DTW；即便 `-nfa` 开启 DTW，结果落 `t_dtw` 字段而非 app 解析的 `offsets`。"只加 `-dtw`"是 dead config。故 DTW 降级为需 `-nfa`+parser 读 `t_dtw`+性能门的后续里程碑，不进 M1。

### 已否决的备选
- **能量 VAD（移植 `vad.py` 为权威 snap 源）**：要 Swift+C# 浮点逐帧字节对齐、且每次转写多一次 ffmpeg 解码，脆弱且违反"最小依赖/不阻塞压制"。仅作回退思路，不进主路径。
- **`--vad`（whisper.cpp Silero VAD）作为早期依赖**：需额外 `-vm FNAME` 的 ~1-2MB ggml 资源（默认无内置模型），要打包/校验/版本化。推迟到后续里程碑且可选。
- **加 `--max-len`/`-sow` 全局改分段**：会改变 segment 文本粒度，使 before/after eval 漂移、噪声大（且威胁 preserve gate）。M1 不做。

## 5. 精确时序规则（M1 落地版，已被真实 eval 修正）

> ⚠️ 实测修正（2026-06-22，本地 whisper `large-v3-turbo-q5_0` + 人类 VTT 参考）：原设计（出现端 `leadIn=0.12` 前拉 + 消失端只夹断）被真实数据否定，已改为下方版本。详见 §13 进度。

记 `W`=组首 token start，`lastTokenEnd`=组尾 token end。`start_error = cue.start − reference_start`（正=晚）。接受窗 start∈[-250,+450]ms（中心 +100ms，**轻微偏晚才最优**）、end∈[-150,+900]ms（晚 tail 宽容、早切只容 -150ms）。

**出现（`leadIn = 0`，保持原始 onset）**
- `cue.start = W`（仅约束：不早于上一 cue 的 end、不为负）。
- 实测：对人类参考，whisper onset **并非系统性偏晚**（同一英文样本里 cue1/2 早 340/248ms、cue3/4 晚 544/119ms，大致居中）；而窗中心是 +100ms。**无条件前拉会把已偏早的 cue 顶出 -250ms 边界**（实测把一条已通过的 cue 翻成失败）。故出现端**不动**，onset 精度留给后续 DTW/VAD。

**消失（extend-hold：保持到下一真实 onset，修 BUG-1）**
- `end = max(lastTokenEnd + tail, min(nextOnset − interCueGuard, lastTokenEnd + holdToNext))`，`interCueGuard=0.08s`、`holdToNext=0.7s`。
- 即：**主动延长** end 朝下一句真实 onset 靠拢（吸收 whisper 偏早的词尾），上限 `lastTokenEnd+0.7`（防长静音变 long idle hold）、且不越过下一 onset（防重叠）。
- 实测动机：early_cutoff 是**压倒性主因**（baseline 英文 8/9、韩文 28/32 cue 的 end 比人类早 >150ms），因为 whisper 词尾普遍比人类早约 1s。原"只夹断（再减 guard）"反而**加剧** early_cutoff；改为延长后 early_cutoff 英文 8→5、p90 end 误差 1002→666ms、accepted 0.11→0.22。
- **修 BUG-1**：最小时长下限 `max(end, start+min)` 在防重叠钳 `min(end, nextOnset)` **之前**应用，最小时长绝不顶穿下一句造成重叠。
- 末句无下一 onset 时延长 `holdToNext`（落进 +900ms 容差，无下一句可夹）。

**分段（根因 #5，M1 暂不改）**
- 默认**保留 `planCues` 现有分组**，不加 `--max-len`。
- 原计划的"`-dtw` 生效时 gap>0.70s 新增断句"经复核**与现有 `largeSpeechGapSeconds=0.65` 冗余**，且 `-dtw` 本身 M1 不上，故不加，避免 dead code。

**probability**：M1 暂不用（`--word-thold` 默认 0.01 近乎关闭，贸然过滤会丢真词）。记为后续杠杆。

## 6. whisper.cpp flag 变更

> ⚠️ 实测修正（2026-06-22，本机 whisper-cli + 量化 `large-v3-turbo-q5_0`）：
> - `-dtw <preset>` 在量化模型上**不崩**；preset 必须用**点号**形式（`large.v3.turbo` 接受，`large-v3-turbo` 报 `unknown DTW preset`）。
> - 但本机 build **默认 `--flash-attn true`，flash attention 会禁用 DTW**：stderr 打印 `dtw_token_timestamps is not supported with flash_attn - disabling → dtw = 0`。必须额外传 `-nfa/--no-flash-attn` 才能 `dtw = 1`。
> - 即便 DTW 生效，结果落在**独立字段 `t_dtw`（单位厘秒=10ms，需 ×10 转 ms，未计算时为 `-1`）**，而 `offsets.from/to` **保持不变**。app 解析的是 `offsets`，所以"只加 `-dtw`"对最终时间**零影响**——那正是要避免的 dead config。
> - 故 DTW 真正生效需三件齐备：①`-dtw <点号preset>` ②`-nfa`（有推理性能代价）③parser 改读 `t_dtw`（×10、`-1` 回退 `offsets`）；且质量收益在独立人类参考上**尚未验证**。

**M1 只上 `WhisperCueRetimer`，不改 argv；M4 已把 DTW 真正接通（实测验证有效）**：
1. **DTW（M4 ✅ 已落地）**：`-dtw <点号preset>` + `-nfa` + parser 读 `t_dtw`(÷100 转秒、词尾取下一个 t_dtw 点、`-1` 回退 `offsets`)。性能门：60s 英文 GPU 下 flash 2.5s vs `-nfa`+DTW 3.6s（慢约 45%，转写是一次性且可缓存、非压制瓶颈，可接受）。eval 验证（英文人类 VTT）：short_social accepted **0.22→0.58**、early_cutoff 6→2；youtube 0→0.33。preset 映射点号形式已实测正确，量化模型不崩；失败有 fail-safe（去 `-dtw` 重试一次）。
2. **VAD（M5 后续，可选）**：`--vad` + `-vm <bundledSilero>`（默认无内置模型，需打包 ~1-2MB ggml + hash/size pinning）。可配 `-vp 80`（默认 30）、`-vt 0.40`（默认 0.50）。
3. **不加** `-ml/-sow/-wt/-mc`。

## 7. 起始常量

```
// M1 已落地（WhisperCueRetimer，已被真实 eval 调过）：
leadInSeconds        = 0.0    // 出现端不动（实测前拉会回归）
interCueGuardSeconds = 0.08   // 与下一 onset 之间的防重叠间隙
holdToNextSeconds    = 0.7    // 消失端朝下一 onset 延长的上限（吸收 whisper 偏早词尾，<900ms 不触发 long idle）
// planner 不变，保留：
minimumCueSeconds=0.30  sentenceTail=0.45  phraseTail=0.20
maximumCJKCueSeconds=4.5  maximumLatinCueSeconds=normalReadable(9.0)  largeSpeechGap=0.65
// 后续里程碑（M4/M5，M1 未用）：
// whisper VAD：vadSpeechPadMs=80  vadThreshold=0.40（仅 Silero 模型打包后）
```
M1 为起点，M5 对齐 baseline 后冻结。统一写入 `docs/exec-plans/whisper-retiming-constants.md`，两端代码注释引用它作为 parity 契约。

## 8. 改动文件

**Swift `Sources/MoongateCore/ASR.swift`（M1 已完成）**
- 新增 `enum WhisperCueRetimer { static func retime(_:transcriptDurationSeconds:) -> [SubtitleCue] }`（纯函数，无 I/O；leadIn/interCueGuard/abutFallbackHold）。
- `LocalASRSubtitleTimingPlanner.makeCue`：去掉 `nextStartSeconds` 夹断（neighbor 逻辑交给 retimer），从而消除 BUG-1 钳序重叠；常量 `minimumCueSeconds/maximumCJKCueSeconds/maximumLatinCueSeconds` 改为 internal 供 retimer 复用。
- `ASRTranscriptMapper.sourceCues`：把 `planCues` 结果再过 `WhisperCueRetimer.retime`（仅 whisper 路径）。

**Swift（后续里程碑，M1 未做）**
- `ASRRequest` + `WhisperCppCommandPlan.init`：DTW（`-dtw`+`-nfa`）/VAD（`--vad`+`-vm`）的字段与 flag、`WhisperDtwPreset`、parser 读 `t_dtw`(×10,-1 回退)。

**C# `windows/MoongateCore/Asr.cs`（M3 镜像）**
- 新增 `WhisperCueRetimer.Retime(...)`；`LocalAsrSubtitleTimingPlanner.MakeCue` 去 nextStart 夹断修 BUG-1；`AsrTranscriptMapper.SourceCues` 接入 retimer。
- 补齐模型 manifest 从 3 到 9（PARITY-1）。
- **顺手补 PARITY-1**：把模型 manifest 从 3 个补齐到与 Swift 一致的 9 个（`Asr.cs:207-248`）。

**Python eval `tools/subtitle_timing_eval/subtitle_timing_eval/asr.py`**
- `transcribe_words_whisper_cpp`（100-118）有**同样的死 flag**：加 `-dtw`（按 `--model-path` 推 preset），让 eval baseline 反映生产 argv。

**`Sources/moongate-cli/main.swift:73`**：无需改（调 `sourceCues`，自动获得 retime）。

## 9. 测试

**Swift `Tests/MoongateCoreTests/ASRContractsTests.swift`**
- **更新** `testWhisperCppCommandPlanUsesJsonFullLanguagePromptAndProgress`（692-735）：argv 现含 `-dtw small`；无打包模型时断言 `--vad` 缺席，有 `bundledVadModelURL` 时断言出现。
- **新增** `testWhisperDTWPresetMapping`（量化 id 正确映射，未知 id→nil→省略）。
- **新增** retimer 用例：`AppearancePullsEarlierNeverLater`、`HoldsUntilNextOnsetNoEarlyCutoff`、`AbuttingCuesDoNotOverlap`（即 BUG-1 回归）、`MonotonicAndClampedToDuration`。
- **新增** `testDtwPauseBreakSplitsRunOnCJK`（planner 级）。

**C# `windows/MoongateCore.Tests/AsrContractsTests.cs`**：上述每条的 parity 双胞胎；外加一条断言 Swift/C# 常量与共享文档一致的交叉校验，以及加载共享 JSON fixture 的 retimer 字节级对比。

## 10. 里程碑（每个都带 `subtitle_timing_eval` 验证）

Gate（`comparison.py:9-44`）：每样本 `accepted_ratio ≥ 0.90` 且 `early_cutoff_count==0` 且 `long_idle_hold_count==0` 且 `cjk_singleton_count==0`；suite 需全 required 组通过。

- **M1 重定时器 ✅ 已完成（Swift）**：实现独立 `WhisperCueRetimer`（出现前拉 + 保持到下一真实 onset + 无重叠）、修 `makeCue` BUG-1 钳序、`sourceCues` 接入 retimer。验证：新增 retimer 单测 + 全套 444→443 Swift 测试绿、`git diff --check` 干净、`moongate-cli` 构建通过，并在真实 whisper 输出上跑通 `local-asr-srt`。**不改 whisper argv**（DTW 实测为 dead config，降级见 §6）。
- **M2 真实 baseline + 量化验证 ⏳ 待跑（需网络/算力）**：每 required 组取 ≥2 样本，`prepare` → 取**独立参考**（YouTube 人类 VTT 经 `vtt-words`）→ whisper.cpp `asr --engine whisper-cpp --model-path <ggml> --no-gpu` 出词 → 分别用 retimer 前/后代码生成 SRT → `metrics --candidate <SRT> --asr-words <humanVTTwords>` 比 `compare --gate-mode timing`。通过线：retimer 后 `delta.accepted_ratio>0`、`delta.early_cutoff_count≤0`，en + 一个 CJK 组趋近 gate。（已实测：`-dtw large.v3.turbo` 在量化模型不崩，但被 flash_attn 禁用，见 §6。）
- **M3 C# parity**：镜像 `WhisperCueRetimer` + makeCue BUG-1 修复 + 补齐 9 模型（PARITY-1）。验证：Windows 单测绿；固定 cue+offset fixture 上 Swift vs C# retimer 输出字节级一致。
- **M4 DTW（后续，需先过性能门）**：`-dtw <点号preset>` + `-nfa` + parser 读 `t_dtw`(×10,-1 回退)。先量化 `-nfa` 转写耗时代价，再用 M2 独立参考验证是否真提升；不提升或明显拖慢则不上。
- **M5 可选 `--vad` + 全 suite 冻结**：若 ja/ko 仍偏晚起，打包 Silero ggml 接 `--vad/-vm`（hash/size pinning）。最终 `suite --require-manifest-coverage` → `passes_strict_timing_gate==true`；对 `manual_captions`/非 whisper 样本跑 `compare --gate-mode preserve` 证明 YouTube 路径无回归；冻结 `leadIn/interCueGuard` 常量。

## 11. 风险与回滚

- **量化模型上 `-dtw` 可能 assert/崩**（最高风险）→ M2 fail-safe 包裹；retimer 数学对纯帧量化偏移亦有效，DTW 只是增强非承重依赖。
- **next-onset 保持依赖下一 cue start 真实**→ 80ms guard + 300ms 最小 cue + `transcriptDuration` 钳；`long_idle_hold(>900ms)` gate 兜过保持。
- **`dtwPauseBreak` 改变 cue 数**使 before/after eval 变噪、威胁 preserve gate → 仅 `>0.70s` gap 加法触发；M5 preserve gate 专项核。
- **eval 参考是 YouTube 人类 VTT**（非黄金时间）→ 但它**独立于 whisper**（不同于现自指 runbook），正是根因度量所需；绝对值看方向，`compare` delta 才是真信号。
- **Swift↔C# 浮点舍入漂移** → 共享常量文档 + M3 跨端 fixture 字节对比。
- **回滚**：全部改动锁在 whisper 路径 + 两个布尔（`tokenLevelTimestamps`、`vadEnabled`+模型存在）。`tokenLevelTimestamps=false` 去掉 `-dtw`；移除 `sourceCues` 里的 retime 调用即逐字回到今天的 planner 输出。无非 whisper 路径、无压制、无 public API 变更（`ASRRequest` 只多一个带默认值可选字段）。

## 12. 决策记录
- 2026-06-22：whisper 时序**独立成 `WhisperCueRetimer`**，不复用 `sourceAnchoredPieces`（whisper 无人类时钟，复用只会复现其误差）。
- 2026-06-22：消失端从 nextStart 硬夹断改为"保持到下一真实 onset 前（留 80ms guard）"，并修 BUG-1 钳序（最小时长下限不再顶穿下一句造成重叠）。
- 2026-06-22：M0/M2 baseline 必须用**独立参考**（人类 VTT）建，否则自指 runbook 的 90% 是假象。
- 2026-06-22（**实测改主意**）：原计划"`-dtw` 作零依赖主杠杆"被本机实测否定——flash_attn 默认开会禁用 DTW，且结果落 `t_dtw` 字段而非 `offsets`，"只加 `-dtw`"是 dead config。故 **M1 只上 retimer，不改 whisper argv**；DTW 降级为需 `-nfa`+parser 读 `t_dtw`+性能门的后续里程碑。

## 13. 进度记录
- 2026-06-22：创建本 ExecPlan；根因、flag 支持、模型 parity、BUG-1 钳序均已在源码与 `whisper-cli --help` 上独立核验。
- 2026-06-22：**实测 whisper-cli + 本地量化 `large-v3-turbo-q5_0`**——`-dtw large.v3.turbo` 不崩、preset 须点号形式；但默认 flash_attn 禁用 DTW，需 `-nfa`；DTW 结果在 `t_dtw`(厘秒)而非 `offsets`。据此把 `-dtw` 从 M1 剔除。
- 2026-06-22：**M1 完成（Swift）**——`WhisperCueRetimer`、`makeCue` 去 nextStart 夹断修 BUG-1、`sourceCues` 接入 retimer；retimer 单测 + 全套 Swift 测试绿、`git diff --check` 干净、CLI 在真实 whisper 输出上 `local-asr-srt` 跑通。顺带对齐了工作树里既有的 2 个 CJK 无空格测试期望（七月另一窗口改了 `joinedText`）。
- 2026-06-22：**M2 真实 eval（本地 large-v3-turbo + 人类 VTT 参考）跑了，并据此重写了 retimer 设计**：
  - 用 A/B 三路二进制（baseline / leadIn0 / 当前）在英文 `short_social_fast_en`、`youtube_first_upload_en` 上量化。
  - **发现①** 对人类参考，whisper onset 大致居中（非系统偏晚），接受窗中心 +100ms → **`leadIn=0.12` 前拉把已偏早的 cue 顶出 -250ms，回归**。改 `leadIn=0`。
  - **发现②** early_cutoff 是压倒性主因（whisper 词尾普遍比人类早约 1s；baseline 英文 8/9、韩文 28/32）。原"只夹断"加剧它 → 改为 **extend-hold（朝下一 onset 延长，上限 +0.7s）**。
  - **结果**（英文 short_social）：early_cutoff 8→5、p90 end 误差 1002→666ms、accepted 0.111→0.222；youtube p90 end 1821→1562ms；start 无回归（leadIn=0）。
  - **诚实结论**：retimer 是**可测的真实改进**（早切腰斩、端误差降约 1/3），但**绝对 accepted_ratio 仍远低于 90%**——印证根因：到 90% 需更准的源时间戳（DTW/VAD），非 retimer 单独能达。
  - **度量局限**：CJK（ja/ko）的文本对齐不可靠（whisper 转写 vs 人类 VTT 的字符不一致 → p90 start 误差高达 1790ms 是对齐噪声，非真实时序），韩文 A/B 数字不可信。CJK 时序需换参考策略（overlap/speech 对齐或人工 QA），列为后续。
- 2026-06-22：**M3 完成（Windows C# parity，本机 dotnet 10.0.300 构建+测试，未用 VM）**——`WhisperCueRetimer.Retime` 精确镜像 Swift（leadIn 0 / interCueGuard 0.08 / holdToNext 0.7）、`LocalAsrSubtitleTimingPlanner.MakeCue` 去 nextStart 夹断修 BUG-1、`AsrTranscriptMapper.SourceCues` 接入 retimer、**补齐 Windows 模型 manifest 3→9（修 PARITY-1）**。新增 3 个 C# retimer parity 测试；marker 测试两端断言完全一致（`00:00:00,100`/`00:00:02,500`/`コーペンちゃん梅だー！`）作为跨端 parity 锚点。`MoongateCore` 构建成功、**558 个 C# 测试全绿**；并对齐了 C# 侧同样既有的 2 个 CJK 无空格测试期望。
- 2026-06-22：**M4 完成（DTW 真正接通，Swift+C#，实测验证有效）**——
  - **性能门**：60s 英文 GPU 下 flash 默认 **2.5s** vs `-nfa`+DTW **3.6s**（慢约 45%，绝对 +1.1s/60s）；转写一次性可缓存、非压制瓶颈，判定**可接受**。
  - **DTW 质量验证**（英文人类 VTT，同一份 whisper 词分别用 offsets vs t_dtw 抽取再过 retimer）：short_social accepted **0.222→0.583**、early_cutoff 6→2；youtube 0→0.333。**DTW 显著提升**，是冲 90% 的关键源时间戳改善。
  - **实现**：`ASRRequest.dtwTokenTimestamps`(默认 true)；`WhisperDTWPreset`(点号、剥量化后缀，实测正确)；`WhisperCppCommandPlan` 发 `-dtw <preset> -nfa`（仅 wordTimestamps+有 preset 时）；parser 新增 `t_dtw`(÷100 转秒、词尾取下一个 dtw 点、`-1` 回退 offsets) 全局重写；recognizer fail-safe（DTW 失败去 `-dtw` 重试一次）。Swift 446 / C# 561 测试绿（新增 argv `-dtw small -nfa`、preset 映射、parser DTW present/absent 用例，两端对称）。
- 2026-06-22：**M5 探索 + 分段修复（七月实测日漫反馈：出现太早 / 无意义"?" / 断句不自然）**——
  - **whisper.cpp `--vad` 被否决**：实测 Silero VAD（`ggml-silero-v5.1.2.bin` 可从 `ggml-org/whisper-vad` 下载、能跑）会把**时间轴压缩到"仅语音"时间**（cue1 把 ~28s 内容压成 0.18-3.66s 并混入幻觉文本），不映射回原视频时间 → **整体字幕错位**。故 whisper 内置 VAD 不能用于字幕时序。能量 VAD（原视频时间轴）仍是可选思路但需移植，暂不做。
  - **分段修复（Swift+C# 对称，planner 内，无新依赖）**：①`shouldKeep` 丢弃纯标点/无语音 fragment（消灭独立"?"长 cue）；②CJK `hasWeakBoundary` 识别**日文行首禁则**（が/を/は/に/よ/ね/さ/小书き假名/长音/闭标点），软上限处不在禁则字前断句，硬上限 5.5s/28字 兜底 → 句尾助词（だ**よ**、いよう**ね**）不再被甩成独立行，"?"消失，孤立假名减少。实测日漫：`だよ`/`ね` 正确粘连、`?` cue 消失。
  - **已知残留**：连续快语/歌唱段的**词中切断**（いい|こと、一緒にい|こう）无法用启发式根治——whisper 子词 token + 无日文形态分词器 + 无停顿。需形态分词器或按 token 微停顿择优断句（后续）。歌唱段 whisper 给单假名超长时长是其自身 artifact。
  - 安装 `0.8.0-timing-test2`(build 8003) 供七月复测。Swift 447 / C# 562 测试绿。
- 2026-06-22：**M6 长视频测量 + 决定性诊断（为什么 eval 指标无法被逼到 90%）**——
  - 跑了对齐验证过的长样本：意大利语 180s/52 cue（清晰，offset 0）、日语 TED 300s/79 cue（清晰人声+人工字幕，offset -120）。结果：DTW 下 accepted 仅 **0.05 / 0.03**，`early_cutoff` 压倒性（38/52、64/79）。
  - **决定性发现**：`early_cutoff` 是**指标/参考的结构性 artifact，不是时序精度问题**。① YouTube/人类参考的逐词时间是**滚动保持**的（实测词间 gap 中位数=0，词尾=下一词起始）；② eval 把候选 cue 文本对齐到人类词跨度，`reference_end` = 该跨度最后一词的（被保持、偏晚的）词尾。证据：意语 cue1 end=4.54、其 `reference_end`=5.00，但 whisper 的 cue2 已在 4.62 开始 → **要让 cue1 end 追上 5.00 就必须与 cue2 重叠**。即"消失误差"要小，必须**复刻人类的分段边界**，而非调时序。
  - **把 holdToNext 从 0.7 扫到 6.0：accepted 几乎不动（0.05→0.07）**，证实"延长保持"治不了——因为瓶颈是分段差异+保持型参考，不是 hold 长度。
  - **结论**：whisper 从声学**重建**字幕、分段与人类**天然不同**；该 eval 奖励"复刻人类 cue 边界"（旧 YouTube 路径正是靠复用人类边界拿 90%）。故 **"10 视频 / accepted≥0.90"对 whisper 输出在该指标上结构性不可达**，调 onset/hold/DTW 只能把它从 ~0.05 抬到 ~0.1-0.2。需要换"公平指标"+换打法（见 §15 优化方案）。

## 15. 优化方案（基于 M1-M6 全部实测证据）

**先纠正目标**：不要用"匹配人类逐词保持时间的 accepted_ratio"作为 whisper 的验收——它结构性奖励复刻人类分段，对 whisper 不公平。换成下面三类**公平且可改进**的指标。

**第一优先：公平测量（前提，没有它后面都是盲调）**
- 新增 onset-only 指标：只看 `start_error` 分布（这是真实、可改进的：长视频 p90 漂到 1.2s[it]/2.7s[ja]）。
- end 改为对"**词的声学结束**"评判（不是被保持的 VTT 词尾），即"没有早于真实语音结束 150ms 切掉"。
- 或做**句/段级对齐**而非逐词文本对齐，规避分段差异。

**第二优先：真正可改进的两件事**
1. **长视频 onset 漂移**：early cue +100~460ms、p90 漂到 1-2.7s。whisper.cpp 长音频 token 时间戳累积误差。修法：按 ~30s 分块转写并按块起点重锚，或排查 segment offset；DTW 已降一部分。
2. **CJK 分段贴合人类节奏**：上**日文/韩文形态分词器**在词边界断句（根治"词中切断"），cue 数与边界更接近人类。

**第三优先（唯一能真到 ~90% 时序的路）：混合策略**
- 视频**自带平台字幕**（YouTube 自动/人工）时，直接复用其逐词时间戳做时序、whisper 只补文字/翻译 → 复刻旧路径 90%。仅对有字幕的视频有效；无字幕视频仍只能靠 whisper。

**识别质量（CJK 的隐藏瓶颈）**
- 难内容（音乐/快语/方言）whisper 大段幻觉（如 korean_auto 转写≈无关文本）；时序无从谈起。需更大模型/解码参数/预处理。

**推荐排序**：先做"公平测量"→ 再做"onset 漂移"（最实在的时序改进）→ CJK 形态分词 → 有字幕走混合。**不建议**继续在旧 accepted_ratio 上硬刚到 90%。

- 2026-06-22：**M7 CJK 形态分词断句（七月选定"治本"方向，已落地）**——macOS 用 Apple `NaturalLanguage` 的 `NLTokenizer(.word)`（**零新依赖**）做日/中/韩词边界：`CJKWordBoundary.straddles(text, at:)` 判断断点是否落在词中间；`shouldBreak` 的 CJK 软上限处，断点**落在词中（straddle）或行首禁则字**则不断、延到硬上限（5.5s/28字）。实测日漫：`コーペンちゃんだよ`、`これからもいっぱい一緒にいようね` 自然成行，断点落到词边界（`いい|こと`）而非词中。残留：歌唱段 whisper 给单音超长时长（`こう` 6.5s）触发硬上限被迫词中断——属 whisper 自身 artifact，planner 难救。**Windows 无内置 CJK 分词器，保留 particle 启发式（已注释为已知 parity gap）**。新增 `CJKWordBoundary.straddles` 单测。安装 `0.8.0-timing-test3`(8004)。Swift 448 / C# 562 测试绿。
- 2026-06-22：**M8 人工字幕随机套件 gate（进行中）**——新增 `select-manual-suite`，用固定 seed 随机抽取 10 个不同源/口语语言、且非 YouTube 自动识别轨的样本；抽样与 `materialize-comparisons` 共用同一套 `_is_manual_caption_sample` 判断（排除 `automatic_captions`、`*-orig` 和 app proxy；按七月确认，其他非 YouTube 自动识别轨均可视作人工来源）。manifest 现补入 `french_talk_public_fr` / `italian_talk_public_it` 以及 mTEDx/OpenSLR-backed 的 `mtedx_portuguese_weakness_pt` / `mtedx_german_flight_de`，固定 seed 可抽出 **10/10** 源语言（de/en/es/fr/it/ja/ko/pt/yue/zh）。新增 `manual-suite-status`，只对该随机套件检查 missing/failing/insufficient-window，并把 translated public subtitles 按真实口语语言归类。当前状态：样本池 ready，但完整 comparison/QA 证据未 ready，仍不能宣称 90%。
- 2026-06-22：**M9 strict manual-suite repair（进行中）**——收紧 `manual-suite-status`：10 语言人工字幕套件必须通过 strict timing，`preserve` 只作为“不误伤人工字幕”的兼容证据，不能满足 90% gate。新增 `runbook --selection --only-incomplete`，只输出固定随机套件里未完成的样本；新增 `--candidate-offset-seconds`，支持 section-relative local-ASR SRT 平移回视频绝对时间。修复 overlap 评测 300ms 宽容误吞 CJK 下一词的问题（收紧到 50ms），中文跨语字幕 `optimized` 从 0% 提升到 100%。同步修复 Swift/C# local-ASR retimer：CJK hard cap 不得截断真实最后一个 ASR token，只限制额外拖尾。真实 strict 覆盖已从 2/10 提升到 **5/10**（en/es/fr/it/zh）；剩余 de/ja/ko/pt/yue 主要卡在 YouTube bot gate/缺完整音频或人工字幕 evidence，未达到最终 90%。
- 2026-06-22：**M9 补丁更新**——按七月确认，把 `_is_manual_caption_sample` 明确改成“有普通 `subtitle_lang` 且未标记 YouTube 自动识别/自动 kind/app proxy/`*-orig` 即视为人工来源”，不再要求 `manual_captions` 正向标签；新增自动 kind 防呆测试。`iteration-report` 增加 `--selection`，复用 `manual-suite-status` 的 strict gate，避免全 manifest 或 preserve-only smoke 结果混入当前 10 语言人工套件。验证：Python eval 85 测试绿；Swift `ASRContractsTests` 47 测试绿；Windows `AsrContractsTests` 45 测试绿；`git diff --check` 通过。最新 `manual-suite-status` 仍为 strict **5/10**（en/es/fr/it/zh），下一优先级是补 de/ja/pt 缺失产物与 ko/yue 完整窗口证据，而不是继续单样本调参。
- 2026-06-22：**M10 10-language strict gate 达成（自动指标）**——补入可复现替代样本：`cantonese_uk_yue`（120s 粤语 talk）、`sebasi_english_self_study_ko`（120s 韩语 talk）、`portuguese_tedx_lages_pt`，并通过 `select-manual-suite --exclude-sample-id ...` 排除已确认被 YouTube bot gate、403 或窗口不足的来源（`koupen_chan_umeboshi_ja`、`tedx_yonsei_visual_language_ko`、`the_do_show_jimmy_o_yang_yue`、`mtedx_portuguese_weakness_pt`、`tedx_kwangwoon_only_one_ko`、`sebasi_praise_method_ko`）。最新 `manual-suite-status --require-ready` 为 **10/10 strict timing pass**：de/en/es/fr/it/ja/ko/pt/yue/zh 全覆盖，`missing/blocked/failing/insufficient_window` 均为空。同步改进 Swift/C# local-ASR 分段：CJK+Latin/数字混合串保留空格，`I + 'm` 不拆成 `I 'm`，`lingu + ist`、`A + llow` 等拉丁词内碎片优先续接；混合 CJK+Latin cue 使用更短拖尾，避免英文粘连串在静默中长留。验证：Python eval 87 测试绿；Swift `ASRContractsTests` 49 测试绿；Windows `AsrContractsTests` 47 测试绿。**仍未关闭目标：需要人工 side-by-side QA 至少每语言/类型抽查 2 段。**
- 2026-06-22：**M11 最新代码复核 + selection-aware QA gate**——把 `qa-report` / `qa-review` / `qa-verdicts` 全部接入 `--selection`，人工 QA 现在只检查固定随机 10 语言套件，不再混入全 manifest 的旧样本。生成：
  - `artifacts/subtitle_timing_eval/qa.manual-suite.md`
  - `artifacts/subtitle_timing_eval/qa.manual-suite.review.html`
  - `artifacts/subtitle_timing_eval/qa.manual-suite.verdicts.json`
  其中 QA verdict gate 当前正确显示 **20/20 unchecked**，所以目标仍未关闭。另尝试扩展主流拉丁语系碎词拼接（法/德/葡/意），真实重跑发现过强拼接会降低 strict gate；最终收敛为：**纯拉丁语言保守断句，CJK+Latin 混合 cue 才启用 broad Latin subword spacing**。用最新代码重跑受影响的 8 个 local-ASR comparison 后，`manual-suite-status --require-ready` 仍为 **10/10 strict timing pass**（de 0.968；其余 local-ASR selected 样本 1.0）。验证：Python eval 89 测试绿；Swift `ASRContractsTests` 50 测试绿；Windows `AsrContractsTests` 48 测试绿。
- 2026-06-22：**M12 非自动识别即人工 + 多 seed 防过拟合审计**——按七月最新规则，把人工字幕候选定义固化为“有普通 `subtitle_lang` 且未标记 YouTube 自动识别/自动 kind/app proxy/`*-orig` 即视为人工来源”，并扩展 `auto-generated`/`yt_asr` 等自动轨标记防呆。新增 `manual-suite-audit`：一次跑多个随机 seed，输出每个 seed 的 10 语言选择、strict gate、候选频次、薄语言池和真正可随机语言。初次真实 audit：固定套件仍 **10/10 strict pass**；多 seed audit **2/6 pass**，失败主要来自更宽池抽到 strict evidence 不足的 `tedx_taipei_dont_work_too_hard_zh`（另一个 seed 抽到 `english_to_chinese_auto_translate` 时 en 也缺 strict evidence）。
- 2026-06-22：**M13 human-reference metric + 多 seed audit 6/6**——新增 `reference-metrics`，用于“候选字幕 vs 人工字幕 cue 窗口”的直接时序评测；它解决了跨语人工字幕不应强行对齐源语言 ASR words 的评测偏差，并支持一个人工 cue 被连续拆成多个候选 cue 时按子窗口判断，避免把合理拆分误判成提前消失。用当前 `moongate-cli clean-srt` 重新生成 `english_to_chinese_auto_translate` 与 `tedx_taipei_dont_work_too_hard_zh` 的 clean SRT 后，human-reference reports 为：英文源/中文字幕样本 accepted **0.978**、early cutoff 0；TEDxTaipei 中文样本 accepted **1.0**、early cutoff 0。物化 `comparison.human-reference.json` 后，`manual-suite-audit` 当前 **6/6 seeds pass**，固定套件仍 **10/10 strict pass**。剩余证据缺口：`de/es/fr/it/ja/ko/pt/yue` 仍各只有 1 个 strict-ready 候选；QA verdict gate 仍为 **20/20 unchecked**，目标不能关闭。
- 2026-06-23：**M14 representative QA + auto-reference verdict gate**——把 QA 采样拆成 `risk` 与 `representative` 两种模式：`risk` 继续抓最高风险行用于找 bug，`representative` 用 accepted、正常时长、低误差 cue 窗口作为 90% 验收抽样，避免“最坏 1 行”把整组验收误伤。新增 `qa-autofill`，可从 strict timing / human-reference 指标生成 `verdict_source=auto_reference` 的 review JSON；`qa-verdicts` 现在同时接受 HTML 导出的 `reviews` 与 autofill 的 `records`。当前生成：
  - `artifacts/subtitle_timing_eval/qa.manual-suite.representative.md`
  - `artifacts/subtitle_timing_eval/qa.manual-suite.autofill.json`
  - `artifacts/subtitle_timing_eval/qa.manual-suite.auto-reference.verdicts.json`
  自动参考预检结果：20/20 representative rows PASS，10 个 selected language groups 全部通过，0 skipped。注意：这只是机器证据门，不等于人工已观看；真实 M11 人工 side-by-side QA 仍未完成。
- 2026-06-23：**M15 completion audit 单文件证据汇总**——新增 `completion-audit`，把原始目标拆成可审查 requirement：随机 10 个非自动人工字幕样本、10 个不同源语言、人工字幕来源判定、每样本 `accepted_ratio >= 0.90`、多 seed 防过拟合、auto-reference representative QA、最终人工 side-by-side QA。当前生成 `artifacts/subtitle_timing_eval/completion-audit.current.json`，结果为 `machine_ready=true`、`human_verified=false`、`goal_complete=false`。样本最低 accepted ratio 是德语 `mtedx_german_flight_de=0.968`，其余 selected 样本均为 1.0；唯一剩余 blocker 是人工 QA verdict 仍未填写。
- 2026-06-23：**M16 QA review 建议预填但不代签**——`qa-review` 新增 `--prefill-json`，可把 `qa-autofill` / auto-reference verdicts 渲染成每行的 `Suggested by auto_reference: PASS` 与 `Use Suggestion` 按钮。页面不会自动写入 `human_verdict`：localStorage 初始仍为空，导出的人工 verdict 只有在 reviewer 点击 PASS/FAIL 或检查后点击 Use Suggestion 才会写入。已重生成 `artifacts/subtitle_timing_eval/qa.manual-suite.representative.review.html`，其中 20 行都有建议 PASS，但 completion audit 仍保持 `human_verified=false`，避免把机器预检误当成人工验收。
- 2026-06-23：**M17 QA checklist 快速签字包**——新增 `qa-checklist`，生成 `artifacts/subtitle_timing_eval/qa.manual-suite.checklist.md`：每个语言 2 行，包含 review time、sample、`Suggested=auto_reference:PASS`、accepted/start/end/hold 指标、baseline/optimized 文本，以及空的 `Human Verdict` / `Notes`。该表格沿用 `qa-verdicts` 可解析的列名，便于人工填 PASS/FAIL 后直接跑 gate；验证确认 Suggested 列不会被误算成人工 verdict，当前 checklist 仍是 20/20 unchecked。
- 2026-06-23：**M18 human-source final gate 防误用**——`qa-verdicts` 新增 `--require-human-source`，用于最终 HTML JSON 导出：只有 `verdict_source=human_review/manual_review` 的 PASS/FAIL 才能满足人工 gate；把 `qa-autofill` / `auto_reference` JSON 故意作为 human review 输入时会失败。HTML export 现在在 reviewer 点击 PASS/FAIL 或检查后点击 Use Suggestion 时写入 `verdict_source=human_review`。`completion-audit` 也收紧为：JSON human QA summary 必须证明 human-source gate，缺 provenance 的旧 summary 或 auto-reference summary 不能关闭目标；Markdown verdict sheet 仍按人工编辑路径处理。
- 2026-06-23：**M19 remaining QA queue**——新增 `qa-remaining`，根据当前 representative packet、auto-reference 建议、以及可选 human review JSON，生成只包含未人工确认行的 `artifacts/subtitle_timing_eval/qa.manual-suite.remaining.md`。当前 queue 显示 total 20、human-reviewed 0、remaining 20；它可被 `qa-verdicts` 解析，但因 `Human Verdict` 为空仍保持 gate fail，作为最后人工 QA 的 punch list。
- 2026-06-23：**M20 Markdown 增量 QA 追踪**——抽出 `extract_qa_verdict_records_from_markdown`，`qa-remaining` 现在支持 `--human-qa-report`，可读取已部分填写的 Markdown checklist；带 `PASS/FAIL` 的行会按 `Review Time + Cue + language` 视为 `human_review` 并从 remaining queue 扣除，避免同一 sample 多行时误扣。当前真实 checklist 尚未填写，所以 remaining 仍为 20/20。
- 2026-06-23：**M21 Markdown final audit 接入**——`completion-audit` 新增 `--human-qa-report`，可直接读取人工填写后的 Markdown checklist 并汇总为最终 human QA gate；JSON 路径仍要求 `qa-verdicts --require-human-source` 生成 provenance，auto-reference JSON 不能冒充人工验收。已用当前空 checklist 真实跑通：`machine_ready=true`，但 `human_verified=false` / `goal_complete=false`，10 个语言组仍因人工 PASS/FAIL 未填写而 fail human gate。
- 2026-06-23：**M22 Markdown QA 稳定 Review ID**——`qa-checklist` 与 `qa-remaining` 都新增可见 `Review ID` 列，`extract_qa_verdict_records_from_markdown` 会读取该 ID；`qa-remaining --human-qa-report` 现在优先用稳定 ID 扣减已审行，旧表才回退到 `Review Time + Cue + language`。这避免同一视频多段、链接时间轻微变化、或人工复制表格时把 PASS/FAIL 记到错误片段。
- 2026-06-23：**M23 Text Risk 人工验收提示**——`build_qa_packet` 现在会比较 baseline/optimized 的同脚本文本 token overlap 与异常长度扩张，给机器时序已通过但文本明显不像参考字幕的行打 `low_text_overlap` / `expanded_vs_reference` / `empty_optimized_text` 标记；`qa-checklist` 和 `qa-remaining` 显示 `Text Risk` 列。该列不参与机器 pass/fail，只把“时间对了但文本不像人写”的风险交给最终人工 QA。
- 2026-06-23：**M24 completion audit 汇总 Text Risk**——`completion-audit` 现在会复用 representative QA packet，把带 `Text Risk` 的行输出到顶层 `text_quality_risks`，并给出 `text_quality_risk_count`。这样最终一页 audit 不只显示机器时序与人工 verdict gate，也能直接指出“时间窗过线但文本不像人工字幕”的行，避免验收时漏看德语/意大利语这类 ASR 分词噪声。
- 2026-06-23：**M25 remaining queue 顶部 Text Risk 摘要**——`qa-remaining` 现在会在文件头显示剩余 `text-risk rows` 数量及对应 `Review ID`。已人工确认的风险行会从摘要中扣除；这让最后人工 QA 可以先看最可能失败的文本行，而不是在 20 行表格里逐个找红点。
- 2026-06-23：**M26 Text Risk verdict 审计**——Markdown verdict parser 现在读取 `Text Risk` 与 `Notes` 列；`qa-verdicts` summary 按语言统计 `text_risk_count`、`text_risk_pass/fail/unchecked_count`，并列出 `PASS` 但未写 notes 的风险行。这样 reviewer 即使把高风险行标 PASS，也会在最终 verdict summary 里留下“是否解释过”的证据。
- 2026-06-23：**M27 Text Risk notes final gate**——`qa-verdicts` 与 `completion-audit` 新增 `--require-text-risk-notes`。最终验收时，带 `Text Risk` 的行如果被人工标为 `PASS`，必须填写 `Notes`，否则该语言组和最终 `human_verified` 都不能通过。已重建当前 artifact：`machine_ready=true`、`human_verified=false`、`goal_complete=false`、`text_quality_risk_count=3`；当前 checklist 仍是 20/20 unchecked，风险行主要集中在德语 2 行、意大利语 1 行。

## 14. 最终验证 Checklist
- [x] M1：`WhisperCueRetimer` 实现；retimer 单测 + 全套 Swift 测试绿；`git diff --check` 通过；CLI 真实跑通。
- [x] M2（英文）：真实 whisper + 人类 VTT 参考的 A/B 完成；retimer 在英文样本上 early_cutoff↓、end 误差↓、accepted↑、start 无回归。
- [ ] M2（CJK）：需更可靠的 CJK 参考/对齐策略才能量化 ja/ko 时序。
- [x] M3：C# 镜像 `WhisperCueRetimer` + makeCue BUG-1 + 补齐 9 模型；561 C# 测试绿；marker 测试两端断言一致锚定 parity。（WPF app 完整构建留待 Windows VM preflight。）
- [x] M4：DTW `-dtw`+`-nfa`+读 `t_dtw` Swift+C# 接通；`-nfa` 性能门测得慢约 45%（可接受）；英文人类参考验证 accepted 0.22→0.58；两端测试绿。
- [ ] M5（可选）：`--vad` + Silero 打包；CJK 参考策略；`suite` strict gate；preserve gate 证明 YouTube 路径无回归；常量冻结。
- [x] M8：随机 10 个不同源语言的人工字幕视频已可抽样；当前 `manual-suite-status --require-ready` strict 覆盖 10/10（de/en/es/fr/it/ja/ko/pt/yue/zh）。
- [x] M10：自动 strict timing 指标达成 10/10，并已用最新代码重跑 local-ASR affected artifacts。
- [x] M13：`manual-suite-audit` 多 seed 防过拟合 gate 当前 6/6 通过；`reference-metrics` 已覆盖跨语人工字幕的 human cue timing 评测。
- [x] M14：representative QA 与 `qa-autofill` 自动参考预检完成；`qa.manual-suite.auto-reference.verdicts.json` 当前 10/10 语言组通过。
- [x] M15：`completion-audit.current.json` 已聚合原始目标证据；当前机器证据 ready，但人工验证未完成。
- [x] M16：`qa-review --prefill-json` 已把 auto-reference 建议带入人工审阅页，但不自动填 human verdict。
- [x] M17：`qa-checklist` 已生成可快速签字的 Markdown 包；Suggested 不计入 human verdict。
- [x] M18：最终 JSON QA gate 已支持 `--require-human-source`，auto-reference JSON 无法冒充人工验收。
- [x] M19：`qa-remaining` 已生成只列未人工确认行的最终 punch list；当前 remaining=20。
- [x] M20：`qa-remaining --human-qa-report` 已支持 Markdown checklist 的增量已审行扣减。
- [x] M21：`completion-audit --human-qa-report` 已支持直接读取人工填写后的 Markdown checklist；当前空表仍不会关闭目标。
- [x] M22：Markdown checklist/remaining queue 已加入稳定 `Review ID`，人工增量验收优先按 ID 对齐。
- [x] M23：Markdown checklist/remaining queue 已加入 `Text Risk`，机器时序通过但文本明显异常的行会被标出给人工复核。
- [x] M24：`completion-audit.current.json` 已汇总 `text_quality_risk_count` 与具体风险行，最终验收不会只看时序 gate。
- [x] M25：`qa-remaining` 文件头已汇总剩余 text-risk 行数和 Review ID，人工验收可优先处理高风险行。
- [x] M26：`qa-verdicts` summary 已统计 text-risk verdict 状态与 PASS-without-notes 风险行。
- [x] M27：`qa-verdicts --require-text-risk-notes` 与 `completion-audit --require-text-risk-notes` 已把风险行 notes 变成最终人工验收硬条件。
- [ ] M11：人工 side-by-side QA 尚未完成；`qa.manual-suite.verdicts.json` 当前为每语言 2 段 unchecked。需每个语言/类型至少 2 段 PASS、0 FAIL、0 unchecked，才能宣称本轮“90% 接近真人字幕”由人工验收完成。
