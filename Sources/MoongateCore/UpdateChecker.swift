import Foundation

// MARK: - 语义版本

/// 简单语义版本：major.minor.patch，容忍前缀 "v" 和多余段。
/// macOS App 内更新从 0.7 起交给 Sparkle；Windows 更新器使用独立 C# 实现。
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
