import AppKit
import Carbon
import SwiftUI

@MainActor
final class HotkeyManager {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredShortcut: HotkeyDescriptor?
    private var activeID: UInt32 = 0
    private var lastTrigger = ContinuousClock.now.advanced(by: .seconds(-1))
    private(set) var failureDescription: String?
    private(set) var triggerCount = 0
    private(set) var lastDelivery = ""
    var onTrigger: (() -> Void)?
    private static let signature: OSType = 0x4A43484B

    init() { installHandler() }

    private func installHandler() {
        guard handler == nil else { return }
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
                  identity.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
                guard identity.id == manager.activeID else { return OSStatus(eventNotHandledErr) }
                manager.fire(origin: "carbon")
                return noErr
            }
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { failureDescription = "无法安装快捷键监听（\(status)）" }
    }

    func register(_ shortcut: HotkeyDescriptor) -> Bool {
        installHandler()
        guard handler != nil else { return false }
        if shortcut == registeredShortcut, hotKey != nil { return true }
        var replacement: EventHotKeyRef?
        let nextID = activeID &+ 1
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: nextID), GetEventDispatcherTarget(), 0, &replacement)
        guard status == noErr else {
            failureDescription = status == eventHotKeyExistsErr ? "这个快捷键已被其他应用占用，请换一个组合键。" : "快捷键注册失败（\(status)），请重新录制。"
            return false
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement; registeredShortcut = shortcut; activeID = nextID
        failureDescription = nil
        return true
    }

    // App-targeted keyboard events (including accessibility input) may bypass Carbon's
    // system dispatcher. Keep the same shortcut working inside our own windows.
    func handleLocal(_ event: NSEvent) -> Bool {
        guard let shortcut = registeredShortcut, UInt32(event.keyCode) == shortcut.keyCode else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers == shortcut.modifiers else { return false }
        fire(origin: "local"); return true
    }
    private func fire(origin: String) {
        guard lastTrigger.duration(to: .now) > .milliseconds(180) else { return }
        lastTrigger = .now; triggerCount += 1; lastDelivery = origin; onTrigger?()
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; registeredShortcut = nil
    }

    static func runDispatchCheck() -> Bool {
        let manager = HotkeyManager()
        defer { manager.unregister() }
        let descriptor = HotkeyDescriptor(keyCode: 79, modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), key: "F18")
        guard manager.register(descriptor) else { print("FAIL: " + (manager.failureDescription ?? "registration")); return false }
        var received = 0
        manager.onTrigger = { received += 1 }
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeUserEvent), &event) == noErr, let event else { return false }
        defer { ReleaseEvent(event) }
        var identity = EventHotKeyID(signature: signature, id: manager.activeID)
        guard SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identity) == noErr else { return false }
        let delivered = SendEventToEventTarget(event, GetEventDispatcherTarget())
        let success = delivered == noErr && received == 1 && manager.triggerCount == 1
        print(success ? "PASS: Carbon registration, event dispatch and callback" : "FAIL: Carbon callback delivery")
        return success
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: HotkeyDescriptor
    var onRecord: (HotkeyDescriptor) -> Void
    func makeNSView(context: Context) -> RecorderButton { let button = RecorderButton(); button.onRecord = onRecord; return button }
    func updateNSView(_ button: RecorderButton, context: Context) { button.shortcut = shortcut; button.onRecord = onRecord; if !button.recording { button.title = shortcut.label } }

    final class RecorderButton: NSButton {
        var onRecord: ((HotkeyDescriptor) -> Void)?
        var shortcut = HotkeyDescriptor()
        var recording = false
        override var acceptsFirstResponder: Bool { true }
        init() {
            super.init(frame: .zero); bezelStyle = .rounded; setButtonType(.momentaryPushIn)
            target = self; action = #selector(beginRecording); title = shortcut.label
            setAccessibilityLabel("录制全局快捷键")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        @objc private func beginRecording() { recording = true; title = "请按组合键…"; window?.makeFirstResponder(self) }
        override func resignFirstResponder() -> Bool { recording = false; title = shortcut.label; return true }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event) }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { recording = false; title = shortcut.label; return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option),
                  let key = event.charactersIgnoringModifiers, !key.isEmpty, key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { NSSound.beep(); return }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let descriptor = HotkeyDescriptor(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key.uppercased())
            recording = false; title = descriptor.label; onRecord?(descriptor)
        }
    }
}
