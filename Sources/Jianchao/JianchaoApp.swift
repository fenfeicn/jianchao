import SwiftUI
import AppKit
import Combine
import ApplicationServices

@main
@MainActor
struct JianchaoLauncher {
    static func main() {
        AppIdentity.recordLaunch()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--check-hotkey") {
            exit(HotkeyManager.runDispatchCheck() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--check-paste-permissions") {
            print("version=\(AppIdentity.version)")
            print("accessibility=\(AXIsProcessTrusted())")
            print("postEvent=\(CGPreflightPostEventAccess())")
            print("signing=\(AppIdentity.signingDescription)")
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var controller: PanelController!
    private var statusItem: NSStatusItem!
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var restartParent: pid_t?
        if let index = CommandLine.arguments.firstIndex(of: "--restart-from"), CommandLine.arguments.count > index + 1,
           let pid = Int32(CommandLine.arguments[index + 1]),
           let parent = NSRunningApplication(processIdentifier: pid),
           parent.bundleIdentifier == Bundle.main.bundleIdentifier,
           parent.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
            restartParent = pid
            parent.terminate()
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.jianchao.app")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.processIdentifier != restartParent && !$0.isTerminated }) {
            DistributedNotificationCenter.default().postNotificationName(.showExistingClipHistory, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        installMainMenu()
        NSApp.setActivationPolicy(.accessory)
        model = AppModel(demo: CommandLine.arguments.contains("--demo"))
        if CommandLine.arguments.contains("--onboarding") { model.onboarded = false }
        controller = PanelController(model: model)
        model.restartApplication = { [weak self] in self?.restart() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let url = Bundle.assets.url(forResource: "MenuTemplate", withExtension: "png"), let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18); image.isTemplate = true; button.image = image
            } else { button.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "剪巢") }
            button.toolTip = "剪巢 · \(model.preferences.shortcut.label)"
            button.setAccessibilityLabel("剪巢剪贴板历史")
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.hotkey.onTrigger = { [weak self] in
            guard let self else { return }
            if let index = CommandLine.arguments.firstIndex(of: "--qa-events"), CommandLine.arguments.count > index + 1 {
                let path = CommandLine.arguments[index + 1]
                let line = "hotkey: " + self.model.hotkey.lastDelivery + "\n"
                if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
                if let file = FileHandle(forWritingAtPath: path) { file.seekToEndOfFile(); file.write(Data(line.utf8)); try? file.close() }
            }
            self.controller.toggle()
        }
        model.shortcutError = !model.hotkey.register(model.preferences.shortcut)
        subscription = model.$captureState.sink { [weak self] state in
            self?.statusItem.button?.appearsDisabled = state == .paused || state == .locked
            self?.statusItem.button?.setAccessibilityLabel("剪巢 · \(state.title)")
        }
        observers.append(NotificationCenter.default.addObserver(forName: .openClipHistory, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.controller.show() } })
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.lock() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.unlock() } })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.lock() } })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.unlock() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.refreshPermissions() } })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .showExistingClipHistory, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.controller.show() } })
        observers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.lock() } })
        observers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.unlock() } })
        if CommandLine.arguments.contains("--show-permissions") { controller.showSettings() }
        else { controller.show() }
    }

    private func restart() {
        guard !model.isDemo else { model.errorMessage = "演示模式不执行应用重启。"; return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--restart-from", String(ProcessInfo.processInfo.processIdentifier), "--show-permissions"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            if let error { Task { @MainActor in self?.model.errorMessage = "暂时无法重新启动：\(error.localizedDescription)" } }
        }
    }

    private func installMainMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let about = NSMenuItem(title: "关于剪巢…", action: #selector(openAbout), keyEquivalent: ""); about.target = self; appMenu.addItem(about)
        appMenu.addItem(.separator())
        let open = NSMenuItem(title: "打开剪巢", action: #selector(openHistory), keyEquivalent: ""); open.target = self; appMenu.addItem(open)
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","); settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出剪巢", action: #selector(quit), keyEquivalent: "q"); quit.target = self; appMenu.addItem(quit)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); bar.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        NSApp.mainMenu = bar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reactivating an already visible window must preserve its search,
        // find field and focus, rather than preparing a fresh presentation.
        if NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) { return true }
        controller?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() }
        else { controller.toggle() }
    }
    private func showMenu() {
        let menu = NSMenu()
        add("打开剪巢", selector: #selector(openHistory), to: menu)
        menu.addItem(.separator())
        add(model.captureState == .recording ? "暂停记录 15 分钟" : "恢复记录", selector: #selector(togglePause), to: menu)
        add("暂停直到手动恢复", selector: #selector(pauseIndefinitely), to: menu)
        add("跳过下一次复制", selector: #selector(skipNext), to: menu)
        menu.addItem(.separator())
        add("设置…", selector: #selector(openSettings), to: menu)
        add("关于剪巢与反馈…", selector: #selector(openAbout), to: menu)
        menu.addItem(.separator())
        add("退出剪巢", selector: #selector(quit), to: menu)
        statusItem.menu = menu; menu.delegate = self; statusItem.button?.performClick(nil)
    }
    private func add(_ title: String, selector: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
    }
    func menuDidClose(_ menu: NSMenu) { statusItem.menu = nil }
    @objc private func openHistory() { controller.show() }
    @objc private func togglePause() { if !model.isDemo { model.togglePause() } }
    @objc private func pauseIndefinitely() { if !model.isDemo { model.pause(minutes: nil) } }
    @objc private func skipNext() { if !model.isDemo { model.skipNext() } }
    @objc private func openSettings() { controller.showSettings() }
    @objc private func openAbout() { model.settingsTab = 3; controller.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension Notification.Name { static let openClipHistory = Notification.Name("Jianchao.openHistory") }

extension Notification.Name { static let showExistingClipHistory = Notification.Name("local.jianchao.showExisting") }
