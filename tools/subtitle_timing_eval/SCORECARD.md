# Moongate 字幕质量 · 可量化测试标准（Scorecard）

把"字幕好不好"拆成四个可独立打分（0–100）、可分别设 **≥80 分（优秀）门禁**的维度，并区分
**「未验证」**（仅靠模型自信度+结构启发式）与**「已验证」**（有人工参考 / LLM 裁判 / 声学 /
场景真值支撑）。门禁只认**已验证**分数——因为"自信乱码"会让纯置信度高分假性通过。

代码：`subtitle_timing_eval/scorecard.py`（纯函数，测试见 `tests/`）。运行器：`run_scorecard_baseline.py`。

---

## 四个维度

### 1. recognition 识别准确率
语音→文字转得对不对。分量（缺失则按存在分量重新归一）：
- **confidence**（自动）：仅当当前评分源是本地 ASR 时，来自 whisper `words.json` 的词级
  `probability`，镜像 `LocalASRConfidence`（avg_prob 映射 + 低置信词占比惩罚；<24 词不可评）。
  平台字幕不能复用本地 ASR 的置信度。
- **near-empty guard**（自动）：本地 ASR 产出文件存在不等于识别成功。若生成结果只有一个极短 cue
  且几乎没有有效字符，应按 `nearEmptyTranscript` 视为识别失败，不能继续当作可翻译源字幕。
- **structural**（自动）：镜像 `PlatformSubtitleQualityGate` 的乱码/重复/罗马音泄漏/CJK 拉丁混入/低唯一率惩罚。
- **reference**（金标准）：存在人工 `*.clean.srt` 时算 CER（CJK 字符级）/ WER（拉丁词级）相似度。
- **llm**（金标准）：agent 读输出、必要时对照在线人工字幕后写入 `agent_recognition_judge.json` 的
  数值型 `accuracyScore`。`accuracyScore: null`、`pass/blockingIssues` 这类未打分/整体裁判 payload
  会被记录为 `ignored:agent_recognition_judge:unscored`，不会让 recognition 变成 verified。
- 当 `accuracyScore < 80` 且没有人工 reference 可纠偏时，最终 recognition 分会被语义裁判 cap，并标注
  `llm:semanticCap`；自动结构分/置信度不能把一个语义不达标的样本抬过门。
- `verified` = 有 reference 或 llm。纯 confidence+structural 标 `unverified:needsReferenceOrLLM`。

### 2. segmentation 分段/分词准确率
切句切词的位置对不对。
- **internal**（自动）：过长 cue 比例 + 悬空助词/词中断候选密度（`weak_boundary_candidates`）惩罚。
- **acoustic**（金标准）：能量 VAD（`vad.py`，即"看音频波谱"）求语音段边界，统计 cue 起点落在
  语音段起/止 ±0.4s 的比例。切点贴边=切在说话起止处（好）；落段中远离边界=很可能切在词中（坏）。
- 当前评分源是平台字幕时，runner 不使用本地 ASR words 计算首词/分段；避免 Whisper 开头幻觉反向惩罚
  人工/平台字幕。平台字幕只用声学 VAD 作为外部 timing 证据，并禁用 VAD-only 的首词起始判罚；
  没有平台词级时间或人工参考时，音乐前奏/片头能量不能单独证明第一条平台字幕来晚了。
- 人工参考边界 F1 **只作信息备注、不计分也不算验证**：whisper 切句风格天然异于人工字幕，已证实
  结构性封顶 ~0.65（风格差异非缺陷），拿它当门会让分段永远不达标。
- `verified` = 有 acoustic。
- ⚠️ **音乐例外**：连续音乐会被能量 VAD 整段当"语音"，cue 起点落段中→声学分偏低且不公正。
  音乐类分段以 **agent LLM 裁判**为准（见 runbook），声学分仅供演讲/对白/动漫参考。

### 3. translation 翻译准确率
- **structural**（自动）：空译文/重复译文/罗马音泄漏/严重 cue 数失配（阈值 0.5，重分段 43→29 合法不罚）惩罚。
- **llm**（金标准，主导 0.7）：agent 写入 `agent_translation_judge.json` 的 `score`（忠实度+通顺+一致+逐字保留）。
- 无 LLM 裁判时翻译分**封顶 75**（`cappedNeedsLLMJudge`）——结构无法认证语义优秀。

### 4. source_decision 源决策正确率
"用平台字幕 / 本地 Whisper / 云端"选得对不对。
- 对 `source_decision_scenarios.json`（带已知正确答案的可执行规格）打分，决策正确率→0–100。
- M0 用 Python 镜像 `predicted_decision_for_gate`；**M1 落地后，Swift/C# `SubtitleSourceDecisionEngine`
  必须在同一份场景上得同样结果**（交叉校验实现符合规格）。
- `verified` = True（场景真值）。

---

## 门禁口径

某维"达标"当且仅当：**已验证样本均分 ≥80** 且**验证覆盖 ≥60% 已评样本**。
`all_dimensions_pass` 要求四维全部经验证达标。同时输出 `*_unverified` 口径供对照（看自动floor）。

---

## 运行

