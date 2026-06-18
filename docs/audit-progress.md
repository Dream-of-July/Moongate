# Moongate 发布加固 · 审计进度跟踪

跟踪外部审查文档 `moongate_code_review_claude_plan.md` 中各 issue 的修复状态。
分阶段执行（Phase 0–7），每个 Phase 独立可验证、可回滚。

> **重要原则**：本表区分“编译/单元测试通过”与“真机验证通过”。
> `Runtime validation` 列在没有真实 Windows / macOS 机器端到端验证之前，一律标
> `Not validated on real hardware`，**不得**因为编译或单测通过就写成已验证。

---

## 基线（Phase 0）

- **基线分支**：`fix/release-hardening`
- **基线 commit**：`1cb2aa0c`（master HEAD，"fix: release zip dependency temp files before cleanup"）
- **工具链**：
  - Swift 6.3.2 (swiftlang-6.3.2.1.108)，Target arm64-apple-macosx
  - .NET SDK 10.0.300
  - makensis 已安装（本 Phase 未调用）
- **基线深度**：编译验证级（跑测试 + Release 编译；不做 `build.sh` 安装 /Applications，不做 NSIS/DMG/appcast 打包）

| 基线命令 | 结果 | 退出码 |
|---|---|---|
| `swift test --scratch-path ~/Library/Caches/vdl-build` | **288 passed / 0 failed** | 0 |
| `swift build -c release --scratch-path ~/Library/Caches/vdl-build` | **Build complete**（~26s） | 0 |
| `dotnet test windows/Moongate.Win.sln --nologo -v minimal` | **311 passed / 0 failed / 0 skipped** | 0 |
| `dotnet publish MoongateApp.csproj -c Release -r win-x64 --self-contained -p:EnableWindowsTargeting=true` | **publish 成功**（产物 `/tmp/moongate-win-baseline`） | 0 |

**结论**：基线全绿，无既有失败。后续任何 Phase 引入的失败都可与本基线对照判定为新引入。

> 备注：`dotnet test` 还原阶段有 `NU1900`（无法访问 nuget.org 漏洞数据库）警告，属网络/环境，非代码问题，不影响测试结果。

---

## Issue 状态表

字段：Status ∈ {Not started, In progress, Done}；Runtime validation ∈ {Not validated on real hardware, Validated}。

### P0 · 发布阻断级

| Issue ID | Priority | Platform | Status | Files changed | Tests added | Runtime validation | Remaining risk |
|---|---|---|---|---|---|---|---|
| WIN-UPD-001 | P0 | Windows | Done (code) | UpdateService.cs, App.xaml.cs, MainWindow.xaml.cs, SettingsWindow.xaml.cs, installer/installer.nsi, Strings.*.xaml | UpdateCheckerTests, 安装器 makensis 编译通过 | Not validated on real hardware | 队列 preflight + /UPDATEPID 等待 + 专用退出态；helper 进程未引入（用 NSIS 等待 PID 替代），需真机验证覆盖安装 |
| SEC-COOKIE-001 | P0 | Both | Done (code) | win: CookieSites.cs/CookieFile.cs/Engine.cs/LoginWindow.xaml.cs/SettingsViewModel.cs/App.xaml.cs; mac: CookieSites.swift/Settings.swift/Engine.swift/LoginWebView.swift/SettingsView.swift/App.swift | CookieIsolationTests(16, win), CookieSitesTests(6, mac) | Not validated on real hardware | 两端按站点隔离 jar + 域过滤 + 认证 cookie 判定 + 旧文件迁移；WebView 导出/清除需真机验证 |
| SEC-CRED-001 | P0 | Both | Not started | — | — | Not validated on real hardware | API Token 明文落盘（Phase 2） |
| WIN-DEP-001 | P0 | Windows | Done (code) | DependencyWindow.xaml(.cs), Dependencies.cs, Strings.*.xaml | DependenciesTests.FormatBytes, i18n 进度测试 | Not validated on real hardware | 加取消按钮/可取消 token/关窗确认/字节+速度进度；断点续传未做 |
| WIN-DEP-002 | P0 | Windows | Done (code) | SettingsWindow.xaml.cs, Dependencies.cs | DependenciesTests.RedownloadAll_NetworkFailure_KeepsExistingBinaries, PlanAll | Not validated on real hardware | 改为 staging 先下后换；SHA-256/PE 架构/能力校验留待 Phase 3 (DEP-WIN-003) |
| DEP-SUPPLY-001 | P0 | Windows | In progress (机制完成) | windows/MoongateCore/Dependencies.cs | DependenciesTests.VerifyDownloadIntegrity*/FileSha256Hex* | Not validated on real hardware | SHA-256 校验机制 + DependencyDownload.Sha256 字段已就位（设置后下载即校验、不符拒装）；**待**：填入固定版本的真实哈希 manifest（需抓取真实发布二进制算 hash），并改 latest URL 为固定版本 |

