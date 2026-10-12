import Foundation
import Testing
@testable import MeleLiteCore

/// 旧式 SSE 接法（10-12）。连真服务器的那条平时跳过：MCP_E2E_SSE=地址1,地址2 swift test --filter MCPLegacySSETests
@Suite struct MCPLegacySSETests {
    @Test func picksLegacyFromTheAddress() async {
        #expect(await MCPClient(url: URL(string: "https://x.example/sse")!, token: nil).legacy)
        #expect(await MCPClient(url: URL(string: "https://x.example/SSE/")!, token: nil).legacy)
        #expect(await !MCPClient(url: URL(string: "https://x.example/mcp")!, token: nil).legacy)
    }

    static let live = ProcessInfo.processInfo.environment["MCP_E2E_SSE"]?
        .split(separator: ",").compactMap { URL(string: String($0)) } ?? []

    @Test(.enabled(if: !live.isEmpty)) func talksToRealServers() async throws {
        for url in Self.live {
            let c = MCPClient(url: url, token: nil)
            let tools = try await c.listTools()
            #expect(!tools.isEmpty, "\(url)")
            let again = try await c.listTools()                  // 同一条流上再问一次
            #expect(again == tools)
            if let echo = tools.first(where: { $0.name == "echo" }) {
                let r = try await c.call(echo.name, argumentsJSON: #"{"text":"在呢"}"#)
                #expect(r.text == "echo: 在呢")
            }
            if tools.contains(where: { $0.name == "list_playlists" }) {
                let r = try await c.call("list_playlists", argumentsJSON: "{}")
                #expect(!r.isError)
            }
        }
    }
}
