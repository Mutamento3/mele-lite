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
    @State private var autos: [LocalBackup.AutoBackup] = []
    @State private var fromAuto = false     // 自动备份是同一台手机留的，钥匙还在钥匙串里

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
            if Lite.hosted { HostExportRows() }

            // 删 TA 前自动留的（10-11）
            if !autos.isEmpty {
                Divider().padding(.vertical, 2)
                Text("删 TA 前自动留的").font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
                Hint(text: String(localized: "每次删 TA 之前，Mele 会自己先整个备份一份，只留最近 3 份。恢复会把 Mele 退回到删之前那一刻，那之后的新聊天也会一起退回去。"))
                ForEach(autos) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("删「\(a.who)」之前").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                            Text("\(a.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: a.bytes, countStyle: .file))")
                                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        }
                        Spacer()
                        Button { fromAuto = true; Task { await prepareRestore(a.url) } } label: {
                            Text("恢复").font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.accentDeep)
                        }
                        .buttonStyle(.plain)
                        .disabled(working)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .onAppear { autos = LocalBackup.autoBackups() }
        .sheet(item: $share) { f in ActivityView(items: [f.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [Self.fileType, .data]) { result in
            guard case .success(let url) = result else { return }
            fromAuto = false
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
                 + ((restored?.keys ?? 0) == 0 && !fromAuto ? String(localized: "\n备份里没有钥匙，打开后在「钥匙串」重新加一下。") : ""))
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

/// 连着 Host 时（10-17 内测）：聊天在服务器上，上面那个一键备份带不走。这里从 Host 拿：
/// 所有 TA 的聊天各一份 md（给人看），和 Host 的 /me/export 整包 JSON（聊天、记忆、设定都在，留底）。
/// 真要整台恢复的备份在服务器上：mele-host backup。
private struct HostExportRows: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @State private var busy: String?
    @State private var files: ShareFiles?
    @State private var note: String?

    struct ShareFiles: Identifiable {
        let urls: [URL]
        var id: String { urls.map(\.path).joined() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 2)
            Text("Host 上的聊天").font(Typo.sans(Typo.Size.body, .semibold)).foregroundStyle(theme.ink)
            Hint(text: String(localized: "聊天存在你的 Host 上，上面的备份不带它们。从这里导出来存一份；想整台服务器都能恢复，在服务器上运行 mele-host backup。"))
            row("导出所有 TA 的聊天", "每个 TA 一份 md，打开就能看", key: "md") { await exportChats() }
            row("导出 Host 上的全部数据", "聊天、记忆、设定打成一个 JSON 留底（钥匙只有后 4 位）", key: "json") { await exportAll() }
            if let note { Text(note).font(Typo.sans(Typo.Size.caption)).foregroundStyle(.red.opacity(0.8)) }
        }
        .sheet(item: $files) { f in ActivityView(items: f.urls) }
    }

    private func row(_ title: String, _ sub: String, key: String, _ run: @escaping () async -> Void) -> some View {
        Button { Task { busy = key; note = nil; await run(); busy = nil } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                    Hint(text: sub)
                }
                Spacer()
                if busy == key { ProgressView() }
                else { Image(systemName: "square.and.arrow.up").font(Typo.icon(14)).foregroundStyle(theme.inkFaint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
    }

    private func exportChats() async {
        let me = model.profile?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var urls: [URL] = []
        do {
            for c in model.companions {
                urls.append(try await ChatExport.markdown(api: model.api, companion: c,
                                                          myName: me.isEmpty ? String(localized: "我") : me))
            }
            if urls.isEmpty { note = String(localized: "还没有 TA") } else { files = ShareFiles(urls: urls) }
        } catch {
            note = String(localized: "没导出来：\(error.localizedDescription)")
        }
    }

    private func exportAll() async {
        do {
            let data = try await model.api.data("me/export")
            let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(localized: "Mele Host 数据 \(day).json"))
            try data.write(to: url)
            files = ShareFiles(urls: [url])
        } catch {
            note = String(localized: "没导出来：\(error.localizedDescription)")
        }
    }
}

struct MeShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
#endif
