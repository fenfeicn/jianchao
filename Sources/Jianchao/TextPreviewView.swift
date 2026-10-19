import AppKit
import SwiftUI
import ClipCore

@MainActor
final class PreviewFindState: ObservableObject {
    @Published var isVisible = false
    @Published var query = "" { didSet { if query != oldValue { search() } } }
    @Published private(set) var ranges: [NSRange] = []
    @Published private(set) var index = 0
    @Published private(set) var truncated = false
    @Published private(set) var searching = false
    @Published private(set) var focusRequest = 0
    var fieldFocused = false
    private var content = ""
    private var task: Task<Void, Never>?
    private var generation = 0

    var activeRange: NSRange? { ranges.indices.contains(index) ? ranges[index] : nil }
    var countLabel: String {
        if searching { return "查找中…" }
        if query.isEmpty { return "" }
        return ranges.isEmpty ? "无匹配" : "\(index + 1)/\(ranges.count)\(truncated ? "+" : "")"
    }
    func setContent(_ text: String) { content = text; search() }
    func open() { isVisible = true; focusRequest += 1 }
    func close() { isVisible = false; fieldFocused = false; query = "" }
    func reset() { task?.cancel(); generation += 1; close(); content = ""; ranges = []; index = 0; truncated = false; searching = false }
    func move(_ delta: Int) {
        guard !ranges.isEmpty, !searching else { return }
        index = (index + delta + ranges.count) % ranges.count
    }
    private func search() {
        task?.cancel(); generation += 1
        let version = generation, text = content, term = query
        ranges = []; index = 0; truncated = false
        guard !term.isEmpty else { searching = false; return }
        searching = true
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) { TextFind.matches(in: text, query: term) }.value
            guard !Task.isCancelled, let self, generation == version else { return }
            ranges = result.ranges; truncated = result.truncated; searching = false
        }
    }
}

struct TextPreviewView: View {
    let text: String
    @ObservedObject var find: PreviewFindState
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            if find.isVisible {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("在当前内容中查找…", text: $find.query)
                        .textFieldStyle(.plain).font(.system(size: 12)).focused($fieldFocused)
                        .accessibilityLabel("在当前预览中查找")
                        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                    Text(find.countLabel).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize().accessibilityLabel("匹配结果：\(find.countLabel)")
                        .help(find.truncated ? "仅标记前 5,000 处，请输入更具体的关键词。" : "")
                    findButton("chevron.up", "上一个匹配 · ⇧⌘G", enabled: !find.ranges.isEmpty) { find.move(-1) }
                    findButton("chevron.down", "下一个匹配 · ⌘G", enabled: !find.ranges.isEmpty) { find.move(1) }
                    findButton("xmark", "关闭内容查找 · Esc") { find.close() }
                }.padding(.horizontal, 10).frame(height: 36)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 0.7))
            }
            SelectablePreviewText(text: text, ranges: find.ranges, activeRange: find.activeRange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { find.setContent(text) }
        .onChange(of: text) { _, value in find.setContent(value) }
        .onChange(of: find.focusRequest) { _, _ in DispatchQueue.main.async { fieldFocused = true } }
        .onChange(of: find.isVisible) { _, visible in if !visible { fieldFocused = false } }
        .onChange(of: fieldFocused) { _, focused in find.fieldFocused = focused }
        .onDisappear { find.fieldFocused = false }
    }
    private func findButton(_ symbol: String, _ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .frame(width: 24, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label).disabled(!enabled)
    }
}

private struct SelectablePreviewText: NSViewRepresentable {
    let text: String
    let ranges: [NSRange]
    let activeRange: NSRange?

    func makeNSView(context: Context) -> PreviewTextContainer { PreviewTextContainer(frame: .zero) }
    func updateNSView(_ container: PreviewTextContainer, context: Context) {
        container.setContent(text, ranges: ranges, activeRange: activeRange)
    }
}

extension PreviewTextContainer {
    func setContent(_ text: String, ranges: [NSRange], activeRange: NSRange?) {
        let container = self
        let view = container.text
        // SwiftUI may deliver the new content before the find model resets its
        // previous matches. Never pass stale UTF-16 ranges to TextKit.
        let length = (text as NSString).length
        let ranges = ranges.filter { $0.location != NSNotFound && $0.location <= length && $0.length <= length - $0.location }
        let activeRange = activeRange.flatMap { range -> NSRange? in
            range.location != NSNotFound && range.location <= length && range.length <= length - range.location ? range : nil
        }
        let contentChanged = view.string != text
        if contentChanged {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: text.contains("{") ? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular) : NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]))
            view.setSelectedRange(NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            container.updateGutter(text)
        }
        let changedRanges = contentChanged || previousRanges != ranges
        if changedRanges {
            view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
            view.layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
            for range in ranges {
                view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), forCharacterRange: range)
            }
            previousRanges = ranges
        }
        if contentChanged || changedRanges || previousActiveRange != activeRange {
            if !changedRanges, let old = previousActiveRange {
                view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), forCharacterRange: old)
                view.layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old)
            }
            if let activeRange {
                view.layoutManager?.addTemporaryAttributes([
                    .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.55),
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], forCharacterRange: activeRange)
                view.scrollRangeToVisible(activeRange)
            }
            previousActiveRange = activeRange
        }
    }
}
