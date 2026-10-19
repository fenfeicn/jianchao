import SwiftUI
import AppKit
import ClipCore

extension Notification.Name { static let focusClipSearch = Notification.Name("Jianchao.focusSearch") }

struct SearchPanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @ViewState private var showsDateRange = false
    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.14) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.onboarded {
                searchBar
                filters
                Divider()
                if model.shortcutError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text(model.hotkey.failureDescription ?? "快捷键不可用，请在设置中重新录制。")
                        Spacer()
                        Button("设置") { model.showSettings?() }
                    }.font(.system(size: 12)).foregroundStyle(Theme.accent).padding(12)
                    Divider()
                }
                HStack(spacing: 0) {
                    historyList.frame(width: 348)
                    Rectangle().fill(Theme.line).frame(width: 0.7)
                    if let item = model.selectedItem {
                        ClipDetailView(item: item, model: model).id(item.id).transition(.opacity)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "rectangle.and.text.magnifyingglass").font(.system(size: 32, weight: .ultraLight))
                            Text("选择内容，在这里预览").font(.system(size: 14))
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.detail)
                    }
                }.frame(maxHeight: .infinity).animation(motion, value: model.selectedID)
                footer
            } else { onboarding }
        }
        .background(MaterialSurface())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7))
        .onAppear { focusSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .focusClipSearch)) { _ in focusSearch() }
        .onChange(of: model.onboarded) { _, _ in focusSearch() }
        .sheet(item: $model.pendingPasteItem) { _ in DirectPastePermissionView(model: model) }
        .sheet(isPresented: $showsDateRange) {
            DateRangeSheet(current: model.dateFilter) { model.dateFilter = $0 }
        }
        .alert("暂时无法完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private func focusSearch() {
        searchFocused = false
        DispatchQueue.main.async { if model.onboarded { searchFocused = true } }
    }
    private var header: some View {
        HStack(spacing: 9) {
            BrandMark(size: 24)
            Text("剪巢").font(.system(size: 13, weight: .semibold))
            if model.isDemo { Text("演示").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3).background(Color.primary.opacity(0.05), in: Capsule()) }
            Spacer()
            if model.onboarded {
                Button {
                    if model.isDemo { model.announce("演示模式不会记录真实剪贴板") } else { model.togglePause() }
                } label: {
                    Label(model.isDemo ? "演示数据" : model.captureState == .recording ? "正在记录" : model.captureState == .paused ? "已暂停" : model.captureState.title,
                          systemImage: model.captureState == .recording ? "circle.fill" : "pause.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("点击暂停或恢复记录")
                Divider().frame(height: 14).padding(.horizontal, 6)
                ChromeButton(symbol: "gearshape", label: "设置") { model.showSettings?() }
            }
            ChromeButton(symbol: "xmark", label: "关闭面板") { model.hidePanel?() }
        }.padding(.horizontal, 18).frame(height: 48)
    }
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary)
            TextField("搜索文字、图片或文件…", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 15)).focused($searchFocused).accessibilityLabel("搜索剪贴历史")
            if !model.query.isEmpty {
                Button { model.query = ""; focusSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
            KeyCap(text: "⌥⌘ F")
        }.padding(.horizontal, 13).frame(height: 42)
            .background(Theme.detail.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(searchFocused ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
            .padding(.horizontal, 18).padding(.bottom, 12)
    }
    private var filters: some View {
        HStack(spacing: 5) {
            filterButton(nil)
            ForEach(ContentKind.allCases, id: \.self) { filterButton($0) }
            Spacer()
            Menu {
                ForEach([HistoryDateFilter.all, .today, .yesterday, .last7Days, .last30Days], id: \.title) { date in
                    Button {
                        model.dateFilter = date
                    } label: {
                        if model.dateFilter == date { Label(date.title, systemImage: "checkmark") }
                        else { Text(date.title) }
                    }
                }
                Divider()
                Button("指定日期范围…") { showsDateRange = true }
            } label: {
                Label(dateFilterLabel, systemImage: "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.dateFilter == .all ? Theme.secondary : Theme.accent)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(model.dateFilter == .all ? .clear : Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            }.menuStyle(.borderlessButton).fixedSize()
                .help(dateFilterHelp).accessibilityLabel("日期筛选：\(dateFilterLabel)")
            Button { withAnimation(motion) { model.favoritesOnly.toggle() } } label: {
                Label("收藏", systemImage: model.favoritesOnly ? "star.fill" : "star")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(model.favoritesOnly ? Theme.accent : Theme.secondary)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(model.favoritesOnly ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).accessibilityAddTraits(model.favoritesOnly ? .isSelected : [])
        }.padding(.horizontal, 18).padding(.bottom, 12)
    }
    private func filterButton(_ kind: ContentKind?) -> some View {
        let active = model.filter == kind
        return Button { withAnimation(motion) { model.filter = kind } } label: {
            HStack(spacing: 5) {
                if let kind { Image(systemName: kind.symbol).font(.system(size: 11)) }
                Text(kind?.title ?? "全部")
            }.font(.system(size: 12, weight: active ? .medium : .regular))
                .foregroundStyle(active ? Color.primary : Theme.secondary)
                .padding(.horizontal, 11).frame(height: 28)
                .background(active ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(kind?.title ?? "全部").accessibilityAddTraits(active ? .isSelected : [])
    }
    private var historyList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.favoritesOnly ? "收藏" : model.query.isEmpty && model.dateFilter == .all ? "最近复制" : "筛选结果")
                Spacer()
                Text("\(model.resultCount) 条").monospacedDigit()
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 36)
            if model.loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.results.isEmpty {
                EmptyHistoryView(searching: !model.query.isEmpty || model.filter != nil || model.dateFilter != .all, favorites: model.favoritesOnly, denied: model.captureState == .denied, retry: { Task { await model.resumeCapture() } })
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                                HistoryRow(item: item, selected: model.selectedID == item.id, quickIndex: index < 9 ? index + 1 : nil,
                                    directPaste: model.wantsDirectPaste, assetsDirectory: model.assetsDirectory,
                                    select: { model.selectedID = item.id; searchFocused = false },
                                    use: { model.use(item) }, copy: { model.use(item, copyOnly: true) },
                                    favorite: { model.toggleFavorite(item) }, delete: { model.delete(item) }).id(item.id)
                            }
                            if model.results.count < model.resultCount {
                                Button(model.loadingMore ? "加载中…" : "加载更多") { model.loadMore() }
                                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .padding(8).disabled(model.loadingMore)
                            }
                        }.padding(.horizontal, 8).padding(.bottom, 10)
                    }.onChange(of: model.selectedID) { _, id in
                        if let id { withAnimation(motion) { proxy.scrollTo(id, anchor: nil) } }
                    }
                }
            }
        }.background(Theme.sidebar)
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield").font(.system(size: 11))
            Text(model.statusText).lineLimit(1)
            Spacer()
            if model.selectedItem?.isImagePreviewable == true { Text("⌘Y 放大图片").padding(.trailing, 12) }
            Text("↵ \(model.wantsDirectPaste ? "粘贴" : "复制")").padding(.trailing, 10)
            Text("⌘1–9 快速使用")
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 34)
            .background(Theme.surface).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.7) }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 8)
            BrandMark(size: 58).padding(.bottom, 22)
            Text("让复制的内容，\n都有归处。").font(.system(size: 31, weight: .semibold)).tracking(-0.7).lineSpacing(5)
            Text("文字、图片、文件，安静收纳在这台 Mac。\n需要的时候，一个快捷键就能找回。")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5).padding(.top, 16)
            VStack(alignment: .leading, spacing: 16) {
                onboardingLine("internaldrive", "只存本地", "没有账号，不上传剪贴内容。")
                onboardingLine("hand.raised", "隐私由你掌控", "随时暂停记录、跳过一次复制或清空历史。")
                onboardingLine("command", model.preferences.shortcut.label + " 随叫随到", "用键盘搜索、选择，直接取回。")
            }.padding(.vertical, 28)
            Spacer(minLength: 10)
            HStack {
                Button("开始记录") { model.begin() }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                Button("稍后设置") { model.hidePanel?() }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 12)
            }
            Text("开始后记录此后复制或剪切的内容，保留期限可在设置中调整。\n复制密码等私密内容前，请暂停记录或跳过下一次复制。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).padding(.top, 16)
            Spacer(minLength: 22)
        }.padding(.horizontal, 36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private func onboardingLine(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon).font(.system(size: 19, weight: .light)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 13, weight: .medium)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
    private var dateFilterHelp: String {
        if case .custom(let start, let end) = model.dateFilter {
            return "\(start.formatted(date: .abbreviated, time: .omitted)) 至 \(end.formatted(date: .abbreviated, time: .omitted))，按最近复制时间筛选"
        }
        return "按最近复制时间筛选；近 7 天及近 30 天包含今天"
    }
    private var dateFilterLabel: String {
        guard case .custom(let start, let end) = model.dateFilter else { return model.dateFilter.title }
        let format = Date.FormatStyle.dateTime.year().month(.twoDigits).day(.twoDigits)
        if Calendar.current.isDate(start, inSameDayAs: end) { return start.formatted(format) }
        return "\(start.formatted(format)) – \(end.formatted(format))"
    }
}

