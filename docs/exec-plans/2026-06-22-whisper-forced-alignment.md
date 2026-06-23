# ExecPlan — Whisper 强制对齐（WhisperX / wav2vec2 路线）

日期：2026-06-22 · 分支：`codex/v0.8-local-asr` · 状态：**已搁置**（P0 两轮离线验证否决：forced-align 只对拉丁语系大胜、对日韩主力内容打不过 whisper 自带 DTW；详 §11/§12。保留本文档供日后若拉丁需求出现时复用）

## 1. 背景与产品意图

Whisper 识别率业界最强，但**词级时间是转写模型的事后启发式**（cross-attention/DTW，30s 窗口），会漂移——这是它时序不如 CTC/强制对齐型 ASR 的固有代价（vanilla Whisper 词时间误差约 ±500ms，wav2vec2 强制对齐约 ±50ms）。

我们已经把"不换识别引擎"能做的都做了：`WhisperCueRetimer`（extend-hold 削早切）、接通 `-dtw`（DTW 是 whisper 自带的对齐头方案，short_social accepted 0.22→0.58）、CJK 形态分词分段、M8 LLM 句子级重断句。**剩下的天花板是源头词时间本身的漂移**，要再上一个台阶必须给 whisper 外挂一个独立的声学对齐器：拿 whisper 的文字 + 原音频，用一个 CTC 声学模型逐帧把文字"钉"回音频。这就是 WhisperX 的做法。

目标产出：whisper 词级时间误差从 ~±500ms 降到 ~±100ms，让出现/消失时机接近人工字幕，而不牺牲识别率。

## 2. 当前仓库理解（已核到行）

