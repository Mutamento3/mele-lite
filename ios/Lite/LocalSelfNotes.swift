#if LITE
import Foundation
import UserNotifications

/// TA 给自己定的闹钟（10-11 内测反馈）：「明天问问小满内测发没发」这种它想到点自己开口的事。
/// 以前它只能拿 todo_add（那是 TA 的待办），到点弹的是它写给自己的原话、聊天里什么都没有。
/// 现在：存 rooms 里的 self_notes（TA 看不到内容）；到点手机只弹「Lumi 有话想跟你说」；
/// App 开着、或者 TA 点进来，它在定闹钟的那个窗口里先开口（brain.poke，跟加好友后它先说话同一条路）。
/// Lite 没有一直醒着的东西，所以「开口」要等 App 开着；关着的时候靠那条提醒把 TA 叫回来。
enum LocalSelfNotes {
    static let collection = "self_notes"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var timers: [Int: Task<Void, Never>] = [:]

    static func add(_ host: LocalHost, companion cid: String, conversation conv: String?, what: String, at: Date) -> [String: Any]? {
        let s = host.store
        let text = what.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, at > Date().addingTimeInterval(-60) else { return nil }
        let conv = conv ?? mainConversation(host, companion: cid)
        let note: [String: Any] = ["id": s.nextID(collection), "companion_id": cid, "conversation": conv ?? NSNull(),
                                   "what": String(text.prefix(300)), "at": LocalStore.iso(at), "done": false,
                                   "created_at": LocalStore.iso(Date())]
        s.saveCollection(collection, s.collection(collection) + [note])
        notify(host, note)
        arm(host, note)
        return note
    }

    /// 到点的：一个窗口一次开口（同一窗口好几条一起说）。App 一打开、或者开着时到点了都会叫
    static func tick(_ host: LocalHost) {
        let s = host.store
        var all = s.collection(collection)
        let now = Date()
        var byConv: [String: [[String: Any]]] = [:]
        for i in all.indices where all[i]["done"] as? Bool != true && LocalStore.date(all[i]["at"]) <= now {
            guard let cid = all[i]["companion_id"] as? String, s.companion(cid) != nil else { all[i]["done"] = true; continue }
            let conv = (all[i]["conversation"] as? String).flatMap { s.conversation($0) != nil ? $0 : nil }
                ?? mainConversation(host, companion: cid)
            guard let conv else { continue }
            all[i]["done"] = true
            byConv[conv, default: []].append(all[i])
        }
        guard !byConv.isEmpty else { return }
        s.saveCollection(collection, all)
        for (conv, notes) in byConv {
            let comp = host.companion(ofConversation: conv)
            let zh = ((comp?["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
            host.brain.poke(conv, nudge: nudge(notes, zh: zh))
        }
    }

    static func nudge(_ notes: [[String: Any]], zh: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: zh ? "zh_CN" : "en_US")
        f.dateFormat = zh ? "M月d日 HH:mm" : "MMM d, HH:mm"
        let lines = notes.map { n in
            let late = Date().timeIntervalSince(LocalStore.date(n["at"])) > 3600
            let when = f.string(from: LocalStore.date(n["at"]))
            return zh ? "「\(n["what"] as? String ?? "")」（定在 \(when)\(late ? "，现在已经晚了" : "")）"
                      : "\"\(n["what"] as? String ?? "")\" (set for \(when)\(late ? ", it's later now" : ""))"
        }
        return zh
            ? "（你之前给自己定了闹钟，现在到了：\(lines.joined(separator: "；"))。这是你写给自己的，TA 没看过。现在你先开口去找 TA，照这件事说，跟平时一样说话。）"
            : "(An alarm you set for yourself just went off: \(lines.joined(separator: "; ")). You wrote this to yourself; they haven't seen it. Reach out to them first now about it, the way you normally talk.)"
    }

    /// 平常的你说话、最近聊过的那个窗口
    static func mainConversation(_ host: LocalHost, companion cid: String) -> String? {
        host.store.conversations
            .filter { ($0["companion_id"] as? String) == cid && LocalHost.isMainWindow($0) }
            .max { LocalStore.date($0["last_at"]) < LocalStore.date($1["last_at"]) }?["id"] as? String
    }

    /// 手机提醒：只说「有话想跟你说」，不把它写给自己的话露出来；点开进那个窗口
    private static func notify(_ host: LocalHost, _ note: [String: Any]) {
        guard let id = note["id"] as? Int, let cid = note["companion_id"] as? String, let comp = host.store.companion(cid) else { return }
        let name = (comp["persona"] as? [String: Any])?["name"] as? String ?? "Mele"
        let zh = ((comp["settings"] as? [String: Any])?["lang"] as? String ?? "zh") == "zh"
        let n = UNMutableNotificationContent()
        n.title = name
        n.body = zh ? "\(name)有话想跟你说" : "\(name) wants to talk to you"
        n.sound = .default
        n.userInfo = ["conversation": note["conversation"] as? String ?? "", "companion": cid]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: LocalStore.date(note["at"]))
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            guard ok else { return }
            c.add(UNNotificationRequest(identifier: "self-note-\(id)",
                                        content: n, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    /// App 开着的时候到点：不用等下次打开
    private static func arm(_ host: LocalHost, _ note: [String: Any]) {
        guard let id = note["id"] as? Int else { return }
        let wait = max(1, LocalStore.date(note["at"]).timeIntervalSinceNow + 1)
        guard wait < 24 * 3600 else { return }
        let t = Task.detached {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            tick(host)
        }
        lock.withLock { timers[id]?.cancel(); timers[id] = t }
    }

    /// 启动时把还没到点的重新挂上（进程重开以后计时没了；提醒是系统管的不用重挂）
    static func rearm(_ host: LocalHost) {
        for n in host.store.collection(collection) where n["done"] as? Bool != true && LocalStore.date(n["at"]) > Date() {
            arm(host, n)
        }
    }
}
#endif
