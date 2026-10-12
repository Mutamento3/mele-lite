import Foundation

/// 旧式 SSE 接法（MCP 2024-11-05，10-12 内测：网易云那类 MCP 还是这种，地址以 /sse 结尾）。
/// 先 GET 地址开一条一直不断的流，对面第一件事发 `event: endpoint` 告诉往哪 POST；
/// 之后每条 JSON-RPC 都 POST 到那里。回话有两种：照规矩从流里回来（POST 只回 202），
/// 或者有的服务器图省事直接回在 POST 的响应里——两种都收。
actor MCPLegacySSE {
    let sseURL: URL
    let token: String?
    let session: URLSession

    private(set) var endpoint: URL?
    private(set) var dead = false
    private var reader: Task<Void, Never>?
    private var endpointWaiters: [Int: CheckedContinuation<URL, Error>] = [:]
    private var waiters: [Int: CheckedContinuation<Data, Error>] = [:]
    private var inbox: [Int: Data] = [:]
    private var ticket = 0

    init(sseURL: URL, token: String?, session: URLSession) {
        self.sseURL = sseURL; self.token = token; self.session = session
    }

    deinit { reader?.cancel() }

    func close() {
        reader?.cancel()
        finish(MCPError.badReply)
    }

    /// 开流、等 endpoint
    func open(timeout: TimeInterval) async throws -> URL {
        if let endpoint { return endpoint }
        if dead { throw MCPError.badReply }
        if reader == nil { start() }
        ticket += 1
        let t = ticket
        return try await withCheckedThrowingContinuation { c in
            endpointWaiters[t] = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expireEndpoint(t)
            }
        }
    }

    /// 等流里 id 对得上的那条回话（Data = 一条 JSON-RPC 消息）
    func wait(_ id: Int, timeout: TimeInterval) async throws -> Data {
        if let got = inbox.removeValue(forKey: id) { return got }
        if dead { throw MCPError.badReply }
        return try await withCheckedThrowingContinuation { c in
            waiters[id] = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id)
            }
        }
    }

    /// 回话已经在 POST 响应里拿到了：流里要是再来一份就不要了
    func drop(_ id: Int) { inbox[id] = nil }

    // MARK: - 读流

    private func start() {
        var req = URLRequest(url: sseURL, timeoutInterval: 300)      // 空闲超时：对面一般 15～30 秒发一次 keepalive
        req.httpMethod = "GET"
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let session = session
        reader = Task { [weak self] in
            do {
                let (bytes, resp) = try await session.bytes(for: req)
                guard let http = resp as? HTTPURLResponse else { throw MCPError.badReply }
                if http.statusCode == 401 || http.statusCode == 403 { throw MCPError.unauthorized }
                guard (200..<300).contains(http.statusCode) else { throw MCPError.http(http.statusCode) }
                // bytes.lines 不给空行，所以不靠空行分事件：endpoint 一行就收，消息的 data 拼到能解析成 JSON 为止
                var event = "message", data = ""
                for try await line in bytes.lines {
                    if line.hasPrefix(":") { continue }                              // keepalive 注释
                    if line.hasPrefix("event:") {
                        event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); data = ""
                        continue
                    }
                    guard line.hasPrefix("data:") else { continue }
                    var piece = Substring(line.dropFirst(5))
                    if piece.hasPrefix(" ") { piece = piece.dropFirst() }
                    data += (data.isEmpty ? "" : "\n") + piece
                    if event == "endpoint" {
                        await self?.gotEndpoint(data.trimmingCharacters(in: .whitespaces))
                        event = "message"; data = ""
                    } else if let one = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] {
                        if let id = one["id"] as? Int { await self?.deliver(id, Data(data.utf8)) }
                        event = "message"; data = ""
                    }
                }
                await self?.finish(MCPError.badReply)
            } catch let e as URLError where e.code == .timedOut {
                await self?.finish(MCPError.timeout)
            } catch let e as MCPError {
                await self?.finish(e)
            } catch {
                await self?.finish(MCPError.badReply)
            }
        }
    }

    private func gotEndpoint(_ raw: String) {
        guard endpoint == nil, let u = URL(string: raw, relativeTo: sseURL)?.absoluteURL else { return }
        endpoint = u
        for c in endpointWaiters.values { c.resume(returning: u) }
        endpointWaiters = [:]
    }

    private func deliver(_ id: Int, _ data: Data) {
        if let c = waiters.removeValue(forKey: id) { c.resume(returning: data) } else { inbox[id] = data }
    }

    private func expireEndpoint(_ t: Int) {
        endpointWaiters.removeValue(forKey: t)?.resume(throwing: MCPError.timeout)
    }

    private func expire(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: MCPError.timeout)
    }

    private func finish(_ error: MCPError) {
        dead = true
        for c in endpointWaiters.values { c.resume(throwing: error) }
        for c in waiters.values { c.resume(throwing: error) }
        endpointWaiters = [:]; waiters = [:]
    }
}
