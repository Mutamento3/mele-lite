#if LITE
import SwiftUI
import UniformTypeIdentifiers

/// 备份（2026-10-10 内测前）：一键把手机里的 Mele 打成一个文件，存到「文件」/ iCloud 云盘；
/// 换手机、误删 App 时从这里恢复。打包和恢复在 Lite/LocalBackup.swift。
struct BackupCard: View {
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("backup.includeKeys") private var includeKeys = false
    @AppStorage("backup.last") private var lastBackup = 0.0

    @State private var working = false
    @State private var share: MeShareFile?
    @State private var failure: String?
    @State private var importing = false
    @State private var pending: URL?
    @State private var pendingSummary: LocalBackup.Summary?
    @State private var restored: LocalBackup.Summary?

    private static let fileType = UTType(filenameExtension: LocalBackup.ext) ?? .data

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("备份").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            Hint(text: Lite.hosted
                 ? String(localized: "聊天和房间在你的 Host 上；这里备份的是手机上的东西：主屏、壁纸、小组件、设置，还有搬家前留在手机里的。")
                 : String(localized: "你的 Mele 全都只存在这台手机上，删了 App 就没了。导出一个备份文件存到「文件」或 iCloud 云盘，换手机、误删都能找回来。"))
            Toggle(isOn: $includeKeys) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("连模型钥匙一起备份").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                    Hint(text: String(localized: "打开的话，备份文件里会有 API key 的原文，别发给别人。不带的话，恢复后重新填一下钥匙就行。"))
                }
            }
            .tint(theme.accentDeep)

            Button { Task { await export() } } label: {
                HStack(spacing: 8) {
                    if working { ProgressView().tint(.white).scaleEffect(0.8) }
                    Text(working ? String(localized: "正在打包……") : String(localized: "一键备份"))
                        .font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Capsule().fill(theme.accentDeep))
            }
            .buttonStyle(.plain)
            .disabled(working)

            HStack {
                if lastBackup > 0 {
                    Text("上次备份：\(Date(timeIntervalSince1970: lastBackup).formatted(date: .abbreviated, time: .shortened))")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
                Spacer()
                Button { importing = true } label: {
                    Label("从备份恢复", systemImage: "arrow.counterclockwise")
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.accentDeep)
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
            if let failure {
                Text(failure).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red.opacity(0.8))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .sheet(item: $share) { f in ActivityView(items: [f.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [Self.fileType, .data]) { result in
            guard case .success(let url) = result else { return }
            Task { await prepareRestore(url) }
        }
        // 弹窗一关 isPresented 就置 false——那时候别删文件，恢复按钮自己带着地址走
        .alert(String(localized: "用这个备份恢复？"), isPresented: Binding(get: { pendingSummary != nil },
                                                                  set: { if !$0 { pendingSummary = nil } })) {
            Button(String(localized: "取消"), role: .cancel) { cancelRestore() }
            Button(String(localized: "恢复"), role: .destructive) {
                if let u = pending { Task { await restore(u) } }
            }
        } message: {
            if let s = pendingSummary { Text(confirmText(s)) }
        }
        .alert(String(localized: "恢复好了"), isPresented: Binding(get: { restored != nil }, set: { if !$0 { restored = nil } })) {
            Button(String(localized: "好")) { restored = nil }
        } message: {
            Text(String(localized: "从后台把 Mele 划掉，再打开，就是备份里的样子了。")
                 + ((restored?.keys ?? 0) == 0 ? String(localized: "\n备份里没有钥匙，打开后在「钥匙串」重新加一下。") : ""))
        }
    }

    private func confirmText(_ s: LocalBackup.Summary) -> String {
        let when = ISO8601DateFormatter().date(from: s.created)?.formatted(date: .abbreviated, time: .shortened) ?? s.created
        let size = ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file)
        return String(localized: "这个备份是 \(when) 做的，\(s.files) 个文件、\(size)。\n恢复会替换掉这台手机上现在的 Mele 内容。")
    }

    private func export() async {
        working = true
        failure = nil
        let keys = includeKeys
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result { try LocalBackup.export(includeKeys: keys) }
        }.value
        working = false
        switch result {
        case .success(let url):
            lastBackup = Date().timeIntervalSince1970
            share = MeShareFile(url: url)
        case .failure(let e):
            failure = String(localized: "没打包成：\(e.localizedDescription)")
        }
    }

    /// 选好文件：先拷进临时文件夹（选来的地址只在这一下能读），读清单给她确认
    private func prepareRestore(_ url: URL) async {
        failure = nil
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).\(LocalBackup.ext)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            pendingSummary = try LocalBackup.peek(copy)
            pending = copy
        } catch {
            try? FileManager.default.removeItem(at: copy)
            failure = (error as? LocalizedError)?.errorDescription ?? String(localized: "读不了这个文件")
        }
    }

    private func cancelRestore() {
        if let p = pending { try? FileManager.default.removeItem(at: p) }
        pending = nil
        pendingSummary = nil
    }

    private func restore(_ url: URL) async {
        working = true
        let result = await Task.detached(priority: .userInitiated) { () -> Result<LocalBackup.Summary, Error> in
            Result { try LocalBackup.restore(url) }
        }.value
        working = false
        try? FileManager.default.removeItem(at: url)
        pending = nil
        pendingSummary = nil
        switch result {
        case .success(let s): restored = s
        case .failure(let e): failure = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
        }
    }
}

struct MeShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
#endif
