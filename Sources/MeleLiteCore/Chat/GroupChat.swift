import Foundation

/// 群聊（10-11 Aporia定）：谁被 @ 了、谁先说、要不要接话的那一下、群里的规矩。
/// 被 @ 的直接说；其余每个 TA 用自己的模型判断一下「说 / 过」，想说的排队一个一个说，后说的看得到先说的。
/// Host 的 brain/group.py 同一份意思、同一份文案。
public enum GroupChat {
    public struct Member: Sendable, Equatable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// 正文里 @ 到的成员 id，按出现先后、不重复。名字长的先认（「@小满满」不会被认成小满）
    public static func mentioned(in text: String, members: [Member]) -> [String] {
        var hits: [(at: Int, id: String)] = []
        var taken: [Range<String.Index>] = []
        for m in members.sorted(by: { $0.name.count > $1.name.count }) where !m.name.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: "@" + m.name, range: from..<text.endIndex) {
                if !taken.contains(where: { $0.overlaps(r) }) {
                    taken.append(r)
                    if !hits.contains(where: { $0.id == m.id }) {
                        hits.append((text.distance(from: text.startIndex, to: r.lowerBound), m.id))
                    }
                }
                from = r.upperBound
            }
        }
        return hits.sorted { $0.at < $1.at }.map(\.id)
    }

    /// 排队：被 @ 的按 @ 的先后排最前；其余想说的打乱
    public static func order(mentioned: [String], wanting: [String],
                             shuffle: ([String]) -> [String] = { $0.shuffled() }) -> [String] {
        var head: [String] = []
        for id in mentioned where !head.contains(id) { head.append(id) }
        return head + shuffle(wanting.filter { !head.contains($0) })
    }

    /// 判断的回答：有「过 / pass」= 过；有「说 / speak」= 说；看不懂 = 过（别让一个坏回答卡住群）
    public static func wantsToSpeak(_ reply: String) -> Bool {
        let t = reply.lowercased()
        if t.contains("过") || t.contains("pass") { return false }
        return t.contains("说") || t.contains("speak")
    }

    /// 判断要不要接话那一下：人设摘要 + 群里最近十来句，只回一个字
    public static func judgePrompt(zh: Bool, me: String, persona: String, group: String, userName: String,
                                   others: [String], recent: [(who: String, text: String)]) -> (system: String, user: String) {
        let who = ([userName] + others).filter { !$0.isEmpty }
        let lines = recent.map { label($0.who) + $0.text }.joined(separator: "\n")
        let brief = String(persona.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        if zh {
            let system = "你是\(me)。" + (brief.isEmpty ? "" : "\n\n\(brief)") +
                "\n\n你在群「\(group)」里，群里还有：\(who.joined(separator: "、"))。"
            let user = "群里最近的聊天：\n\(lines.isEmpty ? "（还没人说话）" : lines)\n\n" +
                "看最后那句，按你的性子来：想接话、想插嘴、被提到了，就回「说」；这句轮不到你，就回「过」。只回一个字。"
            return (system, user)
        }
        let system = "You are \(me)." + (brief.isEmpty ? "" : "\n\n\(brief)") +
            "\n\nYou're in the group \"\(group)\" with: \(who.joined(separator: ", "))."
        let user = "Recent messages in the group:\n\(lines.isEmpty ? "(nobody has spoken yet)" : lines)\n\n" +
            "Look at the last message and go with your nature: if you want to reply, chime in, or you were mentioned, answer \"speak\"; if it's not your turn, answer \"pass\". One word only."
        return (system, user)
    }

    /// 群里 TA 的 system 多这一段
    public static func roomRules(zh: Bool, group: String, me: String, userName: String, others: [String]) -> String {
        let all = ([userName] + others).filter { !$0.isEmpty }
        if zh {
            return "【群聊】这里是群「\(group)」，群里有\(all.joined(separator: "、"))，还有你\(me)。" +
                "别人的话前面标着〔名字〕。你只说你自己的话，不替别人开口，开头也不写自己的名字。想接谁的话就接谁的，想点名就 @名字。\n" +
                "你们现在在群聊里，群里每个人都看得到你说的话。私聊里的日常小事顺嘴提起没关系；很私密的——亲密的事、\(userName)只跟你一个人讲的心事和秘密——留在私聊里说。"
        }
        return "[Group chat] This is the group \"\(group)\" — \(all.joined(separator: ", ")), and you, \(me). " +
            "Other people's lines start with 〔name〕. Speak only as yourself, never for anyone else, and don't start with your own name. Reply to whoever you like; @name to call someone out.\n" +
            "You're in a group chat now — everyone here sees what you say. Everyday bits from your DMs are fine to mention; the truly private things — intimacy, and secrets or feelings \(userName) shared only with you — stay in your DMs."
    }

    public static func label(_ name: String) -> String { "〔\(name)〕" }

    /// 模型偶尔学着历史给自己也垫个名字：开头的「〔阿橘〕」「阿橘：」去掉
    public static func stripOwnLabel(_ text: String, name: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for head in [label(name), name + "：", name + ":"] where t.hasPrefix(head) {
            t = String(t.dropFirst(head.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return t
    }

    /// 刚被拉进群、看得到之前的聊天时，垫在最前面
    public static func joinNote(zh: Bool) -> String {
        zh ? "（你刚被拉进群，翻了翻前面的聊天记录）" : "(You were just added to the group and scrolled back through the earlier messages.)"
    }
}
