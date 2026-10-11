import Foundation

/// 世界书导入（10-11 内测反馈）：酒馆的世界书 JSON、角色卡里的 character_book、或者一份 txt。
/// 都先摊成同一个样子，再走 CardParser.loreEntries（关键词去重、太短的不要、内容截 2000 字），规则跟导卡一样。
///
/// txt 的写法：一段一条（空行隔开；有 `---` 分隔线就按分隔线）。第一行是标题，
/// 可以有一行「关键词：a、b、c」；没写关键词就用标题当关键词。只有一行的写成「标题：内容」也认。
public enum LoreImport {
    static let maxBytes = 5 * 1024 * 1024
    static let maxEntries = 500

    public static func parse(_ data: Data, fileName: String, charName: String, userName: String,
                             lang: Lang) throws -> (entries: [LoreEntry], skipped: Int) {
        let zh = lang == .zh
        guard data.count <= maxBytes else { throw CardError(message: zh ? "文件太大了（最多 5MB）" : "File too large (5MB max)") }
        let raw: [[String: Any]]
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            raw = jsonEntries(obj)
        } else if let text = decodeText(data) {
            raw = textEntries(text)
        } else {
            throw CardError(message: zh ? "只认世界书 JSON 或 txt" : "Only lorebook JSON or .txt")
        }
        guard !raw.isEmpty else { throw CardError(message: zh ? "这个文件里没读到词条" : "No entries found in this file") }
        let user = userName.isEmpty ? (zh ? "你" : "you") : userName
        var (out, skipped) = CardParser.loreEntries(raw, name: charName, user: user)
        if out.count > maxEntries { skipped += out.count - maxEntries; out = Array(out.prefix(maxEntries)) }
        return (out, skipped)
    }

    /// txt 先按 UTF-8 读，不行再按 GB18030（中文 Windows 存的 txt 常是 GBK）
    public static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb))
    }

    // MARK: JSON

    /// 酒馆世界书 {entries: {"0": {...}}}、character_book {entries: [...]}、整张卡、或者直接一个数组
    static func jsonEntries(_ obj: Any) -> [[String: Any]] {
        if let list = obj as? [Any] { return list.compactMap { $0 as? [String: Any] }.map(normalize) }
        guard let d = obj as? [String: Any] else { return [] }
        if let book = ((d["data"] as? [String: Any])?["character_book"] ?? d["character_book"]) as? [String: Any] {
            return jsonEntries(book)
        }
        if let list = d["entries"] as? [Any] { return list.compactMap { $0 as? [String: Any] }.map(normalize) }
        if let dict = d["entries"] as? [String: Any] {
            let sorted = dict.sorted { (Int($0.key) ?? .max, $0.key) < (Int($1.key) ?? .max, $1.key) }
            return sorted.compactMap { $0.value as? [String: Any] }.map(normalize)
        }
        return []
    }

    /// 酒馆世界书的字段名（key / keysecondary / disable）→ 卡里的写法（keys / secondary_keys / enabled）
    static func normalize(_ e: [String: Any]) -> [String: Any] {
        var o = e
        if o["keys"] == nil { o["keys"] = e["key"] }
        if o["secondary_keys"] == nil { o["secondary_keys"] = e["keysecondary"] }
        if o["enabled"] == nil, let off = e["disable"] as? Bool { o["enabled"] = !off }
        return o
    }

    // MARK: txt

    static let rule = try! NSRegularExpression(pattern: #"^\s*(-{3,}|={3,}|\*{3,})\s*$"#)
    static let keysLine = try! NSRegularExpression(pattern: #"^\s*(关键词|关键字|触发词|keywords?|keys?)\s*[:：]\s*(.*)$"#,
                                                   options: .caseInsensitive)

    static func textEntries(_ text: String) -> [[String: Any]] {
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let ruled = lines.contains { matches(rule, $0) }
        var blocks: [[String]] = [], cur: [String] = []
        for l in lines {
            let cut = ruled ? matches(rule, l) : l.trimmingCharacters(in: .whitespaces).isEmpty
            if cut { if !cur.isEmpty { blocks.append(cur) }; cur = [] } else { cur.append(l) }
        }
        if !cur.isEmpty { blocks.append(cur) }
        return blocks.compactMap(block)
    }

    static func block(_ ls: [String]) -> [String: Any]? {
        var rest = ls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !rest.isEmpty else { return nil }
        var keys: [String] = []
        rest = rest.filter { l in
            guard let m = keysLine.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                  let r = Range(m.range(at: 2), in: l) else { return true }
            keys += l[r].split(whereSeparator: { ",，、;；|/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            return false
        }
        guard let first = rest.first else { return nil }
        var title = cleanTitle(first)
        var content = rest.dropFirst().joined(separator: "\n")
        if content.isEmpty {                                  // 只有一行：「标题：内容」
            if let i = first.firstIndex(where: { $0 == "：" || $0 == ":" }), first.distance(from: first.startIndex, to: i) <= 20 {
                title = cleanTitle(String(first[..<i]))
                content = String(first[first.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            } else {
                content = first
                title = ""
            }
        }
        if keys.isEmpty, !title.isEmpty, title.count <= 20 { keys = [title] }
        return ["keys": keys.filter { !$0.isEmpty }, "content": content, "comment": title]
    }

    static func cleanTitle(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "#【】[]「」《》*：: ").union(.whitespaces))
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
