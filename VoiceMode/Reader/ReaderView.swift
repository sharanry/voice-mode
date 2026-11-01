import SwiftUI

struct ReaderView: View {
    @State private var model: ReaderModel
    private let session: PlaybackSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("readerTheme") private var theme: ReaderTheme = .black
    @AppStorage("readerFontSize") private var fontSize: Double = 19
    @State private var showChrome = false
    @State private var showSettings = false
    @State private var showChapters = false

    private let horizontalMargin: CGFloat = 28
    private let topMargin: CGFloat = 36
    private let footerHeight: CGFloat = 92

    init(book: Book, session: PlaybackSession) {
        self.session = session
        _model = State(initialValue: ReaderModel(book: book, session: session))
    }

    private var style: ReaderStyle { ReaderStyle(fontSize: fontSize) }
    private var showPlayer: Bool { showChrome || model.player.status != .idle }

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: theme.background).ignoresSafeArea()

            VStack(spacing: 0) {
                page
                footer.frame(height: footerHeight)
            }

            if showChrome {
                topBar.transition(.move(edge: .top).combined(with: .opacity))
                scrubber.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showChrome)
        .statusBarHidden(!showChrome)
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: model.player.position) { _, spoken in model.follow(spoken) }
        .onAppear { model.didOpen() }
        .onDisappear { session.readerClosed(model.player) }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(theme: $theme, fontSize: $fontSize)
                .presentationDetents([.height(230)])
        }
        .sheet(isPresented: $showChapters) {
            ContentsSheet(chapters: model.document.chapters, current: model.currentContentsEntry) { target in
                model.goTo(target)
                showChapters = false
            }
        }
    }

    private var page: some View {
        GeometryReader { geo in
            let pageSize = CGSize(width: max(0, geo.size.width - horizontalMargin * 2),
                                  height: max(0, geo.size.height - topMargin))
            PageTextView(text: model.pageText, highlight: model.pageHighlight, style: style, theme: theme, size: pageSize)
                .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
                .padding(.top, topMargin)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { location in handleTap(x: location.x, width: geo.size.width) }
                .gesture(
                    DragGesture(minimumDistance: 30).onEnded { value in
                        if value.translation.width < -40 { model.nextPage() }
                        if value.translation.width > 40 { model.previousPage() }
                    }
                )
                .onChange(of: [pageSize.width, pageSize.height, fontSize], initial: true) {
                    model.layout(pageSize: pageSize, style: style)
                }
        }
    }

    private func handleTap(x: CGFloat, width: CGFloat) {
        if x < width * 0.28 {
            model.previousPage()
        } else if x > width * 0.72 {
            model.nextPage()
        } else {
            showChrome.toggle()
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if showPlayer {
                PlayerBar(player: model.player, theme: theme) { model.togglePlayback() }
            }
            Text("\(model.chapter.title)  ·  \(model.pageIndex + 1) of \(max(model.pages.count, 1))  ·  \(model.readingProgress.formatted(.percent.precision(.fractionLength(0))))")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(Color(uiColor: theme.secondary))
                .padding(.horizontal, horizontalMargin)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }

    /// Sits just above the footer while the controls are showing.
    private var scrubber: some View {
        BookScrubber(
            progress: model.progress,
            chapterMarks: model.chapterMarks,
            theme: theme,
            preview: { model.preview(atFraction: $0) },
            commit: { model.goTo(model.position(atFraction: $0)) }
        )
        .padding(.horizontal, horizontalMargin)
        .padding(.top, 12)
        .background(Color(uiColor: theme.background))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, footerHeight)
    }

    private var topBar: some View {
        HStack(spacing: 20) {
            Button { dismiss() } label: { Image(systemName: "chevron.down") }
            Spacer()
            Text(model.document.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button { showChapters = true } label: { Image(systemName: "list.bullet") }
            Button { showSettings = true } label: { Image(systemName: "textformat.size") }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(Color(uiColor: theme.text))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(uiColor: theme.background))
    }
}

private struct ContentsSheet: View {
    let chapters: [Chapter]
    let current: (chapter: Int, heading: Int?)
    let select: (ReadingPosition) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(chapters.indices, id: \.self) { index in
                        let chapter = chapters[index]
                        row(chapter.title, depth: 0, isCurrent: current.chapter == index && current.heading == nil, id: entryID(index, nil)) {
                            select(ReadingPosition(chapter: index, offset: 0))
                        }
                        // Indent relative to the shallowest heading level used in this chapter.
                        let baseLevel = chapter.headings.map(\.level).min() ?? 1
                        ForEach(chapter.headings.indices, id: \.self) { h in
                            let heading = chapter.headings[h]
                            row(heading.title, depth: min(heading.level - baseLevel + 1, 3),
                                isCurrent: current.chapter == index && current.heading == h, id: entryID(index, h)) {
                                select(ReadingPosition(chapter: index, offset: heading.offset))
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(entryID(current.chapter, current.heading), anchor: .center) }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func entryID(_ chapter: Int, _ heading: Int?) -> String {
        heading.map { "\(chapter)-\($0)" } ?? "\(chapter)"
    }

    private func row(_ title: String, depth: Int, isCurrent: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(depth == 0 ? .body.weight(.semibold) : depth == 1 ? .body : .subheadline)
                    .foregroundStyle(depth <= 1 ? .primary : .secondary)
                    .lineLimit(2)
                Spacer()
                if isCurrent { Image(systemName: "checkmark").foregroundStyle(ReaderTheme.accent) }
            }
            .padding(.leading, CGFloat(depth) * 18)
        }
        .tint(.primary)
        .id(id)
    }
}

private struct ReaderSettingsSheet: View {
    @Binding var theme: ReaderTheme
    @Binding var fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Theme", selection: $theme) {
                ForEach(ReaderTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 16) {
                Image(systemName: "textformat.size.smaller")
                Slider(value: $fontSize, in: 14...30, step: 1)
                Image(systemName: "textformat.size.larger")
            }
            .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
