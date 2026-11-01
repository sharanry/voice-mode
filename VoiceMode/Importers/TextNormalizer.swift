import Foundation

nonisolated enum TextNormalizer {
    /// Collapses whitespace within each line, drops empty lines and joins paragraphs with "\n".
    static func lines(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.replacingRegex(#"[\s ]+"#, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// For hard-wrapped text (e.g. Project Gutenberg): blank lines separate paragraphs,
    /// single newlines are just wrapping.
    static func unwrap(_ raw: String) -> String {
        let paragraphs = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingRegex(#"\n[ \t]*\n"#, with: "\u{2029}")
            .components(separatedBy: "\u{2029}")
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
        return lines(paragraphs.joined(separator: "\n"))
    }
}

nonisolated extension String {
    func replacingRegex(_ pattern: String, with template: String) -> String {
        replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    func firstCapture(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(location: 0, length: utf16.count)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self)
        else { return nil }
        return String(self[range])
    }

    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
