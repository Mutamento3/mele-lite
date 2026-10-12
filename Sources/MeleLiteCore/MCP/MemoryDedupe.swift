import Foundation

/// 记新记忆前判断「是不是跟旧的哪条是同一件事」（10-12 内测：同一件事换个说法就并不上）。
/// 字面重合和本机向量都分不清——「下周三考数学 / 下周三考英语」两样都比「换了语序的同一件事」还像，
/// 所以先粗筛出几条候选，再问一句模型。模型回编号就并进那条，回 none 照常新存。
public enum MemoryDedupe {
    public struct Candidate: Equatable, Sendable {
        public var id: Int
        public var content: String
        public init(id: Int, content: String) { self.id = id; self.content = content }
    }

    public static func prompt(new: String, candidates: [Candidate], zh: Bool) -> String {
        let list = candidates.map { "#\($0.id) \($0.content.prefix(200))" }.joined(separator: "\n")
        return zh
            ? """
              要记一条新记忆。看看它跟下面哪条旧记忆说的是同一件事（同一个事实、同一件事，只是说法、语序不同，或者是那条的更新、补充）。

              新记忆：\(new.prefix(400))

              旧记忆：
              \(list)

              只是话题像不算：科目、日子、人、东西、做的事不一样，就是不同的事。
              是同一件事就只回那条的编号（比如 12），都不是就只回 none。不要解释。
              """
            : """
              A new memory is about to be saved. Is it the same thing as one of the existing memories below \
              (same fact or event, just worded differently, or an update/addition to it)?

              New: \(new.prefix(400))

              Existing:
              \(list)

              Merely related topics don't count: a different subject, day, person, object or action makes it a different thing.
              If it's the same thing, reply with only that memory's number (e.g. 12). Otherwise reply only none.
              """
    }

    /// 模型的回话 → 编号（必须是候选里的）；none / 看不懂 → nil
    public static func parse(_ reply: String, candidates: [Candidate]) -> Int? {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty || t.hasPrefix("none") || t.hasPrefix("无") || t.hasPrefix("都不") { return nil }
        guard let r = t.range(of: #"\d+"#, options: .regularExpression), let id = Int(t[r]) else { return nil }
        return candidates.contains { $0.id == id } ? id : nil
    }
}