- **音频已就绪**：`ASR.swift:1146-1167` ffmpeg 抽成 16kHz 单声道 `pcm_s16le` WAV（强制对齐所需格式，无需改）。
- **转写产物**：`ASRWord{ text, startSeconds, endSeconds, probability? }`（`ASR.swift:136-147`），`ASRTranscript.words: [ASRWord]`（`:150-186`）。
- **插入点**：`recognizer.transcribe(...)` 返回后、`LocalASRSubtitleTimingPlanner.planCues`（`:828-880`）之前——即 `ASR.swift` 转写完成那一处（~`:1334`）。新增一个对齐 pass：输入 `request.audioURL` + `transcript`，输出**改写过 start/end 的 `[ASRWord]`**，下游 planner/retimer 不变。结构与现有 `applyDTWTiming`（`:1770-1802`）同型。
- **模型/二进制分发（关键，已成熟可复用）**：
  - 模型目录 `{supportDir}/asr/models/`，manifest `ASRModelManifest.recommendedWhisperCpp`（`:319-419`）模式：`id / fileName / downloadURL / sizeBytes / sha256`。
  - 运行时定位 `ASRRuntimeLocator`（`:2244-2377`）：先查 `asr-runtime-manifest.json`（platform/arch/version/executableRelativePath/sha256），再查 PATH；搜索目录含 `{supportDir}/asr/runtime/bin` 与 app bundle 内 `asr/runtime/bin`。
  - Windows：`%APPDATA%\Moongate\`，`AsrModelManifest.RecommendedWhisperCpp`（`Asr.cs:213-326`，与 macOS 同 URL/sha），`DependencyManager`（`:36-353`）已管理 `yt-dlp/ffmpeg/ffprobe/deno` 的下载+sha 校验（whisper-cli 不在其中，单独管理）。
- **跨平台对称**：Swift `ASR.swift` ↔ C# `Asr.cs` 手工镜像，模型 manifest、planner 阈值、DTW 开关一一对应；唯一既有 gap：macOS 用 `NaturalLanguage` 分词、Windows 用启发式（已注释）。
- **设置位**：`Settings.swift:75-82` `localASREnabled/RuntimePath/ModelPath/ModelID`；C# `Settings.cs:126-132` 同。新对齐开关挂这里。

## 3. 目标与非目标

**目标**
- 给本地 whisper 增加**可选**的强制对齐 pass，把词级 start/end 误差降到 ~±100ms。
- 贴合现有原生分发（不引入 Python/torch 运行时到交付产物）。
- 跨平台对称（macOS Swift + Windows C#），可灰度（开关 + 模型按需下载），失败回退 DTW。
- 用 `tools/subtitle_timing_eval` 量化（词时间误差 + accepted_ratio）。

**非目标**
- 不替换识别模型（不引入 CrisperWhisper 等替换 whisper 本身——那是另一条权衡，会动识别率）。
- 不改 planner/retimer/重断句（它们消费更准的词时间即可）。
- 第一阶段不追求覆盖所有语言；不做说话人分离（diarization）。

## 4. 方案与备选

### 推荐方案：自带 ONNX Runtime + 自实现 CTC 强制对齐（WhisperX 算法的原生版）

理由：Moongate 是已签名的原生消费级 App（.app / .exe + 受管依赖）。给终端用户塞 Python+torch（GB 级、签名/sandbox 脆弱）不可接受。sherpa-onnx 暂无现成强制对齐 API（[k2-fsa#3536](https://github.com/k2-fsa/sherpa-onnx/issues/3536)），所以走 ONNX Runtime 自己跑声学模型 + 自己实现 Viterbi 对齐——算法是 torchaudio `forced_align` 的公开方法，约 150 行、确定性、可单测。

对齐 pass 步骤：
1. 复用 16kHz 单声道 WAV（`request.audioURL`）。
2. ONNX Runtime 跑 wav2vec2/MMS CTC 声学模型 → 帧级发射 log-probs（T 帧 × V 词表，wav2vec2 帧步 ~20ms）。
3. 把 whisper 文字切成模型 CTC 词表单元（拉丁=字符/字母；**CJK=罗马化后单元**，见风险）。
4. Viterbi 强制对齐：在发射矩阵上求文字 token（含 blank）的单调最优路径，回溯得每 token 帧区间 → 每词 start/end。
5. 用对齐时间改写 `ASRWord.start/end`，喂给现有 planner。

引擎：
- macOS：onnxruntime C/Obj-C（SwiftPM binary target 或 bundle dylib，仿现有 `asr/runtime/bin`），可选 CoreML EP 提速。
- Windows：`Microsoft.ML.OnnxRuntime` NuGet（原生 dll 进 bin），可选 DirectML EP。

模型：**MMS-FA**（torchaudio `MMS_FA`，基于 facebook/mms wav2vec2，覆盖 1000+ 语言含 ja/ko/zh），导出 ONNX（fp32 ~300MB / int8 ~150MB）。**按需下载、默认不装**，新增 `AlignmentModelManifest`（并行 `ASRModelManifest`），存 `{supportDir}/asr/alignment-models/`。

### 备选 A：Python sidecar（WhisperX / torchaudio）
最快出效果、±50ms、模型现成。但交付产物要捆 Python+torch（≥2GB、跨平台打包/签名脆弱）。**仅作 P0 离线验证工具，不进产品**。

### 备选 B：每语言专用 CTC 模型（原生词表，免罗马化）
日文用输出假名/汉字的 wav2vec2-CTC、中文用拼音/汉字 CTC 等。免 uroman，但要分发多个模型、各语言质量参差。作为 CJK 的退路。

### 备选 C：维持 DTW + 继续启发式
零新依赖，但已接近天花板，达不到 ±100ms 目标。作为对齐失败时的回退路径（保留）。

## 5. CJK 难点（必须正视，决定排期）

MMS-FA 等多语对齐模型对**非拉丁文要先罗马化**（uroman 把文字转成拉丁音素近似），对齐后再按 token span 映回原字符。这恰好砸在你的痛点语言上：
- **日文**：假名→罗马字是确定性小表（原生 Swift/C# 即可）；但**汉字读音上下文相关**，需形态分析/词典（MeCab 级）——macOS 的 `NaturalLanguage` 不稳定给读音。
- **韩文**：谚文罗马化规则化，可原生实现。
- **中文**：汉字→拼音需字典（多音字靠上下文），体量更大。

退路：用**备选 B 的 CJK 原生词表 CTC 模型**绕开罗马化。哪条路可行必须先用 P0 离线 spike 实测，再决定 CJK 怎么落。

## 6. 里程碑与验证

- **P0 — 离线可行性 spike（不进产品，dev/Python 允许）**：导出 MMS-FA→ONNX；对 `tools/subtitle_timing_eval` 现有样本（英文 + 日漫 koupen_chan + 韩 TED）跑 Viterbi 对齐，量词时间误差 vs 人工 VTT。**门槛：拉丁 ≤±100ms、且至少一条 CJK 路径（MMS-FA+罗马化 或 CJK 原生 CTC）≤±150ms**。否则停，不做原生集成。
- **P1 — 原生集成（macOS，拉丁语先行）**：接 onnxruntime、Swift 实现 Viterbi、接插入点、加开关+按需下载+失败回退 DTW；eval gate。证明端到端时序提升。
- **P2 — CJK（日文优先）**：按 P0 结论落罗马化或 CJK 模型，在 koupen_chan 等样本 eval。
- **P3 — Windows C# 对等**：`Microsoft.ML.OnnxRuntime` 镜像，补测试，保持 parity。
- **P4 — UX/打磨**：设置开关、模型下载进度、长音频分段对齐进度、对齐失败静默回退 DTW、文档。

验证手段：扩 `tools/subtitle_timing_eval` 增"词时间误差"指标（mean/p90 |Δstart|、|Δend| vs 人工逐词 VTT）；目标对齐后 ≤±100ms（DTW 基线 ~±500ms）；同时跑既有 accepted_ratio。Swift `swift test --scratch-path "$HOME/Library/Caches/vdl-build"`、C# `dotnet test`。

## 7. 预计改动文件

- `Sources/MoongateCore/ASR.swift`：新增 `ForcedAligner`（ONNX 推理 + Viterbi）、对齐 pass 插入（~`:1334`）、`AlignmentModelManifest`、对齐模型下载/定位（仿 `ASRModelManifest`/`ASRRuntimeLocator`）。
- `Sources/MoongateCore/Settings.swift`：`localASRForcedAlignmentEnabled`（默认 off）+ 对齐模型 id/path。
- `Sources/Moongate/SettingsView.swift`：开关 + 模型下载入口/进度。
- `windows/MoongateCore/Asr.cs` + `Settings.cs` + 设置 UI：C# 对等镜像。
- `tools/subtitle_timing_eval/*`：词时间误差指标 + P0 spike 脚本（dev-only）。
- 新增 onnxruntime 依赖：SwiftPM binary target（macOS）/ NuGet（Windows）+ 运行时 manifest 项。
- 测试：Viterbi 对齐确定性单测（合成发射矩阵 → 已知 span）、罗马化映射单测、manifest/下载单测，Swift+C# 双端。

## 8. 风险与回滚

- **CJK 罗马化映射**（最大未知）→ P0 先验，不行走备选 B（CJK 原生 CTC 模型）。
- **onnxruntime 二进制体积/各 platform-arch 打包签名** → 仿现有 runtime manifest；macOS bundle、Windows 受管下载。
- **模型体积下载摩擦** → 默认不装、按需下载、int8 量化（~150MB）、清晰进度。
- **计算耗时**（多一遍声学模型）→ 复用已抽好的 wav、显示进度；长音频按 VAD/whisper 段切块对齐。
- **whisper 文字本身的错字会传导**（对齐假设文字正确）→ 接受；对齐不修识别，仅修时间。
- **回滚**：全程开关后置且默认 off；任何对齐失败/不可用静默回退现有 DTW 时间轴——产品行为零退化。

## 9. 开放问题（待七月定，决定走哪条分支）

1. **引擎/打包**：确认走原生 ONNX（推荐）？Python sidecar 仅作 P0 dev 工具，不进产品——是否同意？
2. **语言优先级/胃口**：CJK 是真痛点但也是最难路。先用英文 P1 把整条管线+提升验证扎实，再啃 CJK（P2）；还是直接奔日文（接受更高不确定性）？
3. **安装体积**：可选对齐模型 ~150–300MB 按需下载，能接受吗？
4. **是否值得**：P0 若显示 CJK 路径达不到 ≤±150ms，是否仍要仅对拉丁语上线（你的内容以日韩为主，可能性价比不足）——还是 P0 不达标就整体搁置、留在 DTW+LLM 重断句这一档？

## 10. 决策记录
- 2026-06-22：选原生 ONNX 而非 Python sidecar（消费级原生 App 分发约束）。
- 2026-06-22：选 MMS-FA 多语模型起步而非每语言专用（覆盖面），CJK 罗马化可行性待 P0。
- 2026-06-22：对齐全程可选 + 失败回退 DTW，保证零行为退化。
- 2026-06-22（七月拍板）：**起步走 P0 离线验证**（不碰产品代码，数据决定值不值得原生集成）；**产品引擎确定原生 ONNX Runtime**（Python 仅可用于 P0 离线出基线）。

## 11. 进度
- 2026-06-22：完成代码地形勘察 + 强制对齐生态调研；确认 sherpa-onnx 无现成对齐 API（#3536）。ExecPlan 成文。
- 2026-06-22：七月确认起步方式（P0 离线验证）+ 产品引擎（原生 ONNX）。
- 2026-06-22：**P0 离线验证完成（torchaudio MMS-FA + uroman，真实 YouTube 词级 VTT 作 Google 对齐金标准）**：
  - **英文（拉丁）= 决定性胜出**：词起点误差中位 220ms→**67ms**、均值 248→77ms、p90 420→**124ms**（whisper DTW vs 强制对齐，n=250）。完全符合文献 ±50–100ms。**过 P0 拉丁门槛**。
  - **日文 = 不成立**：中位 140ms→**190ms（反而更差）**、p90 800→746ms（n=129）。拆 kana/kanji：kana 140→156ms（基本持平）、**kanji 140→230ms（明显更差）**。根因实锤：**uroman 把汉字按中文读音罗马化**（日本語→ribenyu、今日→jinri），声学模型听到的是日语发音 → 汉字词对齐崩。且日文 whisper 自带 DTW 本就 ~140ms（比英文 DTW 还好），改善空间小。**未过 P0 的 CJK 门槛（无任一 CJK 路径 ≤±150ms 优于 DTW）**。
  - **结论**：通用多语模型（MMS-FA+uroman）对 CJK 不可用。日文要见效需**每语言专用 CTC 模型**（输出假名的 JA wav2vec2 + 汉字→假名）——七月选 B，已 spike 验证（见下）。
- 2026-06-22：**P0b 日文专用 CTC spike 完成（jonatasgrosman/wav2vec2-large-xlsr-53-japanese 假名 CTC + pykakasi 汉字→假名，绕开 uroman 中文读音）**：
  - **仍不成立**：[all] DTW 140→**187ms**；[kana] 140→153ms（持平）；[kanji] 140→**236ms**（p90 **1705ms**，pykakasi 误读如 今日→こんにち 而非 きょう，整词崩）。
  - **决定性铁证：kana-only 子集（读音无歧义）也没赢**（153 vs 140ms）——说明瓶颈不只是 pykakasi 误读；**日文 forced-align 的天花板就在 whisper DTW（~140ms）附近**，换 MeCab 更准的读音也救不回来。根因：日文 whisper DTW 本就好（比英文还好），而 kanji→读音转换这一步本质有歧义、必然引入误差，恰好抵消声学对齐的收益；whisper DTW 直接对齐自己的 token、跳过了读音转换这一步。
  - **跨两轮总结论**：forced-align **只对拉丁语系（英文 220→67ms）是明确大胜**；**对日文（两条路都试过）打不过 whisper 自带 DTW**。收益与七月日韩主力内容错配。

## 12. P0 最终决策建议（B 已验证为负）
- **A（强烈推荐）：不上强制对齐。** 两轮 spike 实证：拉丁收益与需求错配、日文两条路都打不过 DTW（且 DTW 已 ~140ms）。继续打磨已交付的 DTW + retimer + CJK 分段 + LLM 重断句更划算。
- **~~B：日文专用 CTC~~——已验证为负**（kana-only 都不赢，天花板≈DTW）。
- **C（可选，仅当七月看重拉丁内容）：只给 en/es/fr/it 等拉丁语系上原生 ONNX 强制对齐**，CJK 维持 DTW。收益明确但只服务非主力内容，工程量中等。

P0 产物在 `~/Library/Caches/mg-forced-align/`（venv + 模型 + `align_eval.py`/`align_ja.py`，仓库外、未提交），可复跑或删除。

## 参考
- WhisperX（forced alignment with wav2vec2 phoneme model）：https://github.com/m-bain/whisperX
- torchaudio MMS forced aligner / `forced_align`（算法与多语模型）：https://pytorch.org/audio/stable/tutorials/forced_alignment_tutorial.html
- sherpa-onnx 强制对齐 feature request（暂无原生 API）：https://github.com/k2-fsa/sherpa-onnx/issues/3536
- ONNX Runtime（C#/C 绑定）：https://onnxruntime.ai/
