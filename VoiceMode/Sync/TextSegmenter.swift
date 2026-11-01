import Foundation

nonisolated enum TextSegmenter {
    /// Splits a chapter into contiguous TTS request ranges, roughly one paragraph each: cuts at a
    /// paragraph end once a chunk reaches `preferred` length, or at any sentence end at `maximum`.
    /// Synthesis time grows linearly with length (~0.8 s per 100 characters on eleven_v4_turbo), so short
    /// chunks keep time-to-first-audio low; very short paragraphs are merged to save requests.
    static func chunks(in text: String, preferred: Int = 160, maximum: Int = 450) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var ranges: [NSRange] = []
        var start = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            let end = NSMaxRange(enclosing)
            let length = end - start
            let endsParagraph = end >= ns.length || ns.character(at: end - 1) == 10 || ns.character(at: end) == 10
            if length >= maximum || (length >= preferred && endsParagraph) {
                ranges.append(NSRange(location: start, length: length))
                start = end
            }
        }
        if start < ns.length { ranges.append(NSRange(location: start, length: ns.length - start)) }
        return ranges
    }

    /// Sentence ranges (without trailing whitespace), used to highlight what's being spoken.
    static func sentences(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        let whitespace = CharacterSet.whitespacesAndNewlines
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            var range = range
            while range.length > 0,
                  let scalar = Unicode.Scalar(ns.character(at: NSMaxRange(range) - 1)),
                  whitespace.contains(scalar) {
                range.length -= 1
            }
            if range.length > 0 { ranges.append(range) }
        }
        return ranges
    }

    /// Index of the last range starting at or before `offset`.
    static func index(of offset: Int, in ranges: [NSRange]) -> Int? {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].location <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }
}
