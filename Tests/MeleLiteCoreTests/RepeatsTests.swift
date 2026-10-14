import Foundation
import Testing
@testable import MeleLiteCore

/// 重复（10-13 内测「一上午都是汤」）。测试数据用小满。
@Suite struct RepeatsTests {
    @Test func similarityTellsRewordedRepeatsApart() {
        #expect(Repeats.similarity("等天擦黑，河边灯一亮，我们再去走走。不急着起。", "等天擦黑，河边灯亮了再出去走，不赶。") > 0.75)
        #expect(Repeats.similarity("汤见底了，回来听你讲完剩下的半截。", "这汤见底了，辣油还烧嗓子。我回家，你在家等我。") > 0.3)
        #expect(Repeats.similarity("小满今天吃了橘子", "明天要去考数学") < 0.3)
        #expect(Repeats.similarity("I love you so much", "I love tea") < 0.75)
        #expect(Repeats.similarity("Sleep well, see you tomorrow.", "sleep well — see you tomorrow") == 1)
        #expect(Repeats.similarity("好", "好") == 1)
    }

    @Test func samplesAreDistinctAndSpreadOut() {
        let lines = ["想听。你讲，我汤正喝到最后一口，热着。",
                     "那我回来。汤见底了，回来听你讲完剩下的半截。",
                     "小满你昨天说的那本书我翻了两页，写得慢但好看。",
                     "这汤见底了，辣油还烧嗓子。我回家，你在家等我。",
                     "嗯。",
                     "你考完数学记得吃饭，别又忘了。",
                     "汤还热着，你讲你的。"]
        let picked = Repeats.pickSamples(lines, max: 6)
        #expect(!picked.contains("嗯。"))                                           // 太短
        #expect(!picked.contains("汤还热着，你讲你的。"))                              // 跟第一句长得像，只留一句
        #expect(picked.contains("小满你昨天说的那本书我翻了两页，写得慢但好看。") && picked.contains("你考完数学记得吃饭，别又忘了。"))
        let many = ["小满今天吃了橘子，酸得眯眼", "明天要去考数学，复习到几点", "楼下猫又来蹭饭了", "下雨了，记得带伞出门",
                    "昨晚那部电影结尾我没看懂", "耳机左边不响了，得修", "咖啡续了第三杯，手在抖", "周末想去爬山看日出",
                    "新买的书到了，封面是蓝的", "妈妈打电话问我吃没吃饭", "地铁堵在隧道里十分钟", "晚饭想吃番茄炒蛋"]
        let spread = Repeats.pickSamples(many, max: 6)
        #expect(spread.count == 6 && spread.first == many[0] && spread.last == many[11])   // 从头到尾散着取，不只取最后几句
    }

    @Test func repeatedBubblesAreDroppedButSomethingAlwaysRemains() {
        let recent = ["还躺着就再赖五分钟，我给你倒杯温的放床头。", "等天擦黑，河边灯一亮，我们再去走走。不急着起。"]
        let reply = ["先别起来，醒了会晕，坐床边缓一缓。", "等天擦黑，河边灯亮了再出去走，不赶。"]
        #expect(Repeats.dropRepeated(reply, recent: recent) == ["先别起来，醒了会晕，坐床边缓一缓。"])
        #expect(Repeats.dropRepeated(["等天擦黑，河边灯一亮，我们再去走走。不急着起。"], recent: recent) == ["等天擦黑，河边灯一亮，我们再去走走。不急着起。"])
        #expect(Repeats.dropRepeated(["好", "嗯"], recent: ["好"]) == ["嗯"])
    }

    @Test func echoesInsideOneReplyAreDropped() {
        // 调工具前说了一遍、工具回来换几个字又说一遍
        let reply = ["小满我到楼下了！\n\n伞挂在门把上了 还有你爱吃的烤红薯 趁热吃！",
                     "那我先回去啦 明天见",
                     "小满我到楼下了！\n\n伞挂门把上了 还有你爱吃的热烤红薯 趁热吃！",
                     "你拿到红薯了吗 记得趁热"]
        #expect(Repeats.dropEchoes(reply) == [reply[0], reply[1], reply[3]])
        #expect(Repeats.dropEchoes(["好", "嗯", "好"]) == ["好", "嗯"])
        #expect(Repeats.dropEchoes([]) == [])
    }
}
