# 0.7（批次一）：多语言 UI + 翻译目标语言 + 更好的 Onboarding

## 背景与产品意图
月之门当前只对简体中文用户友好：四端里只有 Windows 做了 i18n（且仅 zh/en 二值），macOS/iOS/Android 全部界面文案硬编码简体中文；翻译目标语言在 8+ 处写死 `"zh-Hans"`，且 macOS/Windows 的 LLM 提示词直接写死「简体中文」、**无视** `context.targetLanguage`；没有任何首启引导。

0.7 批次一把月之门变成**面向多语言用户的产品**：界面支持英语 / 简体 / 繁体并可在 App 内即时切换；翻译目标语言可由用户选择；首启有清晰 Onboarding，允许「无 API 当纯下载器」，macOS 默认引导本地 Apple 翻译。

## 范围与平台深度（2026-06-16 最新任务）
- 本轮 0.7 = **桌面端 A/B/C/D/E 全量**：A 多语言 UI/UX；B 翻译目标语言；C 更好 Onboarding；D 更好翻译（字幕后总结/分类/提示词预设，含歌曲/歌词模式）；E 更多站点（TikTok/抖音/小红书等）。
- **手机端暂时搁置**：不继续推进 iOS/Android UI、构建、上架或移动端行为。本轮只保护已有 mobile core/schema 不被破坏，必要时更新共享模型以保持编译。
- macOS + Windows 是本轮交付平台。所有新增用户可见能力都必须有两端可见入口，除非平台能力天然不同（例如 macOS 本地 Apple Translation 引导）。
- macOS Onboarding 默认 = 本地 Apple 翻译（复用 `AppleTranslationExecutor` + `AppleTranslationSetupGuidance`）；允许用户跳过 API/本地翻译配置，把 App 当普通视频下载器。
- Windows Onboarding 默认 = 普通下载器；允许后续在设置中配置云端 API；不得把 API 配置作为首启阻塞项。
- 繁体中文 = **全人工撰写**道地繁中（台/港用语），**不走** OpenCC 字形转换；关键文案交 July 审核。

## 关键架构决策
- **i18n 机制（macOS/iOS）= 运行时 `Localizer` 字典表，镜像 Windows `Loc.cs`**，不用 `.xcstrings`。理由：`build.sh` 手工组装 `.app`（无 Xcode 本地化工具链）；原生 `.strings` 依赖 `AppleLanguages`，运行时切换需重启；运行时表 `@Published` 即时切换，且与 Windows 同构、CLI/测试可无 bundle 直接用。字符串以 **Swift 字典内嵌**（非 JSON 资源），缺 key 返回 key 本身（镜像 `Loc.cs:11-12`）。
- **版本号收敛**：引入单一版本常量，`ReleaseSurfaceTests.cs` 改为读常量（当前 0.6.1 手抄 6+ 处 + 测试硬钉）。

---

## 冻结的 schema 契约（M1+ 据此实现，四端逐字节对齐）

### settings.json 新增字段（统一 JSON key）
| JSON key | 类型 | 值域 | 默认 | 说明 |
|---|---|---|---|---|
| `appLanguage` | String | `auto` / `zh-Hans` / `zh-Hant` / `en` | `auto` | 界面语言；`auto`=跟随系统 UI 语言 |
| `translationTargetLanguage` | String | `zh-Hans` / `zh-Hant` / `en` | **`zh-Hans`** | 字幕翻译目标；默认必须是 `zh-Hans` 以保证老用户升级后行为不变 |
| `onboardingCompleted` | Bool | — | `false` | 首启引导是否完成 |
| `smartTranslationPromptsEnabled` | Bool | — | `false` | 是否在字幕翻译前先做内容分析/分类，再选择翻译提示词预设 |

约束：
- `appLanguage` 与 `translationTargetLanguage` **相互独立**（界面语言≠字幕目标，例如英文界面 + 翻译成繁中）。
- **解码铁律**：所有新字段 `decodeIfPresent ?? default`，**禁止裸 `decode`**。`Settings.swift load()`（:242/:249）在任何解码 throw 时回退到全新 `AppSettings()`，会静默清空已保存 API token——缺键的旧文件必须安全取默认、不得抛错。
- `translationTargetLanguage` 值域同时被 LLM 提示词与 Apple Translation 接受（`appleTranslationSourceLanguages` 已含 zh-Hans/zh-Hant/en，见 `SettingsView.swift:37-43`）。
- Swift `CodingKeys` raw value 必须与 C# `ToJson` key 同名（M1.5 加 parity 测试守护）。

