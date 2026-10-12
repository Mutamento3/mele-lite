import Testing
@testable import MeleLiteCore

@Suite struct MemoryDedupeTests {
    let c = [MemoryDedupe.Candidate(id: 12, content: "小满下周三有数学考试"), MemoryDedupe.Candidate(id: 30, content: "小满对芒果过敏")]

    @Test func parsesOnlyCandidateIDs() {
        #expect(MemoryDedupe.parse("12", candidates: c) == 12)
        #expect(MemoryDedupe.parse(" #30\n", candidates: c) == 30)
        #expect(MemoryDedupe.parse("是 #12", candidates: c) == 12)
        #expect(MemoryDedupe.parse("none", candidates: c) == nil)
        #expect(MemoryDedupe.parse("None.", candidates: c) == nil)
        #expect(MemoryDedupe.parse("都不是", candidates: c) == nil)
        #expect(MemoryDedupe.parse("99", candidates: c) == nil)          // 不是候选里的：不信
        #expect(MemoryDedupe.parse("", candidates: c) == nil)
    }

    @Test func promptListsCandidates() {
        let p = MemoryDedupe.prompt(new: "小满下周三要考数学，有点紧张", candidates: c, zh: true)
        #expect(p.contains("#12 小满下周三有数学考试") && p.contains("#30 小满对芒果过敏") && p.contains("none"))
        #expect(MemoryDedupe.prompt(new: "x", candidates: c, zh: false).contains("reply only none"))
    }
}
