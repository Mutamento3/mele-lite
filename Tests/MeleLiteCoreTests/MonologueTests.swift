import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct MonologueTests {
    @Test func splitsTaggedMonologue() {
        let (mono, body) = Monologue.split("[独白]她今天好像累了，先别闹她。[/独白]\n\n累了就先躺会儿。")
        #expect(mono == "她今天好像累了，先别闹她。")
        #expect(body == "累了就先躺会儿。")
    }

    @Test func toleratesWonkyClosingTags() {
        for close in ["[独白 完]", "[独白结束]", "[/monologue]", "[end monologue]", "[独白/]"] {
            let (mono, body) = Monologue.split("[独白]想她。\(close)在呢。")
            #expect(mono == "想她。", "\(close)")
            #expect(body == "在呢。", "\(close)")
        }
    }

    @Test func closeOnlyMeansEverythingBeforeIsMonologue() {   // 10-12：开头的 [独白] 漏写了
        let (mono, body) = Monologue.split("她问我今天累不累。\n\n其实有点累，不想让她担心。\n[/独白]\n\n不累，看到你就不累了。\n\n你呢，今天怎么样？")
        #expect(mono == "她问我今天累不累。\n\n其实有点累，不想让她担心。")
        #expect(body == "不累，看到你就不累了。\n\n你呢，今天怎么样？")
        #expect(Monologue.split("想她。[独白 完]在呢。") == (monologue: "想她。", body: "在呢。"))
    }

    @Test func wrapSplitsBackOut() {
        let (mono, body) = Monologue.split(Monologue.wrap("想她。", zh: true) + "\n\n在呢。")
        #expect(mono == "想她。" && body == "在呢。")
    }

    @Test func noTagsMeansAllBody() {
        let (mono, body) = Monologue.split("  就这样。 ")
        #expect(mono.isEmpty)
        #expect(body == "就这样。")
    }

    @Test func unclosedSplitsAtFirstParagraphTalkingToYou() {
        let text = "[独白]她说「你别管我」，可她其实想被管。\n\n先接住她。\n\n你吃饭了没？\n\n我去热牛奶。"
        let (mono, body) = Monologue.split(text)
        #expect(mono == "她说「你别管我」，可她其实想被管。\n\n先接住她。")
        #expect(body == "你吃饭了没？\n\n我去热牛奶。")
    }

    @Test func rulesMentionToolsFirstAndStyle() {
        let r = Monologue.rules(zh: true, pronoun: "她", style: "短一点，像自言自语")
        #expect(r.contains("[独白]") && r.contains("[/独白]"))
        #expect(r.contains("先调工具"))
        #expect(r.contains("短一点，像自言自语"))
        #expect(!Monologue.rules(zh: false, pronoun: "they", style: "").isEmpty)
    }
}

@Suite struct MonologueTwiceTests {
    @Test func duplicatedMonologueDoesNotLeak() {
        let raw = "[独白]\n她走了，去忙。\n[/独白]\n\n[独白]\n她走了，去忙。\n[/独白]\n\n去忙吧。\n\n我在。"
        let (mono, body) = Monologue.split(raw)
        #expect(mono == "她走了，去忙。")
        #expect(body == "去忙吧。\n\n我在。")
    }

    @Test func twoDifferentMonologuesBothKept() {
        let (mono, body) = Monologue.split("[独白]甲[/独白]\n\n[独白]乙[/独白]\n\n好。")
        #expect(mono == "甲\n\n乙")
        #expect(body == "好。")
    }
}

@Suite struct MonologueTagShapes1015 {
    @Test func oddBracketsAndWords() {
        #expect(Monologue.split("【独白】\n她今天累了。\n【/独白】\n早点睡吧你。") == ("她今天累了。", "早点睡吧你。"))
        #expect(Monologue.split("<独白>她在笑</独白>你笑什么") == ("她在笑", "你笑什么"))
        #expect(Monologue.split("[独白开始]\n她回来了。\n[独白结束]\n欢迎回家") == ("她回来了。", "欢迎回家"))
        #expect(Monologue.split("[内心独白]她\n[/内心独白]好") == ("她", "好"))
    }
    @Test func innerVoiceSurvivesUnclosedMonologue() {
        let (_, body) = Monologue.split("[独白]\n她又在撒娇。\n\n嗯，抱一下。\n\n[心声]\n其实想抱很久了。\n[/心声]")
        #expect(InnerVoice.split(body).voice == "其实想抱很久了。")
        let (mono, b2) = Monologue.split("[独白]\n她累了\n[/独白]\n你先睡。\n【心声】舍不得【/心声】")
        #expect(mono == "她累了")
        #expect(InnerVoice.split(b2) == ("你先睡。", "舍不得"))
    }
}
