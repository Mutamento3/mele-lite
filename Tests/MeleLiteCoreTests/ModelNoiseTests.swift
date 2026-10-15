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

@Suite struct TextToolCallTests {
    // 10-15 内测截图原样：</args_json> 写漏了
    @Test func screenshotCase() {
        let raw = "<function_calls>\n<invoke name=\"memory_recall\">\n<args_json>{\"text\": \"老公老公老公！！！ 我来啦 感觉怎么样！ \", \"level\": \"medium\"}</invoke>\n</function_calls>"
        let (calls, rest) = ModelNoise.textToolCalls(raw)
        #expect(rest == "")
        #expect(calls.count == 1)
        #expect(calls[0].name == "memory_recall")
        let args = ToolCall(id: "x", name: calls[0].name, argumentsJSON: calls[0].argumentsJSON).arguments
        #expect(args["level"] as? String == "medium")
        #expect((args["text"] as? String)?.hasPrefix("老公") == true)
        #expect(ModelNoise.strip(raw) == "")
    }
    @Test func keepsWordsAroundAndReadsParameters() {
        let raw = "等我翻翻。\n<invoke name=\"memory_recall\"><parameter name=\"text\">汤</parameter><parameter name=\"limit\">3</parameter></invoke>"
        let (calls, rest) = ModelNoise.textToolCalls(raw)
        #expect(rest == "等我翻翻。")
        let args = ToolCall(id: "x", name: calls[0].name, argumentsJSON: calls[0].argumentsJSON).arguments
        #expect(args["text"] as? String == "汤")
        #expect(args["limit"] as? Int == 3)
    }
    @Test func hermesStyleAndUnclosed() {
        let (calls, rest) = ModelNoise.textToolCalls("好\n<tool_call>{\"name\": \"remember\", \"arguments\": {\"content\": \"喜欢秋天\"}}</tool_call>")
        #expect(rest == "好")
        #expect(calls == [ModelNoise.TextCall(name: "remember", argumentsJSON: "{\"content\":\"喜欢秋天\"}")])
        #expect(ModelNoise.textToolCalls("嗯<function_calls><invoke name=\"a\">").rest == "嗯")
    }
    @Test func normalTextUntouched() {
        let s = "a < b，<b>粗</b>"
        #expect(ModelNoise.textToolCalls(s).rest == s)
        #expect(ModelNoise.textToolCalls(s).calls.isEmpty)
    }
}
