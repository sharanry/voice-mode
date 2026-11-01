import Foundation

/// Lightweight HTML → plain text conversion. Regex-based rather than NSAttributedString
/// so it can run off the main thread and stays fast on large EPUBs.
nonisolated enum HTMLText {
    static func plainText(fromHTML html: String, dropPageChrome: Bool = false) -> String {
        textAndHeadings(fromHTML: html, dropPageChrome: dropPageChrome).text
    }

    /// Plain text plus the position of every `<h1>`–`<h6>` heading in it.
    static func textAndHeadings(fromHTML html: String, dropPageChrome: Bool = false) -> (text: String, headings: [Heading]) {
        var s = html
            .replacingRegex(#"(?is)<head\b.*?</head>"#, with: " ")
            .replacingRegex(#"(?is)<(script|style|noscript|svg|template)\b.*?</\1>"#, with: " ")
            .replacingRegex(#"(?s)<!--.*?-->"#, with: " ")
        if dropPageChrome {
            s = s.replacingRegex(#"(?is)<(nav|header|footer|aside|form|figure)\b.*?</\1>"#, with: " ")
        }
        s = s.replacingRegex(#"\s+"#, with: " ")
            // Mark headings so their position survives tag stripping and normalization.
            .replacingRegex(#"(?i)<h([1-6])\b"# + attributes + ">", with: "\n\(headingMarker)$1")
            .replacingRegex(#"(?i)<br\s*/?>"#, with: "\n")
            .replacingRegex(#"(?i)</?(p|div|h[1-6]|li|ul|ol|blockquote|section|article|main|tr|table|pre|dd|dt|hr)\b"# + attributes + ">", with: "\n")
            .replacingRegex("<" + attributes + ">", with: "")

        var lines: [String] = []
        var headings: [Heading] = []
        var length = 0
        for line in TextNormalizer.lines(decodeEntities(s)).components(separatedBy: "\n") {
            var line = line
            var level: Int?
            if line.hasPrefix(headingMarker) {
                let rest = line.dropFirst(headingMarker.count)
                level = rest.first?.wholeNumberValue
                line = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }
            let offset = lines.isEmpty ? 0 : length + 1
            if let level { headings.append(Heading(title: line, level: level, offset: offset)) }
            lines.append(line)
            length = offset + line.utf16.count
        }
        return (lines.joined(separator: "\n"), headings)
    }

    private static let headingMarker = "\u{E000}"
    /// The inside of a tag. Quoted attribute values may contain ">" (Wikipedia's data-mw JSON does).
    private static let attributes = #"(?:[^>"']|"[^"]*"|'[^']*')*"#

    static func title(fromHTML html: String) -> String? {
        html.firstCapture(#"(?is)<title[^>]*>(.*?)</title>"#).flatMap(inlineText)
    }

    static func firstHeading(inHTML html: String) -> String? {
        html.firstCapture(#"(?is)<h[1-3]\b[^>]*>(.*?)</h[1-3]>"#).flatMap(inlineText)
    }

    /// The `<article>` or `<main>` element if the page has one, otherwise the whole page.
    static func mainContent(ofHTML html: String) -> String {
        html.firstCapture(#"(?is)<article\b[^>]*>(.*)</article>"#)
            ?? html.firstCapture(#"(?is)<main\b[^>]*>(.*)</main>"#)
            ?? html
    }

    private static func inlineText(_ fragment: String) -> String? {
        decodeEntities(fragment.replacingRegex(#"<[^>]*>"#, with: ""))
            .replacingRegex(#"\s+"#, with: " ")
            .nonEmpty
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
        "ldquo": "“", "rdquo": "”", "copy": "©", "shy": "",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"),
              let regex = try? NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")
        else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += decodeEntity(ns.substring(with: match.range(at: 1))) ?? ns.substring(with: match.range)
            last = NSMaxRange(match.range)
        }
        return out + ns.substring(from: last)
    }

    private static func decodeEntity(_ body: String) -> String? {
        let scalar: UInt32?
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            scalar = UInt32(body.dropFirst(2), radix: 16)
        } else if body.hasPrefix("#") {
            scalar = UInt32(body.dropFirst())
        } else {
            return namedEntities[body]
        }
        return scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}
