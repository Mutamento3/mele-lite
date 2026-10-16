#if LITE
import Foundation
import MeleLiteCore
import UIKit

/// 看图和画图（10-15 Aporia：让用户自己填 Gemini key 看图、填生图 key）。
/// Me →「看图和画图」从钥匙串里挑两把：
/// - 看图：TA 聊天的模型看不见图（DeepSeek、兼容口）时，TA 发的照片先交给这把写一段描述，描述跟着那句话进上下文、存在附件上，以后也记得；
///   没挑就用钥匙串里第一把会看图、同意过的。
/// - 画图：挑了才有 draw 工具。Gemini 走 generateContent（图片模型），OpenAI / 兼容口走 /images/generations。不限张数（10-15 Aporia：用户自己的 key，想画多少画多少）。
/// 10-15 起挑哪把存在钥匙串分活表（LocalChores / chores.json）；media.json 只剩搬家时读一次
/// 10-16 Aporia：Me 里改成两栏直接填（哪家 / key / 中转站地址 / 模型），不进钥匙串；存在 media_direct.json，key 在 vault「media-direct-<栏>」。
/// 直接填的优先，没填照旧看钥匙串里勾的。存的时候查一遍模型列表（不花钱）；中转站画图 /images/generations 不通就换 /chat/completions
enum LocalMedia {
    static let defaultModels = ["gemini": "gemini-2.5-flash-image", "openai": "gpt-image-1", "openai-compatible": "gpt-image-1"]

    static func settings(_ s: LocalStore) -> [String: Any] { s.read("media.json") as? [String: Any] ?? [:] }

    static func handle(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        if r.parts.count == 4, Array(r.parts.prefix(3)) == ["me", "media", "direct"], r.method == "PUT" {
            return await putDirect(host, slot: r.parts[3], body: r.json)
        }
        guard r.parts == ["me", "media"] else { return nil }
        switch r.method {
        case "GET": return .json(publicOut(host))
        case "PUT":
            var (t, dm) = LocalChores.table(host)
            let live = LocalChores.live(host)
            for (field, chore) in [("vision_key", "vision"), ("image_key", "draw")] where r.json.keys.contains(field) {
                guard let id = r.json[field] as? String, !id.isEmpty else { t[chore] = nil; continue }
                guard let p = live[id] else { return .error(404, String(localized: "没有这把钥匙")) }
                guard Chores.can(p).contains(chore) else {
                    return .error(400, chore == "vision" ? String(localized: "DeepSeek 看不见图，挑一把 Gemini / Claude / OpenAI 的")
                                                         : String(localized: "这家不会画图，挑一把 Gemini 或 OpenAI（兼容口）的"))
                }
                t[chore] = id
            }
            if let model = r.json["image_model"] as? String { dm = model.trimmingCharacters(in: .whitespacesAndNewlines) }
            LocalChores.save(host, table: t, drawModel: dm)
            return .json(publicOut(host))
        default: return nil
        }
    }

    static func publicOut(_ host: LocalHost) -> [String: Any] {
        let (t, dm) = LocalChores.table(host)
        let live = LocalChores.live(host)
        let d = directTable(host.store)
        return ["vision_key": Chores.pick(t, "vision", live: live) ?? NSNull(), "image_key": Chores.pick(t, "draw", live: live) ?? NSNull(),
                "image_model": dm, "default_models": defaultModels, "vision_defaults": MediaDirect.visionDefaults,
                "direct": ["vision": d["vision"] ?? NSNull(), "draw": d["draw"] ?? NSNull()] as [String: Any],
                "drawn_today": drawnToday(host.store)]
    }

    // MARK: - 直接填的看图 / 画图钥匙（10-16）

    static func directTable(_ s: LocalStore) -> [String: [String: Any]] {
        s.read("media_direct.json") as? [String: [String: Any]] ?? [:]
    }

    static func vaultID(_ slot: String) -> String { "media-direct-\(slot)" }

