import Foundation

/// 卷账本的门（10-15 内测：搬家过来「开头每轮都 5 万 token，一直在打包」）。
/// 水位看的是这一轮整份喂了多少，可回声只能卷聊天记录——人设、说明书、记忆、账本这些固定的部分自己就超过记性长度时，
/// 卷完还是「满了」，原来每轮都去卷最老的两句、每轮多一次写账。现在要卷的攒够记性长度的四分之一再卷（跟 Host ledger.worth_rolling 同一条线）。
public enum RollGate {
    public static let minShare = 0.25

    /// 粗估 token：中日韩一个字算一个，别的约 3 个字符一个（跟 Host 的 estimate_tokens 一样，宁可估高）
    public static func estimateTokens(_ parts: [String]) -> Int {
        parts.reduce(0) { sum, text in
            let scalars = text.unicodeScalars
            let wide = scalars.filter { $0.value >= 0x2E80 }.count
            return sum + wide + (scalars.count - wide + 2) / 3
        }
    }

    /// 要卷掉的那些（留下尾巴之后）够不够一批
    public static func worthRolling(_ rolled: [String], highWater: Int) -> Bool {
        !rolled.isEmpty && Double(estimateTokens(rolled)) >= minShare * Double(highWater)
    }

    /// 这一轮里卷不掉的那部分（system + 每轮垫的 context）大约多少 token：按估出来的比例分上一轮实际的总数
    public static func fixedTokens(total: Int, fixed: [String], history: [String]) -> Int {
        let f = estimateTokens(fixed), h = estimateTokens(history)
        guard f + h > 0 else { return 0 }
        return Int((Double(total) * Double(f) / Double(f + h)).rounded())
    }
}
