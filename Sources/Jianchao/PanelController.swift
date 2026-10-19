import AppKit
import SwiftUI
import ClipCore

final class SearchPanel: NSPanel {
    var handlePanelKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Key equivalents can be dispatched before keyDown/local-monitor delivery,
    // especially while SwiftUI or the field editor owns the responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePanelKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if handlePanelKey?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: SearchPanel
    private let model: AppModel
    private var keyMonitor: Any?
    private var menuTracking = false
    private var menuObservers: [NSObjectProtocol] = []
    private var dismissTask: Task<Void, Never>?
    private var settingsWindow: NSWindow?
    private var imageWindow: NSWindow?

    init(model: AppModel) {
        self.model = model
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = "剪巢"
        panel.setAccessibilitySubrole(.standardWindow)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: SearchPanelView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting; panel.delegate = self
        model.hidePanel = { [weak self] in self?.hide() }
        model.showImage = { [weak self] item in self?.showImage(item) }
        model.showPanel = { [weak self] in self?.show() }
        model.showSettings = { [weak self] in self?.showSettings() }
        model.pasteCoordinator.dismiss = { [weak self] in self?.hide(restoreTarget: false, animated: false) }
        model.updateAppearance = { [weak self] in self?.applyAppearance() }
        panel.handlePanelKey = { [weak self] in self?.handlePanelKey($0) ?? false }
        installKeyboardHandling()
        applyAppearance()
    }

    func toggle() { if panel.isVisible && panel.isKeyWindow { hide() } else { show() } }
    func show() {
        dismissTask?.cancel()
        settingsWindow?.orderOut(nil)
        imageWindow?.orderOut(nil)
        model.prepareForPresentation()
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { model.pasteCoordinator.target = app }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(model.onboarded ? 660 : 640, visible.height - 40)
        let width = min(model.onboarded ? 920 : 620, visible.width - 40)
        let frame = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2 + 20, width: width, height: height)
        panel.setFrame(frame, display: false)
        applyAppearance(); model.refreshPermissions()
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animate ? 0 : 1
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in context.duration = animate ? 0.16 : 0; panel.animator().alphaValue = 1 }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusClipSearch, object: nil) }
    }

    func hide(restoreTarget: Bool = true, animated: Bool = true) {
        guard panel.isVisible else { return }
        dismissTask?.cancel()
        let target = model.pasteCoordinator.target
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animate {
            panel.orderOut(nil); panel.alphaValue = 1
            if restoreTarget, let target, !target.isTerminated,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { target.activate(options: []) }
            return
        }
        if animate {
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.10; panel.animator().alphaValue = 0 }
        }
        dismissTask = Task {
            if animate { try? await Task.sleep(for: .milliseconds(105)) }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil); panel.alphaValue = 1
            if restoreTarget, let target, !target.isTerminated,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                target.activate(options: [])
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard imageWindow?.isVisible != true else { return }
        guard !model.isDemo else { return }
        guard let window = notification.object as? NSWindow, window === panel, panel.attachedSheet == nil else { return }
        hide(restoreTarget: false)
    }

    func showSettings() {
        model.pendingPasteItem = nil
        hide(restoreTarget: false, animated: false)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "剪巢设置"; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
            // SwiftUI's intrinsic height changes with each tab. Never let that
            // resize the native window or vertically recenter the sidebar.
            let hosting = NSHostingView(rootView: SettingsView(model: model))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.setContentSize(NSSize(width: 760, height: 560))
            window.center(); settingsWindow = window
        }
        applyAppearance(); settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func showImage(_ item: HistoryItem) {
        guard item.isImagePreviewable else { return }
        if imageWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "图片预览"; window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false; window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1); window.delegate = self
            window.center(); imageWindow = window
        }
        imageWindow?.contentView = NSHostingView(rootView: ImageViewerView(item: item, directory: model.assetsDirectory))
        applyAppearance(); imageWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === imageWindow {
            imageWindow?.orderOut(nil)
            panel.makeKeyAndOrderFront(nil)
        }
    }
    func applyAppearance() {
        panel.appearance = model.preferences.nsAppearance
        settingsWindow?.appearance = model.preferences.nsAppearance
        imageWindow?.appearance = model.preferences.nsAppearance
    }

    private func installKeyboardHandling() {
        menuObservers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.menuTracking = true } },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.menuTracking = false } }
        ]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard !self.menuTracking else { return event }
            let recording = (NSApp.keyWindow?.firstResponder as? ShortcutRecorder.RecorderButton)?.recording == true
            if !recording, self.model.hotkey.handleLocal(event) { return nil }
            if self.imageWindow?.isKeyWindow == true, event.keyCode == 53 { self.imageWindow?.close(); return nil }
            return self.handlePanelKey(event) ? nil : event
        }
    }

    private func handlePanelKey(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow, panel.attachedSheet == nil, !menuTracking else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let textView = panel.firstResponder as? NSTextView
        // Command shortcuts must also work while an input method is composing.
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        if flags == .command, let index = digits.firstIndex(of: event.keyCode), model.onboarded {
            if !event.isARepeat { model.quickUse(index % 9) }
            return true
        }
        if event.keyCode == 3 {
            if flags == [.command, .option] {
                model.previewFind.close()
                NotificationCenter.default.post(name: .focusClipSearch, object: nil); return true
            }
            if flags == .command {
                if model.selectedItem?.kind == .text { model.previewFind.open() }
                else { NotificationCenter.default.post(name: .focusClipSearch, object: nil) }
                return true
            }
        }
        if event.keyCode == 5, model.previewFind.isVisible, flags == .command || flags == [.command, .shift] {
            model.previewFind.move(flags.contains(.shift) ? -1 : 1); return true
        }
        guard textView?.hasMarkedText() != true else { return false }
        if event.keyCode == 53, model.previewFind.isVisible { model.previewFind.close(); return true }
        if model.previewFind.isVisible, [UInt16(36), 76].contains(event.keyCode), flags.isEmpty || flags == .shift {
            model.previewFind.move(flags == .shift ? -1 : 1); return true
        }
        if model.previewFind.fieldFocused {
            // Arrow keys belong to the find field; never change the history selection.
            if flags.isEmpty, [UInt16(125), 126].contains(event.keyCode) { return false }
        }
        switch event.keyCode {
            case 53: // Escape closes preview first, then returns focus to the original app.
                self.hide(); return true
            case 125, 126:
                guard flags.isEmpty, self.model.onboarded, textView?.isEditable != false else { return false }
                self.model.moveSelection(event.keyCode == 125 ? 1 : -1); return true
            case 36, 76:
                guard self.model.onboarded, flags.isEmpty || flags == .command else { return false }
                guard !event.isARepeat else { return true }
                self.model.useSelected(copyOnly: flags == .command); return true
            case 2 where flags == .command:
                if let item = self.model.selectedItem { self.model.toggleFavorite(item) }; return true
            case 49 where flags.isEmpty && (textView == nil || self.model.query.isEmpty):
                guard let item = self.model.selectedItem, item.isImagePreviewable else { return false }
                self.showImage(item); return true
            case 16 where flags == .command:
                if let item = self.model.selectedItem, item.isImagePreviewable { self.showImage(item) }; return true
            case 13 where flags == .command: self.hide(); return true
            case 43 where flags == .command: self.showSettings(); return true
            default: return false
            }
    }
}