```bash
cd tools/subtitle_timing_eval
python3 -m unittest discover -s tests -p "test_*.py"          # 222 测试
python3 run_scorecard_baseline.py                             # 扫缓存,产 scorecard.json/.md
python3 run_scorecard_baseline.py --acoustic                  # 额外算声学(需 ffmpeg,演讲类才公正)
python3 run_scorecard_baseline.py --roots ted_school_creativity_en italian_talk_public_it
python3 run_scorecard_baseline.py --acoustic --write-recognition-prompts --recognition-prompt-limit 12
python3 run_scorecard_baseline.py --acoustic \
  --recognition-judge-source-backfills tools/subtitle_timing_eval/recognition_judge_source_backfills.json
python3 run_scorecard_baseline.py --acoustic \
  --recognition-judge-source-backfills tools/subtitle_timing_eval/recognition_judge_source_backfills.json \
  --recognition-reference-acquisition tools/subtitle_timing_eval/recognition_reference_acquisition.json
```
产物：`artifacts/subtitle_timing_eval/scorecard/scorecard.{json,md}`，以及 recognition 审查队列/证据计划/
审听任务单（Markdown + 本地 HTML）。
若样本目录存在 `source_candidates.json`，runner 会按其中 `selected: true` 的最终字幕源打分，并在
JSON 样本节点写出 `scored_source_kind` / `scored_source_path`；没有候选源报告时才回退到旧的
`local-asr.*.srt` 基线。
`--recognition-judge-source-backfills` 只把可追溯 `sourceUrls` / URL evidence 合并进已有的数值型
recognition judge，不覆盖 `accuracyScore`，也不会让没有数值 judge 的样本变成 verified。
`--write-recognition-prompts` 会为未验证 recognition 样本生成 `agent_recognition.prompt.md`，但不会
改变分数。prompt 会尽量列出同目录下可审听的 `clip.wav`、`local-asr.wav`、`source/*.webm` 或
`local-asr-media/*`；这些只是给 reviewer 打开证据的路径，只有人工参考或带数值型 `accuracyScore` 的有效
`agent_recognition_judge.json` 才能让样本变成 verified。刷新后的
`recognition_review_queue.md` / `recognition_evidence_plan.md` 也会带同一组 audio 路径；`recognition_review_packet.md`
会把推荐样本、audio、prompt、judge 输出路径和 JSON contract 收成一张任务单，`recognition_review_packet.html`
会用本地 `<audio>` / `<video>` 控件打开同一组素材。`recognition_review_judge_templates.json`
提供默认 `accuracyScore: null` 的安全模板，方便审听后复制到对应样本目录；它本身不会被当作 judge 读取。
当最快补 gap 的推荐样本集中在单一语言时，`recognition_evidence_plan.md` 还会输出非评分的
`Multilingual Follow-up` 队列，提醒后续审听优先补其它语言覆盖。
`--recognition-reference-acquisition` 只把参考查证尝试写进 `recognition_evidence_plan.md`，例如
`bot_gate`、`translated_subtitles_only`、`no_uploaded_subtitles`；这些状态不改分、不认证 recognition。

---

## Agent 评分 Runbook（语义维度由 agent 补金标准，七月免手工标注）

对每个要认证 ≥80 的样本：
1. **找在线人工字幕**：能找到官方/字幕组人工字幕→存为 `<dir>/*.clean.srt`，识别维度自动算 CER/WER（已验证）。
   YouTube 证据只认原语言的 `Available subtitles` / 上传字幕轨；`Available automatic captions` 只能当弱参考，
   翻译轨（例如日语歌的英文/韩文字幕）不能证明原文 recognition。可用 `yt-dlp --list-subs <url>` 先查轨道，
   再用 `yt-dlp --write-subs --sub-langs <lang> --sub-format srt --skip-download ...` 下载到 ignored artifacts。
2. **识别 LLM 裁判**（无人工参考或需复核时）：实际读 `local-asr.<lang>.srt`，按语言通顺性+内容合理性
   判断转写对不对（重点抓"自信乱码"：置信度高但听错，如青花瓷/BLACKPINK）。写
   `<dir>/agent_recognition_judge.json`：`{"accuracyScore": 0-100, "issues":[...], "notes":"..."}`。
   可先用 runner 生成 `<dir>/agent_recognition.prompt.md`；证据不足时不要硬给分，保持未验证。
3. **翻译 LLM 裁判**：读 `translated.srt` 对 final source，判断忠实/通顺/术语人物一致/歌词逐字保留。写
   `<dir>/agent_translation_judge.json`：`{"score": 0-100, "adequacy":..,"fluency":..,"issues":[...]}`。
4. **分段**：演讲/对白/动漫看声学分；音乐看 LLM 裁判（断句是否落在乐句/语义边界、有无词中断）。
5. 重跑 `run_scorecard_baseline.py` 合并裁判，看 `scorecard.md` 的「门禁(验证)」列。

判分尺度：90+ 几乎无误可直接用；80–89 个别小错不碍理解；60–79 多处错或断句碎；<60 乱码/错源/不可用。
保守诚实：宁可标低并写明原因，绝不为凑分放水。

---

## 当前基线（2026-06-29，缓存 49 样本；详见 scorecard.md）

| 维度 | 未验证均分 | 已验证均分 | 说明 |
|---|---:|---:|---|
| recognition | ~87 | ~75 | 自动 floor 虚高；有人工参考处真实 ~75，未达 80 |
| segmentation | ~91 | 演讲 ~74 / 音乐 ~45 | 声学验证；演讲可冲，音乐需 LLM 裁判 |
| translation | 73.6(封顶) | — | 全部待 agent LLM 裁判 |
| source_decision | 100 | 100 | 规格自洽；M1 引擎须交叉达标 |

**结论**：四维框架就位、可量化、能区分好坏（已知乱码样本全落低分区）。冲 80 的真实工作量在
线 B（识别）/ 线 A（源决策）/ agent 逐样本 LLM 裁判（识别+翻译）。
