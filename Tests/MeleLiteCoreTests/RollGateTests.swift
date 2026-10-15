import Foundation
import Testing
@testable import MeleLiteCore

/// 卷账本的门（10-15 内测：固定部分自己就超过记性长度，每轮都卷两句、怎么卷都降不下来）。测试数据用小满。
@Suite struct RollGateTests {
    @Test func estimatesLikeHost() {
        #expect(RollGate.estimateTokens(["你好世界"]) == 4)
        #expect((2...4).contains(RollGate.estimateTokens(["hello world"])))
    }

    @Test func twoOldLinesAreNotWorthARoll() {
        let two = ["小满说今天好热", "那去游泳吧"]                                    // 每轮新挤出去的就这两句
        #expect(!RollGate.worthRolling(two, highWater: 30_000))
        #expect(!RollGate.worthRolling([], highWater: 1))
        let batch = Array(repeating: String(repeating: "小满", count: 50), count: 80)   // 8000 字 ≥ 3 万的四分之一
        #expect(RollGate.worthRolling(batch, highWater: 30_000))
        #expect(RollGate.worthRolling(two, highWater: 1))                            // 记性长度调到很小：照旧卷
    }

    @Test func fixedShareSplitsTheReportedTotal() {
        let fixed = [String(repeating: "设", count: 45_000)], history = [String(repeating: "话", count: 5_000)]
        #expect(RollGate.fixedTokens(total: 50_000, fixed: fixed, history: history) == 45_000)
        #expect(RollGate.fixedTokens(total: 100, fixed: [], history: []) == 0)
    }
}
