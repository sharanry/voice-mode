import UIKit

enum Paginator {
    /// Lays the text out into page-sized TextKit containers and returns each page's character range.
    /// Ranges are contiguous and cover the whole text.
    static func pages(for text: String, size: CGSize, style: ReaderStyle) -> [NSRange] {
        let storage = NSTextStorage(string: text, attributes: style.attributes(color: .label))
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var pages: [NSRange] = []
        while true {
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphs = layoutManager.glyphRange(for: container)
            guard glyphs.length > 0 else { break }
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            pages.append(characters)
            if NSMaxRange(characters) >= storage.length { break }
        }
        return pages.isEmpty ? [NSRange(location: 0, length: storage.length)] : pages
    }
}
