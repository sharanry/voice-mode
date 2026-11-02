import SwiftUI
import UIKit

/// Renders one page with TextKit 1 so layout matches `Paginator` exactly.
struct PageTextView: UIViewRepresentable {
    let text: String
    let highlight: NSRange?
    /// Names of people and organisations.
    var underlines: [Underline] = []
    var probe: PageProbe?
    let style: ReaderStyle
    let theme: ReaderTheme
    let size: CGSize

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = .clear
        view.textContainer.widthTracksTextView = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        probe?.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Wrap at exactly the width Paginator used, rather than the text's unwrapped width.
        if view.textContainer.size != size { view.textContainer.size = size }
        let string = NSMutableAttributedString(string: text, attributes: style.attributes(color: theme.text))
        if let highlight, NSMaxRange(highlight) <= string.length {
            string.addAttribute(.backgroundColor, value: theme.highlight, range: highlight)
        }
        for underline in underlines where NSMaxRange(underline.range) <= string.length {
            // Underlines don't affect layout, so pages from Paginator stay valid.
            let pattern: NSUnderlineStyle = underline.dotted ? .patternDot : .patternDash
            string.addAttributes([.underlineStyle: NSUnderlineStyle.single.union(pattern).rawValue,
                                  .underlineColor: theme.secondary], range: underline.range)
        }
        if view.attributedText != string { view.attributedText = string }
    }

    struct Underline: Equatable {
        var range: NSRange
        var dotted = false
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        size
    }
}

/// Lets the reader find which character of the page is under a tap.
final class PageProbe {
    weak var textView: UITextView?

    /// Index into the page text at `point` (in text-container coordinates), if the point is on a glyph.
    func characterIndex(at point: CGPoint) -> Int? {
        guard let view = textView, view.textStorage.length > 0 else { return nil }
        let layout = view.layoutManager, container = view.textContainer
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -3, dy: -4).contains(point) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }
}
