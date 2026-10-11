#if LITE
import Foundation
import UIKit
import MeleLiteCore

/// 群聊（10-11 Aporia定，设计在 docs/superpowers/specs/2026-10-11-group-chat-design.md）：
/// 群是一种特殊的窗口（kind = group），不挂在哪个 TA 名下，存成员名单、群名、群头像、轮数上限、新成员看不看得到之前。
/// 消息照旧存在 conversations/<id>.json，TA 说的那条带 speaker（谁说的）。
/// 这里还管「一段脑子」：TA 在哪说话，都从它待过的别的房间捞最近 N 条（otherRooms）。
enum LocalGroups {
    static let defaultRounds = 6
    static let historyOnJoin = 30

    static func isGroup(_ c: [String: Any]?) -> Bool { (c?["kind"] as? String) == "group" }

    static func group(_ s: LocalStore, _ id: String) -> [String: Any]? {
        s.conversation(id).flatMap { isGroup($0) ? $0 : nil }
    }

    static func memberIDs(_ g: [String: Any]) -> [String] { g["members"] as? [String] ?? [] }

    /// 现在的成员（联系人字典，按名单顺序；删掉的 TA 跳过）
    static func members(_ s: LocalStore, _ conv: String) -> [[String: Any]] {
        guard let g = group(s, conv) else { return [] }
        return memberIDs(g).compactMap { s.companion($0) }
    }

    static func name(of comp: [String: Any]) -> String {
        (comp["persona"] as? [String: Any])?["name"] as? String ?? "TA"
    }

