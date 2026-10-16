import Foundation
import Testing
@testable import MeleLiteCore

/// 看图 / 画图钥匙直接填（10-16）
struct MediaDirectTests {
    @Test func verdict() {
        #expect(!MediaDirect.verdict(code: 401, ids: [], model: "x", slot: "draw").ok)
        #expect(MediaDirect.verdict(code: 404, ids: [], model: "x", slot: "draw").ok)          // 不给看列表：存下
        #expect(MediaDirect.verdict(code: 200, ids: ["gpt-4.1-mini"], model: "gpt-4.1-mini", slot: "vision").ok)
        let miss = MediaDirect.verdict(code: 200, ids: ["gemini-2.5-flash", "gpt-image-1-mini", "nano-banana"], model: "gpt-image-1", slot: "draw")
        #expect(!miss.ok && miss.message.contains("gpt-image-1-mini") && miss.message.contains("nano-banana") && !miss.message.contains("gemini-2.5-flash、"))
        #expect(MediaDirect.verdict(code: 200, ids: ["gpt-4.1-mini"], model: "gpt-image-1", slot: "draw").message.contains("没有画图模型"))
        #expect(!MediaDirect.verdict(code: 0, ids: [], model: "x", slot: "vision").ok)
    }

    @Test func imageRefsFromChatReply() {
        let uri = "data:image/png;base64,iVBORw0KGgo="
        #expect(MediaDirect.imageRefs(chatMessage: ["content": "好的 ![img](\(uri))"]) == [uri])
        #expect(MediaDirect.imageRefs(chatMessage: ["images": [["image_url": ["url": uri]]], "content": ""]) == [uri])
        #expect(MediaDirect.imageRefs(chatMessage: ["content": [["type": "image_url", "image_url": ["url": "https://x.example/a.png"]]]]) == ["https://x.example/a.png"])
        #expect(MediaDirect.decodeDataURI(uri) != nil && MediaDirect.decodeDataURI("https://x") == nil)
    }
}