    /// (哪家, key, 模型, 地址)
    static func direct(_ host: LocalHost, _ slot: String) -> (provider: String, key: String, model: String, base: String?)? {
        guard let d = directTable(host.store)[slot], let p = d["provider"] as? String, let key = host.vault.get(vaultID(slot)) else { return nil }
        let defaults = slot == "draw" ? MediaDirect.drawDefaults : MediaDirect.visionDefaults
        let m = (d["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaults[p] ?? ""
        return (p, key, m, (d["base_url"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func config(_ provider: String, model: String, base: String?) -> ProviderConfig {
        switch provider {
        case "anthropic": ProviderConfig(kind: .anthropic, model: model)
        case "gemini": ProviderConfig(kind: .gemini, model: model)
        default: ProviderConfig(kind: .openai, baseURL: base, model: model)
        }
    }

    static func putDirect(_ host: LocalHost, slot: String, body: [String: Any]) async -> LocalResponse {
        guard let allowed = MediaDirect.providers[slot] else { return .error(404, "没有这一栏") }
        var table = directTable(host.store)
        guard let provider = body["provider"] as? String, !provider.isEmpty else {        // 空 = 清掉
            table[slot] = nil
            host.store.write("media_direct.json", table)
            host.vault.set(nil, for: vaultID(slot))
            var out = publicOut(host); out["check"] = NSNull()
            return .json(out)
        }
        guard allowed.contains(provider) else {
            return .error(400, slot == "draw" ? String(localized: "这家不会画图，挑 Gemini、OpenAI 或中转站") : String(localized: "挑 Gemini、Claude、OpenAI 或中转站"))
        }
        var base = (body["base_url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let model = (body["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "openai-compatible" {
            if base.isEmpty { return .error(400, String(localized: "中转站要填地址（一般以 /v1 结尾）")) }
            if model.isEmpty {
                return .error(400, slot == "draw" ? String(localized: "中转站要填模型名：去中转站后台看它的画图模型叫什么")
                                                  : String(localized: "中转站要填模型名：去中转站后台看它的会看图的模型叫什么"))
            }
        }
        var key = (body["api_key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            guard let old = host.vault.get(vaultID(slot)) else { return .error(400, String(localized: "要填 key")) }
            key = old
        }
        host.vault.set(key, for: vaultID(slot))
        table[slot] = ["provider": provider, "base_url": provider == "openai-compatible" ? base : "", "model": model, "last4": String(key.suffix(4))]
        host.store.write("media_direct.json", table)
        let cfg = config(provider, model: model, base: provider == "openai-compatible" ? base : nil)
        LiteConsent.book.grant(cfg)                     // 自己在这儿填的，就是同意把图发给这家
        let defaults = slot == "draw" ? MediaDirect.drawDefaults : MediaDirect.visionDefaults
        let v = await check(provider, key: key, model: model.isEmpty ? defaults[provider] ?? "" : model, base: base, slot: slot)
        var out = publicOut(host)
        out["check"] = ["ok": v.ok, "message": v.message]
        return .json(out)
    }

    /// 查模型列表（不花钱）
    static func check(_ provider: String, key: String, model: String, base: String, slot: String) async -> (ok: Bool, message: String) {
        var req: URLRequest
        switch provider {
        case "gemini":
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case "anthropic":
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1000")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        default:
            guard let u = URL(string: (provider == "openai-compatible" ? base : "https://api.openai.com/v1") + "/models") else {
                return MediaDirect.verdict(code: 0, ids: [], model: model, slot: slot)
            }
            req = URLRequest(url: u)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 20
        guard let (d, resp) = try? await URLSession.shared.data(for: req) else {
            return MediaDirect.verdict(code: 0, ids: [], model: model, slot: slot)
        }
        let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let ids: [String] = provider == "gemini"
            ? (obj["models"] as? [[String: Any]] ?? []).compactMap { ($0["name"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }
            : (obj["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return MediaDirect.verdict(code: (resp as? HTTPURLResponse)?.statusCode ?? 0, ids: ids, model: model, slot: slot)
    }

    // MARK: - 看图

    /// 看图用哪把：挑过的那把 → 钥匙串里第一把会看图、同意过的
    static func visionRoute(_ host: LocalHost) -> (ProviderConfig, String)? {
        if let d = direct(host, "vision") { return (config(d.provider, model: d.model, base: d.base), d.key) }     // Me 里直接填的（10-16）
        if let r = host.route(chore: "vision", else: nil), r.0.seesImages { return r }
        for k in host.keys {
            guard let id = k["id"] as? String, let r = host.route(key: id), r.0.seesImages,
                  !LiteConsent.book.needsAsk(r.0) else { continue }
            return r
        }
        return nil
    }

    /// 给一张图写描述（写过就直接用，存在附件的 caption 上）；写不出来返回 nil
    static func describe(_ host: LocalHost, attachment id: String, zh: Bool) async -> String? {
        let s = host.store
        if let a = s.collection("attachments").first(where: { ($0["id"] as? String) == id }),
           let c = a["caption"] as? String, !c.isEmpty { return c }
        guard let (provider, key) = visionRoute(host),
              let d = try? Data(contentsOf: s.fileURL("att-\(id)")), let img = UIImage(data: d),
              let jpeg = LocalBrain.jpeg(img, maxSide: 1280) else { return nil }
        let ask = zh ? "把这张图写成一段客观、具体的描述（100～200 字）：图里有什么、在哪、什么样子、颜色和光线，有字就照抄。这是写给以后看不到这张图的自己看的，不评价、不客套、不猜拍的人在想什么。"
                     : "Write an objective, concrete description of this photo (60–120 words): what's in it, where, what it looks like, colours and light; copy any text exactly. It's for your future self who can't see the image — no judging, no pleasantries, no guessing what the person was thinking."
        var text = ""
        do {
            let req = ChatRequest(system: zh ? "你在帮一个聊天伙伴看图。只描述，不聊天。" : "You're looking at a photo for a chat companion. Describe only; don't chat.",
                                  turns: [ChatTurn(role: .user, text: ask, imageJPEG: jpeg)], maxTokens: 600)
            for try await e in makeClient(provider, key: key).stream(req) { if case .text(let t) = e { text += t } }
        } catch {
            return nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var all = s.collection("attachments")
        if let i = all.firstIndex(where: { ($0["id"] as? String) == id }) {
            all[i]["caption"] = text
            s.saveCollection("attachments", all)
        }
        return text
    }

    /// 历史里一张图怎么写（看不见图的模型每张都用；看得见的、不是这一轮的那几张也用）
    static func photoLine(_ caption: String, zh: Bool) -> String {
        caption.isEmpty ? (zh ? "〔发了一张照片，还没看清是什么〕" : "〔Sent a photo — not described yet〕")
                        : (zh ? "〔发了一张照片：\(caption)〕" : "〔Sent a photo: \(caption)〕")
    }

    // MARK: - 画图

    static func imageRoute(_ host: LocalHost) -> (provider: String, key: String, model: String, base: String?)? {
        if let d = direct(host, "draw") { return d }                // Me 里直接填的（10-16）
        let (t, dm) = LocalChores.table(host)
        guard let id = Chores.pick(t, "draw", live: LocalChores.live(host)), let k = host.keys.first(where: { ($0["id"] as? String) == id }),
              let p = k["provider"] as? String, let fallback = defaultModels[p], let secret = host.vault.get(id) else { return nil }
        let own = k["chat_model"] as? String ?? ""          // 钥匙上本来填的就是画图模型（10-16 内测）就用它
        let model = !dm.isEmpty ? dm : Chores.isImageModel(own) ? own : fallback
        return (p, secret, model, (k["base_url"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func drawnToday(_ s: LocalStore) -> Int {
        let today = LocalRooms.today()
        return (s.read("media_draws.json") as? [String: Int])?[today] ?? 0
    }

    static let toolSpec = ToolSpec(
        name: "draw",
        description: "用途：画一张图发给 TA（用 TA 挑的画图模型）。TA 让你画、或者你真想给 TA 看个画面（你那边的样子、你想象的场景）时用；prompt 写清楚画什么、什么风格、什么构图。画好的图会跟你这句话一起发过去，不用再描述一遍。每张都花 TA 的钱，不是每轮都画。",
        parametersJSON: #"{"type":"object","required":["prompt"],"properties":{"prompt":{"type":"string","description":"画什么：主体、动作、场景、风格、光线、构图"}}}"#)

    enum DrawError: Error { case noKey, failed(String) }

    /// 画一张，存成附件，返回附件号
    static func draw(_ host: LocalHost, prompt: String, conversation conv: String) async throws -> String {
        guard let r = imageRoute(host) else { throw DrawError.noKey }
        let s = host.store
        let data = r.provider == "gemini" ? try await gemini(prompt, key: r.key, model: r.model)
                                          : try await openAI(prompt, key: r.key, model: r.model, base: r.base, relay: r.provider == "openai-compatible")
        guard let img = UIImage(data: data), let jpg = LocalBrain.jpeg(img, maxSide: 1600) else { throw DrawError.failed("not an image") }
        let id = UUID().uuidString.lowercased()
        s.saveFile(jpg, name: "att-\(id)")
        var all = s.collection("attachments")
        all.append(["id": id, "conversation": conv, "kind": "image", "name": "drawn-\(id.prefix(8)).jpg", "mime": "image/jpeg",
                    "size": jpg.count, "caption": prompt, "drawn": true])
        s.saveCollection("attachments", all)
        var counts = s.read("media_draws.json") as? [String: Int] ?? [:]
        let today = LocalRooms.today()
        counts = counts.filter { $0.key >= today }            // 只留今天
        counts[today, default: 0] += 1
        s.write("media_draws.json", counts)
        return id
    }

    private static func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? String(data: d.prefix(200), encoding: .utf8) ?? ""
            throw DrawError.failed("\(code) \(msg)")
        }
        return obj
    }

    static func gemini(_ prompt: String, key: String, model: String) async throws -> Data {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        let obj = try await post(url, headers: ["x-goog-api-key": key],
                                 body: ["contents": [["parts": [["text": prompt]]]],
                                        "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]]])
        let parts = ((obj["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        for p in parts {
            let inline = (p["inlineData"] ?? p["inline_data"]) as? [String: Any]
            if let b64 = inline?["data"] as? String, let d = Data(base64Encoded: b64) { return d }
        }
        throw DrawError.failed("没有图（模型名对吗？要选会出图的，比如 gemini-2.5-flash-image）")
    }

    static func openAI(_ prompt: String, key: String, model: String, base: String?, relay: Bool = false) async throws -> Data {
        var b = base ?? "https://api.openai.com/v1"
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + "/images/generations") else { throw DrawError.failed("地址不对") }
        let obj: [String: Any]
        do {
            obj = try await post(url, headers: ["Authorization": "Bearer \(key)"],
                                 body: ["model": model, "prompt": prompt, "n": 1, "size": "1024x1024"])
        } catch DrawError.failed(let first) where relay {
            // 中转站的出图模型常只走聊天接口（10-16 内测 503）
            do { return try await viaChat(prompt, key: key, model: model, base: b) }
            catch DrawError.failed(let why) { throw DrawError.failed("\(first)；换聊天接口也不行：\(why)") }
        }
        guard let first = (obj["data"] as? [[String: Any]])?.first else { throw DrawError.failed("没有图") }
        if let b64 = first["b64_json"] as? String, let d = Data(base64Encoded: b64) { return d }
        if let u = (first["url"] as? String).flatMap(URL.init(string:)) {
            let (d, _) = try await URLSession.shared.data(from: u)
            return d
        }
        throw DrawError.failed("没有图")
    }

    static func viaChat(_ prompt: String, key: String, model: String, base: String) async throws -> Data {
        guard let url = URL(string: base + "/chat/completions") else { throw DrawError.failed("地址不对") }
        let obj = try await post(url, headers: ["Authorization": "Bearer \(key)"],
                                 body: ["model": model, "messages": [["role": "user", "content": prompt]]])
        let msg = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        for ref in MediaDirect.imageRefs(chatMessage: msg) {
            if let d = MediaDirect.decodeDataURI(ref) { return d }
            if let u = URL(string: ref), let (d, resp) = try? await URLSession.shared.data(from: u),
               (resp as? HTTPURLResponse)?.statusCode == 200, UIImage(data: d) != nil { return d }
        }
        throw DrawError.failed("回话里没有图（这个模型会出图吗？）")
    }

    static func runTool(_ a: [String: Any], host: LocalHost, conversation: String?, zh: Bool) async -> (LocalTools.Outcome, String?) {
        let prompt = (a["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return (.init(result: "没成：prompt 要写画什么", card: nil), nil) }
        guard let conv = conversation else { return (.init(result: "没成：这里发不了图", card: nil), nil) }
        do {
            let id = try await draw(host, prompt: prompt, conversation: conv)
            let card: [String: Any] = ["kind": "tool", "text": "\(zh ? "画了一张" : "Drew")：\(String(prompt.prefix(40)))"]
            return (.init(result: zh ? "画好了，会跟你这句话一起发给 TA。" : "Done — it'll be sent along with your message.", card: card), id)
        } catch DrawError.failed(let why) {
            return (.init(result: "没成：\(why)", card: nil), nil)
        } catch {
            return (.init(result: zh ? "没成：画图那边连不上" : "Failed: couldn't reach the image model", card: nil), nil)
        }
    }
}
#endif
