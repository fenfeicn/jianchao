import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum CaptureResult { case unchanged, captured(CapturedClip), blocked, ignored, failed(ClipError) }

/// A single executor handles general-pasteboard reads and writes. Never decode images here.
public actor PasteboardService {
    private let board: NSPasteboard
    private var lastCount: Int
    private let ownMarker = UUID().uuidString

    public init(name: NSPasteboard.Name? = nil) {
        board = name.map(NSPasteboard.init(name:)) ?? .general
        lastCount = board.changeCount
    }
    public func resetBaseline() { lastCount = board.changeCount }

    public func poll(source: SourceApplication, skip: Bool) -> CaptureResult {
        let count = board.changeCount
        guard count != lastCount else { return .unchanged }
        lastCount = count
        guard !skip else { return .ignored }
        if #available(macOS 15.4, *), board.accessBehavior == .alwaysDeny { return .blocked }
        let types = Set((board.types ?? []).map(\.rawValue))
        // Ignore our writeback even when its marker is on a secondary item.
        let allTypes = types.union((board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        guard !CaptureRules.shouldIgnore(types: allTypes) else { return .ignored }
        if #available(macOS 15.4, *), board.accessBehavior == .alwaysDeny { return .blocked }
        let result: CaptureResult
        do {
            if let payload = try readPayload(types: allTypes, source: source) {
                result = .captured(.init(payload: payload, source: source))
            } else { result = .ignored }
        } catch { result = .failed((error as? ClipError) ?? .unavailableImage) }
        // Do not join representations from different clipboard owners.
        guard board.changeCount == count else { return .unchanged }
        if #available(macOS 15.4, *), board.accessBehavior == .alwaysDeny { return .blocked }
        return result
    }

    private func readPayload(types: Set<String>, source: SourceApplication) throws -> ClipPayload? {
        let urls = types.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
            ? (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []) : []
        // Finder selections and multiple files retain file-paste semantics.
        if !urls.isEmpty, source.bundleID == "com.apple.finder" || urls.count > 1 { return .files(urls) }
        let preferred = [UTType.png.identifier, UTType.tiff.identifier]
        let imageTypes = preferred.filter(types.contains) + types.sorted().filter {
            !preferred.contains($0) && UTType($0)?.conforms(to: .image) == true
        }
        var imageError: ClipError?
        for type in imageTypes {
            guard let data = board.data(forType: .init(type)) else { continue }
            do { return try CapturedImage.payload(data) }
            catch { imageError = (error as? ClipError) ?? .invalidImage }
        }
        if let url = urls.first {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true || !imageTypes.isEmpty {
                // Chat clients often publish only a short-lived file. Own its bytes now.
                return try CapturedImage.snapshot(url)
            }
            return .files(urls)
        }
        if let imageError { throw imageError }
        if let text = board.string(forType: .string), !text.isEmpty { return .text(text) }
        return nil
    }

    public func write(_ payload: ClipPayload) throws {
        let marker = NSPasteboard.PasteboardType(CaptureRules.ownType)
        var items: [NSPasteboardItem] = []
        switch payload {
        case .text(let text):
            let item = NSPasteboardItem(); item.setString(text, forType: .string); items = [item]
        case .image(let data, let type):
            let item = NSPasteboardItem(); item.setData(data, forType: .init(type)); items = [item]
        case .files(let urls):
            guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw ClipError.unavailableFile }
            items = urls.map { url in let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item }
        }
        items.forEach { $0.setString(ownMarker, forType: marker) }
        board.clearContents()
        guard board.writeObjects(items) else { throw ClipError.missingContent }
        lastCount = board.changeCount
    }
}

/// Validate encoded headers without rasterizing on the clipboard polling path.
private enum CapturedImage {
    static let maximumBytes = 20 * 1_024 * 1_024
    static func payload(_ data: Data) throws -> ClipPayload {
        guard data.count <= maximumBytes else { throw ClipError.tooLarge }
        guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(image),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height else { throw ClipError.invalidImage }
        return .image(data, type: type as String)
    }
    static func snapshot(_ url: URL) throws -> ClipPayload {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else { throw ClipError.unavailableImage }
        guard size <= maximumBytes else { throw ClipError.tooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ClipError.unavailableImage }
        defer { try? handle.close() }
        // Bound the read even if the file grows after checking its metadata.
        guard let data = try? handle.read(upToCount: maximumBytes + 1) else { throw ClipError.unavailableImage }
        return try payload(data)
    }
}