### P1 · 高优先级

| Issue ID | Priority | Platform | Status | Files changed | Tests added | Runtime validation | Remaining risk |
|---|---|---|---|---|---|---|---|
| SETTINGS-001 | P1 | Both | Done (code) | windows: SettingsWindow.xaml.cs; macOS: Sources/Moongate/ViewModel.swift | 行为修复 | Not validated on real hardware | 两端登录/依赖跳转在保存失败时保持设置窗打开、不设 pending、显示原因（macOS requestLogin/requestDependencySetup guard saveSettings()） |
| MAC-DEP-001 | P1 | macOS | Not started | — | — | Not validated on real hardware | 卸载误删用户自装 Homebrew 包 |
| PROC-001 | P1 | Both | Not started | — | — | Not validated on real hardware | 暂停乐观更新，失败仍释放并发槽 |
| PROC-MAC-002 | P1 | macOS | Not started | — | — | Not validated on real hardware | 取消可能留下孤儿 ffmpeg 子进程 |
| UPDATE-MAC-001 | P1 | macOS | Done (code) | Sources/Moongate/UpdateService.swift, ViewModel.swift, SettingsView.swift | UpdateCheckerTests / MacOS*BoundaryTests 更新断言 | Not validated on real hardware | 删除实为 no-op 的 silent 检查与误导注释，后台检查依赖 Sparkle 调度（Info.plist 已配 SUEnableAutomaticChecks + 86400s） |
| UPDATE-WIN-002 | P1 | Windows | Done (code) | UpdateChecker.cs, Settings.cs, UpdateService.cs | UpdateCheckerTests.SemVer_PrereleasePrecedence / StableChannel_*, SettingsTests.ReceiveBetaUpdates | Not validated on real hardware | SemVer 完整预发布优先级 + 通道过滤；默认 ReceiveBetaUpdates=true（当前发布全是 prerelease，待首个正式版后改默认） |
| LOGIN-WIN-001 | P1 | Windows | Done (code) | SettingsViewModel.cs, App.xaml.cs, Strings.*.xaml | CookieIsolationTests 间接覆盖；ClearAllLogins 逻辑 | Not validated on real hardware | 清除登录区分 cookie/ WebView 成功，部分失败显示「部分清除」并写待删标记下次启动清理 |
| DATA-WIN-001 | P1 | Windows | Done (code) | docs/WINDOWS.md, installer/installer.nsi | makensis 编译通过 | Not validated on real hardware | 卸载器询问删除 %APPDATA%\Moongate + %LOCALAPPDATA%\Moongate；文档修正 |
| DATA-SETTINGS-002 | P1 | Both | Done (code) | windows/MoongateCore/Settings.cs, MainViewModel.cs, Strings.*.xaml; Sources/MoongateCore/Settings.swift | SettingsTests.Load_CorruptFile_*, TranslationSettingsTests.testLoadingCorruptSettings* | Not validated on real hardware | 损坏 settings.json 改名 settings.corrupt-<ts>.json + 一次性提示 + 回默认（不静默覆盖） |
| PATH-WIN-001 | P1 | Windows | Done (code) | windows/MoongateCore/Paths.cs | PathsTests reserved-name 系列(13) | Not validated on real hardware | 规避 CON/PRN/AUX/NUL/COM1-9/LPT1-9（含带扩展名 CON.video）+ 结尾点号空格 |
| DEP-WIN-003 | P1 | Windows | Done (code) | windows/MoongateCore/DependencyHealth.cs, MoongateApp/SettingsViewModel.cs, SettingsWindow.xaml.cs, Strings.*.xaml | DependencyHealthTests (12) | Not validated on real hardware | 结构化体检：跑 --version / -filters，状态分 正常/缺失/损坏/缺能力（零字节视为缺失），设置页异步细化显示 |
| REL-001 | P1 | Both | Not started | — | — | Not validated on real hardware | 正式包缺平台级签名链 |
| REL-WIN-002 | P1 | Windows | Not started | — | — | Not validated on real hardware | GUI/安装器无真机运行验证 |

