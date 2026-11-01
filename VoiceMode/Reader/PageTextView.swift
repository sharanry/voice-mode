import SwiftUI
import UIKit

/// Renders one page with TextKit 1 so layout matches `Paginator` exactly.
struct PageTextView: UIViewRepresentable {
    let text: String
    let highlight: NSRange?
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
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Wrap at exactly the width Paginator used, rather than the text's unwrapped width.
        if view.textContainer.size != size { view.textContainer.size = size }
        let string = NSMutableAttributedString(string: text, attributes: style.attributes(color: theme.text))
        if let highlight, NSMaxRange(highlight) <= string.length {
            string.addAttribute(.backgroundColor, value: theme.highlight, range: highlight)
        }
        if view.attributedText != string { view.attributedText = string }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        size
    }
}
