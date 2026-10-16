import Foundation

/// 「试一下」没通时说清楚为什么（10-16 内测：只说「连不上」，其实是地址填了 localhost）。
/// 跟 Host 的 brain/mcp.explain 同一套话；inHost = 连的是 Mele Host（在 Docker 里），否则是这台手机
public enum MCPExplain {
    static let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

    public static func text(_ error: Error, url: String, inHost: Bool = false) -> String {
        if let e = error as? MCPError, e == .unauthorized {
            return String(localized: "钥匙不对")
        }
        if loopback.contains((URL(string: url)?.host ?? "").lowercased()) {
            return inHost
                ? String(localized: "Host 跑在 Docker 里，地址里的 localhost / 127.0.0.1 指的是 Host 自己，不是你的服务器。记忆库跟 Host 在同一台服务器上的话：记忆库那边 .env 加一行 MELE_MEMORY_BIND=172.17.0.1，在记忆库目录 docker compose up -d 重启它，这里地址填 http://172.17.0.1:8765/mcp。记忆库在别的机器上，就填那台机器的地址")
                : String(localized: "地址里的 localhost / 127.0.0.1 指的是这台手机自己。记忆库装在电脑或服务器上的话，填那台机器的地址：同一个 Wi-Fi 下填电脑的局域网 IP，服务器填它的域名")
        }
        switch error {
        case MCPError.timeout: return String(localized: "等了很久没回：地址打得开吗？服务器的防火墙放行这个端口没有")
        case MCPError.http(let code) where code == 404 || code == 405:
            return String(localized: "地址通了，但那里不是 MCP：结尾一般是 /mcp（老式的是 /sse）")
        case MCPError.http(let code): return String(localized: "对方回了 \(code)，服务那边出了问题，看看它的日志")
        case MCPError.rpc(_, let m): return String(localized: "连上了但对不上话（\(String(m.prefix(80)))）：确认填的是 MCP 地址，不是网页地址")
        case MCPError.badReply: return String(localized: "连上了但对不上话：确认填的是 MCP 地址，不是网页地址")
        default:
            let why = (error as? URLError).map { $0.localizedDescription } ?? String(describing: error)
            return String(localized: "连不上这个地址（\(String(why.prefix(80)))）：看看地址、端口对不对，服务开着没")
        }
    }
}
