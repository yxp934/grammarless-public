import Foundation
import NaturalLanguage

public enum LanguageRouter {
    public static func detectLanguage(for text: String) -> DetectedLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .en }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)

        let hasHan = trimmed.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
        let hasLatin = trimmed.range(of: "[A-Za-z]", options: .regularExpression) != nil

        if hasHan && hasLatin { return .mixed }
        if let top = hypotheses.max(by: { $0.value < $1.value })?.key {
            switch top {
            case .simplifiedChinese, .traditionalChinese:
                return hasLatin ? .mixed : .zh
            case .english:
                return hasHan ? .mixed : .en
            default:
                break
            }
        }
        if hasHan { return .zh }
        return .en
    }
}