    /// 群名：没起就是成员名字连起来
    static func displayName(_ s: LocalStore, _ g: [String: Any]) -> String {
        let n = (g["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return memberIDs(g).compactMap { s.companion($0) }.map(name(of:)).joined(separator: "、")
    }

    // MARK: 接口

    static func handle(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        let p = r.parts, s = host.store
        guard p.first == "groups" else { return nil }
        switch (r.method, p.count) {
        case ("GET", 1):
            let all = s.conversations.filter { isGroup($0) }
                .sorted { LocalStore.date($0["last_at"]) > LocalStore.date($1["last_at"]) }
            return .json(all.map { groupOut(host, $0) })
        case ("POST", 1):
            return create(host, r.json)
        case ("GET", 2):
            guard let g = group(s, p[1]) else { return .error(404, String(localized: "没有这个群")) }
            return .json(groupOut(host, g))
        case ("PATCH", 2):
            return patch(host, p[1], r.json)
        case ("DELETE", 2):
            guard group(s, p[1]) != nil else { return .error(404, String(localized: "没有这个群")) }
            s.removeFile("group-\(p[1]).jpg")
            return host.deleteConversation(p[1])
        case ("GET", 3) where p[2] == "avatar":
            guard let d = try? Data(contentsOf: s.fileURL("group-\(p[1]).jpg")) else { return .error(404, String(localized: "还没有头像")) }
            return .data(d, mime: "image/jpeg")
        case ("PUT", 3) where p[2] == "avatar":
            guard var g = group(s, p[1]), let file = r.form.files["file"]?.first else { return .error(400, String(localized: "图读不了")) }
            s.saveFile(LocalHost.squareJPEG(file.data) ?? file.data, name: "group-\(p[1]).jpg")
            g["avatar_ver"] = (g["avatar_ver"] as? Int ?? 0) + 1
            s.saveConversation(g)
            return .json(groupOut(host, g))
        case ("DELETE", 3) where p[2] == "avatar":          // 恢复成员头像拼图
            guard var g = group(s, p[1]) else { return .error(404, String(localized: "没有这个群")) }
            s.removeFile("group-\(p[1]).jpg")
            g["avatar_ver"] = 0
            s.saveConversation(g)
            return .json(groupOut(host, g))
        case ("POST", 3) where p[2] == "members":
            return addMember(host, p[1], r.json["companion"] as? String ?? "")
        case ("DELETE", 4) where p[2] == "members":
            return kick(host, p[1], p[3])
        case ("GET", 3) where p[2] == "estimate":
            guard let g = group(s, p[1]) else { return .error(404, String(localized: "没有这个群")) }
            return .json(estimate(host, g))
        default:
            return nil
        }
    }

    static func groupOut(_ host: LocalHost, _ g: [String: Any]) -> [String: Any] {
        let s = host.store
        let id = g["id"] as? String ?? ""
        let last = s.messages(id).last
        var preview = String((last?["text"] as? String ?? "").prefix(40))
        if (last?["role"] as? String) == "assistant", let who = last?["speaker_name"] as? String { preview = "\(who)：" + preview }
        return ["id": id, "kind": "group", "name": g["name"] as? String ?? "", "display_name": displayName(s, g),
                "members": memberIDs(g), "former_members": g["former_members"] as? [String] ?? [],
                "avatar_ver": g["avatar_ver"] as? Int ?? 0, "max_rounds": g["max_rounds"] as? Int ?? defaultRounds,
                "new_member_sees_history": g["new_member_sees_history"] as? Bool ?? true,
                "last_at": g["last_at"] ?? "", "created_at": g["created_at"] ?? "", "preview": preview, "incognito": false]
    }

    private static func create(_ host: LocalHost, _ b: [String: Any]) -> LocalResponse {
        let s = host.store
        var ids: [String] = []
        for id in b["members"] as? [String] ?? [] where s.companion(id) != nil && !ids.contains(id) { ids.append(id) }
        guard ids.count >= 2 else { return .error(400, String(localized: "群里至少要两个 TA")) }
        let now = LocalStore.iso(Date())
        let g: [String: Any] = ["id": UUID().uuidString.lowercased(), "kind": "group",
                                "name": String((b["name"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(30)),
                                "members": ids, "former_members": [String](), "joined_at": Dictionary(uniqueKeysWithValues: ids.map { ($0, now) }),
                                "left_at": [String: String](), "max_rounds": defaultRounds, "new_member_sees_history": true,
                                "avatar_ver": 0, "created_at": now, "last_at": now, "incognito": false, "title": ""]
        s.saveConversation(g)
        return .json(groupOut(host, g), status: 201)
    }

    private static func patch(_ host: LocalHost, _ id: String, _ b: [String: Any]) -> LocalResponse {
        guard var g = group(host.store, id) else { return .error(404, String(localized: "没有这个群")) }
        if let n = b["name"] as? String { g["name"] = String(n.trimmingCharacters(in: .whitespaces).prefix(30)) }
        if let r = b["max_rounds"] as? Int { g["max_rounds"] = max(1, min(12, r)) }
        if let v = b["new_member_sees_history"] as? Bool { g["new_member_sees_history"] = v }
        host.store.saveConversation(g)
        return .json(groupOut(host, g))
    }

    private static func addMember(_ host: LocalHost, _ id: String, _ cid: String) -> LocalResponse {
        let s = host.store
        guard var g = group(s, id) else { return .error(404, String(localized: "没有这个群")) }
        guard s.companion(cid) != nil else { return .error(404, String(localized: "没有这个联系人")) }
        var ids = memberIDs(g)
        guard !ids.contains(cid) else { return .json(groupOut(host, g)) }
        ids.append(cid)
        g["members"] = ids
        g["former_members"] = (g["former_members"] as? [String] ?? []).filter { $0 != cid }
        var joined = g["joined_at"] as? [String: String] ?? [:]
        joined[cid] = LocalStore.iso(Date())
        g["joined_at"] = joined
        var left = g["left_at"] as? [String: String] ?? [:]
        left[cid] = nil
        g["left_at"] = left
        s.saveConversation(g)
        return .json(groupOut(host, g))
    }

    static func kick(_ host: LocalHost, _ id: String, _ cid: String, force: Bool = false) -> LocalResponse {
        let s = host.store
        guard var g = group(s, id) else { return .error(404, String(localized: "没有这个群")) }
        var ids = memberIDs(g)
        guard ids.contains(cid) else { return .json(groupOut(host, g)) }
        guard force || ids.count > 1 else { return .error(400, String(localized: "群里至少留一个 TA")) }
        ids.removeAll { $0 == cid }
        g["members"] = ids
        var former = g["former_members"] as? [String] ?? []
        if !former.contains(cid) { former.append(cid) }
        g["former_members"] = former
        var left = g["left_at"] as? [String: String] ?? [:]
        left[cid] = LocalStore.iso(Date())
        g["left_at"] = left
        s.saveConversation(g)
        return .json(groupOut(host, g))
    }

    /// 删掉一个 TA：自动退所有群（说过的话留着）
    static func companionRemoved(_ host: LocalHost, _ cid: String) {
        for g in host.store.conversations where isGroup(g) && memberIDs(g).contains(cid) {
            _ = kick(host, g["id"] as? String ?? "", cid, force: true)
        }
    }

    /// 「这个群大概一句多少钱」：每个成员判断一次（约 2000 字进、几个字出）+ 平均两个 TA 开口（各约 8000 token 进、300 出）
    static func estimate(_ host: LocalHost, _ g: [String: Any]) -> [String: Any] {
        let s = host.store
        var judge = 0.0, replies: [Double] = [], known = true
        for c in memberIDs(g).compactMap({ s.companion($0) }) {
            guard let kid = c["key_id"] as? String, let k = host.keys.first(where: { ($0["id"] as? String) == kid }),
                  let model = k["chat_model"] as? String,
                  let j = LocalUsage.cost(["model": model, "input": 1500, "output": 5]),
                  let r = LocalUsage.cost(["model": model, "input": 8000, "output": 300]) else { known = false; continue }
            judge += j
            replies.append(r)
        }
        let avg = replies.isEmpty ? 0 : replies.reduce(0, +) / Double(replies.count)
        let usd = judge + avg * Double(min(2, replies.count))
        return ["per_message_usd": usd, "known": known && !replies.isEmpty]
    }

    // MARK: 一段脑子

    /// 这个 TA 最近在用的普通私聊窗口（不是无痕、不是小号、不是群）
    static func mainWindow(_ s: LocalStore, companion cid: String) -> String? {
        s.conversations.filter { ($0["companion_id"] as? String) == cid && LocalHost.isMainWindow($0) && !isGroup($0) }
            .max { LocalStore.date($0["last_at"]) < LocalStore.date($1["last_at"]) }?["id"] as? String
    }

    /// 从 TA 待过的别的房间捞最近 limit 条：它在 / 待过的群（被踢的只到踢出那刻）+ 它的主私聊窗口。
    /// 当前窗口、别的 TA 的私聊、无痕、小号都不捞；心声和思考不带
    static func otherRooms(_ s: LocalStore, companion cid: String, except conv: String, limit: Int,
                           userName: String, zh: Bool) -> [RoomTimeline.Item] {
        guard limit > 0 else { return [] }
        var out: [RoomTimeline.Item] = []
        func add(_ room: String, _ convID: String, from: Date, until: Date) {
            for m in s.messages(convID) {
                let at = LocalStore.date(m["at"])
                guard at >= from, at <= until else { continue }
                let text = (m["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let who: String? = (m["role"] as? String) == "assistant"
                    ? ((m["speaker"] as? String).map { $0 == cid ? nil : (m["speaker_name"] as? String ?? "TA") } ?? nil)
                    : userName
                out.append(RoomTimeline.Item(id: "\(convID)-\(m["id"] as? Int ?? 0)", room: room, who: who, text: text, at: at))
            }
        }
        for g in s.conversations where isGroup(g) {
            guard let gid = g["id"] as? String, gid != conv else { continue }
            let now = memberIDs(g).contains(cid), was = (g["former_members"] as? [String] ?? []).contains(cid)
            guard now || was else { continue }
            let left = (g["left_at"] as? [String: String])?[cid]
            let joined = (g["joined_at"] as? [String: String])?[cid]
            let seesBefore = g["new_member_sees_history"] as? Bool ?? true
            let from = (!seesBefore && joined != nil) ? LocalStore.date(joined) : .distantPast
            add(RoomTimeline.groupRoom(displayName(s, g), zh: zh), gid,
                from: from, until: (!now && left != nil) ? LocalStore.date(left) : .distantFuture)
        }
        // 私聊只在它人在群里时捞（在私聊窗口里，那段本来就是当前房间）
        if isGroup(s.conversation(conv)), let main = mainWindow(s, companion: cid) {
            add(RoomTimeline.privateRoom(zh: zh), main, from: .distantPast, until: .distantFuture)
        }
        return Array(out.sorted { $0.at < $1.at }.suffix(limit))
    }
}
#endif