### 翻译目标语言 → 提示词 display name 映射
| 代码 | LLM 提示词 display name | 输出文件后缀 |
|---|---|---|
| `zh-Hans` | Simplified Chinese / 简体中文 | `.zh-Hans.srt` |
| `zh-Hant` | Traditional Chinese / 繁體中文 | `.zh-Hant.srt` |
| `en` | English | `.en.srt` |

注：输出后缀由 `.zh.srt` 改为按目标派生（**安静的破坏性变更**，M2 前须 grep 所有 `.zh.srt` 读取方）。

### i18n KEY 命名空间 `L.<Area>.<Name>`
四端共用，从 Windows `Strings.en.xaml`（199 keys）起底。现有 Area：
`App / Common / Main / Idle / Loading / Choosing / Error / Ready / Mode / Summary / Output / Hint / Failed / Notice / Queue / Row / Status / Confirm / Settings / Update / Login / Dep`。

0.7 新增 key（在既有 Area 内补充）：
- `L.Settings.TargetLanguage`（「翻译目标语言」标签）、`L.Settings.LangHans` / `L.Settings.LangHant` / `L.Settings.LangEn`（语言选项名，**语言名本身不翻译**，恒为「简体中文 / 繁體中文 / English」）。
- `L.Settings.LangHantOption`（界面语言选项「繁體中文」，Windows ComboBox 第 4 项）。
- 新 Area `L.Onboarding.*`：`Welcome` / `Subtitle` / `PickAppLang` / `PickTargetLang` / `PickMode` / `ModePlainDownloader` / `ModeCloudAPI` / `ModeLocalApple`（仅 macOS）/ `LocalAppleGuide` / `Skip` / `Continue` / `Done` 等（具体清单在 M4 落定）。

Swift 侧 key 以 `enum L { enum App {…}; … }` 表达（编译期可检），与 Windows `L.App.Title` 等字符串 key 一一对应。

---

## 现状勘察（file:line）
- macOS UI 全 SwiftUI，单窗口 `Window("月之门")`（`App.swift:11`），单 `@StateObject ViewModel`（`App.swift:7`）。零本地化。NSAlert 关闭确认硬编码中文（`App.swift:30-53`）。
- `AppSettings`（`Settings.swift:6`）：`init`(:62) / `CodingKeys`(:141) / `init(from:)`(:150) / `encode(to:)`(:209) 四处协同；`maxBurnHeight`(:182-186/:227-231) 是「缺键 vs 显式 null」的范例（新字段无此需求，默认对缺键/显式值相同）。
- 翻译目标硬编码 `"zh-Hans"`：`ViewModel.swift:367/492/799/803`、`QueueManager.swift:511`、`SettingsView.swift:460/462`、`moongate-cli/main.swift:299`、`IOSMobileAppModel.swift:412/2394`。提示词写死简中且无视 target：`Translator.swift:936-940`（翻译）/`:773-777`（总结）；输出 `.zh.srt`(:1039)；双语「中文在上」(:1028)。Mobile core 已正确参数化：`MobileModels.swift:1111/1148`。Windows 镜像：`Translator.cs:866-867`/`:681`/`:991`。
- 「源是中文则跳过翻译」：`ViewModel.swift:613/637/648`、`QueueManager.swift:453-455`、`ContentView.swift:574`、`IOSMobileAppModel.swift:2432`——须泛化为「源==解析后目标才跳过」，且区分 zh-Hans/zh-Hant 脚本。
- 首启钩子：`ViewModel.onAppear():159` + `didRunStartupDependencyCheck:130`；`:885` 明确告诫：勿在 `onAppear` 同步 spawn 子进程（AttributeGraph 重入）。
- Windows i18n 参考：`Loc.cs`（`Apply(appLanguage)` 换装 ResourceDictionary + 设 `L10n.Language` + 触发 `LanguageChanged`，`IsEnglish` 是 **bool**），`Strings.{en,zh}.xaml`（199 keys），核心 `L10n.cs`（`CoreLanguage {Chinese,English}` + 内联 `T(zh,en)` 数十处）。`Settings.cs:118` `AppLanguage ∈ {auto,zh-Hans,en}`。
- 测试地雷：iOS `PackageBoundaryTests.swift`（2209 行硬断言中文串）、macOS `MacOSSettingsBoundaryTests.swift`（断言 `targetLanguage:"zh-Hans"`）、Windows `ReleaseSurfaceTests.cs`（钉 0.6.1 + 文档测试数 242）、`WindowsSettingsSurfaceTests.cs`（部分 key parity）。
- 版本 0.6.1 手抄：`build.sh:71`、`build-windows.sh:10`、`make-dmg.sh:8`、`installer.nsi:11`、`windows-release.yml:9/13`、README、docs/WINDOWS.md。
- ⚠ 已纠正：`SettingsView.swift:41-42 ("zh-Hant","繁体中文")` 是 Apple Translation 的**源**语言列表（`:37` `appleTranslationSourceLanguages`），**不是**目标选择器；且标签 mis-glyph（「繁体」是简体字），正是 zh-Hant 必须人工撰写的反例。