private struct DateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var start: Date
    @ViewState private var end: Date
    let apply: (HistoryDateFilter) -> Void

    init(current: HistoryDateFilter, apply: @escaping (HistoryDateFilter) -> Void) {
        let interval = current.interval() ?? HistoryDateFilter.last7Days.interval()!
        _start = ViewState(initialValue: interval.start)
        _end = ViewState(initialValue: Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start)
        self.apply = apply
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("按日期找回内容").font(.system(size: 20, weight: .semibold))
            Text("按最近复制时间筛选，包含开始和结束当天。").font(.system(size: 12)).foregroundStyle(.secondary)
            DatePicker("开始日期", selection: $start, displayedComponents: .date)
            DatePicker("结束日期", selection: $end, in: start..., displayedComponents: .date)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用筛选") { apply(.custom(start: start, end: end)); dismiss() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 380)
            .onChange(of: start) { _, value in if end < value { end = value } }
    }
}

private struct EmptyHistoryView: View {
    var searching: Bool
    var favorites: Bool
    var denied: Bool
    var retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: denied ? "lock.shield" : searching ? "magnifyingglass" : favorites ? "star" : "square.stack.3d.up")
                .font(.system(size: 36, weight: .ultraLight)).foregroundStyle(.tertiary).padding(.bottom, 5)
            Text(denied ? "需要你允许剪贴板访问" : searching ? "没有找到匹配内容" : favorites ? "常用的，值得留下" : "你的下一次复制，从这里开始")
                .font(.system(size: 16, weight: .medium))
            Text(denied ? "在系统设置中允许剪巢读取剪贴板，再重试。" : searching ? "试试更短的关键词，或换个内容类型。" : favorites ? "点击记录旁的星标，把常用内容收好。" : "照常复制文字、图片或文件，剪巢会帮你收好。")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if denied { Button("重新检查") { retry() }.buttonStyle(.bordered).padding(.top, 6) }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
