import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @ViewState private var confirmClear = false
    @ViewState private var confirmEverything = false
    @ViewState private var settingsError: String?
    @ViewState private var reportCopied = false
    @ViewState private var pendingLimit: HistoryLimitChange?
    private let tabs = ["通用", "历史与存储", "便捷操作", "关于剪巢"]
    private let tabIcons = ["slider.horizontal.3", "internaldrive", "cursorarrow.click", "info.circle"]

    init(model: AppModel) { self.model = model; preferences = model.preferences }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 178).frame(maxHeight: .infinity, alignment: .top)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(["顺手，就很好。", "留住需要的。", "少一步，更顺手。", "小小剪巢，随手收好。"][model.settingsTab])
                            .font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                        Text(["让剪巢融入你的工作习惯。", "给历史一个期限，给常用内容留个位置。", "常用操作随手可达，工作节奏不被打断。", "一个免费、轻巧的 macOS 剪贴板伙伴。"][model.settingsTab])
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.bottom, 3)
                    switch model.settingsTab { case 1: storageSettings; case 2: convenienceSettings; case 3: aboutSettings; default: generalSettings }
                    Spacer(minLength: 0)
                }.padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }.frame(width: 760, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(Theme.accent)
            .onAppear { model.refreshPermissions(); Task { await model.updateUsage() } }
            .alert("清空普通历史？", isPresented: $confirmClear) {
                Button("取消", role: .cancel) {}
                Button("清空历史", role: .destructive) { model.clear(includingFavorites: false) }
            } message: { Text("收藏会保留。普通历史删除后无法恢复，不会清空当前系统剪贴板。") }
            .alert("删除包括收藏在内的全部记录？", isPresented: $confirmEverything) {
                Button("取消", role: .cancel) {}
                Button("删除全部记录", role: .destructive) { model.clear(includingFavorites: true) }
            } message: { Text("将删除全部历史、收藏和剪巢保存的图片。原始文件不会被删除，偏好设置会保留。此操作无法恢复。") }
            .alert("暂时无法完成", isPresented: Binding(get: { model.errorMessage != nil || settingsError != nil }, set: { if !$0 { model.errorMessage = nil; settingsError = nil } })) {
                Button("知道了", role: .cancel) { model.errorMessage = nil; settingsError = nil }
            } message: { Text(model.errorMessage ?? settingsError ?? "") }
            .alert("缩小历史保存范围？", isPresented: Binding(get: { pendingLimit != nil }, set: { if !$0 { pendingLimit = nil } })) {
                Button("取消", role: .cancel) { pendingLimit = nil }
                Button("调整并清理", role: .destructive) {
                    if let pendingLimit { applyLimit(pendingLimit) }
                    pendingLimit = nil
                }
            } message: { Text("\(pendingLimit?.summary ?? "")\n超出限制的较旧普通记录可能立即删除，删除后无法恢复。收藏会保留。") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 11) { BrandMark(size: 35); VStack(alignment: .leading, spacing: 2) { Text("剪巢").font(.system(size: 15, weight: .semibold)); Text("设置").font(.system(size: 11)).foregroundStyle(.secondary) } }.padding(.bottom, 27).padding(.top, 14)
            ForEach(tabs.indices, id: \.self) { index in
                Button { model.settingsTab = index } label: {
                    Label(tabs[index], systemImage: tabIcons[index])
                        .font(.system(size: 13, weight: model.settingsTab == index ? .medium : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 40)
                        .background(Theme.accent.opacity(model.settingsTab == index ? 0.11 : 0), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityAddTraits(model.settingsTab == index ? .isSelected : [])
            }
            Spacer()
            Button { model.showPanel?() } label: {
                Label("返回剪贴历史", systemImage: "arrow.uturn.backward").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(10)
            Text(model.isDemo ? "界面演示\n不会记录真实内容" : "本地优先 · 无需账号\n版本 \(AppIdentity.version)")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4).padding(10)
        }.padding(15).background(Theme.sidebar).transaction { $0.animation = nil }
    }

    private var generalSettings: some View {
        Group {
            SettingsGroup {
                HStack {
                    settingText("呼出快捷键", "点击右侧，按下你喜欢的组合键。")
                    Spacer()
                    ShortcutRecorder(shortcut: preferences.shortcut, onRecord: model.recordShortcut).frame(width: 138, height: 28)
                }
                if model.shortcutError { Text("快捷键无法使用，请换一个组合键重试。").font(.system(size: 11)).foregroundStyle(.red) }
                Divider()
                HStack {
                    settingText("外观", "跟随系统，或固定使用浅色与深色。")
                    Spacer()
                    Picker("外观", selection: $preferences.appearance) {
                        Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                    }.labelsHidden().frame(width: 138)
                }
            }
            SettingsGroup {
                Toggle(isOn: $preferences.automaticPaste) { settingText("选中后直接粘贴", "回车、双击或点击粘贴，直接回到原输入位置。") }.toggleStyle(.switch)
                if preferences.automaticPaste {
                    Divider()
                    PastePermissionStatusView(model: model)
                }
            }
            Text("使用方式：点选输入位置 → \(preferences.shortcut.label) 呼出 → 选中记录 → 回车粘贴。⌘Return 始终仅复制。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }

    private var storageSettings: some View {
        Group {
            SettingsGroup {
                HStack {
                    settingText("普通历史保留", "按最近复制时间计算；收藏不按时间清理。")
                    Spacer()
                    Picker("保留期限", selection: Binding(get: { preferences.retentionDays }, set: { requestLimit(.days($0)) })) {
                        Text("1 天").tag(1); Text("7 天").tag(7); Text("30 天").tag(30)
                        Text("90 天").tag(90); Text("半年").tag(180); Text("一年").tag(365)
                        Text("不按时间清理").tag(0)
                    }.labelsHidden().frame(width: 145)
                }
                Divider()
                HStack {
                    settingText("历史条数上限", "达到上限时先清理最旧的普通历史。")
                    Spacer()
                    Picker("历史条数上限", selection: Binding(get: { preferences.maximumItems }, set: { requestLimit(.items($0)) })) {
                        Text("500 条").tag(500); Text("1,000 条").tag(1_000); Text("5,000 条").tag(5_000)
                        Text("10,000 条").tag(10_000); Text("20,000 条").tag(20_000)
                    }.labelsHidden().frame(width: 145)
                }
                Divider()
                HStack {
                    settingText("存储预算", "收藏占满预算时停止新增，不会自动删除收藏。")
                    Spacer()
                    Picker("存储预算", selection: Binding(get: { preferences.maximumMB }, set: { requestLimit(.megabytes($0)) })) {
                        Text("100 MB").tag(100); Text("250 MB").tag(250); Text("500 MB").tag(500)
                        Text("1 GB").tag(1_024); Text("2 GB").tag(2_048); Text("5 GB").tag(5_120)
                    }.labelsHidden().frame(width: 145)
                }
            }
            .onChange(of: preferences.retentionDays) { _, _ in Task { await model.applyRetention() } }
            .onChange(of: preferences.maximumItems) { _, _ in Task { await model.applyRetention() } }
            .onChange(of: preferences.maximumMB) { _, _ in Task { await model.applyRetention() } }
            Text("“不按时间清理”仍受条数与空间上限约束；达到上限时先清理较旧普通记录。想长期留住的内容请收藏。收藏占满预算时停止新增。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            SettingsGroup {
                HStack {
                    settingText("本地存储", "\(model.itemCount) 条记录 · \(model.diskUsage)")
                    Spacer()
                    Button("查看文件夹") { if let url = model.store?.directory { NSWorkspace.shared.open(url) } }.controlSize(.small)
                }
                Divider()
                HStack { Text("普通历史").font(.system(size: 13)); Spacer(); Button("清空…") { confirmClear = true }.controlSize(.small) }
                Divider()
                HStack { Text("所有历史与收藏").font(.system(size: 13)); Spacer(); Button("删除全部…", role: .destructive) { confirmEverything = true }.controlSize(.small) }
            }
            Text("Finder 和多文件记录保留原文件引用；聊天图片会保存本地快照。剪贴内容当前使用本地明文存储；删除记录不会清空系统剪贴板，也无法删除系统备份中的副本。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }

    private var convenienceSettings: some View {
        Group {
            SettingsGroup {
                Toggle(isOn: $preferences.rememberSearch) {
                    settingText("保留上次搜索与筛选", "关闭时，每次呼出都从完整的最近历史开始。")
                }.toggleStyle(.switch)
                Divider()
                HStack {
                    settingText("快速使用前 9 条", "先呼出剪巢，再按 ⌘1–9；按当前搜索或筛选结果的顺序使用。")
                    Spacer()
                    KeyCap(text: "⌘ 1–9")
                }
                Divider()
                HStack {
                    settingText("只复制，不粘贴", "先将历史内容放回剪贴板，稍后在自己选的位置按 ⌘V；无需直接粘贴权限。")
                    Spacer()
                    KeyCap(text: "⌘ ↵")
                }
            }
            SettingsGroup {
                HStack {
                    settingText("临时暂停记录", model.isDemo ? "演示模式未读取真实剪贴板。" : model.captureState.title)
                    Spacer()
                    Button(model.captureState == .recording ? "暂停 15 分钟" : "恢复记录") {
                        if model.isDemo { settingsError = "演示模式不记录真实剪贴板。" } else { model.togglePause() }
                    }.controlSize(.small)
                }
                Divider()
                HStack {
                    settingText("跳过下一次复制", "只跳过一次，不用再回来恢复记录。")
                    Spacer()
                    Button("跳过一次") {
                        if model.isDemo { settingsError = "演示模式不记录真实剪贴板。" } else { model.skipNext() }
                    }.controlSize(.small)
                }
            }
            Text("锁屏时自动暂停，解锁后继续。所有内容只存本机。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }

    private var aboutSettings: some View {
        Group {
            HStack(spacing: 17) {
                BrandMark(size: 62)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text("剪巢").font(.system(size: 22, weight: .semibold))
                    }
                    Text("版本 \(AppIdentity.version) · 作者 \(AppIdentity.author)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 5)
            SettingsGroup {
                HStack {
                    settingText("遇到问题，告诉我", AppIdentity.feedbackEmail)
                    Spacer()
                    Button("邮件反馈…") {
                        if let url = AppIdentity.feedbackURL { NSWorkspace.shared.open(url) }
                    }.controlSize(.small)
                }
                Divider()
                HStack {
                    settingText("附上诊断，更容易解决", "仅包含版本、系统、权限和粘贴阶段，不含剪贴内容。")
                    Spacer()
                    Button(reportCopied ? "已复制" : "复制反馈模板") {
                        Task {
                            do { try await model.copyDiagnosticReport(); reportCopied = true }
                            catch { settingsError = error.localizedDescription }
                        }
                    }.controlSize(.small)
                }
            }
            Text("剪贴历史只保存在本机。邮件反馈由你确认并发送，应用不会自动上传记录。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            Text(AppIdentity.copyright).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 3)
        }
    }

    private func settingText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 13)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
    private func requestLimit(_ change: HistoryLimitChange) {
        let decreases: Bool
        switch change {
        case .days(let value): decreases = value > 0 && (preferences.retentionDays == 0 || value < preferences.retentionDays)
        case .items(let value): decreases = value < preferences.maximumItems
        case .megabytes(let value): decreases = value < preferences.maximumMB
        }
        if decreases { pendingLimit = change } else { applyLimit(change) }
    }
    private func applyLimit(_ change: HistoryLimitChange) {
        switch change {
        case .days(let value): preferences.retentionDays = value
        case .items(let value): preferences.maximumItems = value
        case .megabytes(let value): preferences.maximumMB = value
        }
    }
}

private enum HistoryLimitChange {
    case days(Int), items(Int), megabytes(Int)
    var summary: String {
        switch self {
        case .days(let days): return "普通历史保留期将调整为 \(days) 天。"
        case .items(let count): return "历史条数上限将调整为 \(count.formatted()) 条。"
        case .megabytes(let size): return "存储预算将调整为 \(ByteCountFormatter.string(fromByteCount: Int64(size) * 1_024 * 1_024, countStyle: .binary))。"
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}