## 目标 / 非目标
**目标**：A 三语界面（en/zh-Hans/zh-Hant）+ App 内即时切换；B 翻译目标语言可选并贯穿翻译/提示词/输出；C 三语 Onboarding + 无 API 纯下载 + macOS 本地翻译默认；D 可开关的“智能翻译提示词路由”（字幕后先总结/分类，再按普通/歌曲等预设翻译）；E 对 TikTok/抖音/小红书等站点给出可解析路径、登录/风控提示和测试覆盖。迁移零回归（老用户配置与行为不变）。
**非目标**：手机端继续推进；真实站点批量爬取或规避平台风控；绕过登录/付费/区域限制；自动下载 Apple 系统语言包或替用户修改系统设置。

## 里程碑
- **M0**（本文档）— 冻结 schema 契约 + key 命名空间。
- **M1** — settings 模型 + 向后兼容解码（四端）。
- **M1.5** — 跨平台 parity 门禁（旧文件往返不丢 token + Swift↔C# key parity）。
- **M2** — 翻译目标单一漏斗（`resolvedTranslationTargetLanguage` + `makeTranslationContext(source:)`）+ 提示词/输出后缀参数化 + 泛化跳过逻辑（B）。
- **M3** — 桌面 i18n 字符串抽取（A）：共享 `Localizer` 模块；macOS 关键窗口/设置/Onboarding 三语；Windows 加 `Strings.zhHant.xaml` + `Loc` 三态 + `L10n.CoreLanguage` 2→3；测试断言迁移为 key/行为。手机端不扩展。
- **M4** — 翻译目标语言 UI（B）：macOS/Windows 设置与 Onboarding 都能选择 `zh-Hans` / `zh-Hant` / `en`，保存后影响 readiness、跳过逻辑、LLM prompt 和队列快照。
- **M5** — Onboarding（C）：首启引导 gated by `onboardingCompleted`；允许纯下载器路径；macOS 本地 Apple 翻译引导必须无副作用、异步探测、不与依赖 sheet 打架；Windows 不阻塞 API 配置。
- **M6** — 更好翻译（D）：新增独立开关；字幕下载后先用总结配置做内容分析/分类，选择普通/歌曲等 prompt preset；开关默认关闭，普通下载/普通翻译不受影响；开启后若当前 summary/text-generation 配置不可用，应明确失败并提示去设置配置，而不是静默产出低质量翻译。
- **M7** — 更多站点（E）：把 TikTok/抖音/小红书识别为 yt-dlp 原生站点，失败时不误导回网页嗅探；补登录/风控/短链提示与测试；README/Windows 文档说明支持边界。
- **M8** — 版本 0.6.1→0.7.0 + 单一版本常量 + 文档 + CI。

## 风险与对策
1. settings 漏默认→静默清空 token：每字段 `decodeIfPresent ?? default`，M1.5 覆盖「缺键旧文件」。
2. 漏改 zh-Hans 站点→静默仍翻中文：收敛单一漏斗 + 逐路径测试。
3. 字符串硬断言成批红：同 PR lockstep 迁移为 key/行为断言（不删覆盖）。
4. Windows `CoreLanguage` 2→3 是最大隐藏成本（数十站点人工繁中）：作 M3 内独立子里程碑 + parity 测试。
5. `.zh.srt` 后缀变更：M2 前 grep 所有读取方。
6. macOS Onboarding 双弹窗/AttributeGraph 重入：gate + 全异步探测 + 明确顺序。
7. iCloud/git（遵守 MEMORY）：构建产物出 `~/Documents`（放 `~/Library/Caches`）；**绝不 push 本仓库，commit 先问 July**。

## 验证
- macOS：`swift test --scratch-path ~/Library/Caches/vdl-build`；`./build.sh` 后手测语言即时切换 + 三语 onboarding + 不同目标语言产出对应 `.xx.srt`。
- Windows：`dotnet test windows/Moongate.Win.sln --nologo -v minimal`。
- Android：`Scripts/build-android-local.sh`（offline）。
- 全平台手动 QA：三语逐屏无混语；无 API 启动可纯下载。

