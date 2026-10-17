import Foundation

// MARK: - 导出一个 TA 的聊天记录（10-17 内测：一键备份只能整包恢复、打开也看不懂，想单独留一个人的）
//
// 走的是聊天页同一个接口（本机 / Host 一样）：每个窗口用 before 往前一页页翻到头，拼成一份人看得懂的 md。
// 不用 after 往后翻：本机那边 after 取的是最后一段，跟 Host 不一样。
// 想法过程、动作卡片这些不进；心声、图片 / 文件 / 语音占个位。

enum ChatExport {
    struct File: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    static func markdown(api: APIClient, companion: CompanionDTO, myName: String) async throws -> URL {
        let path = "companions/\(companion.id.lowercased)/conversations"
        let convs: [ConversationDTO] = try await api.call("GET", path)
        var windows: [(ConversationDTO, [MessageDTO])] = []
        for c in convs.reversed() {                                   // 列表是新的在前；导出从最早的窗口写起
            let msgs = try await allMessages(api: api, conversation: c.id)
            if !msgs.isEmpty { windows.append((c, msgs)) }
        }
        let text = render(companion: companion.name, myName: myName, windows: windows, now: Date())
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let safe = companion.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(localized: "和\(safe)的聊天记录 \(day).md"))
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func allMessages(api: APIClient, conversation: UUID) async throws -> [MessageDTO] {
        let path = "conversations/\(conversation.uuidString.lowercased())/messages"
        var out: [MessageDTO] = []
        var before = Int64(1) << 62
        while true {
            let page: MessagesPage = try await api.call("GET", path, query: [
                URLQueryItem(name: "before", value: String(before)),
                URLQueryItem(name: "limit", value: "500"),
            ])
            let got = page.messages.sorted { $0.id < $1.id }
            guard let first = got.first else { break }
            out.insert(contentsOf: got, at: 0)
            if !(page.hasMore ?? false) || Int64(first.id) >= before { break }
            before = Int64(first.id)
        }
        return out
    }

    static func render(companion: String, myName: String, windows: [(ConversationDTO, [MessageDTO])], now: Date) -> String {
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd EEE"; dayFmt.timeZone = .current
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"; timeFmt.timeZone = .current
        let total = windows.reduce(0) { $0 + $1.1.count }
        var lines = [
            "# " + String(localized: "和\(companion)的聊天记录"),
            "",
            String(localized: "导出于 \(now.formatted(date: .abbreviated, time: .shortened)) · \(windows.count) 个窗口 · \(total) 条"),
        ]
        if windows.isEmpty { lines += ["", String(localized: "（还没有聊过）")] }
        for (i, (conv, msgs)) in windows.enumerated() {
            var title = conv.title.isEmpty ? String(conv.first.prefix(24)) : conv.title
            if title.isEmpty { title = String(localized: "窗口 \(i + 1)") }
            var tags: [String] = []
            if !conv.altName.isEmpty { tags.append(String(localized: "小号：\(conv.altName)")) }
            if conv.incognito { tags.append(String(localized: "无痕")) }
            lines += ["", "", "## " + title + (tags.isEmpty ? "" : "（\(tags.joined(separator: " · "))）")]
            let me = conv.altName.isEmpty ? myName : conv.altName
            var lastDay = ""
            for m in msgs {
                let day = dayFmt.string(from: m.at)
                if day != lastDay { lines += ["", "### " + day]; lastDay = day }
                if let d = m.divider, !d.isEmpty { lines += ["", "— \(d) —"] }
                let who = m.role == "user" ? me : (m.speakerName ?? companion)
                var body = (m.bubbles?.isEmpty == false ? m.bubbles! : [m.text])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                for a in m.attachments ?? [] {
                    switch a.kind {
                    case "image": body.append(String(localized: "［图片］"))
                    case "voice": body.append(String(localized: "［语音］"))
                    default: body.append(String(localized: "［文件］"))
                    }
                }
                if body.isEmpty { continue }
                lines += ["", "**\(who)** \(timeFmt.string(from: m.at))"]
                lines += body.flatMap { [$0, ""] }.dropLast()
                if let v = m.innerVoice?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    lines += ["", "> " + String(localized: "心声：") + v.replacingOccurrences(of: "\n", with: "\n> ")]
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
