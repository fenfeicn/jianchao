import SwiftUI
import AppKit

// Explicitly use the stable property wrapper. Newer SDKs also expose a same-name
// State macro whose plugin is not included with the standalone Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Theme {
    private static func adaptive(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
    static let accent = adaptive((0.74, 0.35, 0.18), (0.94, 0.63, 0.42))
    static let surface = adaptive((0.975, 0.973, 0.968), (0.13, 0.14, 0.15))
    static let sidebar = adaptive((0.956, 0.953, 0.946), (0.15, 0.16, 0.17))
    static let detail = adaptive((0.997, 0.996, 0.992), (0.105, 0.115, 0.125))
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let line = Color.primary.opacity(0.09)
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

struct MaterialSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            Theme.surface
            if !reduceTransparency {
                VisualEffect(material: .sidebar).opacity(0.18)
            }
        }
    }
}

struct GlassControl: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            content.background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 30
    // Resolve the file explicitly: standalone SwiftPM resource bundles do not
    // always participate in SwiftUI's named-image lookup on macOS.
    private static let artwork: NSImage = {
        if let url = Bundle.assets.url(forResource: "BrandMark", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 1, height: 1))
    }()
    var body: some View {
        Image(nsImage: Self.artwork)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ChromeButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void
    @ViewState private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(hovered || active ? 0.065 : 0), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
            .onHover { hovered = $0 }
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

// Resolve resources inside a standalone app before the SwiftPM development path.
extension Bundle {
    static var assets: Bundle {
        if let root = Bundle.main.resourceURL,
           let bundle = Bundle(url: root.appendingPathComponent("Jianchao_Jianchao.bundle")) { return bundle }
        return .module
    }
}