## 进度日志（2026-06-16）
- **M0 ✅** 本契约文档落盘。
- **M1 ✅** macOS `AppSettings` / Windows `Settings.cs` / Android `AndroidSettingsState` 加 `appLanguage`/`translationTargetLanguage`(默认 zh-Hans)/`onboardingCompleted`，均 `decodeIfPresent ?? default` 无 token-wipe。**iOS 修正**：iOS 不用 `AppSettings`（仅依赖 MoongateMobileCore），三设置改走 native host `@AppStorage`，留到 iOS 功能里程碑。
- **M1.5 ✅** 旧文件往返不丢 token + Swift↔C# key parity 测试。macOS 60 项 settings 测试绿、Windows 247 项绿。
- **M2 ✅（B）** 新增 `AppSettings.makeTranslationContext(source:)` 单一漏斗，删除桌面全部 11 处 `zh-Hans` 字面量；`Translator` 提示词按目标语言参数化（macOS + Windows core）；跳过逻辑泛化为 **脚本级** `TranslationLanguage.matches`（简↔繁仍翻译）。译文输出后缀改为按目标语言派生（`.zh-Hans.srt` / `.zh-Hant.srt` / `.en.srt`）；队列重试时只把形如 `video.en.zh-Hans.srt` 的“双语言后缀”识别为译文输出，避免误伤源字幕 `video.en.srt` / `video.zh-Hans.srt`。Windows `MainViewModel` 同构（仅审阅，WPF 不在 mac 编译）。iOS 2 处 `zh-Hans` 待 iOS 里程碑。Swift build 通过、Windows 247 测试绿。
- **M3 🚧 桌面核心推进** 建成运行时 `Localizer` 机制（`Sources/MoongateMobileCore/Localization/`：`AppLanguage`/`ResolvedLanguage`/`L` key 命名空间/纯查表 `LocalizedStrings`/`#if canImport(Combine)` 的 `Localizer`），植入 en/zh-Hans/**人工繁中** 三表 + 键集一致性测试；已接入 macOS `App.swift`（窗口标题 + 设置菜单走 Localizer、`environmentObject` 注入）和 `ContentView` 主流程文案（输入、解析、idle、候选列表、返回列表、加入队列、footer、格式/输出/字幕区第一批）。Windows 已补 `Strings.zh-Hant.xaml`，`Loc.cs` 可应用 zh-Hant，`L10n.CoreLanguage` 支持 zh-Hant；`Models.cs` 错误外壳、`Queue.cs` 高频队列/字幕状态、`UpdateChecker.cs` 更新错误原因、`Transcoder.cs` 转码错误原因已改成三参 `L10n.T(zhHans, zhHant, en)`，并用 `L10n.Language` 测试 collection 避免并行测试抢全局语言。**剩余**：macOS 仍有大量既有硬编码中文（`ContentView` 剩余字幕处理/错误/Apple setup 区、`SettingsView`、队列视图、登录、更新等），Windows core 的 `Engine` / `Burner` / `Dependencies` / `PageSniffer` 等仍有二参或硬编码中文；全量三语文案抽取与 zh-Hant 人工校对需继续。
- **M4 ✅（B）** macOS/Windows 设置页都新增界面语言与翻译目标语言选择；目标语言保存到 `translationTargetLanguage`，并会影响运行时 readiness / 翻译上下文。
- **M5 ✅（C）** macOS/Windows 首启 Onboarding 已接入 `onboardingCompleted`。macOS 默认可选择本地 Apple 翻译并提示语言包；两端都允许不配置 API、直接作为普通下载器进入。
- **M6 ✅（D）** macOS/Windows core 新增 `smartTranslationPromptsEnabled`，默认关闭；开启后字幕翻译先通过总结配置做 JSON 内容分析，当前支持 `general` / `songLyrics` 预设，歌曲/歌词会走更诗意、保留意象与节奏的系统提示词；解析失败会给可行动错误。
- **M7 ✅（E）** macOS/Windows yt-dlp 原生提取站点识别加入 TikTok、抖音、iesdouyin/amemv 与小红书/xhslink，避免这些站点失败后误导用户走普通网页嗅探；仍不绕过登录、地域、风控或平台限制。
- **M8 ✅** 版本/文档/CI 收口到 0.7.0：macOS build/DMG 脚本、Windows build/workflow/NSIS、README、CHANGELOG、docs/WINDOWS 与 release surface 测试已更新到 0.7.0；Windows 安装包命名沿用 `Moongate-` 基线，未回退外部已有改名。
- **已知环境问题（非本次改动）**：`Scripts/build-android-local.sh` 被 iCloud 剥掉 group/other 执行位（0o100），令 `testAndroidLocalBuildGateScriptUsesOnlyExistingGradle` 红；`chmod 755` 可恢复，但 iCloud 可能再剥。
- **2026-06-16 最新盘点**：当前在 `codex/v07-desktop-i18n-onboarding` 承接已有未提交 0.7 改动；`master` 已有 M1/M2/M3 起步工作但未提交。手机端本轮冻结；后续实现只在必要时保持共享模型编译，不扩展移动 UI。
- **2026-06-17 00:10 本轮推进**：macOS 队列 UI 接入运行时 `Localizer`（标题/计数、浮层、进度状态、按钮 help/hint、转码/翻译/烧录进度），新增 `L.Queue.*` 三语表与 `MacOSQueueBoundaryTests`/`LocalizerTests` 覆盖；macOS 设置页高频入口接入 `L.Settings.*`（语言 section、AI 设置、AI 翻译/总结、模型拉取/连接测试、复用 `APIConfigEditor`），新增边界测试；Windows `Engine.cs` 下载/解析/登录/风控/语言名/格式标签的用户可见文案扩成 `zh-Hans`/`zh-Hant`/`en` 三参 `L10n.T`，新增 `EngineI18nTests`。验证：Swift 0.7 组合 22 tests 绿；Windows 0.7/core i18n 组合 23 tests 绿（仍有 NuGet vulnerability source `NU1900` 网络告警）。**剩余 M3/M8**：macOS `App.swift` 关闭确认、`SettingsView` 依赖/Apple readiness/更新/性能/字幕/登录/底栏、`LoginWebView`、`SummaryView`、`UpdateService` 等仍有硬编码中文；Windows core `Burner`/`DependencySetup`/`PageSniffer` 等仍需继续扫尾；版本 0.7.0 与文档/CI 尚未收口。
- **2026-06-17 02:10 收口**：补齐 macOS 关闭确认、登录、依赖、更新、总结、设置/ready 高频文案；新增 `CoreL10n` 让 `MoongateCore` 错误、readiness、Apple Translation、转码/烧录/更新/嗅探/下载状态按运行时语言输出；Windows core `Burner`/`Dependencies`/`PageSniffer`/`Paths`/`Models`/`Translator`/`Queue` 等三语扫尾。根据只读复查修复两个 0.7 漏点：译文文件名按目标语言后缀输出，且源字幕等于目标语言时 UI/状态不再写“中文字幕/Chinese subtitle”；Windows 测试禁用并行化以避免全局 `L10n.Language` 串扰。验证：Swift 桌面/核心组合 170 tests 绿；Windows core 全量 276 tests 绿；`git diff --check` 绿。仍见 NuGet `NU1900` 网络告警（无法读取 vulnerability source），不影响测试结果。
- **2026-06-17 02:25 字幕与登录体验补丁**：对比用户提供的 NVIDIA SRT 样本后确认 `.en-orig.srt` 为 YouTube 自动滚动字幕（约 15005 行），人工 `.en.srt` 约 2905 行；自动字幕存在 10ms 重复窗口、无标点碎句，以及 `[Music]` 被翻译成 `[音乐]` 混入正文的问题。macOS/Windows 共用字幕清洗入口补齐三项行为：翻译前移除/丢弃多语言非语音提示（如 `[Music]`/`[音乐]`/`[笑]`/`(Applause)`），自动字幕按软阈值合并时遇 `if/how/do` 等续句信号不再硬切，长 LLM 翻译块若返回缺行会自动拆半重试（小块仍缺行才失败）。Bilibili `HTTP 412` 在无已保存 cookies 时改判为 `loginRequired("bilibili.com")`，让 UI 走登录/WebView 引导；已有 cookies 时仍保留风控提示，避免反复登录。验证：Swift 新增红绿测试 5 条通过；Swift `TranslationSettingsTests|LoginDetectionTests` 共 76 tests 绿；Windows `MoongateCore.Tests` 全量 281 tests 绿；`git diff --check` 绿。Swift 全量 `MoongateCoreTests` 仍有既有 Android 边界失败 `testAndroidLocalBuildGateScriptUsesOnlyExistingGradle`（脚本行号/权限类，移动端本轮冻结，非本补丁引入）。
