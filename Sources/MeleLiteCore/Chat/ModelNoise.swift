import Foundation

/// 模型自己漏出来的内部标记（10-11 群聊真 key 测出来：DeepSeek 在回复开头吐了一段 <ds_safety>…</ds_safety> 安全分类）。
/// 不是 TA 说的话，进气泡之前删掉。Host 的 brain 同一份规则。
public enum ModelNoise {
    static let block = try! NSRegularExpression(pattern: #"<(ds_[A-Za-z_]+)>[\s\S]*?</\1>"#)
    static let open = try! NSRegularExpression(pattern: #"<ds_[A-Za-z_]+>[^\n]*\n?"#)

    public static func strip(_ text: String) -> String {
        var t = block.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        t = open.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        t = textToolCalls(t).rest
        return t == text ? text : t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ── 写成文字的工具调用（10-15 内测：本机模式 <function_calls><invoke name="memory_recall">… 原样进了气泡）──
    // 有的中转 / 模型不走工具接口，把调用当正文写出来。认三种：<function_calls><invoke>…、单独的 <invoke>…、<tool_call>{json}…；
    // 收尾标签常常写漏（截图里就没有 </args_json>），没收尾就算到下一个调用或者结尾。

    public struct TextCall: Equatable, Sendable {
        public var name: String
        public var argumentsJSON: String
    }

    static let wrapper = try! NSRegularExpression(pattern: #"<(?:antml:)?function_calls>([\s\S]*?)(?:</(?:antml:)?function_calls>|$)"#)
    static let invoke = try! NSRegularExpression(
        pattern: #"<(?:antml:)?invoke\s+name\s*=\s*["']([^"']+)["']\s*>([\s\S]*?)(?:</(?:antml:)?invoke>|(?=<(?:antml:)?invoke[\s>])|$)"#)
    static let toolCall = try! NSRegularExpression(pattern: #"<tool_call>([\s\S]*?)(?:</tool_call>|$)"#)
    static let parameter = try! NSRegularExpression(
        pattern: #"<(?:antml:)?parameter\s+name\s*=\s*["']([^"']+)["']\s*>([\s\S]*?)</(?:antml:)?parameter>"#)

    /// 找出写成文字的调用，返回 (调用, 删掉之后的正文)。没有就原样还回去
    public static func textToolCalls(_ text: String) -> (calls: [TextCall], rest: String) {
        guard text.contains("<") else { return ([], text) }
        var calls: [TextCall] = []
        var rest = text
        for (inner, _) in matches(wrapper, rest) {
            for (name, body) in matches(invoke, inner) { calls.append(fromInvoke(name, body)) }
        }
        rest = replace(wrapper, rest)
        for (name, body) in matches(invoke, rest) { calls.append(fromInvoke(name, body)) }
        rest = replace(invoke, rest)
        for (inner, _) in matches(toolCall, rest) {
            if let o = jsonObject(inner), let name = o["name"] as? String {
                calls.append(TextCall(name: name, argumentsJSON: json(o["arguments"] ?? o["parameters"] ?? [String: Any]())))
            }
        }
        rest = replace(toolCall, rest)
        if rest == text { return ([], text) }
        rest = rest.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return (calls, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fromInvoke(_ name: String, _ body: String) -> TextCall {
        let params = matches(parameter, body)
        if !params.isEmpty {
            var o: [String: Any] = [:]
            for (k, v) in params {
                let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
                o[k] = (try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed)) ?? s
            }
            return TextCall(name: name, argumentsJSON: json(o))
        }
        // <args_json>{…}</args_json> / 直接一段 JSON：从第一个 { 到最后一个 }
        if let a = body.firstIndex(of: "{"), let b = body.lastIndex(of: "}"), a < b,
           let o = jsonObject(String(body[a...b])) {
            return TextCall(name: name, argumentsJSON: json(o))
        }
        return TextCall(name: name, argumentsJSON: "{}")
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> [(String, String)] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (group($0, 1, s), group($0, 2, s)) }
    }
    static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }
    static func replace(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
    static func jsonObject(_ s: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(s.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any]
    }
    static func json(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}
