import Foundation

public struct ParagraphContext {
    public let analysisText: String
    public let analysisRangeInFullText: NSRange
    public let paragraphIdentity: String
}

public enum ParagraphContextExtractor {
    public static func extract(
        from fullText: String,
        selectedRange: NSRange,
        visibleRange: NSRange? = nil
    ) -> ParagraphContext {
        let nsText = fullText as NSString
        guard nsText.length > 0 else {
            return ParagraphContext(
                analysisText: "",
                analysisRangeInFullText: NSRange(location: 0, length: 0),
                paragraphIdentity: "0:0"
            )
        }

        if let visibleContext = visibleContext(from: nsText, visibleRange: visibleRange) {
            return visibleContext
        }

        let safeLocation = min(max(0, selectedRange.location), nsText.length)
        let anchorLocation = safeLocation == nsText.length ? nsText.length - 1 : safeLocation
        let anchor = NSRange(location: anchorLocation, length: 0)
        let paragraphRange = nsText.paragraphRange(for: anchor)
        return context(from: nsText, range: paragraphRange)
    }

    private static func visibleContext(from nsText: NSString, visibleRange: NSRange?) -> ParagraphContext? {
        guard let visibleRange,
              visibleRange.location != NSNotFound,
              visibleRange.location >= 0,
              visibleRange.length > 0,
              NSMaxRange(visibleRange) <= nsText.length
        else {
            return nil
        }

        let startAnchor = min(visibleRange.location, nsText.length - 1)
        let endAnchor = min(max(NSMaxRange(visibleRange) - 1, visibleRange.location), nsText.length - 1)
        let startParagraph = nsText.paragraphRange(for: NSRange(location: startAnchor, length: 0))
        let endParagraph = nsText.paragraphRange(for: NSRange(location: endAnchor, length: 0))
        let expanded = NSUnionRange(startParagraph, endParagraph)
        guard expanded.length > 0, NSMaxRange(expanded) <= nsText.length else { return nil }
        return context(from: nsText, range: expanded)
    }

    private static func context(from nsText: NSString, range: NSRange) -> ParagraphContext {
        let analysisText = nsText.substring(with: range)
        let identity = "\(range.location):\(range.length)"
        return ParagraphContext(
            analysisText: analysisText,
            analysisRangeInFullText: range,
            paragraphIdentity: identity
        )
    }

    public static func mapAnalysisRangeToFullText(
        analysisRange: NSRange,
        analysisRangeInFullText: NSRange
    ) -> NSRange {
        NSRange(
            location: analysisRangeInFullText.location + analysisRange.location,
            length: analysisRange.length
        )
    }

    public static func surroundingContext(
        from fullText: String,
        targetRange: NSRange,
        contextRadius: Int = 220
    ) -> String {
        let nsText = fullText as NSString
        let start = max(0, targetRange.location - contextRadius)
        let end = min(nsText.length, NSMaxRange(targetRange) + contextRadius)
        return nsText.substring(with: NSRange(location: start, length: end - start))
    }
}
