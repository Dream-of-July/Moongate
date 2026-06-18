; 月之门 Windows 安装器（NSIS，在 macOS 上用 brew 的 makensis 交叉构建）
; 设计目标：双击即装、无需管理员权限（装到当前用户目录）、开始菜单/桌面快捷方式、可卸载。
; 构建参数（由 build-windows.sh 传入）：
;   /DPUBLISH_DIR=<dotnet publish 输出目录>  /DOUTFILE=<安装器输出路径>  /DAPPVERSION=<版本>

Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!ifndef APPVERSION
  !define APPVERSION "0.7.2"
!endif
!ifndef ICON_PATH
  !define ICON_PATH "windows/assets/app-nsis.ico"
!endif

!define APPNAME "月之门"
!define EXENAME "Moongate.exe"
!define INSTALL_MARKER ".moongate-install-root"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Moongate"

Name "${APPNAME}"
OutFile "${OUTFILE}"
; 每用户安装，免 UAC 弹窗（与“允许用户直接安装”的诉求一致）
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
SetCompressor /SOLID lzma

!define MUI_ICON "${ICON_PATH}"
!define MUI_UNICON "${ICON_PATH}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXENAME}"
!define MUI_FINISHPAGE_RUN_TEXT "$(RunApp)"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; UX-WIN-003：与 App 一致支持简中/英文/繁中。多语言插入后 MUI 内置对话框按系统语言自动选择。
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "TradChinese"

; 自定义文案的本地化（MUI 只本地化内置文本，这些自定义串需 LangString）。
LangString SecCore ${LANG_SIMPCHINESE} "安装 ${APPNAME}"
LangString SecCore ${LANG_ENGLISH} "Install ${APPNAME}"
LangString SecCore ${LANG_TRADCHINESE} "安裝 ${APPNAME}"
LangString SecDesktop ${LANG_SIMPCHINESE} "创建桌面快捷方式"
LangString SecDesktop ${LANG_ENGLISH} "Create a desktop shortcut"
LangString SecDesktop ${LANG_TRADCHINESE} "建立桌面捷徑"
LangString RunApp ${LANG_SIMPCHINESE} "立即运行 ${APPNAME}"
LangString RunApp ${LANG_ENGLISH} "Run ${APPNAME} now"
LangString RunApp ${LANG_TRADCHINESE} "立即執行 ${APPNAME}"
LangString DataPrompt ${LANG_SIMPCHINESE} "是否同时删除用户数据？$\r$\n包含：设置、API 凭证、登录 Cookie 与 WebView 登录态（%APPDATA%\Moongate），以及已下载的 yt-dlp/ffmpeg/deno（%LOCALAPPDATA%\Moongate）。$\r$\n选择「否」保留这些数据，便于以后重装。"
LangString DataPrompt ${LANG_ENGLISH} "Also delete your user data?$\r$\nIncludes settings, API credentials, login cookies and WebView session (%APPDATA%\Moongate), plus the downloaded yt-dlp/ffmpeg/deno (%LOCALAPPDATA%\Moongate).$\r$\nChoose No to keep them for a future reinstall."
LangString DataPrompt ${LANG_TRADCHINESE} "是否同時刪除使用者資料？$\r$\n包含：設定、API 憑證、登入 Cookie 與 WebView 登入狀態（%APPDATA%\Moongate），以及已下載的 yt-dlp/ffmpeg/deno（%LOCALAPPDATA%\Moongate）。$\r$\n選擇「否」保留這些資料，方便日後重裝。"

Section "$(SecCore)" SecCoreId
  SectionIn RO
  ; 更新安装：App 以 /UPDATEPID=<pid> 启动本安装器，这里先等旧进程完全退出再覆盖文件，
  ; 避免「安装器已启动但旧 App 仍占用 $INSTDIR 文件」的竞态导致部分覆盖 / 更新后无法启动。
  ${GetParameters} $R0
  ${GetOptions} $R0 "/UPDATEPID=" $R1
  ${If} $R1 != ""
    ; OpenProcess(SYNCHRONIZE=0x00100000, FALSE, pid)
    System::Call 'kernel32::OpenProcess(i 0x00100000, i 0, i $R1) i .R2'
    ${If} $R2 <> 0
      ; 最多等 15s；旧进程已退出会立即返回。
      System::Call 'kernel32::WaitForSingleObject(i $R2, i 15000)'
      System::Call 'kernel32::CloseHandle(i $R2)'
    ${EndIf}
  ${EndIf}

  SetOutPath "$INSTDIR"
  File /r "${PUBLISH_DIR}\*"
  FileOpen $0 "$INSTDIR\${INSTALL_MARKER}" w
  FileWrite $0 "Moongate ${APPVERSION}$\r$\n"
  FileClose $0

  ; 开始菜单快捷方式始终创建；桌面快捷方式为可选组件（见下方 SecDesktop）。
  CreateShortCut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\${EXENAME}"

  ; 卸载信息（当前用户注册表，控制面板可见）
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${APPVERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\${EXENAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "月之门 · Moongate"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
  ; EstimatedSize 单位 KB
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTKEY}" "EstimatedSize" "$0"
SectionEnd

; 可选：桌面快捷方式（默认勾选，用户可在组件页取消）。
Section "$(SecDesktop)" SecDesktopId
  CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${EXENAME}"
SectionEnd

Section "Uninstall"
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  Delete "$DESKTOP\${APPNAME}.lnk"
  IfFileExists "$INSTDIR\${INSTALL_MARKER}" 0 skipRecursiveRemove
  StrCmp "$INSTDIR" "$LOCALAPPDATA\Programs\${APPNAME}" 0 skipRecursiveRemove
  Delete "$INSTDIR\${INSTALL_MARKER}"
  RMDir /r "$INSTDIR"
  Goto uninstallRegistry
skipRecursiveRemove:
  Delete "$INSTDIR\Uninstall.exe"
  Delete "$INSTDIR\${EXENAME}"
  RMDir "$INSTDIR"
uninstallRegistry:
  DeleteRegKey HKCU "${UNINSTKEY}"
  ; 询问是否删除用户数据。默认保留（便于重装免重下依赖、免重新登录）。
  ; 关键：设置 / 凭证 / Cookie / WebView2 登录态在 %APPDATA%\Moongate，
  ; 依赖缓存在 %LOCALAPPDATA%\Moongate——只删其一不会清干净登录与凭证。
  MessageBox MB_YESNO|MB_ICONQUESTION "$(DataPrompt)" IDNO keepUserData
  RMDir /r "$APPDATA\Moongate"
  RMDir /r "$LOCALAPPDATA\Moongate"
keepUserData:
SectionEnd
