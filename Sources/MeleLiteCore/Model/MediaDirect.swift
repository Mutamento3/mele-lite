import Foundation

/// 看图 / 画图钥匙直接填（10-16 Aporia：从钥匙串挑太绕、看图画图一般不是同一把）。
/// 跟 Host 的 brain/media.py（verdict / _via_chat / DIRECT_PROVIDERS）同一个规矩，改要两边改。
public enum MediaDirect {
    public static let providers: [String: [String]] = [
        "vision": ["gemini", "anthropic", "openai", "openai-compatible"],
        "draw": ["gemini", "openai", "openai-compatible"],
    ]
    public static let drawDefaults = ["gemini": "gemini-2.5-flash-image", "openai": "gpt-image-1", "openai-compatible": "gpt-image-1"]
    public static let visionDefaults = ["anthropic": "claude-haiku-4-5", "gemini": "gemini-3.5-flash-lite", "openai": "gpt-4.1-mini"]
    static let imagey = ["image", "dall", "flux", "imagen", "banana", "seedream", "kolors", "midjourney", "sdxl", "stable-diffusion"]

    /// 查模型列表的结果 → 给用户看的一句话（code 0 = 连不上）
    public static func verdict(code: Int, ids: [String], model: String, slot: String) -> (ok: Bool, message: String) {
        if code == 0 { return (false, String(localized: "连不上这个地址，检查一下地址和网络")) }
        if code == 401 || code == 403 { return (false, String(localized: "key 不对，或者这把 key 没权限")) }
        if !(200..<300).contains(code) || ids.isEmpty {
            return (true, String(localized: "存好了。这家不给看模型列表，没法提前确认模型名，用的时候才知道"))
        }
        if ids.contains(model) { return (true, String(localized: "通了：这家有「\(model)」")) }
        var hint = ""
        if slot == "draw" {
            let like = ids.filter { i in imagey.contains { i.lowercased().contains($0) } }.prefix(8)
            hint = like.isEmpty ? String(localized: "。这家好像没有画图模型") : String(localized: "。像画图的有：") + like.joined(separator: "、")
        }
        return (false, String(localized: "这家没有叫「\(model)」的模型") + hint)
    }

    /// 中转站出图模型走 /chat/completions 时，回话里图在哪：message.images（OpenRouter 那种）、content 的 image_url 段、
    /// 正文里的 data URI / 链接。返回按先后的 data URI 或 http 链接
    public static func imageRefs(chatMessage msg: [String: Any]) -> [String] {
        var out: [String] = []
        for im in msg["images"] as? [[String: Any]] ?? [] {
            if let u = (im["image_url"] as? [String: Any])?["url"] as? String { out.append(u) }
        }
        func scan(_ t: String) {
            let ns = t as NSString
            for m in dataURI.matches(in: t, range: NSRange(location: 0, length: ns.length)) { out.append(ns.substring(with: m.range)) }
            for m in httpURL.matches(in: t, range: NSRange(location: 0, length: ns.length)) { out.append(ns.substring(with: m.range)) }
        }
        if let parts = msg["content"] as? [[String: Any]] {
            for p in parts {
                if let u = (p["image_url"] as? [String: Any])?["url"] as? String { out.append(u) }
                else if let u = p["image_url"] as? String { out.append(u) }
                if let t = p["text"] as? String { scan(t) }
            }
        } else if let t = msg["content"] as? String {
            scan(t)
        }
        return out
    }

    /// data URI 里的图
    public static func decodeDataURI(_ s: String) -> Data? {
        guard s.hasPrefix("data:image/"), let comma = s.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(s[s.index(after: comma)...]))
    }

    static let dataURI = try! NSRegularExpression(pattern: #"data:image/[a-zA-Z+]+;base64,[A-Za-z0-9+/=]+"#)
    static let httpURL = try! NSRegularExpression(pattern: #"https?://[^\s)\]"']+"#)
}
