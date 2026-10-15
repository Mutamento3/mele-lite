import Foundation

/// 双语气泡（10-15 Aporia：别家截图那种，TA 说英文、每泡下面一行中文；你那句不翻——10-15 内测说不要）。
/// 译文跟气泡一一对应存一列 translations；历史里你的话用翻好的那版，TA 的话只有原文。Host 那份是 server/brain/bilingual.py。
public enum Bilingual {
    public static let mark = "〔译〕"
    static let markLine = try! NSRegularExpression(pattern: #"\n?\s*[〔\[【(（]\s*译\s*[〕\]】)）]\s*[:：]?\s*"#)

    /// TA 自己写的〔译〕切下来：(原文们, 译文们)。〔译〕单独成了一泡的，算前一泡的译文
    public static func splitSelf(_ bubbles: [String]) -> (originals: [String], translations: [String?]) {
        var originals: [String] = [], trans: [String?] = []
        for b in bubbles {
            let ns = b as NSString
            guard let m = markLine.firstMatch(in: b, range: NSRange(location: 0, length: ns.length)) else {
                originals.append(b); trans.append(nil); continue
            }
            let head = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = ns.substring(from: m.range.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
            if head.isEmpty, !originals.isEmpty {
                if trans[trans.count - 1] == nil { trans[trans.count - 1] = tail.isEmpty ? nil : tail }
                continue
            }
            originals.append(head.isEmpty ? b : head)
            trans.append(tail.isEmpty ? nil : tail)
        }
        return (originals, trans)
    }

    /// 翻译模型回的 JSON 数组（可能包在 ```json 里）→ 长度 n；对不上就全 nil
    public static func parseList(_ text: String, count n: Int) -> [String?] {
        let none = [String?](repeating: nil, count: n)
        guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b,
              let arr = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [Any], arr.count == n else { return none }
        return arr.map { v in
            guard let s = v as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }

    /// 历史里你那句：每段都翻好了就用翻好的那版
    public static func userSide(_ text: String, _ translations: [Any]?) -> String {
        guard let t = translations as? [String], !t.isEmpty, t.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return text }
        return t.joined(separator: "\n")
    }

    public static func rule(zh: Bool, speaks lang: String, to: String, selfWrites: Bool) -> String {
        if zh {
            var line = "〔双语〕你一直用\(lang)说话（对方用别的语言跟你说也照样用\(lang)回）。"
            if selfWrites { line += "每个气泡写完原文，另起一行写「\(mark)」加上这句的\(to)翻译，翻译跟原文的语气一样。" }
            return line
        }
        var line = "〔Bilingual〕Always speak \(lang), even when they write to you in another language."
        if selfWrites { line += " After each bubble, on a new line, write \"\(mark)\" followed by its \(to) translation in the same tone." }
        return line
    }

    public static func prompt(zh: Bool, texts: [String], from src: String, to dst: String) -> String {
        let items = texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return zh
            ? "把下面编号的 \(texts.count) 句从\(src)翻成\(dst)。口语、保持原来的语气和称呼，不解释、不加东西。只回一个 JSON 字符串数组，\(texts.count) 个元素，顺序跟编号一样。\n\n\(items)"
            : "Translate the \(texts.count) numbered lines below from \(src) into \(dst). Keep it conversational, same tone and forms of address; no explanations, nothing added. Reply with only a JSON array of \(texts.count) strings, in order.\n\n\(items)"
    }
}
