#if LITE
import Foundation
import MeleLiteCore

/// 双语气泡（10-15）：TA 设定里开。译文谁写：key = 钥匙串「翻译」那把翻（便宜，默认）；self = TA 每泡自己写〔译〕。
/// 你那句不翻（10-15 内测：用户不要）；TA 的几泡说完再翻（或切下 TA 写的〔译〕），存在那条消息的 translations 上。
enum LocalBilingual {
    static func active(_ s: [String: Any], group: Bool) -> Bool { (s["bilingual"] as? Bool ?? false) && !group }

    static func speaks(_ s: [String: Any]) -> String {
        let v = (s["bilingual_lang"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "English" : v
    }

    static func target(_ s: [String: Any], zh: Bool) -> String {
        let v = (s["bilingual_to"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? (zh ? "中文" : "English") : v
    }

    static func selfWrites(_ s: [String: Any]) -> Bool { (s["bilingual_by"] as? String) == "self" }

    static func rule(_ s: [String: Any], zh: Bool) -> String {
        Bilingual.rule(zh: zh, speaks: speaks(s), to: target(s, zh: zh), selfWrites: selfWrites(s))
    }

    /// 一次翻好几句；出错 = 全 nil（只显示原文）
    static func translate(_ host: LocalHost, comp: [String: Any], _ texts: [String], from src: String, to dst: String, zh: Bool) async -> [String?] {
        let none = [String?](repeating: nil, count: texts.count)
        guard !texts.isEmpty, let (p, key) = host.route(chore: "translate", else: host.quietRoute(for: comp)),
              !LiteConsent.book.needsAsk(p) else { return none }
        var cfg = p
        cfg.thinking = false
        let req = ChatRequest(system: "You are a careful translator.",
                              turns: [ChatTurn(role: .user, text: Bilingual.prompt(zh: zh, texts: texts, from: src, to: dst))],
                              maxTokens: 200 + 200 * texts.count)
        var out = ""
        do { for try await e in makeClient(cfg, key: key).stream(req) { if case .text(let t) = e { out += t } } }
        catch { NSLog("[bilingual] translate failed: \(error)"); return none }
        return Bilingual.parseList(out, count: texts.count)
    }
}
#endif