### P2 · 中优先级与 UI/UX

| Issue ID | Priority | Platform | Status | Files changed | Tests added | Runtime validation | Remaining risk |
|---|---|---|---|---|---|---|---|
| PARITY-001 | P2 | Windows | Done (code) | windows/MoongateCore/UrlTokenizer.cs, MoongateApp/MainViewModel.cs | UrlTokenizerTests (10) | Not validated on real hardware | 统一到 Core 的 UrlTokenizer（按 http(s):// 锚点切分），覆盖换行/相邻/Tab/标点/括号/重复；与 macOS 同构 |
| PARITY-002 | P2 | Windows | Done (code) | windows/MoongateCore/Settings.cs, MoongateApp/MainViewModel.cs | SettingsTests.LastDownloadOptions_RoundTrip* | Not validated on real hardware | Win 记住上次字幕模式/语言/输出格式/HDR，选档页恢复（与 macOS 同构，按语言代码匹配字幕） |
| UX-WIN-001 | P2 | Windows | Not started | — | — | Not validated on real hardware | 设置窗口固定尺寸，高 DPI 不友好 |
| UX-WIN-002 | P2 | Windows | Not started | — | — | Not validated on real hardware | 硬编码浅色主题，高对比弱 |
| UX-WIN-003 | P2 | Windows | Not started | — | — | Not validated on real hardware | 安装器只有简体中文 |
| UX-WIN-004 | P2 | Windows | Not started | — | — | Not validated on real hardware | WebView2 缺失无直接修复入口 |
| REL-WIN-003 | P2 | Windows | Not started | — | — | Not validated on real hardware | 仅发布 x64，ARM 仅模拟 |
| UPDATE-WIN-003 | P2 | Windows | Done (code) | UpdateService.cs, App.xaml.cs | 经现有更新测试覆盖编译 | Not validated on real hardware | 取消/失败即时清理临时目录 + 启动清理 moongate-update-* 残留 |
| UPDATE-WIN-004 | P2 | Windows | Not started | — | — | Not validated on real hardware | 每次开设置新建更新器并静默请求 GitHub |
| UX-QUEUE-001 | P2 | Both | Not started | — | — | Not validated on real hardware | 自动收起队列可能在交互时关闭 |
| DOC-001 | P2 | macOS | Not started | — | — | Not validated on real hardware | README 对 Swift 依赖描述自相矛盾 |

---

## Phase 进度

