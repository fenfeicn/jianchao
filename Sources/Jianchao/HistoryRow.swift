import SwiftUI
import AppKit
import ClipCore

struct HistoryRow: View {
    let item: HistoryItem
    let selected: Bool
    let quickIndex: Int?
    let directPaste: Bool
    let assetsDirectory: URL?
    let select: () -> Void
    let use: () -> Void
    let copy: () -> Void
    let favorite: () -> Void
    let delete: () -> Void
    @ViewState private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 12) {
                    ContentIcon(item: item, assetsDirectory: assetsDirectory)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 5) {
                            Text(item.source.name).lineLimit(1)
                            Text("·")
                            Text(item.lastCopiedAt.formatted(date: .omitted, time: .shortened))
                            if item.isImagePreviewable { Text("· 图片") }
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).padding(.vertical, 12)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded(use))
                .accessibilityLabel(item.title + "，" + item.source.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(directPaste ? "单击预览，双击粘贴" : "单击预览，双击复制")
            Button(action: favorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12)).foregroundStyle(item.isFavorite ? Theme.accent : Theme.secondary)
                    .opacity(item.isFavorite || selected || hovered ? 1 : 0.35)
                    .frame(width: 30, height: 40).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.trailing, 5)
                .accessibilityLabel((item.isFavorite ? "取消收藏：" : "收藏：") + item.title)
        }
        .frame(height: 76)
        .background(selected ? Theme.accent.opacity(0.10) : hovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent.opacity(0.22) : .clear, lineWidth: 0.7))
        .onHover { hovered = $0 }
        .contextMenu {
            Button(directPaste ? "粘贴内容" : "复制内容", action: use)
            if directPaste { Button("仅复制", action: copy) }
            Button(item.isFavorite ? "取消收藏" : "收藏", action: favorite)
            Divider()
            Button("删除记录", role: .destructive, action: delete)
        }
        .overlay(alignment: .topTrailing) {
            if let quickIndex {
                Text("⌘\(quickIndex)").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                    .padding(.top, 5).padding(.trailing, 10).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

struct ContentIcon: View {
    let item: HistoryItem
    let assetsDirectory: URL?
    var body: some View {
        Group {
            if item.isImagePreviewable {
                AsyncLocalImage(url: item.thumbnailURL(in: assetsDirectory),
                                fallback: item.previewImageURL(in: assetsDirectory), maximumPixels: 180, contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 9).fill(Theme.detail)
                    .overlay(Image(systemName: item.symbol).font(.system(size: 20, weight: .light)).foregroundStyle(.secondary))
            }
        }.frame(width: 56, height: 48).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct AsyncLocalImage: View {
    let url: URL?
    var fallback: URL? = nil
    var maximumPixels = 1_600
    var contentMode: ContentMode = .fit
    var showsError = false
    @ViewState private var image: NSImage?
    @ViewState private var failed = false
    private var identity: String { "\(url?.path ?? "")|\(fallback?.path ?? "")|\(maximumPixels)" }
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 25, weight: .light))
                    if showsError { Text("图片文件不可用").font(.system(size: 13)); Text("可以删除这条记录，重新复制原图。").font(.system(size: 12)) }
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: identity) {
            image = nil; failed = false
            do {
                let data = try await ClipCore.ImageRenderer.shared.render(primary: url, fallback: fallback, maximumPixels: maximumPixels)
                guard !Task.isCancelled else { return }
                image = NSImage(data: data); failed = image == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct ClipDetailView: View {
    let item: HistoryItem
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: item.symbol).foregroundStyle(Theme.accent)
                Text(item.kind.title).fontWeight(.medium)
                Spacer()
                if item.kind == .text {
                    Button { model.previewFind.open() } label: { Label("查找", systemImage: "magnifyingglass") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("查找当前内容 · ⌘F")
                    Divider().frame(height: 12).padding(.horizontal, 5)
                }
                Button { model.toggleFavorite(item) } label: {
                    Label(item.isFavorite ? "已收藏" : "收藏", systemImage: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? Theme.accent : Theme.secondary)
                }.buttonStyle(.plain).help("收藏 · ⌘D")
            }.font(.system(size: 12)).padding(.bottom, 20)

            if item.isImagePreviewable {
                Text(item.kind == .file ? "图片文件预览" : "图片预览").font(.system(size: 18, weight: .semibold)).padding(.bottom, 14)
                Button { model.showImage?(item) } label: {
                    ZStack {
                        Checkerboard().opacity(0.45)
                        AsyncLocalImage(url: item.previewImageURL(in: model.assetsDirectory),
                                        fallback: item.thumbnailURL(in: model.assetsDirectory), showsError: true)
                            .padding(14)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 0.7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("放大图片预览").help("点击放大 · ⌘Y")
                HStack {
                    Text(item.kind == .file ? (item.referencedImageURL?.lastPathComponent ?? "原文件引用") : "\(item.imageWidth ?? 0) × \(item.imageHeight ?? 0) · \(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))")
                    Spacer()
                    Button { model.showImage?(item) } label: { Label("放大", systemImage: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain)
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
            } else if item.kind == .text {
                if let text = item.text { TextPreviewView(text: text, find: model.previewFind) }
                else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.on.doc").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(Theme.accent)
                    Text(item.title).font(.system(size: 17, weight: .medium)).multilineTextAlignment(.center)
                    Text("保存的是文件引用，不会复制原文件。").font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(item.fileURLs, id: \.self) { url in Text(url.path).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().padding(.top, 20).padding(.bottom, 14)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.source.name).font(.system(size: 12, weight: .medium))
                    Text(item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.wantsDirectPaste {
                    ChromeButton(symbol: "doc.on.doc", label: "仅复制到剪贴板，稍后自行粘贴 · ⌘Return") { model.use(item, copyOnly: true) }
                        .disabled(model.isUsingItem)
                }
                Button { model.use(item) } label: {
                    HStack(spacing: 8) {
                        Text(model.wantsDirectPaste ? (item.kind == .file ? "粘贴文件" : "粘贴内容") : item.kind == .file ? "复制文件" : "复制内容")
                        Text("↵").opacity(0.7)
                    }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
                }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large).disabled(model.isUsingItem)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.detail)
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.primary.opacity(0.025)))
            for row in 0..<Int(ceil(size.height / 12)) {
                for column in 0..<Int(ceil(size.width / 12)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: column * 12, y: row * 12, width: 12, height: 12)), with: .color(Color.primary.opacity(0.055)))
                }
            }
        }.accessibilityHidden(true)
    }
}

struct ImageViewerView: View {
    let item: HistoryItem
    let directory: URL?
    @ViewState private var zoom: CGFloat = 1
    @ViewState private var startingZoom: CGFloat = 1
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(item.kind == .file ? (item.referencedImageURL?.lastPathComponent ?? "图片文件") : "\(item.imageWidth ?? 0) × \(item.imageHeight ?? 0)").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button { setZoom(zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
                Button("适应窗口") { setZoom(1) }
                Text("\(Int(zoom * 100))% ").monospacedDigit().frame(width: 45)
                Button { setZoom(zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
            }.buttonStyle(.borderless).padding(16)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    AsyncLocalImage(url: item.previewImageURL(in: directory), maximumPixels: 4_096, showsError: true)
                        .padding(20).frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                }.background(Checkerboard())
                    .gesture(MagnifyGesture().onChanged { value in zoom = min(4, max(0.5, startingZoom * value.magnification)) }.onEnded { _ in startingZoom = zoom })
            }
        }.background(Theme.detail).frame(minWidth: 500, minHeight: 360)
    }
    private func setZoom(_ value: CGFloat) { zoom = min(4, max(0.5, value)); startingZoom = zoom }
}
