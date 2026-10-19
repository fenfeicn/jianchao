import SwiftUI
import AppKit

struct PastePermissionStatusView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 16) {
                status("辅助功能", allowed: model.hasAccessibility)
                status("发送按键", allowed: model.hasEventAccess)
                Spacer(minLength: 0)
                Button("重新检查") { model.refreshPermissions() }.controlSize(.small)
            }
            if model.requiresRestart {
                Text("应用已在运行中被更新。请先重新启动，让系统检查当前版本的权限。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("重新启动剪巢") { model.restartApplication?() }.controlSize(.small).disabled(model.isDemo)
            } else if !model.canDirectPaste {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1  打开系统设置 → 隐私与安全，在「辅助功能」或「设备控制和数据访问」中找到剪巢。入口名称因系统版本而异。")
                    Text("2  若已开启仍未允许，移除旧条目，再用下方显示的当前应用重新添加。")
                    Text("3  开启后点击「授权后重新启动」，再检查上方状态。")
                }.font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                Text(Bundle.main.bundlePath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                HStack {
                    Button("打开权限设置") {
                        guard !model.isDemo else { return }
                        model.pasteCoordinator.requestAccessibility()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                    }.disabled(model.isDemo)
                    Button("定位当前应用") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    Button("授权后重新启动") { model.restartApplication?() }
                }.controlSize(.small).disabled(model.isDemo)
            }
        }
        .onAppear { model.refreshPermissions() }
        .task {
            // Refresh only while this view is visible, not in the capture loop.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                model.refreshPermissions()
            }
        }
    }
    private func status(_ name: String, allowed: Bool) -> some View {
        Label("\(name) · \(allowed ? "已允许" : "未允许")", systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.system(size: 11)).foregroundStyle(allowed ? Color.secondary : Theme.accent)
    }
}