| Phase | 范围 | 状态 |
|---|---|---|
| Phase 0 | 建立可验证基线 + 本跟踪文档 | **Done**（基线全绿，见上） |
| Phase 1 | Windows 更新与依赖阻断项（WIN-UPD-001、WIN-DEP-001/002、UPDATE-WIN-003/002） | **Done (code)** — dotnet test 321 通过（+10），NSIS 编译通过；覆盖安装/取消下载需真机验证 |
| Phase 2 | 凭证与登录隔离（SEC-CRED-001、SEC-COOKIE-001、LOGIN-WIN-001、DATA-WIN-001） | Not started |
| Phase 3 | 依赖可信度与 macOS Homebrew 边界（DEP-SUPPLY-001、MAC-DEP-001、DEP-WIN-003） | Not started |
| Phase 4 | 队列、暂停、取消可靠性（PROC-001、PROC-MAC-002） | Not started |
| Phase 5 | 设置可靠性与跨平台一致性（SETTINGS-001、DATA-SETTINGS-002、PATH-WIN-001、PARITY-001/002、UPDATE-MAC-001） | **Done (code)** — 全部完成（真机/UI 验证待定） |
| Phase 6 | UI/UX 与无障碍 | Not started（UI 重，难单测，需真机） |
| Phase 7 | 正式发布链路（签名、notarization、stable/beta channel、真机矩阵） | **Blocked** — 需 Apple Developer ID 与 Authenticode 证书等外部资源，本环境无法产出已签名包 |

---

## 后续执行计划与门槛（供审查）

本批改动均为**可在本机用单测验证**的项。以下为剩余项的执行约束与建议，未盲目落地：

### SEC-CRED-001（P0，凭证安全存储）——需评审 + 真机验证后落地
**为何未在本会话落地**：这是对两端 `Settings` 凭证持久化的核心改造，DPAPI（Windows）/ Keychain（macOS）
**无法在本机运行时验证**，且迁移写错会丢用户 Token。盲改违背「保护凭证 / 不堆未验证复杂度」。

**建议实现（可注入抽象 + 假存储单测迁移编排）**：
1. 定义 `ICredentialStore`（C#）/ `CredentialStore`（Swift）：`Get/Set/Delete(key)`。
   - Windows 实现：DPAPI `ProtectedData`（CurrentUser），密文存 `%APPDATA%\Moongate\credentials.dat`（key→base64）。
   - macOS 实现：Keychain Services 通用密码项。
   - 非目标平台（跨平台 dev/test）：可注入的内存/文件 fallback，单测用假实现。
2. `Settings.Save`：先把 3 个 token 写入 store，**成功后**再写不含明文 token 的 settings.json；store 写失败则抛错、保留旧明文，绝不清除。
3. `Settings.Load`：读 JSON（无 token）后从 store 覆盖 token。
4. 迁移：若旧 JSON 仍含明文 token → 写入 store 成功后，原子改写 JSON 去除明文；确认后才算迁移完成。
5. 单测（假存储）：迁移成功、store 写失败时旧 token 不丢、多 provider 独立、日志/异常不含 token。
6. **真机验证**：Windows DPAPI 跨重启可读、换用户不可读；macOS Keychain 首次授权、清除凭证。

### 其余可继续的纯逻辑项（低风险，可单测）
- PARITY-002：Windows `AppSettings` 增 last* 字段 + MainViewModel 选档页 restore/persist（settings 往返可单测）。
- DEP-WIN-003：结构化依赖健康检查（--version / -filters 解析可单测；实际 exec 需依赖在位）。
- DEP-SUPPLY-001：固定版本 manifest + 下载后 SHA-256 校验（manifest 解析 + 校验逻辑可单测）。
- MAC-DEP-001：删除或严格限制「卸载 Homebrew 依赖」，记录实际 provider（检测映射可单测）。
- PROC-001 / PROC-MAC-002：暂停返回成功/失败、失败不释放槽位、进程组取消（状态机可单测；真机压力测试需真机）。
- SETTINGS-001(mac)：`requestLogin/requestDependencySetup` 检查保存结果，失败不跳转。

### 真正的外部门槛（本环境不可完成）
- Phase 7 全部：macOS Developer ID + hardened runtime + notarization + staple；Windows Authenticode 签名；
  更新器验证发布者。均需**付费证书 / Apple 账号**，只能产出脚本与文档，无法生成真正已签名的发布包。
- REL-WIN-002 / 真机测试矩阵：需真实 Windows / macOS 机器跑安装、更新、卸载、DPI、WebView2、杀软等。

