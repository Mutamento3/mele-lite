import Foundation
import Testing
@testable import MeleLiteCore

@Suite struct GroupChatTests {
    let ju = GroupChat.Member(id: "a", name: "阿橘")
    let man = GroupChat.Member(id: "b", name: "小满")
    let manman = GroupChat.Member(id: "c", name: "小满满")

    @Test func mentionsInOrderOfAppearance() {
        #expect(GroupChat.mentioned(in: "@小满 你说呢 @阿橘", members: [ju, man]) == ["b", "a"])
        #expect(GroupChat.mentioned(in: "没有人被点名", members: [ju, man]).isEmpty)
        #expect(GroupChat.mentioned(in: "@阿橘 @阿橘", members: [ju, man]) == ["a"])
    }
    @Test func longerNameWins() {
        #expect(GroupChat.mentioned(in: "@小满满 来", members: [man, manman]) == ["c"])
        #expect(GroupChat.mentioned(in: "@小满满 和 @小满", members: [man, manman]) == ["c", "b"])
    }
    @Test func mentionedGoFirstOthersShuffled() {
        let q = GroupChat.order(mentioned: ["b"], wanting: ["a", "b", "c"], shuffle: { $0.reversed() })
        #expect(q == ["b", "c", "a"])
        #expect(GroupChat.order(mentioned: [], wanting: ["a", "c"], shuffle: { $0 }) == ["a", "c"])
        #expect(GroupChat.order(mentioned: ["c"], wanting: [], shuffle: { $0 }) == ["c"])
    }
    @Test func parsesJudgeReplies() {
        #expect(GroupChat.wantsToSpeak("说"))
        #expect(GroupChat.wantsToSpeak(" 说。\n"))
        #expect(!GroupChat.wantsToSpeak("过"))
        #expect(!GroupChat.wantsToSpeak("嗯……过吧"))
        #expect(GroupChat.wantsToSpeak("Speak"))
        #expect(!GroupChat.wantsToSpeak("pass"))
        #expect(!GroupChat.wantsToSpeak(""))
        #expect(!GroupChat.wantsToSpeak("???"))
    }
    @Test func judgePromptHasNoNegativeOptOut() {
        let p = GroupChat.judgePrompt(zh: true, me: "阿橘", persona: "嘴硬心软的猫", group: "三人行", userName: "她",
                                      others: ["小满"], recent: [("她", "今天吃什么"), ("小满", "火锅！")])
        let all = p.system + p.user
        #expect(all.contains("阿橘") && all.contains("三人行") && all.contains("〔小满〕火锅！"))
        #expect(!all.contains("不想") && !all.contains("不说"))
        let en = GroupChat.judgePrompt(zh: false, me: "Ju", persona: "", group: "Trio", userName: "her", others: ["Man"], recent: [])
        #expect(en.user.contains("speak") && en.user.contains("pass"))
    }
    @Test func roomRulesNameEveryone() {
        let r = GroupChat.roomRules(zh: true, group: "三人行", me: "阿橘", userName: "她", others: ["小满"])
        #expect(r.contains("三人行") && r.contains("小满") && r.contains("她") && r.contains("〔"))
        #expect(r.contains("群聊里") && r.contains("留在私聊里"))
    }
    @Test func stripsOwnLabel() {
        #expect(GroupChat.stripOwnLabel("〔阿橘〕好啊", name: "阿橘") == "好啊")
        #expect(GroupChat.stripOwnLabel("阿橘：好啊", name: "阿橘") == "好啊")
        #expect(GroupChat.stripOwnLabel("阿橘: 好啊", name: "阿橘") == "好啊")
        #expect(GroupChat.stripOwnLabel("阿橘觉得好", name: "阿橘") == "阿橘觉得好")
        #expect(GroupChat.stripOwnLabel("〔小满〕好啊", name: "阿橘") == "〔小满〕好啊")
    }
}
