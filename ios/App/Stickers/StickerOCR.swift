import UIKit
import Vision

/// 图上的字（10-13 内测：表情包描述一直「还在写」——TA 的模型不会看图，DeepSeek 发图过去直接报错）：
/// 手机自带的文字识别，离线、不花钱。认出来的字当描述，像「亲密度↑」这种表情包直接就能用；没字返回 nil
enum StickerOCR {
    static func text(in data: Data) -> String? {
        guard let img = UIImage(data: data), let cg = img.cgImage else { return nil }
        // 中日文一套、英文一套各认一遍，取更有把握的那次（混着给时英文会认成「llove yoU」）
        guard let best = [["zh-Hans", "zh-Hant", "ja"], ["en-US"]].map({ pass(cg, $0) }).max(by: { $0.score < $1.score }) else { return nil }
        // 只有一个字母 / 全是符号的多半是把线条花纹认成字了：汉字一个就算，字母要两个
        let letters = best.text.filter(\.isLetter)
        guard !letters.isEmpty, letters.count >= 2 || letters.contains(where: { !$0.isASCII }) else { return nil }
        return String(best.text.prefix(60))
    }

    private static func pass(_ cg: CGImage, _ langs: [String]) -> (text: String, score: Float) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = langs
        req.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])) != nil else { return ("", 0) }
        let cands = (req.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.3 }
        let lines = cands.map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (lines.joined(separator: " "), cands.map(\.confidence).reduce(0, +))
    }
}
