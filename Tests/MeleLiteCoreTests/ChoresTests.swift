import Testing
@testable import MeleLiteCore

@Suite struct ChoresTests {
    @Test func canByProvider() {
        #expect(Chores.can("elevenlabs") == ["voice"])
        let ds = Set(Chores.can("deepseek"))
        #expect(ds.contains("ledger") && ds.contains("diary") && ds.isDisjoint(with: ["vision", "caption", "draw", "voice"]))
        #expect(Chores.can("anthropic").contains("vision") && !Chores.can("anthropic").contains("draw"))
        #expect(Chores.can("openai-compatible") == Chores.can("gemini"))
    }
    @Test func assignMovesAndClears() throws {
        var (t, moved) = try Chores.assign([:], key: "g", provider: "gemini", chores: ["vision", "draw"])
        #expect(t == ["vision": "g", "draw": "g"] && moved.isEmpty)
        (t, moved) = try Chores.assign(t, key: "o", provider: "openai", chores: ["draw"])
        #expect(t == ["vision": "g", "draw": "o"] && moved == [["chore": "draw", "from_key": "g"]])
        (t, _) = try Chores.assign(t, key: "g", provider: "gemini", chores: [])
        #expect(t == ["draw": "o"])
        #expect(throws: Chores.Cannot.self) { try Chores.assign(t, key: "d", provider: "deepseek", chores: ["vision"]) }
    }
    @Test func migrateFromOldFiles() {
        let m = Chores.migrate(media: ["vision_key": "g", "image_key": "o", "image_model": "gpt-image-1"], echoKey: "d")
        #expect(m.table == ["vision": "g", "draw": "o", "ledger": "d"] && m.drawModel == "gpt-image-1")
        #expect(Chores.migrate(media: [:], echoKey: nil).table.isEmpty)
    }
    @Test func pickNeedsLiveCapableKey() {
        let t = ["vision": "g", "ledger": "gone", "draw": "d"]
        let live = ["g": "gemini", "d": "deepseek"]
        #expect(Chores.pick(t, "vision", live: live) == "g")
        #expect(Chores.pick(t, "ledger", live: live) == nil)
        #expect(Chores.pick(t, "draw", live: live) == nil)
    }
    @Test func groups() {
        #expect(Chores.own == ["diary", "day", "moments", "tarot", "focus"])
        #expect(Chores.odd == ["dedupe", "food", "caption", "import", "music", "translate"])
        #expect(Set(Chores.all) == Chores.own.union(Chores.odd).union(["vision", "draw", "ledger", "voice"]))
    }

    @Test func imageModelAndNotChat() {
        // 10-16 内测：钥匙上填 gpt-image-1 当聊天模型
        #expect(Chores.isImageModel("gpt-image-1") && Chores.isImageModel("dall-e-3") && Chores.isImageModel("gemini-2.5-flash-image"))
        #expect(!Chores.isImageModel("gpt-5.6") && !Chores.isImageModel("gemini-3.5-flash") && !Chores.isImageModel(""))
        #expect(Chores.notChatModelError("HTTP 400 This model is not supported on the Chat Completions endpoint"))
        #expect(!Chores.notChatModelError("HTTP 400 bad request"))
    }

    @Test func wantsDrawing() {
        for t in ["生成一张男大学生自拍照", "画一幅海边", "给我画个头像", "能出图吗", "Draw me a cat", "can you generate an image of a dog"] {
            #expect(Chores.wantsDrawing(t), "\(t)")
        }
        for t in ["画画课好累", "今天拍了张照片", "生个孩子吧", "I drew this yesterday", "你看这张图"] {
            #expect(!Chores.wantsDrawing(t), "\(t)")
        }
    }
}
