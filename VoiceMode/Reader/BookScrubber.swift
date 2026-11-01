import SwiftUI

/// Kindle-style whole-book scrubber: drag or tap anywhere to preview a spot, release to jump there.
struct BookScrubber: View {
    let progress: Double
    let chapterMarks: [Double]
    let theme: ReaderTheme
    let preview: (Double) -> (title: String, snippet: String)
    let commit: (Double) -> Void

    @State private var dragFraction: Double?

    private var fraction: Double { dragFraction ?? progress }
    private var chapterUnderThumb: Int { chapterMarks.filter { $0 <= fraction }.count }

    var body: some View {
        VStack(spacing: 12) {
            if let dragFraction {
                let info = preview(dragFraction)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(info.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(dragFraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color(uiColor: theme.secondary))
                    }
                    Text(info.snippet)
                        .font(.footnote)
                        .lineLimit(2)
                        .foregroundStyle(Color(uiColor: theme.secondary))
                }
                .foregroundStyle(Color(uiColor: theme.text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            GeometryReader { geo in
                let width = geo.size.width
                let thumb: CGFloat = dragFraction == nil ? 14 : 22
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: theme.secondary).opacity(0.35)).frame(height: 4)
                    Capsule().fill(ReaderTheme.accent).frame(width: max(4, width * fraction), height: 4)
                    ForEach(chapterMarks, id: \.self) { mark in
                        Rectangle()
                            .fill(Color(uiColor: theme.background))
                            .frame(width: 2, height: 4)
                            .offset(x: width * mark - 1)
                    }
                    Circle()
                        .fill(ReaderTheme.accent)
                        .frame(width: thumb, height: thumb)
                        .offset(x: width * fraction - thumb / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in dragFraction = min(max(value.location.x / width, 0), 1) }
                        .onEnded { value in
                            commit(min(max(value.location.x / width, 0), 1))
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 32)
        }
        .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
        .sensoryFeedback(.selection, trigger: chapterUnderThumb)
        .accessibilityElement()
        .accessibilityLabel("Position in book")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            commit(min(max(progress + (direction == .increment ? 0.05 : -0.05), 0), 1))
        }
    }
}
