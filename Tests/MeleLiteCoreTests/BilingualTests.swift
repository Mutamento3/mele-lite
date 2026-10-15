import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct BilingualTests {
    @Test func splitSelf() {
        let (o, t) = Bilingual.splitSelf(["...Right.\n〔译〕……对。", "Keegan?\n[译]: 基根？", "Plain"])
        #expect(o == ["...Right.", "Keegan?", "Plain"])
        #expect(t == ["……对。", "基根？", nil])
        let (o2, t2) = Bilingual.splitSelf(["What?", "〔译〕什么？"])
        #expect(o2 == ["What?"] && t2 == ["什么？"])
    }
    @Test func parseList() {
        #expect(Bilingual.parseList("```json\n[\"对。\", \"基根？\"]\n```", count: 2) == ["对。", "基根？"])
        #expect(Bilingual.parseList("[\"一句\"]", count: 2) == [nil, nil])
        #expect(Bilingual.parseList("不是", count: 1) == [nil])
    }
    @Test func userSide() {
        #expect(Bilingual.userSide("你知道吗？", ["Did you know?"]) == "Did you know?")
        #expect(Bilingual.userSide("你知道吗？", nil) == "你知道吗？")
        #expect(Bilingual.userSide("你知道吗？", [NSNull()]) == "你知道吗？")
    }
    @Test func rule() {
        #expect(Bilingual.rule(zh: true, speaks: "English", to: "中文", selfWrites: true).contains("〔译〕"))
        #expect(!Bilingual.rule(zh: true, speaks: "English", to: "中文", selfWrites: false).contains("〔译〕"))
    }
}
