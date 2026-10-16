import Foundation
import Testing
@testable import MeleLiteCore

/// MCP「试一下」的报错说人话（10-16）
struct MCPExplainTests {
    @Test func reasons() {
        #expect(MCPExplain.text(MCPError.unauthorized, url: "http://localhost:8765/mcp").hasPrefix("钥匙不对"))
        #expect(MCPExplain.text(MCPError.timeout, url: "http://localhost:8765/mcp").contains("这台手机"))
        #expect(MCPExplain.text(MCPError.timeout, url: "http://127.0.0.1:8765/mcp", inHost: true).contains("172.17.0.1"))
        #expect(MCPExplain.text(MCPError.http(404), url: "https://mem.example/").contains("/mcp"))
        #expect(MCPExplain.text(MCPError.timeout, url: "https://mem.example/mcp").contains("防火墙"))
        #expect(MCPExplain.text(URLError(.cannotConnectToHost), url: "https://mem.example/mcp").hasPrefix("连不上这个地址"))
    }
}
