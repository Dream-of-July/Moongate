import Foundation

// MARK: - 语义版本

/// 简单语义版本：major.minor.patch，容忍前缀 "v" 和多余段。
public struct SemVer: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 从 "v0.4.0" / "0.4" / "0.4.0-beta" 等解析；失败返回 nil。
    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // 去掉构建/预发布后缀（- 或 + 之后）。
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<cut])
        }
        let parts = s.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        self.patch = parts.count > 2 ? (parts[2] ?? 0) : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
// MARK: - 更新信息

public struct UpdateInfo: Sendable, Equatable {
    public let version: SemVer
    public let tag: String
    public let notes: String
    public let dmgURL: URL
    public let assetName: String

    public init(version: SemVer, tag: String, notes: String, dmgURL: URL, assetName: String) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.dmgURL = dmgURL
        self.assetName = assetName
    }
}

// MARK: - 更新检查

public struct UpdateChecker: Sendable {
    public let owner: String
    public let repo: String

    public init(owner: String = "Dream-of-July", repo: String = "moongate") {
        self.owner = owner
        self.repo = repo
    }

    /// 仓库 releases 页（失败兜底引导用户手动下载）。
    public var releasesPageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    }

    /// 查询 GitHub releases，返回比 currentVersion 更新的 macOS 版本；无更新返回 nil。
    /// 公开仓库匿名访问即可；超时短、失败抛错由调用方决定是否静默。
    public func checkForUpdate(currentVersion: String) async throws -> UpdateInfo? {
        guard let current = SemVer(currentVersion) else {
            throw MoongateError.updateFailed("无法解析当前版本号：\(currentVersion)")
        }
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20")!)
        // GitHub API 在代理/VPN 环境下偶尔需要更长握手时间；保持和 Windows 更新器一致。
        request.timeoutInterval = 45
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub 要求带 User-Agent，否则可能被拒。
        request.setValue("MoongateUpdater", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw MoongateError.cancelled }
            if error.code == .timedOut {
                throw MoongateError.updateFailed("连接更新服务器超时。若在中国大陆，请检查代理/VPN 是否开启并能正常访问 GitHub。")
            }
            throw MoongateError.updateFailed("无法连接到更新服务器，请检查网络与代理设置。")
        }
        guard let http = response as? HTTPURLResponse else {
            throw MoongateError.updateFailed("更新服务器返回了无效响应。")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 {
                throw MoongateError.updateFailed("更新检查过于频繁（GitHub 限流），请稍后再试。")
            }
            throw MoongateError.updateFailed("HTTP \(http.statusCode)。")
        }
        return Self.latestMacUpdate(fromReleasesJSON: data, currentVersion: current)
    }

    /// 纯解析：从 releases 列表 JSON 里挑出含 macOS DMG 资产、版本号最高且 > current 的 release。
    /// 与网络解耦，便于测试。
    public static func latestMacUpdate(
        fromReleasesJSON data: Data,
        currentVersion current: SemVer
    ) -> UpdateInfo? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var candidates: [UpdateInfo] = []
        for release in array {
            // 草稿跳过；预发布也接受（项目目前全是 prerelease）。
            if (release["draft"] as? Bool) == true { continue }
            let tag = (release["tag_name"] as? String) ?? (release["name"] as? String) ?? ""
            guard let version = SemVer(tag) else { continue }
            let notes = (release["body"] as? String) ?? ""
            let assets = (release["assets"] as? [[String: Any]]) ?? []
            // macOS DMG 资产：名字含 "mac" 且以 .dmg 结尾。
            guard let asset = assets.first(where: { asset in
                let name = ((asset["name"] as? String) ?? "").lowercased()
                return name.hasSuffix(".dmg")
                    && name.contains("mac")
                    && Self.assetName(name, matches: version)
            }),
                  let assetName = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else { continue }
            candidates.append(UpdateInfo(
                version: version, tag: tag, notes: notes, dmgURL: url, assetName: assetName
            ))
        }
        guard let newest = candidates.max(by: { $0.version < $1.version }) else { return nil }
        return newest.version > current ? newest : nil
    }

    // MARK: 安装辅助（纯函数，跨平台可测；实际执行在 macOS UpdateService）

    /// 只接受 GitHub 该仓库 releases 下载地址的 https DMG。
    public static func isTrustedDMGURL(_ url: URL, owner: String, repo: String) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased(),
              host == "github.com" else { return false }
        guard url.path.lowercased().hasSuffix(".dmg") else { return false }
        return url.path.hasPrefix("/\(owner)/\(repo)/releases/download/")
    }

    private static func assetName(_ name: String, matches version: SemVer) -> Bool {
        let regex = try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])v?\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?(?=$|[^A-Za-z0-9]|\.[A-Za-z]{2,5}$)"#,
            options: [.caseInsensitive]
        )
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.matches(in: name, range: range).contains { match in
            guard let matchRange = Range(match.range, in: name) else { return false }
            return SemVer(String(name[matchRange])) == version
        }
    }

    /// 生成替换脚本：等旧进程退出 → 复制到临时目录 → 备份交换 → 去 quarantine → 重开。
    /// 先完整准备新 App，再替换目标路径，避免失败后留下空安装。
    public static func installScript(mountedAppPath: String, targetAppPath: String, pid: Int32) -> String {
        let mount = mountedAppPath.replacingOccurrences(of: "'", with: "'\\''")
        let target = targetAppPath.replacingOccurrences(of: "'", with: "'\\''")
        return """
        #!/bin/zsh
        # 等待旧进程退出（最多 ~30s）
        for i in {1..60}; do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.5
        done
        parent="$(/usr/bin/dirname '\(target)')"
        targetBase="$(/usr/bin/basename '\(target)')"
        tmp="$(/usr/bin/mktemp -d "$parent/.moongate-update.XXXXXX")" || exit 1
        newApp="$tmp/$targetBase"
        backup="$parent/.moongate-previous-$targetBase"
        /usr/bin/ditto '\(mount)' "$newApp" || { /bin/rm -rf "$tmp"; exit 1; }
        /usr/bin/xattr -dr com.apple.quarantine "$newApp" 2>/dev/null
        /bin/rm -rf "$backup"
        if [ -e '\(target)' ]; then
          /bin/mv '\(target)' "$backup" || { /bin/rm -rf "$tmp"; exit 1; }
        fi
        if ! /bin/mv "$newApp" '\(target)'; then
          if [ -e "$backup" ]; then /bin/mv "$backup" '\(target)'; fi
          /bin/rm -rf "$tmp"
          exit 1
        fi
        /bin/rm -rf "$backup" "$tmp"
        /usr/bin/xattr -dr com.apple.quarantine '\(target)' 2>/dev/null
        /usr/bin/open '\(target)'
        """
    }
}
