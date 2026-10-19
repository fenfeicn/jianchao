import SwiftUI
import AppKit

struct DirectPastePermissionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "text.cursor").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.accent)
            Text("选好，就粘贴。")
                .font(.system(size: 23, weight: .semibold))
            Text("系统允许辅助功能与发送按键后，剪巢会返回\(model.targetName)，把内容粘贴到刚才的输入位置。以下是当前版本的实际权限状态。")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            PastePermissionStatusView(model: model)
                .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("取消") { model.pendingPasteItem = nil }.keyboardShortcut(.cancelAction)
                Button("这次仅复制") { model.copyPendingItem() }
                Spacer(minLength: 8)
                if model.canDirectPaste {
                    Button("继续粘贴") { model.continuePendingPaste() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("打开系统设置") {
                        guard !model.isDemo else { return }
                        model.pasteCoordinator.requestAccessibility()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isDemo)
                }
            }.controlSize(.large)
            Text("⌘Return 随时仅复制。\(model.isDemo ? "当前为演示模式，不会请求权限。" : "授权由你在系统设置中完成。")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(28).frame(width: 490).background(Theme.detail).tint(Theme.accent)
            .onAppear { model.refreshPermissions() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
}
