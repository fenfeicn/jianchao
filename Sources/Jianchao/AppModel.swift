import AppKit
import SwiftUI
import Combine
import ClipCore

enum CaptureState: Equatable {
    case off, recording, paused, locked, denied
    var title: String {
        switch self { case .off: return "尚未开始记录"; case .recording: return "仅存本地"; case .paused: return "已暂停记录"; case .locked: return "锁屏期间暂停"; case .denied: return "需要剪贴板访问许可" }
    }
    var symbol: String {
        switch self { case .recording: return "shield.lefthalf.filled"; case .denied: return "exclamationmark.lock"; case .paused, .locked: return "pause.circle"; case .off: return "shield" }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let preferences: Preferences
    let isDemo: Bool
    let pasteboard: PasteboardService
    lazy var pasteCoordinator = PasteCoordinator(service: pasteboard)
    lazy var monitor = ClipboardMonitor(service: pasteboard)
    let hotkey = HotkeyManager()
    let previewFind = PreviewFindState()
    @Published private(set) var itemCount = 0
    @Published private(set) var resultCount = 0
    @Published private(set) var detailItem: HistoryItem?
    @Published private(set) var loadingMore = false
    @Published private(set) var results: [HistoryItem] = []
    @Published var query = "" { didSet { search() } }
    @Published var filter: ContentKind? { didSet { search() } }
    @Published var favoritesOnly = false { didSet { search() } }
    @Published var dateFilter: HistoryDateFilter = .all { didSet { search() } }
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { previewFind.reset(); loadDetail() } }
    }
    @Published var captureState: CaptureState = .off
    @Published var onboarded: Bool
    @Published var errorMessage: String?
    @Published var notification: String?
    @Published var loading = true
    @Published var diskUsage = "—"
    @Published var shortcutError = false
    @Published var hasAccessibility = false
    @Published var hasEventAccess = false
    @Published var requiresRestart = false
    @Published var settingsTab = 0
    @Published var pendingPasteItem: HistoryItem?
    @Published private(set) var isUsingItem = false
    var store: HistoryStore?
    var assetsDirectory: URL?
    var showImage: ((HistoryItem) -> Void)?
    var showPanel: (() -> Void)?
    var showSettings: (() -> Void)?
    var hidePanel: (() -> Void)?
    var updateAppearance: (() -> Void)?
    var restartApplication: (() -> Void)?
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var retentionTimer: Timer?
    private var resumeTimer: Timer?
    private var wantsCapture = true
    private var sessionLocked = false
    private var subscriptions: Set<AnyCancellable> = []
    private var searchGeneration = 0

    init(demo: Bool) {
        isDemo = demo
        pasteboard = PasteboardService(name: demo ? .init("local.jianchao.demo.\(UUID().uuidString)") : nil)
        preferences = Preferences(demo: demo)
        onboarded = demo || preferences.consent
        monitor.onCapture = { [weak self] clip in await self?.capture(clip) }
        monitor.onBlocked = { [weak self] in self?.captureState = .denied }
        monitor.onFailure = { [weak self] error in self?.report(error) }
        preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        preferences.$appearance.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateAppearance?() }
        }.store(in: &subscriptions)
        Task { await initialize() }
    }

    var selectedItem: HistoryItem? { detailItem?.id == selectedID ? detailItem : results.first { $0.id == selectedID } }
    var statusText: String { notification ?? (isDemo ? "演示模式 · 未读取剪贴板" : captureState.title) }
    var wantsDirectPaste: Bool { preferences.automaticPaste }
    var targetName: String { pasteCoordinator.target?.localizedName ?? "原应用" }

    func prepareForPresentation() {
        pendingPasteItem = nil
        previewFind.reset()
        if let item = selectedItem, item.kind == .text { previewFind.setContent(item.text ?? item.title) }
        if !preferences.rememberSearch { query = ""; filter = nil; favoritesOnly = false; dateFilter = .all; selectedID = nil; search() }
    }

    func quickUse(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedID = results[index].id
        use(results[index])
    }

    private func initialize() async {
        do {
            let directory: URL
            if isDemo {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent("Jianchao-Demo-\(UUID().uuidString)")
            } else if let index = CommandLine.arguments.firstIndex(of: "--data-directory"), CommandLine.arguments.count > index + 1 {
                directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            } else {
                directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jianchao", isDirectory: true)
            }
            let database = try await Task.detached(priority: .userInitiated) { try HistoryStore(directory: directory) }.value
            store = database; assetsDirectory = database.assetsDirectory
            try await database.recoverOrphanedAssets()
            if isDemo { try await seedDemo(database) }
            _ = try await database.prune(policy: preferences.policy, returningItems: false)
            itemCount = try await database.count()
            loading = false; search()
            if onboarded && !isDemo { await resumeCapture() }
            retentionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.applyRetention() } }
            await updateUsage()
        } catch { loading = false; report(error) }
    }

    func begin() {
        preferences.consent = true; onboarded = true
        showPanel?()
        Task { await resumeCapture() }
    }
    func pause(minutes: Int? = 15) {
        wantsCapture = false; monitor.stop(); captureState = .paused
        resumeTimer?.invalidate(); resumeTimer = nil
        if let minutes {
            resumeTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in Task { @MainActor in await self?.resumeCapture() } }
        }
    }
    func resumeCapture() async {
        wantsCapture = true
        guard !isDemo, preferences.consent, store != nil else { return }
        guard !sessionLocked else { captureState = .locked; return }
        resumeTimer?.invalidate(); resumeTimer = nil
        await monitor.start()
        guard wantsCapture && !sessionLocked else { monitor.stop(); return }
        captureState = .recording
    }
    func togglePause() {
        if captureState == .recording { pause() } else { Task { await resumeCapture() } }
    }
    func lock() { sessionLocked = true; monitor.stop(); if wantsCapture { captureState = .locked } }
    func unlock() { sessionLocked = false; if wantsCapture { Task { await resumeCapture() } } }
    func skipNext() { monitor.skipNext = true; announce("将跳过下一次复制") }
    var canDirectPaste: Bool { hasAccessibility && hasEventAccess && !requiresRestart }
    func refreshPermissions() {
        let accessibility = pasteCoordinator.hasAccessibility
        let eventAccess = pasteCoordinator.hasEventAccess
        let restart = AppIdentity.wasReplacedWhileRunning
        if hasAccessibility != accessibility { hasAccessibility = accessibility }
        if hasEventAccess != eventAccess { hasEventAccess = eventAccess }
        if requiresRestart != restart { requiresRestart = restart }
    }
    var diagnosticReport: String {
        """
        剪巢问题反馈
        版本：\(AppIdentity.version)
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
        架构：\(AppIdentity.architecture)
        签名：\(AppIdentity.signingDescription)
        运行中被更新：\(requiresRestart ? "是，需要重新启动" : "否")
        辅助功能：\(hasAccessibility ? "允许" : "未允许")
        发送按键：\(hasEventAccess ? "允许" : "未允许")
        最近粘贴阶段：\(pasteCoordinator.lastAttempt)

        问题描述：
        复现步骤：
        预期结果：
        """
    }
    func copyDiagnosticReport() async throws {
        refreshPermissions()
        try await pasteboard.write(.text(diagnosticReport))
    }
    func shutdown() { monitor.stop(); resumeTimer?.invalidate(); retentionTimer?.invalidate(); hotkey.unregister() }

    private func capture(_ clip: CapturedClip) async {
        guard let store else { return }
        do { _ = try await store.insert(clip, policy: preferences.policy, returningItems: false); itemCount = try await store.count(); search() }
        catch { report(error) }
    }
    func applyRetention() async {
        guard let store else { return }
        do { _ = try await store.prune(policy: preferences.policy, returningItems: false); itemCount = try await store.count(); search(); await updateUsage() }
        catch { report(error) }
    }
    func updateUsage() async {
        guard let store else { return }
        do { diskUsage = ByteCountFormatter.string(fromByteCount: Int64(try await store.managedBytes()), countStyle: .file) }
        catch { report(error) }
    }

    private func search() {
        searchTask?.cancel(); searchGeneration += 1; loadingMore = false
        let generation = searchGeneration, q = query, kind = filter, favorites = favoritesOnly
        let interval = dateFilter.interval()
        searchTask = Task {
            do {
                // Coalesce fast typing; obsolete searches never enter SQLite.
                if !q.isEmpty { try await Task.sleep(for: .milliseconds(70)) }
                guard !Task.isCancelled, let store else { return }
                let page = try await store.search(query: q, kind: kind, favoritesOnly: favorites, dateInterval: interval)
                guard !Task.isCancelled, generation == searchGeneration else { return }
                results = page.items; resultCount = page.total
                if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
                else { loadDetail() }
            } catch is CancellationError {} catch { report(error) }
        }
    }
    func loadMore() {
        guard !loadingMore, results.count < resultCount, let store else { return }
        loadingMore = true
        let generation = searchGeneration, offset = results.count, q = query, kind = filter, favorites = favoritesOnly
        let interval = dateFilter.interval()
        Task {
            do {
                let page = try await store.search(query: q, kind: kind, favoritesOnly: favorites, dateInterval: interval, offset: offset)
                guard generation == searchGeneration else { return }
                results.append(contentsOf: page.items); resultCount = page.total; loadingMore = false
            } catch { if generation == searchGeneration { loadingMore = false; report(error) } }
        }
    }
    private func loadDetail() {
        detailTask?.cancel(); detailItem = nil
        guard let id = selectedID else { return }
        detailTask = Task {
            do {
                guard let store else { return }
                let item = try await store.item(id: id)
                guard !Task.isCancelled, selectedID == id else { return }
                detailItem = item
            } catch { if !Task.isCancelled { report(error) } }
        }
    }
    func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = results[max(0, min(results.count - 1, index + offset))].id
    }
    func toggleFavorite(_ item: HistoryItem) {
        Task {
            guard let store else { return }
            do { _ = try await store.setFavorite(item.id, value: !item.isFavorite, returningItems: false); search() }
            catch { report(error) }
        }
    }
    func delete(_ item: HistoryItem) {
        Task {
            guard let store else { return }
            do { _ = try await store.delete([item.id], returningItems: false); itemCount = try await store.count(); search(); await updateUsage() }
            catch { report(error) }
        }
    }
    func clear(includingFavorites: Bool) {
        Task {
            guard let store else { return }
            do { _ = try await store.clear(includingFavorites: includingFavorites, returningItems: false); itemCount = try await store.count(); search(); await updateUsage() }
            catch { report(error) }
        }
    }
    func useSelected(copyOnly: Bool = false) { if let item = selectedItem { use(item, copyOnly: copyOnly) } }
    func use(_ item: HistoryItem, copyOnly: Bool = false) {
        guard !isUsingItem else { return }
        refreshPermissions()
        if !copyOnly && wantsDirectPaste && (!isDemo || CommandLine.arguments.contains("--preview-paste-permission")) && !canDirectPaste {
            pendingPasteItem = item
            return
        }
        isUsingItem = true
        if isDemo {
            Task {
                defer { isUsingItem = false }
                guard let store else { return }
                do { try await pasteboard.write(try await store.payload(for: item)); announce("已写入演示剪贴板 · 真实剪贴板未改动") }
                catch { report(error) }
            }
            return
        }
        Task {
            defer { isUsingItem = false }
            guard let store else { return }
            do {
                let payload = try await store.payload(for: item)
                let pasted = try await pasteCoordinator.use(payload, automaticallyPaste: !copyOnly && wantsDirectPaste)
                announce(pasted ? "已发送粘贴" : "已复制")
                if !pasted { hidePanel?() }
            } catch {
                // The panel may have closed while returning to the target. Put
                // errors back on screen instead of silently falling back to copy.
                showPanel?(); report(error)
            }
        }
    }
    func copyPendingItem() {
        guard let item = pendingPasteItem else { return }
        pendingPasteItem = nil; use(item, copyOnly: true)
    }
    func continuePendingPaste() {
        refreshPermissions()
        guard canDirectPaste, let item = pendingPasteItem else { return }
        pendingPasteItem = nil; use(item)
    }
    func recordShortcut(_ descriptor: HotkeyDescriptor) {
        guard hotkey.register(descriptor) else { shortcutError = true; return }
        shortcutError = false; preferences.shortcut = descriptor
    }
    func announce(_ message: String) {
        notificationTask?.cancel(); notification = message
        notificationTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            notification = nil
        }
    }
    private func report(_ error: Error) { errorMessage = error.localizedDescription }

    private func seedDemo(_ store: HistoryStore) async throws {
        let clips: [(ClipPayload, String, String)] = [
            (.text("好的设计，让每一次使用都成为享受。\n\n清晰的层级，恰好的留白，自然发生的交互。"), "备忘录", "com.apple.Notes"),
            (.text("https://developer.apple.com/design/"), "Safari", "com.apple.Safari"),
            (.text("withAnimation(.smooth) {\n    isPresented.toggle()\n}\n\n" + (1...32).map { "// 第 \($0) 行：预览支持查找与行号，自动折行保留原行号。" }.joined(separator: "\n")), "Xcode", "com.apple.dt.Xcode"),
            (.text("复制有处收，常用随手取。"), "备忘录", "com.apple.Notes"),
            (.text("交付清单\n\n☑ 检查文字与图片\n☑ 核对快捷键\n☐ 整理反馈"), "备忘录", "com.apple.Notes"),
            (.text("🪺 剪巢，把复制的灵感收好。\n\n查找支持中文、英文与 emoji。"), "备忘录", "com.apple.Notes")
        ]
        for (index, clip) in clips.enumerated() {
            let age = index == clips.count - 1 ? 86_400.0 : Double(index * 180)
            let items = try await store.insert(.init(payload: clip.0, source: .init(name: clip.1, bundleID: clip.2), date: Date().addingTimeInterval(-age)))
            if index == 0, let id = items.first?.id { _ = try await store.setFavorite(id, value: true) }
        }
        if let url = Bundle.assets.url(forResource: "DemoLandscape", withExtension: "png"), let data = try? Data(contentsOf: url) {
            _ = try await store.insert(.init(payload: .image(data, type: "public.png"), source: .init(name: "Safari", bundleID: "com.apple.Safari"), date: Date().addingTimeInterval(-300)))
            let imageFile = store.directory.appendingPathComponent("山景.png")
            try data.write(to: imageFile)
            _ = try await store.insert(.init(payload: .files([imageFile]), source: .init(name: "Finder", bundleID: "com.apple.finder"), date: Date().addingTimeInterval(-450)))
        }
        let sample = store.directory.appendingPathComponent("界面设计说明.txt")
        try "这是演示文件，不包含你的真实文件。".write(to: sample, atomically: true, encoding: .utf8)
        _ = try await store.insert(.init(payload: .files([sample]), source: .init(name: "Finder", bundleID: "com.apple.finder"), date: Date().addingTimeInterval(-900)))
    }
}
