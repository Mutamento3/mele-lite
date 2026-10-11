#if LITE
import MeleLiteCore
import SwiftUI

/// 世界书导入（10-11 内测反馈）：选一个文件 → 手机上先读（MeleLiteCore/LoreImport）→ 看一眼读到几条、给谁 → 一条条存。
/// 在手机上读，存走跟手写一样的 POST lore，所以手机里的小管家和 Host 都能用。
struct LoreImportFile: Identifiable {
    let id = UUID()
    let name: String
    let entries: [MeleLiteCore.LoreEntry]
    let skipped: Int
}

struct LoreImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LoreStore
    let file: LoreImportFile

    @State private var forWho = ""
    @State private var saved = 0
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(file.skipped > 0
                         ? String(localized: "读到 \(file.entries.count) 条（另有 \(file.skipped) 条没有关键词或是空的，跳过）")
                         : String(localized: "读到 \(file.entries.count) 条"))
                    Picker(String(localized: "给谁"), selection: $forWho) {
                        ForEach(model.companions) { c in Text(c.name).tag(c.id.uuidString.lowercased()) }
                        Text(String(localized: "所有人都知道")).tag("")
                    }
                } footer: { Text(file.name) }
                Section {
                    ForEach(file.entries) { e in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(e.title).font(Typo.sans(Typo.Size.body, .medium)).foregroundStyle(theme.ink)
                                if e.constant { Text(String(localized: "常驻")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.accentDeep) }
                                if !e.enabled { Text(String(localized: "关着")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint) }
                            }
                            Text(e.keys.joined(separator: "、")).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim).lineLimit(1)
                            Text(e.content).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint).lineLimit(2)
                        }
                    }
                }
                if let err = store.error { Text(err).foregroundStyle(.red) }
            }
            .navigationTitle(String(localized: "导入世界书"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { Text("\(saved)/\(file.entries.count)").foregroundStyle(theme.inkDim) }
                    else { Button(String(localized: "导入")) { Task { await save() } }.disabled(file.entries.isEmpty) }
                }
            }
            .onAppear { forWho = model.primaryCompanion?.id.uuidString.lowercased() ?? "" }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        for e in file.entries {
            let body: [String: Any] = ["name": e.title, "keywords": e.keys.joined(separator: ", "), "content": e.content,
                                       "enabled": e.enabled, "constant": e.constant,
                                       "companion_id": forWho.isEmpty ? NSNull() : forWho]
            guard await store.save(nil, body: body) else { return }    // 出错就停，前面的已经存好
            saved += 1
        }
        dismiss()
    }

    /// 读文件：失败给一句人话
    static func read(_ url: URL, charName: String, userName: String) -> Result<LoreImportFile, CardError> {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let zh = !(Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("en")
        guard let data = try? Data(contentsOf: url) else {
            return .failure(CardError(message: zh ? "这个文件打不开" : "Couldn't open this file"))
        }
        do {
            let (es, skipped) = try LoreImport.parse(data, fileName: url.lastPathComponent, charName: charName,
                                                     userName: userName, lang: zh ? .zh : .en)
            return .success(LoreImportFile(name: url.lastPathComponent, entries: es, skipped: skipped))
        } catch let e as CardError {
            return .failure(e)
        } catch {
            return .failure(CardError(message: zh ? "读不出来" : "Couldn't read it"))
        }
    }
}
#endif
