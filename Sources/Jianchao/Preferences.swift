import AppKit
import Carbon
import ClipCore

struct HotkeyDescriptor: Codable, Equatable {
    var keyCode: UInt32 = 9
    var modifiers: UInt32 = UInt32(cmdKey | optionKey)
    var key: String = "V"
    var label: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + key.uppercased()
    }
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults: UserDefaults?
    @Published var consent: Bool { didSet { defaults?.set(consent, forKey: "captureConsent") } }
    @Published var automaticPaste: Bool { didSet { defaults?.set(automaticPaste, forKey: "automaticPaste") } }
    @Published var retentionDays: Int { didSet { defaults?.set(retentionDays, forKey: "retentionDays") } }
    @Published var maximumItems: Int { didSet { defaults?.set(maximumItems, forKey: "maximumItems") } }
    @Published var maximumMB: Int { didSet { defaults?.set(maximumMB, forKey: "maximumMB") } }
    @Published var rememberSearch: Bool { didSet { defaults?.set(rememberSearch, forKey: "rememberSearch") } }
    @Published var shortcut: HotkeyDescriptor { didSet { defaults?.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") } }
    @Published var appearance: String { didSet { defaults?.set(appearance, forKey: "appearance") } }

    init(demo: Bool) {
        defaults = demo ? nil : .standard
        consent = defaults?.bool(forKey: "captureConsent") ?? false
        // 0.2 defaulted to copy-only. Adopt the requested direct-paste workflow once;
        // subsequent explicit choices in this version are preserved.
        if defaults?.bool(forKey: "directPasteDefaultV3") != true {
            defaults?.set(true, forKey: "automaticPaste")
            defaults?.set(true, forKey: "directPasteDefaultV3")
        }
        automaticPaste = defaults?.object(forKey: "automaticPaste") as? Bool ?? true
        retentionDays = defaults?.object(forKey: "retentionDays") as? Int ?? 30
        maximumItems = defaults?.object(forKey: "maximumItems") as? Int ?? 5_000
        maximumMB = defaults?.object(forKey: "maximumMB") as? Int ?? 500
        rememberSearch = defaults?.bool(forKey: "rememberSearch") ?? false
        shortcut = defaults?.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(HotkeyDescriptor.self, from: $0) } ?? .init()
        appearance = defaults?.string(forKey: "appearance") ?? "system"
    }
    var policy: RetentionPolicy { .init(days: retentionDays, maximumItems: maximumItems, maximumBytes: maximumMB * 1_024 * 1_024) }
    var nsAppearance: NSAppearance? {
        switch appearance { case "light": return NSAppearance(named: .aqua); case "dark": return NSAppearance(named: .darkAqua); default: return nil }
    }
}
