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
}
