import Testing
@testable import MeleLiteCore

@Suite struct InnerVoiceTests {
    @Test func splitsTheLastBlock() {
        let (b, v) = InnerVoice.split("来，下地。\n\n[心声]\n她喊得又急又霸道。\n我心里软得不行。\n[/心声]")
        #expect(b == "来，下地。" && v == "她喊得又急又霸道。\n我心里软得不行。")
    }
    @Test func toleratesSloppyEndsAndMissingEnd() {
        #expect(InnerVoice.split("好。[心声]有点高兴[心声 完]").voice == "有点高兴")
        #expect(InnerVoice.split("好。[心声]有点高兴[心声/]").voice == "有点高兴")
        #expect(InnerVoice.split("好。\n[心声]没收尾也算").voice == "没收尾也算")
        #expect(InnerVoice.split("ok.\n[Inner Voice] she's cute [/inner voice]") == (body: "ok.", voice: "she's cute"))
    }
    @Test func keepsOnlyTheLastAndCleansBody() {
        let (b, v) = InnerVoice.split("前面[心声]第一段[/心声]中间\n[心声]第二段[/心声]")
        #expect(b == "前面中间" && v == "第二段")
    }
    @Test func noBlockLeavesTextAlone() {
        #expect(InnerVoice.split("就一句话") == (body: "就一句话", voice: ""))
    }
    @Test func promptPieces() {
        let r = InnerVoice.rules(zh: true, pronoun: "她", style: "")
        #expect(r.contains("[心声]") && r.contains("[/心声]") && r.contains("她一直是「她」"))
        let own = InnerVoice.rules(zh: true, pronoun: "她", style: "只写一句。")
        #expect(own.contains("只写一句。") && !own.contains("口是心非"))
        #expect(InnerVoice.hook(zh: true, pronoun: "她").hasPrefix("〔心声〕"))
        #expect(InnerVoice.contextLine("有点高兴", zh: true) == "（当时心里：有点高兴）")
        #expect(InnerVoice.contextLine("glad", zh: false) == "(What I felt then: glad)")
    }
}
