import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decode a bounded image off the UI actor. The original is used for large previews;
/// a missing thumbnail falls back to it, including records made by older builds.
public actor ImageRenderer {
    public static let shared = ImageRenderer()
    private let cache = NSCache<NSString, NSData>()

    public init() { cache.totalCostLimit = 40 * 1_024 * 1_024 }

    public func render(primary: URL?, fallback: URL? = nil, maximumPixels: Int) throws -> Data {
        let candidates = [primary, fallback].compactMap { $0 }
        for url in candidates {
            let version = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
            let key = "\(url.path)|\(maximumPixels)|\(version)" as NSString
            if let cached = cache.object(forKey: key) { return cached as Data }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, min(maximumPixels, 4_096))
                  ] as CFDictionary) else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { continue }
            let data = output as Data
            cache.setObject(data as NSData, forKey: key, cost: data.count)
            return data
        }
        throw ClipError.missingContent
    }
}
