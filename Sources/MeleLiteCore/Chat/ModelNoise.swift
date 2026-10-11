import Foundation

/// 模型自己漏出来的内部标记（10-11 群聊真 key 测出来：DeepSeek 在回复开头吐了一段 <ds_safety>…</ds_safety> 安全分类）。
/// 不是 TA 说的话，进气泡之前删掉。Host 的 brain 同一份规则。
public enum ModelNoise {
    static let block = try! NSRegularExpression(pattern: #"<(ds_[A-Za-z_]+)>[\s\S]*?</\1>"#)
    static let open = try! NSRegularExpression(pattern: #"<ds_[A-Za-z_]+>[^\n]*\n?"#)

    public static func strip(_ text: String) -> String {
        var t = block.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        t = open.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        return t == text ? text : t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
