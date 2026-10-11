import Compression
import Foundation

/// 导入酒馆角色卡。按公开规范读（Character Card V2 / V3），解析自己写；照 Mele 服务器 brain/tavern.py 的规则改写。
/// PNG：文字块里 `ccv3` 优先、`chara` 其次，值是 base64 JSON；图本身当头像。JSON 直接读。卡里的东西只当数据。
public struct ParsedCard: Sendable {
    public var name: String
    public var persona: String
    public var greetings: [String]
    public var avatarPNG: Data?
    public var lore: [LoreEntry]
    public var creatorNotes: String
    public var skippedLore: Int
}

public struct CardError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

public enum CardParser {
    static let maxBytes = 10 * 1024 * 1024
    static let maxText = 30_000
    static let textFields = ["name", "nickname", "description", "personality", "scenario", "first_mes", "mes_example",
                             "system_prompt", "post_history_instructions", "creator_notes"]
    static let pngSig = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// fileName 只用来认 txt 人设（10-11）：文件名当名字，整段当人设
    public static func parse(_ data: Data, userName: String, lang: Lang, fileName: String = "") throws -> ParsedCard {
        let zh = lang == .zh
        guard data.count <= maxBytes else { throw CardError(message: zh ? "文件太大了（最多 10MB）" : "File too large (10MB max)") }
        let obj: [String: Any]
        var image: Data?
        if data.starts(with: pngSig) {
            let texts = pngTexts(data)
            guard let raw = texts["ccv3"] ?? texts["chara"] else {
                throw CardError(message: zh ? "这张图里没有角色卡的数据" : "This image has no character card data")
            }
            guard let d = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                throw CardError(message: zh ? "卡里的数据读不出来" : "Couldn't read the card data")
            }
            obj = o; image = data
        } else if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if o["always_matters"] is [Any] || o["in_the_moment"] is [Any] {
                return try qaCard(o, fileName: fileName, userName: userName, zh: zh)
            }
            obj = o
        } else if [".txt", ".md", ".markdown"].contains(where: fileName.lowercased().hasSuffix), let text = LoreImport.decodeText(data) {   // md 10-11 内测反馈
            return try textCard(text, fileName: fileName, userName: userName, zh: zh)
        } else {
            throw CardError(message: zh ? "只认 PNG、JSON 角色卡或 txt / md 人设" : "Only PNG / JSON character cards or a .txt / .md persona")
        }
        let d = (obj["data"] as? [String: Any]) ?? obj
        let name = String((s(d["nickname"]).isEmpty ? s(d["name"]) : s(d["nickname"])).prefix(20))
        guard !name.isEmpty else { throw CardError(message: zh ? "这张卡没有名字，读不出来" : "This card has no name") }
        guard textFields.reduce(0, { $0 + s(d[$1]).count }) <= maxText else {
            throw CardError(message: zh ? "这张卡的文字太长了（超过 \(maxText) 字）" : "This card's text is too long")
        }
        let user = userName.isEmpty ? (zh ? "你" : "you") : userName
        let f = { (t: String) in fill(t, char: name, user: user) }
        let first = s(d["first_mes"])
        let alts = (d["alternate_greetings"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let greetings = (first.isEmpty ? [] : [first]) + alts
        let entries = ((d["character_book"] as? [String: Any])?["entries"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let (lore, skipped) = loreEntries(entries, name: name, user: user)
        return ParsedCard(name: name, persona: persona(d, f: f, zh: zh), greetings: greetings.map(f), avatarPNG: image,
                          lore: lore, creatorNotes: String(s(d["creator_notes"]).prefix(2000)), skippedLore: skipped)
    }

    /// txt 人设（10-11 内测反馈）：没有开场白、没有世界书；名字先用文件名，导进来以后能改
    static func textCard(_ text: String, fileName: String, userName: String, zh: Bool) throws -> ParsedCard {
        let body = text.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw CardError(message: zh ? "这个文件是空的" : "This file is empty") }
        guard body.count <= maxText else {
            throw CardError(message: zh ? "这个文件太长了（超过 \(maxText) 字）" : "This file is too long")
        }
        let stem = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        let name = String(stem.prefix(20)).isEmpty ? "TA" : String(stem.prefix(20))
        let user = userName.isEmpty ? (zh ? "你" : "you") : userName
        return ParsedCard(name: name, persona: persona(["description": body], f: { fill($0, char: name, user: user) }, zh: zh),
                          greetings: [], avatarPNG: nil, lore: [], creatorNotes: "", skippedLore: 0)
    }

    /// 一问一答式的角色导出（10-11 内测反馈）：exported_name + always_matters / in_the_moment 两组
    /// {id, question, answer}，问题里用 %companion_name% / %user% 占位。没答的题不要；认得的题中文换成中文小标题。
    static func qaCard(_ o: [String: Any], fileName: String, userName: String, zh: Bool) throws -> ParsedCard {
        let stem = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = String((s(o["exported_name"]).isEmpty ? (s(o["name"]).isEmpty ? stem : s(o["name"])) : s(o["exported_name"])).prefix(20))
        guard !name.isEmpty else { throw CardError(message: zh ? "这张卡没有名字，读不出来" : "This card has no name") }
        let user = userName.isEmpty ? (zh ? "你" : "you") : userName
        func fillQA(_ t: String) -> String {
            fill(t.replacingOccurrences(of: "%companion_name%", with: name).replacingOccurrences(of: "%user%", with: user), char: name, user: user)
        }
        var parts: [String] = []
        let kind = [s(o["companion_type"]), s(o["companion_subtype"])].filter { !$0.isEmpty }.joined(separator: " · ")
        for (key, head) in [("always_matters", zh ? "## 角色" : "## Character"), ("in_the_moment", zh ? "## 你们之间" : "## Between you")] {
            var block: [String] = []
            if key == "always_matters" && !kind.isEmpty { block.append((zh ? "类型：" : "Type: ") + kind) }
            for q in (o[key] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                let id = s(q["id"]), answer = fillQA(s(q["answer"]))
                if answer.isEmpty || qaSkip.contains(id) { continue }
                let title = (zh ? qaZH[id] : nil).map(fillQA) ?? fillQA(s(q["question"]))
                block.append("### " + (title.isEmpty ? id : title) + "\n" + answer)
            }
            if !block.isEmpty { parts.append(head + "\n" + block.joined(separator: "\n\n")) }
        }
        let persona = parts.joined(separator: "\n\n")
        guard !persona.isEmpty else { throw CardError(message: zh ? "这个文件里没有写角色设定" : "This file has no character details") }
        guard persona.count <= maxText else {
            throw CardError(message: zh ? "这张卡的文字太长了（超过 \(maxText) 字）" : "This card's text is too long")
        }
        return ParsedCard(name: name, persona: persona, greetings: [], avatarPNG: nil, lore: [], creatorNotes: "", skippedLore: 0)
    }

    /// 只是选项的题（「性格怎么定义：自定义描述」），答案对 TA 没用
    static let qaSkip: Set<String> = ["how_do_you_want_to_define_personality"]
    static let qaZH: [String: String] = [
        "whats_your_mbti_type": "MBTI",
        "what_are_you_like_as_a_person": "%companion_name%是什么样的人",
        "personality_quirks_and_mannerisms": "小习惯和口头禅",
        "situational_behaviors": "不同情况下会怎么做",
        "flaws_agency_and_imperfections": "缺点和不完美",
        "who_are_you_beyond_this_relationship": "这段关系以外的%companion_name%",
        "what_does_user_need_from_you": "%user%需要%companion_name%做什么",
        "how_should_you_treat_user": "%companion_name%怎么对待%user%",
        "whats_our_story": "%companion_name%和%user%的故事",
        "big_memories_and_milestones": "不能忘的大事",
        "inside_jokes_and_recurring_bits": "只有你们懂的梗",
        "your_story_accomplishments_struggles_dreams": "%companion_name%的经历、难处和梦想",
        "current_relationship_status": "现在有多亲近",
        "if_other_describe_status": "关系（补充）",
        "shared_interests": "你们都喜欢的",
        "favorites_and_avoidances": "%companion_name%喜欢和避开的",
        "little_things_to_remember": "要记住的关于%user%的小事",
        "sensitive_topics_preferences": "敏感话题和偏好",
        "what_do_you_hope_for_with_user": "%companion_name%对%user%的期待",
        "important_people_in_companions_life": "%companion_name%生命里重要的人",
        "additional_information": "补充",
    ]

    static func s(_ v: Any?) -> String { (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    /// {{char}} → 角色名，{{user}} → TA 的名字；{{original}} 拿掉（那是酒馆自己的系统提示词）。
    static func fill(_ text: String, char: String, user: String) -> String {
        var t = text.replacingOccurrences(of: #"\{\{\s*original\s*\}\}"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\{\{\s*char\s*\}\}|<BOT>|<CHAR>"#, with: char, options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\{\{\s*user\s*\}\}|<USER>"#, with: user, options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func persona(_ d: [String: Any], f: (String) -> String, zh: Bool) -> String {
        let h = zh ? ["## 角色", "性格：", "## 场景", "## 说话示例", "## 作者对这个角色的说明"]
                   : ["## Character", "Personality: ", "## Scenario", "## How they talk (examples)", "## The author's notes on this character"]
        var parts: [String] = []
        let body = [f(s(d["description"])), s(d["personality"]).isEmpty ? "" : h[1] + f(s(d["personality"]))].filter { !$0.isEmpty }
        if !body.isEmpty { parts.append(h[0] + "\n" + body.joined(separator: "\n")) }
        if !s(d["scenario"]).isEmpty { parts.append(h[2] + "\n" + f(s(d["scenario"]))) }
        let example = f(s(d["mes_example"]).replacingOccurrences(of: "<START>", with: "", options: .caseInsensitive))
        if !example.isEmpty { parts.append(h[3] + "\n" + example) }
        let author = f(s(d["system_prompt"]))
        if !author.isEmpty { parts.append(h[4] + "\n" + author) }
        return parts.joined(separator: "\n\n")
    }

    /// 单个汉字可以当关键词，单个字母不行。
    static func keywordOK(_ k: String) -> Bool {
        if k.count >= 2 { return true }
        guard let u = k.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(Int(u.value)) || (0x3400...0x4DBF).contains(Int(u.value))
    }

    static func loreEntries(_ entries: [[String: Any]], name: String, user: String) -> ([LoreEntry], Int) {
        var out: [LoreEntry] = []
        var skipped = 0
        for e in entries {
            let raw = ((e["keys"] as? [Any] ?? []) + (e["secondary_keys"] as? [Any] ?? [])).compactMap { $0 as? String }
            var seen = Set<String>(), kws: [String] = []
            for k in raw {
                let k2 = fill(k, char: name, user: user).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if keywordOK(k2) && seen.insert(k2.lowercased()).inserted { kws.append(String(k2.prefix(40))) }
            }
            let content = String(fill(s(e["content"]), char: name, user: user).prefix(2000))
            let constant = (e["constant"] as? Bool) == true
            if content.isEmpty || (kws.isEmpty && !constant) { skipped += 1; continue }
            let title = [s(e["comment"]), s(e["name"]), kws.first ?? name].first { !$0.isEmpty } ?? name
            out.append(LoreEntry(title: String(title.prefix(40)), keys: kws.isEmpty ? [name] : Array(kws.prefix(20)), content: content,
                                 constant: constant, enabled: (e["enabled"] as? Bool) != false))
        }
        return (out, skipped)
    }

    /// PNG 的 tEXt / zTXt / iTXt 文字块 → [关键字: 文字]
    static func pngTexts(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        let b = [UInt8](data)
        var i = 8
        while i + 8 <= b.count {
            let n = Int(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
            let kind = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            let start = i + 8, end = min(start + n, b.count)
            let body = Array(b[start..<end])
            i = start + n + 4
            if kind == "IEND" { break }
            guard let z = body.firstIndex(of: 0) else { continue }
            let key = String(bytes: body[..<z], encoding: .isoLatin1) ?? ""
            let rest = Array(body[(z + 1)...])
            switch kind {
            case "tEXt":
                out[key] = String(bytes: rest, encoding: .isoLatin1)
            case "zTXt":
                if rest.count > 1, let d = inflate(Array(rest[1...])) { out[key] = String(bytes: d, encoding: .isoLatin1) }
            case "iTXt":
                guard rest.count > 2 else { continue }
                let compressed = rest[0] == 1
                var r = Array(rest[2...])
                guard let l = r.firstIndex(of: 0) else { continue }; r = Array(r[(l + 1)...])
                guard let t = r.firstIndex(of: 0) else { continue }; r = Array(r[(t + 1)...])
                let bytes = compressed ? inflate(r) : r
                if let bytes { out[key] = String(bytes: bytes, encoding: .utf8) }
            default: break
            }
        }
        return out
    }

    /// zlib 流（去掉 2 字节头）用系统自带的 Compression 解开。
    static func inflate(_ z: [UInt8]) -> [UInt8]? {
        guard z.count > 2 else { return nil }
        let src = Array(z[2...])
        var cap = max(src.count * 8, 4096)
        while cap <= 64 * 1024 * 1024 {
            var dst = [UInt8](repeating: 0, count: cap)
            let n = compression_decode_buffer(&dst, cap, src, src.count, nil, COMPRESSION_ZLIB)
            if n > 0 && n < cap { return Array(dst[..<n]) }
            cap *= 4
        }
        return nil
    }
}
