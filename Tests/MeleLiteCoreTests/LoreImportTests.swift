import Foundation
import Testing
@testable import MeleLiteCore

/// 世界书导入（10-11）：酒馆世界书 JSON、character_book、整张卡、txt。测试用小满。
@Suite struct LoreImportTests {
    func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    @Test func tavernWorldInfo() throws {
        let wi: [String: Any] = ["entries": [
            "1": ["key": ["雾港"], "keysecondary": ["港口"], "content": "{{char}} 住在雾港", "comment": "雾港", "disable": true],
            "0": ["key": ["灯塔"], "content": "灯塔在北边", "comment": "灯塔", "constant": true],
            "2": ["key": ["a"], "content": "关键词太短"],
        ]]
        let (es, skipped) = try LoreImport.parse(json(wi), fileName: "w.json", charName: "林晚", userName: "小满", lang: .zh)
        #expect(es.map(\.title) == ["灯塔", "雾港"])                 // 按序号排
        #expect(es[0].constant && es[0].enabled)
        #expect(es[1].keys == ["雾港", "港口"] && !es[1].enabled && es[1].content == "林晚 住在雾港")
        #expect(skipped == 1)
    }

    @Test func characterBookAndCard() throws {
        let book: [String: Any] = ["entries": [["keys": ["画室"], "content": "画室在三楼", "comment": "画室"]]]
        #expect(try LoreImport.parse(json(book), fileName: "b.json", charName: "", userName: "", lang: .zh).entries.count == 1)
        let card: [String: Any] = ["spec": "chara_card_v2", "data": ["name": "林晚", "character_book": book]]
        #expect(try LoreImport.parse(json(card), fileName: "c.json", charName: "", userName: "", lang: .zh).entries.first?.keys == ["画室"])
        #expect(throws: CardError.self) { try LoreImport.parse(json(["name": "x"]), fileName: "x.json", charName: "", userName: "", lang: .zh) }
    }

    @Test func textBlankLines() throws {
        let txt = """
        # 雾港
        关键词：雾港、港口
        常年起雾的港口城市。
        小满小时候在这里长大。

        灯塔
        北边的旧灯塔，晚上会亮。

        暗号：说「今天月亮很圆」就是想你了

        这一段只有一句很长很长很长很长很长很长很长很长的话，没有冒号能拆
        """
        let (es, skipped) = try LoreImport.parse(Data(txt.utf8), fileName: "w.txt", charName: "", userName: "", lang: .zh)
        #expect(es.map(\.title) == ["雾港", "灯塔", "暗号"])
        #expect(es[0].keys == ["雾港", "港口"] && es[0].content == "常年起雾的港口城市。\n小满小时候在这里长大。")
        #expect(es[1].keys == ["灯塔"])
        #expect(es[2].content == "说「今天月亮很圆」就是想你了")
        #expect(skipped == 1)
    }

    @Test func textRules() throws {
        let txt = "雾港\n第一段\n\n还是雾港这条\n---\n灯塔\nkeys: lighthouse, 灯塔\n北边"
        let es = try LoreImport.parse(Data(txt.utf8), fileName: "w.txt", charName: "", userName: "", lang: .zh).entries
        #expect(es.count == 2)
        #expect(es[0].content == "第一段\n还是雾港这条")
        #expect(es[1].keys == ["lighthouse", "灯塔"])
    }

    @Test func gbkText() throws {
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = "灯塔\n北边的旧灯塔".data(using: String.Encoding(rawValue: gb))!
        #expect(String(data: data, encoding: .utf8) == nil)
        #expect(try LoreImport.parse(data, fileName: "w.txt", charName: "", userName: "", lang: .zh).entries.first?.content == "北边的旧灯塔")
    }
}
