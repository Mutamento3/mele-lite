#if LITE
import Foundation
import MeleLiteCore

/// TA 写日记（10-05 Aporia：本机也要）。服务器是每天凌晨等 TA 睡了写前一天；Lite 没有一直醒着的东西，
/// 改成**打开 App 时**：昨天聊过（或你昨天写了日记）、TA 还没写昨天的，就用你的 key 补写一篇。只补昨天，不往前翻。
/// 主联系人默认写（diary_on，默认开）；10-12 起别的联系人也能写（diary_also，默认关——多一个人写就多花一份 key）。
/// diary_chars 管长短；不写〔锁着〕（本机没有要钥匙那一套）。
/// 你那天没锁的日记只给主联系人读，页边那一句也只有它留（存在你那篇的 margin 上）。提示词在 MeleLiteCore/DiaryDesk。
enum LocalDiary {
    static let sourceChars = 12_000
    nonisolated(unsafe) private static var writing = false
    private static let lock = NSLock()

    static func maybeWrite(_ host: LocalHost, now: Date = Date()) {
        guard lock.withLock({ () -> Bool in if writing { return false }; writing = true; return true }) else { return }
        Task {
            defer { lock.withLock { writing = false } }
            await write(host, now: now)
        }
    }

    /// 这个联系人写不写日记：主联系人看 diary_on（默认开），别的看 diary_also（默认关）
    static func writes(_ settings: [String: Any], main: Bool) -> Bool {
        main ? settings["diary_on"] as? Bool ?? true : settings["diary_also"] as? Bool ?? false
    }

    static func write(_ host: LocalHost, now: Date) async {
        let cal = Calendar.current
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) else { return }
        for (i, comp) in host.store.companions.enumerated() {               // 一个一个写，不并发（各用各的 key）
            await write(host, comp, main: i == 0, yesterday: yesterday, now: now)
        }
    }

    static func write(_ host: LocalHost, _ comp: [String: Any], main: Bool, yesterday: Date, now: Date) async {
        let s = host.store
        guard let cid = comp["id"] as? String else { return }
        let st = comp["settings"] as? [String: Any] ?? [:]
        guard writes(st, main: main), let (provider, key) = host.route(chore: "diary", else: host.route(for: comp)),
              !LiteConsent.book.needsAsk(provider) else { return }
        let day = dayString(yesterday)
        let all = s.collection("diary")
        if all.contains(where: { ($0["author"] as? String) == "companion" && ($0["companion_id"] as? String) == cid && ($0["day"] as? String) == day }) {
            return
        }
        let zh = (st["lang"] as? String ?? "zh") == "zh"
        let user = (st["user_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let who = user.isEmpty ? (zh ? "TA" : "Them") : user
        let contact = LocalBrain.contact(comp, provider: provider)

        // 那天的对话：这个 TA 的平常窗口（无痕、小号不算），按时间排，太长留最后的
        let end = yesterday.addingTimeInterval(86_400)
        var lines: [(Date, String)] = []
        for c in s.conversations where (c["companion_id"] as? String) == cid && LocalHost.isMainWindow(c) {
            guard let conv = c["id"] as? String else { continue }
            for m in s.messages(conv) {
                let at = LocalStore.date(m["at"])
                guard at >= yesterday, at < end, m["divider"] == nil || m["divider"] is NSNull,
                      let text = (m["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                let speaker = (m["role"] as? String) == "assistant" ? (zh ? "我" : "Me") : who
                lines.append((at, "\(speaker)：\(text)"))
            }
        }
        var transcript = lines.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
        if transcript.count > sourceChars { transcript = "……\n" + String(transcript.suffix(sourceChars)) }
        let theirs = main ? all.filter { ($0["author"] as? String) == "user" && ($0["day"] as? String) == day && ($0["private"] as? Bool) != true } : []
        guard !transcript.isEmpty || !theirs.isEmpty else { return }          // 没材料不写（防编）

        var materials = (zh ? "〔那天的对话〕\n" : "〔That day's conversation〕\n")
            + (transcript.isEmpty ? (zh ? "（那天我们没说话）" : "(We didn't talk that day)") : transcript)
        if !theirs.isEmpty {
            materials += zh ? "\n\n〔TA 那天的日记〕（TA 写给自己的，没锁，所以我读得到）\n" : "\n\n〔Their diary that day〕(written for themselves, not locked, so I can read it)\n"
            materials += theirs.map { "#\($0["id"] as? Int ?? 0)\n\($0["body"] as? String ?? "")" }.joined(separator: "\n\n")
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let limit = max(300, min(1500, st["diary_chars"] as? Int ?? 600))
        let prompt = DiaryDesk.prompt(now: f.string(from: now), day: day, materials: materials, limit: limit, lang: zh ? .zh : .en)
        let system = (zh ? "你是 \(contact.name)。\n" : "You are \(contact.name).\n") + contact.persona
        let req = ChatRequest(system: system, turns: [ChatTurn(role: .user, text: prompt)], maxTokens: 3000)
        var text = ""
        do {
            for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } }
        } catch { return }
        let got = DiaryDesk.parse(text)
        let body = String(got.body.prefix(Int(Double(limit) * 1.3)))
        guard !body.isEmpty else { return }

        let stamp = LocalStore.iso(Date())
        var fresh = s.collection("diary")
        if fresh.contains(where: { ($0["author"] as? String) == "companion" && ($0["companion_id"] as? String) == cid && ($0["day"] as? String) == day }) {
            return                                                            // 写的时候另一处已经写了
        }
        for (id, line) in got.margins where main {
            if let i = fresh.firstIndex(where: { ($0["id"] as? Int) == id && ($0["author"] as? String) == "user" && ($0["day"] as? String) == day }) {
                fresh[i]["margin"] = line
                fresh[i]["margin_from"] = contact.name
            }
        }
        fresh.append(["id": s.nextID("diary"), "author": "companion", "companion_id": cid, "from": contact.name, "day": day,
                      "body": body, "has_locked": false, "private": false, "written_at": stamp, "updated_at": stamp])
        s.saveCollection("diary", fresh)
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: d)
    }
}
#endif
