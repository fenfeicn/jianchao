import Foundation

enum AppIdentity {
    // A running process may retain stale TCC state if its app bundle is rebuilt.
    private static let launchedExecutableDate = executableDate
    static func recordLaunch() { _ = launchedExecutableDate }
    static var wasReplacedWhileRunning: Bool { executableDate != launchedExecutableDate }
    private static var executableDate: Date? {
        guard let url = Bundle.main.executableURL else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "开发版") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }
    static var author: String { Bundle.main.object(forInfoDictionaryKey: "JianchaoAuthor") as? String ?? "hck" }
    static var feedbackEmail: String { Bundle.main.object(forInfoDictionaryKey: "JianchaoFeedbackEmail") as? String ?? "87975531@qq.com" }
    static var copyright: String { Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 hck · MIT License" }
    static var signingDescription: String {
        switch Bundle.main.object(forInfoDictionaryKey: "JianchaoSigningMode") as? String {
        case "distribution": return "分发签名"
        case "local": return "固定本地开发签名"
        default: return "临时开发签名"
        }
    }
    static var architecture: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }
    static var feedbackURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackEmail
        components.queryItems = [.init(name: "subject", value: "剪巢 \(version) · 问题反馈"),
                                 .init(name: "body", value: "问题描述：\n\n复现步骤：\n\n预期结果：\n\n可附上「关于剪巢」中复制的诊断信息。")]
        return components.url
    }
}
