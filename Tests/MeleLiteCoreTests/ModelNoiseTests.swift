import Testing
@testable import MeleLiteCore

@Suite struct ModelNoiseTests {
    @Test func stripsSafetyBlock() {
        let raw = "<ds_safety>[用户未成年]否 [分类]其他 [判定]日常闲聊。 [规则]无</ds_safety>  那口汤记我名下。\n\n小满，吃完把碗放那儿。"
        #expect(ModelNoise.strip(raw) == "那口汤记我名下。\n\n小满，吃完把碗放那儿。")
    }
    @Test func stripsUnclosedTagLine() {
        #expect(ModelNoise.strip("<ds_safety>[分类]其他\n好啊") == "好啊")
    }
    @Test func leavesNormalTextAlone() {
        #expect(ModelNoise.strip("  就一句话 <b>不是</b>") == "  就一句话 <b>不是</b>")
    }
}
