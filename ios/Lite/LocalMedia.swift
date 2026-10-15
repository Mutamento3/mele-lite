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
enum LocalMedia {
    static let defaultModels = ["gemini": "gemini-2.5-flash-image", "openai": "gpt-image-1", "openai-compatible": "gpt-image-1"]

    static func settings(_ s: LocalStore) -> [String: Any] { s.read("media.json") as? [String: Any] ?? [:] }

    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
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
        return ["vision_key": Chores.pick(t, "vision", live: live) ?? NSNull(), "image_key": Chores.pick(t, "draw", live: live) ?? NSNull(),
                "image_model": dm, "default_models": defaultModels, "drawn_today": drawnToday(host.store)]
    }

    // MARK: - 看图

    /// 看图用哪把：挑过的那把 → 钥匙串里第一把会看图、同意过的
    static func visionRoute(_ host: LocalHost) -> (ProviderConfig, String)? {
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

    /// 历史里一张图怎么写（模型看不见图时）
    static func photoLine(_ caption: String, zh: Bool) -> String {
        caption.isEmpty ? (zh ? "〔发了一张照片，还没看清是什么〕" : "〔Sent a photo — not described yet〕")
                        : (zh ? "〔发了一张照片：\(caption)〕" : "〔Sent a photo: \(caption)〕")
    }

    // MARK: - 画图

    static func imageRoute(_ host: LocalHost) -> (provider: String, key: String, model: String, base: String?)? {
        let (t, dm) = LocalChores.table(host)
        guard let id = Chores.pick(t, "draw", live: LocalChores.live(host)), let k = host.keys.first(where: { ($0["id"] as? String) == id }),
              let p = k["provider"] as? String, let fallback = defaultModels[p], let secret = host.vault.get(id) else { return nil }
        let model = dm.isEmpty ? fallback : dm
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
                                          : try await openAI(prompt, key: r.key, model: r.model, base: r.base)
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

    static func openAI(_ prompt: String, key: String, model: String, base: String?) async throws -> Data {
        var b = base ?? "https://api.openai.com/v1"
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + "/images/generations") else { throw DrawError.failed("地址不对") }
        let obj = try await post(url, headers: ["Authorization": "Bearer \(key)"],
                                 body: ["model": model, "prompt": prompt, "n": 1, "size": "1024x1024"])
        guard let first = (obj["data"] as? [[String: Any]])?.first else { throw DrawError.failed("没有图") }
        if let b64 = first["b64_json"] as? String, let d = Data(base64Encoded: b64) { return d }
        if let u = (first["url"] as? String).flatMap(URL.init(string:)) {
            let (d, _) = try await URLSession.shared.data(from: u)
            return d
        }
        throw DrawError.failed("没有图")
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
