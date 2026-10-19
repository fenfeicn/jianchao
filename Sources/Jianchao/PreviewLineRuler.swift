import AppKit
import ClipCore

/// A sibling of the scroll view, rather than an NSRulerView: toggling a ruler
/// inside SwiftUI's size negotiation can repeatedly retile the text container.
/// Drawing uses cached geometry only and never asks TextKit to perform layout.
final class PreviewLineGutter: NSView {
    weak var textView: NSTextView?
    weak var scrollView: NSScrollView?
    private var index = TextLineIndex("")
    private var labels: [(String, CGFloat)] = []
    private var observers: [NSObjectProtocol] = []
    private var refreshPending = false
    var visibleLabelCount: Int { labels.count }
    var preferredWidth: CGFloat { index.showsNumbers ? CGFloat(max(2, String(index.starts.count).count)) * 7 + 18 : 0 }
    override var isFlipped: Bool { true }

    init(scroll: NSScrollView, text: NSTextView) {
        super.init(frame: .zero)
        clipsToBounds = true
        textView = text; scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        text.postsFrameChangedNotifications = true
        for (name, object) in [(NSView.boundsDidChangeNotification, scroll.contentView as NSView), (NSView.frameDidChangeNotification, text as NSView)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.scheduleRefresh() })
        }
        setAccessibilityLabel("文本行号")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func update(text: String) {
        index = TextLineIndex(text); labels = []; needsDisplay = true; scheduleRefresh()
    }
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false; self.refreshGeometry()
        }
    }
    private func refreshGeometry() {
        labels = []
        defer { needsDisplay = true }
        guard preferredWidth > 0, bounds.height > 0, let text = textView,
              let layout = text.layoutManager, let container = text.textContainer else { return }
        let origin = text.textContainerOrigin
        let visible = text.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        guard visible.width > 0, visible.height > 0 else { return }
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let first = glyphs.length > 0 ? layout.characterIndexForGlyph(at: glyphs.location) : index.utf16Count
        let last = glyphs.length > 0 ? NSMaxRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)) : index.utf16Count
        for line in index.line(atUTF16: first)..<index.starts.count {
            let character = index.starts[line]
            if character > last { break }
            let fragment: NSRect
            if character < index.utf16Count {
                let glyph = layout.glyphIndexForCharacter(at: character)
                guard glyph < layout.numberOfGlyphs else { continue }
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else { fragment = layout.extraLineFragmentRect }
            guard fragment.height > 0 else { continue }
            let point = convert(NSPoint(x: origin.x, y: origin.y + fragment.minY), from: text)
            if point.y + fragment.height >= 0 && point.y < bounds.height { labels.append(("\(line + 1)", point.y + 3)) }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.35).setFill(); dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for (value, y) in labels {
            let label = value as NSString
            label.draw(at: NSPoint(x: bounds.maxX - label.size(withAttributes: attributes).width - 9, y: y), withAttributes: attributes)
        }
    }
}

final class PreviewTextContainer: NSView {
    let scroll = NSScrollView()
    let text: NSTextView
    var previousRanges: [NSRange] = []
    var previousActiveRange: NSRange?
    let gutter: PreviewLineGutter
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override init(frame: NSRect) {
        // Explicit TextKit 1 stack avoids switching engines while painting.
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.allowsNonContiguousLayout = true
        text = NSTextView(frame: .zero, textContainer: container)
        gutter = PreviewLineGutter(scroll: scroll, text: text)
        super.init(frame: frame)
        clipsToBounds = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.drawsBackground = false; text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 2, height: 6)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        container.widthTracksTextView = true
        text.setAccessibilityLabel("当前文本预览")
        scroll.documentView = text
        addSubview(gutter); addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func updateGutter(_ value: String) { gutter.update(text: value); needsLayout = true }
    override func layout() {
        super.layout()
        let width = min(gutter.preferredWidth, bounds.width)
        gutter.isHidden = width == 0
        let gutterFrame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let scrollFrame = NSRect(x: width + (width > 0 ? 6 : 0), y: 0, width: max(0, bounds.width - width - (width > 0 ? 6 : 0)), height: bounds.height)
        if gutter.frame != gutterFrame { gutter.frame = gutterFrame }
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        gutter.scheduleRefresh()
    }
}
