import AppKit
import ClipCore
import ApplicationServices

@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var busy = false
    private var generation = 0
    private let service: PasteboardService
    var onCapture: ((CapturedClip) async -> Void)?
    var onBlocked: (() -> Void)?
    var onFailure: ((ClipError) -> Void)?
    var skipNext = false

    init(service: PasteboardService) { self.service = service }
    func start() async {
        stop()
        let token = generation
        await service.resetBaseline()
        guard token == generation else { return }
        let next = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        next.tolerance = 0.02
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
    func stop() { timer?.invalidate(); timer = nil; generation += 1 }
    private func tick() {
        guard !busy else { return }
        busy = true
        let token = generation
        let app = NSWorkspace.shared.frontmostApplication
        let source = SourceApplication(name: app?.localizedName ?? "来源未知", bundleID: app?.bundleIdentifier)
        let skip = skipNext
        Task {
            let result = await service.poll(source: source, skip: skip)
            guard token == generation else { busy = false; return }
            switch result {
            case .captured(let clip): await onCapture?(clip)
            case .ignored: if skip { skipNext = false }
            case .blocked: stop(); onBlocked?()
            case .failed(let error): onFailure?(error)
            case .unchanged: break
            }
            busy = false
        }
    }
}

@MainActor
final class PasteCoordinator {
    private let service: PasteboardService
    var target: NSRunningApplication?
    var dismiss: (() -> Void)?
    init(service: PasteboardService) { self.service = service }
    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var hasEventAccess: Bool { CGPreflightPostEventAccess() }
    var canPaste: Bool { hasAccessibility && hasEventAccess }
    private(set) var lastAttempt = "尚未尝试"

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if hasAccessibility && !hasEventAccess { _ = CGRequestPostEventAccess() }
    }

    func use(_ payload: ClipPayload, automaticallyPaste: Bool) async throws -> Bool {
        do { return try await performUse(payload, automaticallyPaste: automaticallyPaste) }
        catch {
            lastAttempt = (error as? PasteFailure)?.diagnosticCode ?? "payload-write-failed"
            throw error
        }
    }

    private func performUse(_ payload: ClipPayload, automaticallyPaste: Bool) async throws -> Bool {
        guard automaticallyPaste else { try await service.write(payload); return false }
        guard hasAccessibility else { throw PasteFailure.permission }
        guard hasEventAccess else { throw PasteFailure.eventPermission }
        guard let target, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw PasteFailure.target }
        let expectedPID = target.processIdentifier
        try await service.write(payload)
        // Abort if the user switched away from our panel to another app while preparing data.
        let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard current == ProcessInfo.processInfo.processIdentifier || current == expectedPID else { throw PasteFailure.focus }
        // Numeric shortcuts and Return may still be held. Avoid sending ⌘V with
        // the user's Option/Shift modifiers or while the triggering key repeats.
        let releaseDeadline = ContinuousClock.now.advanced(by: .milliseconds(1_200))
        while !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            guard ContinuousClock.now < releaseDeadline else { throw PasteFailure.modifiers }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == ProcessInfo.processInfo.processIdentifier || front == expectedPID else { throw PasteFailure.focus }
            try await Task.sleep(for: .milliseconds(16))
        }
        dismiss?()
        guard target.activate(options: []) else { throw PasteFailure.target }
        // Wait for observed activation, not a fixed assumption that 100ms is enough.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(650))
        while ContinuousClock.now < deadline {
            guard !target.isTerminated else { throw PasteFailure.target }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID { break }
            if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               front != ProcessInfo.processInfo.processIdentifier { throw PasteFailure.focus }
            try await Task.sleep(for: .milliseconds(16))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { throw PasteFailure.focus }
        // Give the restored text responder a run-loop turn, then recheck focus.
        try await Task.sleep(for: .milliseconds(120))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { throw PasteFailure.focus }
        guard hasAccessibility else { throw PasteFailure.permission }
        guard hasEventAccess else { throw PasteFailure.eventPermission }
        // Isolate generated flags from the shortcut which opened the panel.
        // Session delivery follows normal keyboard shortcut routing in the target.
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw PasteFailure.event }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        lastAttempt = "session-command-v-sent (insertion-unverified)"
        return true // Event sent; this does not assert the target accepted its contents.
    }
}

enum PasteFailure: LocalizedError {
    case permission, eventPermission, target, focus, modifiers, event
    var diagnosticCode: String {
        switch self {
        case .permission: return "accessibility-denied"
        case .eventPermission: return "post-event-denied"
        case .target: return "target-unavailable"
        case .focus: return "focus-changed"
        case .modifiers: return "modifiers-held"
        case .event: return "event-creation-failed"
        }
    }
    var errorDescription: String? {
        switch self {
        case .permission: return "系统尚未认可当前版本的辅助功能权限。如果剪巢已经勾选，请从权限列表移除旧条目，重新添加当前应用，再退出并重新打开剪巢。"
        case .eventPermission: return "系统尚未允许当前版本发送粘贴按键。请在设置中重新检查粘贴权限；已勾选时可移除旧条目并重新添加当前应用。"
        case .target: return "没有可返回的输入应用。请先点选输入位置，再用快捷键呼出剪巢；也可使用 ⌘Return 仅复制。"
        case .focus: return "输入焦点已改变，已停止发送粘贴。内容已复制，可以在需要的位置按 ⌘V。"
        case .modifiers: return "请松开快捷键后再试。内容已复制，也可直接按 ⌘V。"
        case .event: return "内容已复制，暂时无法发送粘贴，请在输入位置按 ⌘V。"
        }
    }
}
