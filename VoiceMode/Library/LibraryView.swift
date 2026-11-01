import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(PlaybackSession.self) private var playback
    @Query private var storedBooks: [Book]
    @State private var openBook: Book?
    @State private var costBook: Book?
    @State private var showFileImporter = false
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    /// Most recently opened (or added) first.
    private var books: [Book] { storedBooks.sorted { $0.recency > $1.recency } }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView("No Books Yet", systemImage: "books.vertical",
                                           description: Text("Import an EPUB, PDF or text file, or add a web page."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 16)], spacing: 22) {
                            ForEach(books) { book in
                                Button { openBook = book } label: { BookCover(book: book) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Cost Details", systemImage: "dollarsign.circle") { costBook = book }
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            if book.persistentModelID == playback.book?.persistentModelID { playback.player?.stop() }
                                            context.delete(book)
                                        }
                                    } preview: {
                                        // Long-press shows what this book's narration has cost so far.
                                        BookCostCard(book: book)
                                    }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                    .safeAreaInset(edge: .bottom) {
                        if let playing = playback.book, let player = playback.player, player.isEngaged {
                            ContinueReadingBar(book: playing, player: player) { openBook = playing }
                        } else if let current = books.first(where: { $0.lastOpenedAt != nil && !$0.isFinished }) {
                            ContinueReadingBar(book: current, player: nil) { openBook = current }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                Menu {
                    Button("Import File…", systemImage: "doc") { showFileImporter = true }
                    Button("Add Web Page…", systemImage: "link") { showURLPrompt = true }
                    Button("Add Sample Book", systemImage: "book") { add(SampleContent.document, source: "Sample") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
            .overlay {
                if isImporting {
                    ProgressView("Importing…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.epub, .pdf, .plainText], onCompletion: importFile)
            .alert("Add Web Page", isPresented: $showURLPrompt) {
                TextField("https://", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") { importURL() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
            .fullScreenCover(item: $openBook) { ReaderView(book: $0, session: playback) }
            .sheet(item: $costBook) { book in
                BookCostSheet(book: book).presentationDetents([.medium, .large])
            }
            .onChange(of: playback.openRequested) { _, requested in
                guard requested else { return }
                playback.openRequested = false
                if let book = playback.book, openBook == nil { openBook = book }
            }
        }
        .tint(ReaderTheme.accent)
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            // The picked file is only readable while the security scope is open, so copy it first.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appending(path: url.lastPathComponent)
            do {
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            runImport(source: url.lastPathComponent) { try await DocumentImporter.importFile(at: copy) }
        }
    }

    private func importURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        urlText = ""
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"), url.host() != nil else {
            errorMessage = "That doesn’t look like a web address."
            return
        }
        runImport(source: url.absoluteString) { try await DocumentImporter.importWebPage(url) }
    }

    private func runImport(source: String, _ work: @escaping () async throws -> Document) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                add(try await work(), source: source)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add(_ document: Document, source: String) {
        let book = Book(document: document, source: source)
        context.insert(book)
        openBook = book
    }
}

private struct BookCover: View {
    let book: Book

    var body: some View {
        CoverArt(book: book)
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .overlay(alignment: .topTrailing) {
                if !book.isFinished, book.readingProgress >= 0.005 {
                    Text(book.readingProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.85))
                        .padding(.trailing, 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if book.isFinished {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(.black.opacity(0.85), in: Circle())
                        .padding(6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(book.title)
            .accessibilityValue(book.isFinished ? "Finished" : "\(Int((book.readingProgress * 100).rounded())) percent read")
    }
}

/// The book's own cover, or a generated one: title on a colour picked from the title.
struct CoverArt: View {
    let book: Book
    /// Too small for a title: show just its first letter.
    var compact = false

    private static let palette: [Color] = [
        Color(red: 0.16, green: 0.24, blue: 0.33), Color(red: 0.36, green: 0.18, blue: 0.20),
        Color(red: 0.18, green: 0.30, blue: 0.24), Color(red: 0.33, green: 0.27, blue: 0.16),
        Color(red: 0.24, green: 0.20, blue: 0.34), Color(red: 0.14, green: 0.14, blue: 0.15),
    ]

    var body: some View {
        if let data = book.coverData, let image = UIImage(data: data) {
            Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill())
        } else {
            let seed = book.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            ZStack(alignment: .topLeading) {
                Self.palette[seed % Self.palette.count]
                if compact {
                    Text(book.title.prefix(1))
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .lineLimit(5)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    if let author = book.author ?? URL(string: book.source)?.host() {
                        Text(author).font(.caption2).lineLimit(2).opacity(0.75)
                    }
                }
                .foregroundStyle(.white)
                .padding(10)
                }
            }
        }
    }
}

/// "Continue reading", or a mini player while a book is narrating with the reader closed.
private struct ContinueReadingBar: View {
    let book: Book
    let player: NarrationPlayer?
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                CoverArt(book: book, compact: true)
                    .frame(width: 34, height: 51)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(book.author ?? "Continue reading") · \(book.readingProgress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the book")

            if let player {
                    Button {
                        player.status == .playing || player.status == .loading ? player.pause() : player.resume()
                    } label: {
                        Image(systemName: player.status == .playing || player.status == .loading ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(ReaderTheme.accent)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(player.status == .playing ? "Pause" : "Play")
            } else {
                Image(systemName: "book").foregroundStyle(ReaderTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
