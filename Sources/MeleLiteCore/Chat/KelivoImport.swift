import Foundation
import SQLite3

/// Kelivo 的整包备份（10-11，内测用户要的）。格式是照着 Kelivo 开源仓库（github.com/Chevey339/kelivo，AGPL-3.0）
/// 里备份 / 恢复的实现弄清的，下面的解析是自己写的，没有搬它的代码（THIRD_PARTY.md 记了一笔）。
///
/// 备份是一个 .zip：manifest.json（format = kelivo-backup）、settings.json、database/kelivo.db（SQLite），
/// 勾了「包含文件」还有 upload/、images/ 等文件夹。settings.json 和数据库里的 provider_rows 存着用户的 API key——
/// 这里只读对话那几张表和 Kelivo 自己记的记忆，别的一概不碰。
///
/// 数据库里（时间都是微秒）：
/// - conversation_rows：id、title、created_at、assistant_id、version_selections_json（{组号: 选中的版本}）
/// - message_rows：id、conversation_id、role、timestamp、group_id、version、message_order
///   重新生成的几个回答同一个 group_id、不同 version；没有 group_id 的自己一组
/// - message_part_rows：revision_id（= 消息 id）、ordinal、kind、payload；kind = text 的 payload 就是正文，
///   reasoning（思考）、tool_call、image、file 不要
/// - assistant_rows：payload 是 JSON，name 是角色名
/// - assistant_memory_rows：payload 是 JSON，content 是一条记忆
extension ChatImport {
    static let kelivoDBPath = "database/kelivo.db"

    static func isSQLite(_ d: Data) -> Bool { d.prefix(16) == Data("SQLite format 3\0".utf8) }

    /// 包里的数据库；不是 Kelivo 的包返回 nil
    static func kelivoDatabase(in data: Data) -> Data? {
        if isSQLite(data) { return data }
        return (try? MiniZip.entries(in: data, path: { $0 == kelivoDBPath }))?.first?.data
    }

    /// 屏幕上看到的那条线：按 message_order 排，每组取选中的版本（没选过就是最新的版本）
    static func kelivo(sqlite data: Data) throws -> [ImportedConversation] {
        try withKelivo(data) { db in
            var names: [String: String] = [:]
            try query(db, "SELECT id, payload FROM assistant_rows") { r in
                if let name = (json(r.text(1))?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    names[r.text(0)] = name
                }
            }
            var texts: [String: [String]] = [:]
            try query(db, "SELECT revision_id, payload FROM message_part_rows WHERE kind = 'text' ORDER BY revision_id, ordinal") { r in
                texts[r.text(0), default: []].append(r.text(1))
            }
            struct Row { let id, role, group: String; let version: Int; let at: Date }
            var rows: [String: [Row]] = [:]
            try query(db, """
                SELECT conversation_id, id, role, timestamp, group_id, version FROM message_rows
                ORDER BY conversation_id, message_order
                """) { r in
                let id = r.text(1)
                rows[r.text(0), default: []].append(Row(id: id, role: r.text(2), group: r.optionalText(4) ?? id,
                                                         version: r.int(5), at: micros(r.int(3))))
            }
            var out: [ImportedConversation] = []
            try query(db, "SELECT id, title, created_at, assistant_id, version_selections_json FROM conversation_rows ORDER BY created_at") { r in
                let cid = r.text(0)
                let chosen = (json(r.text(4)) ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
                var order: [String] = [], groups: [String: [Row]] = [:]
                for m in rows[cid] ?? [] {
                    if groups[m.group] == nil { order.append(m.group) }
                    groups[m.group, default: []].append(m)
                }
                let messages: [ImportedMessage] = order.compactMap { g in
                    let versions = groups[g]!.sorted { $0.version < $1.version }
                    let m = versions.first { $0.version == chosen[g] } ?? versions.last!
                    let role: Role? = switch m.role { case "user": .user; case "assistant": .assistant; default: nil }
                    let text = (texts[m.id] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let role, !text.isEmpty else { return nil }
                    return ImportedMessage(role: role, text: text, at: m.at)
                }
                guard !messages.isEmpty else { return }
                out.append(ImportedConversation(id: cid, title: r.text(1), createdAt: micros(r.int(2)), messages: messages,
                                                assistant: r.optionalText(3).flatMap { names[$0] }))
            }
            return out
        }
    }

    /// Kelivo 自己记的、关于用户的事（跟 Claude 的 memories 一样带过去当搬家笔记）
    public static func kelivoMemories(_ data: Data) -> [String] {
        guard let db = kelivoDatabase(in: data) else { return [] }
        return (try? withKelivo(db) { db in
            var out: [String] = []
            try query(db, "SELECT payload FROM assistant_memory_rows ORDER BY assistant_id, sort_order") { r in
                if let s = (json(r.text(0))?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    out.append(s)
                }
            }
            return out
        }) ?? []
    }

    // MARK: SQLite

    struct SQLRow {
        let s: OpaquePointer
        func text(_ i: Int32) -> String { optionalText(i) ?? "" }
        func optionalText(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
    }

    /// 系统 SQLite 只认文件：写到临时文件，只读打开（immutable：不建 -wal / -journal），用完删掉
    static func withKelivo<T>(_ data: Data, _ body: (OpaquePointer) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kelivo-\(UUID().uuidString).db")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        let uri = "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw ChatImportError.unrecognized
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    static func query(_ db: OpaquePointer, _ sql: String, _ each: (SQLRow) throws -> Void) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else {
            sqlite3_finalize(s)
            throw ChatImportError.unrecognized          // 没有这张表 = 不是 Kelivo 的库（或者太老 / 太新）
        }
        defer { sqlite3_finalize(s) }
        while true {
            switch sqlite3_step(s) {
            case SQLITE_ROW: try each(SQLRow(s: s))
            case SQLITE_DONE: return
            default: throw ChatImportError.unrecognized
            }
        }
    }

    static func micros(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) / 1_000_000) }
    static func json(_ s: String) -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] }
}
