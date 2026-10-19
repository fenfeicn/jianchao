import Foundation
import CryptoKit
import UniformTypeIdentifiers

public enum ContentKind: String, Codable, CaseIterable, Sendable {
    case text, image, file
    public var title: String {
        switch self { case .text: return "文本"; case .image: return "图片"; case .file: return "文件" }
    }
    public var symbol: String {
        switch self { case .text: return "text.alignleft"; case .image: return "photo"; case .file: return "doc.on.doc" }
    }
}

public struct SourceApplication: Codable, Equatable, Sendable {
    public var name: String
    public var bundleID: String?
    public init(name: String = "来源未知", bundleID: String? = nil) { self.name = name; self.bundleID = bundleID }
}

public enum ClipPayload: Sendable {
    case text(String)
    case image(Data, type: String)
    case files([URL])
    public var kind: ContentKind {
        switch self { case .text: return .text; case .image: return .image; case .files: return .file }
    }
    public var byteCount: Int {
        switch self {
        case .text(let text): return text.utf8.count
        case .image(let data, _): return data.count
        case .files(let urls): return urls.reduce(0) { $0 + $1.absoluteString.utf8.count }
        }
    }
    public var fingerprint: String {
        var hash = SHA256()
        hash.update(data: Data(kind.rawValue.utf8))
        switch self {
        case .text(let text): hash.update(data: Data(text.utf8))
        case .image(let data, let type): hash.update(data: Data(type.utf8)); hash.update(data: data)
        case .files(let urls):
            // JSON preserves boundaries and order, including filenames containing newlines.
            hash.update(data: (try? JSONEncoder().encode(urls.map(\.absoluteString))) ?? Data())
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct CapturedClip: Sendable {
    public let payload: ClipPayload
    public let source: SourceApplication
    public let date: Date
    public init(payload: ClipPayload, source: SourceApplication = .init(), date: Date = Date()) {
        self.payload = payload; self.source = source; self.date = date
    }
}

public struct HistoryItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let fingerprint: String
    public let kind: ContentKind
    public var title: String
    public var text: String?
    public var fileURLs: [URL]
    public var imageType: String?
    public var imageFilename: String?
    public var thumbnailFilename: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var source: SourceApplication
    public let createdAt: Date
    public var lastCopiedAt: Date
    public var isFavorite: Bool
    public var byteCount: Int
    /// Preview Finder image references without changing their clipboard representation.
    public var referencedImageURL: URL? {
        guard kind == .file, fileURLs.count == 1, let url = fileURLs.first else { return nil }
        let suffix = url.pathExtension.lowercased()
        let commonImages: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "gif", "heic", "heif", "webp", "bmp", "avif", "icns", "ico"]
        guard commonImages.contains(suffix) || UTType(filenameExtension: suffix)?.conforms(to: .image) == true else { return nil }
        return url
    }
    public var isImagePreviewable: Bool { kind == .image || referencedImageURL != nil }
    public func previewImageURL(in directory: URL?) -> URL? {
        if let referencedImageURL { return referencedImageURL }
        return imageFilename.flatMap { directory?.appendingPathComponent($0) }
    }
    public func thumbnailURL(in directory: URL?) -> URL? {
        if let referencedImageURL { return referencedImageURL }
        return thumbnailFilename.flatMap { directory?.appendingPathComponent($0) }
    }
    public var searchText: String {
        [text ?? title, fileURLs.map(\.path).joined(separator: " "), source.name].joined(separator: " ")
    }
    public var symbol: String {
        if kind == .text, let url = URL(string: (text ?? title).trimmingCharacters(in: .whitespacesAndNewlines)),
           ["https", "http"].contains(url.scheme?.lowercased() ?? "") { return "link" }
        return kind.symbol
    }
}

public struct RetentionPolicy: Sendable {
    public var days: Int
    public var maximumItems: Int
    public var maximumBytes: Int
    /// Zero days disables age expiry; count and disk limits always remain active.
    public init(days: Int = 30, maximumItems: Int = 5_000, maximumBytes: Int = 500 * 1_024 * 1_024) {
        self.days = max(0, days); self.maximumItems = max(1, maximumItems); self.maximumBytes = max(1_024, maximumBytes)
    }
}

public enum ClipError: LocalizedError {
    case storage(String), invalidImage, tooLarge, capacity, unavailableFile, unavailableImage, missingContent
    public var errorDescription: String? {
        switch self {
        case .storage: return "无法保存历史，请检查存储空间与文件夹权限。"
        case .invalidImage: return "这张图片无法读取，已跳过记录。"
        case .tooLarge: return "内容超过大小限制，已跳过记录。"
        case .capacity: return "收藏已占满存储预算，请先删除部分内容。"
        case .unavailableFile: return "原文件已移动、删除或无法访问。"
        case .unavailableImage: return "图片临时文件已失效或无法读取。请打开原图后重新复制。"
        case .missingContent: return "这条内容已不可用，可以将它删除。"
        }
    }
}

public enum SearchEngine {
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func filter(_ items: [HistoryItem], query: String, kind: ContentKind?, favoritesOnly: Bool, dateInterval: DateInterval? = nil) -> [HistoryItem] {
        let terms = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            if let dateInterval, !(item.lastCopiedAt >= dateInterval.start && item.lastCopiedAt < dateInterval.end) { return false }
            let matchesKind = kind == nil || item.kind == kind || (kind == .image && item.isImagePreviewable)
            guard matchesKind, !favoritesOnly || item.isFavorite else { return false }
            guard !terms.isEmpty else { return true }
            let content = normalize(item.searchText)
            return terms.allSatisfy { content.contains($0) }
        }.sorted { left, right in
            if !terms.isEmpty {
                let a = terms.allSatisfy { normalize(left.title).contains($0) }
                let b = terms.allSatisfy { normalize(right.title).contains($0) }
                if a != b { return a }
            }
            if left.lastCopiedAt == right.lastCopiedAt { return left.id < right.id }
            return left.lastCopiedAt > right.lastCopiedAt
        }
    }
}

public enum CaptureRules {
    public static let ownType = "local.jianchao.clipboard-origin"
    public static func shouldIgnore(types: Set<String>) -> Bool {
        types.contains(ownType)
    }
}

public struct HistorySearchPage: Sendable {
    public let items: [HistoryItem]
    public let total: Int
}

extension HistoryItem {
    /// Full bodies are fetched only for the selected preview or paste action.
    public var listSummary: HistoryItem {
        var result = self
        result.text = nil
        return result
    }
}
