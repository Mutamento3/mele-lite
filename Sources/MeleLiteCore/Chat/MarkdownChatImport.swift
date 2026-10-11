import Foundation

/// md 聊天记录（10-11 内测反馈）。一个文件 = 一段对话：
///   # Chat with 阿橘
///   ## 2026年10月11日星期日            ← 日期行（中文 / 英文 / 2026-10-11 都认）
///   ### 6:49 PM — D                    ← 时间 — 谁说的；TA 主动说的后面带 *(proactive)*
///   正文……
/// 「Chat with」后面的名字 = TA，别人都是你；标题里没写名字时，带 (proactive) 的是 TA，再不行第一个开口的算你。
/// 只认得这种「### 时间 — 名字」的写法：时间里要有 几:几，正文里的小标题不会被当成一条消息。
extension ChatImport {
    static func markdownChat(_ data: Data, timeZone: TimeZone = .current) -> ImportedConversation? {
        guard let first = data.first(where: { !Set<UInt8>([0x20, 0x0A, 0x0D, 0x09, 0xEF, 0xBB, 0xBF]).contains($0) }),
              first != UInt8(ascii: "{"), first != UInt8(ascii: "["),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var title = "", companion: String?
        struct Raw { var speaker: String; var proactive: Bool; var at: Date?; var body: [String] }
        var raws: [Raw] = [], day: DateComponents?
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# "), title.isEmpty, raws.isEmpty {
                title = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                for p in ["Chat with ", "与", "和"] where title.hasPrefix(p) {
                    var n = String(title.dropFirst(p.count))
                    for suf in ["的聊天记录", "的聊天", "的对话"] where n.hasSuffix(suf) { n = String(n.dropLast(suf.count)) }
                    companion = n.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if t.hasPrefix("## "), !t.hasPrefix("### "), let d = mdDay(String(t.dropFirst(3))) { day = d; continue }
            if t.hasPrefix("### "), let (time, who, pro) = mdHeader(String(t.dropFirst(4))) {
                raws.append(Raw(speaker: who, proactive: pro, at: mdDate(day, time, timeZone), body: []))
                continue
            }
            if !raws.isEmpty { raws[raws.count - 1].body.append(line) }
        }
        guard !raws.isEmpty else { return nil }

        let them = companion ?? raws.first(where: \.proactive)?.speaker ?? raws.first(where: { $0.speaker != raws[0].speaker })?.speaker
        var out: [ImportedMessage] = [], last = Date(timeIntervalSince1970: 0)
        let fallback = raws.compactMap(\.at).first ?? Date()
        for r in raws {
            var body = r.body
            while let l = body.last, ["", "---", "***"].contains(l.trimmingCharacters(in: .whitespaces)) { body.removeLast() }
            let msg = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty else { continue }
            var at = r.at ?? fallback
            if at <= last { at = last.addingTimeInterval(1) }      // 同一分钟好几条：保住先后
            last = at
            out.append(ImportedMessage(role: r.speaker == them ? .assistant : .user, text: msg, at: at))
        }
        guard !out.isEmpty else { return nil }
        let name = companion ?? them ?? ""
        return ImportedConversation(id: "md-\(name)-\(Int(out[0].at.timeIntervalSince1970))",
                                    title: title.isEmpty ? name : title, createdAt: out[0].at, messages: out,
                                    assistant: name.isEmpty ? nil : name)
    }

    /// 「6:49 PM — 阿橘 *(proactive)*」→ (时间, 名字, 是不是主动)。时间里没有 几:几 就不是消息头
    static func mdHeader(_ s: String) -> (String, String, Bool)? {
        guard let r = s.range(of: #"\s+[—–-]{1,2}\s+"#, options: .regularExpression) else { return nil }
        let time = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard time.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil else { return nil }
        var who = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        let pro = who.range(of: #"\*?\((proactive|主动)\)\*?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
        who = who.replacingOccurrences(of: #"\s*\*?\([^)]*\)\*?\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "* ").union(.whitespaces))
        return who.isEmpty ? nil : (time, who, pro)
    }

    /// 日期行：2026年10月11日星期日 / Sunday, October 11, 2026 / 2026-10-11
    static func mdDay(_ s: String) -> DateComponents? {
        func ints(_ pattern: String) -> [Int]? {
            guard let m = try? NSRegularExpression(pattern: pattern).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).flatMap { Int(s[$0]) } }
        }
        if let v = ints(#"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日"#) ?? ints(#"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})"#), v.count == 3 {
            return DateComponents(year: v[0], month: v[1], day: v[2])
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let cleaned = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["EEEE, MMMM d, yyyy", "MMMM d, yyyy", "EEEE, d MMMM yyyy", "d MMMM yyyy", "MMM d, yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: cleaned) {
                return Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
                    .settingTime()
            }
        }
        return nil
    }

    /// 日期 + 「6:49 PM」/「18:49」/「下午6:49」→ 时间（按手机时区）；没有日期行就没有时间
    static func mdDate(_ day: DateComponents?, _ time: String, _ tz: TimeZone) -> Date? {
        guard let day, let m = try? NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})"#)
            .firstMatch(in: time, range: NSRange(time.startIndex..., in: time)),
              let hr = Range(m.range(at: 1), in: time).flatMap({ Int(time[$0]) }),
              let mi = Range(m.range(at: 2), in: time).flatMap({ Int(time[$0]) }) else { return nil }
        var h = hr
        let low = time.lowercased()
        if (low.contains("pm") || time.contains("下午") || time.contains("晚上")) && h < 12 { h += 12 }
        if (low.contains("am") || time.contains("凌晨") || time.contains("上午")) && h == 12 { h = 0 }
        var c = DateComponents(year: day.year, month: day.month, day: day.day, hour: h, minute: mi)
        c.timeZone = tz
        return Calendar(identifier: .gregorian).date(from: c)
    }
}

private extension DateComponents {
    func settingTime() -> DateComponents { DateComponents(year: year, month: month, day: day) }
}
