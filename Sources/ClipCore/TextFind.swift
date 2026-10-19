import Foundation

public struct TextFindResult: Sendable {
    public let ranges: [NSRange]
    public let truncated: Bool
}

public enum TextFind {
    /// UTF-16 ranges match NSTextView's indexing, including emoji and combining marks.
    public static func matches(in text: String, query: String, limit: Int = 5_000) -> TextFindResult {
        guard !query.isEmpty, limit > 0 else { return .init(ranges: [], truncated: false) }
        let source = text as NSString
        var ranges: [NSRange] = [], offset = 0
        while offset < source.length {
            let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if ranges.count == limit { return .init(ranges: ranges, truncated: true) }
            ranges.append(range)
            offset = NSMaxRange(range)
        }
        return .init(ranges: ranges, truncated: false)
    }
}
