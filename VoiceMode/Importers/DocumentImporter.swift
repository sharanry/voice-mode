import Foundation

nonisolated enum ImportError: LocalizedError {
    case unsupported(String)
    case unreadable
    case malformed(String)
    case noText
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): "Unsupported file type “\(ext)”."
        case .unreadable: "The file couldn’t be opened."
        case .malformed(let detail): "The file looks damaged: \(detail)."
        case .noText: "No readable text was found."
        case .http(let status): "The page couldn’t be loaded (HTTP \(status))."
        }
    }
}

nonisolated extension [Heading] {
    /// Drops a leading heading that just repeats the chapter title.
    func droppingTitle(_ title: String) -> [Heading] {
        guard let first, first.offset == 0, first.title == title else { return self }
        return Array(dropFirst())
    }
}

nonisolated enum DocumentImporter {
    @concurrent static func importFile(at url: URL) async throws -> Document {
        let name = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "epub":
            return try validated(EPUBImporter.document(fromEPUBAt: url))
        case "pdf":
            return try validated(PDFImporter.document(fromPDFAt: url))
        case "txt", "text", "md":
            let raw = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(decoding: Data(contentsOf: url), as: UTF8.self)
            return try validated(TextImporter.document(fromPlainText: raw, title: name))
        default:
            throw ImportError.unsupported(url.pathExtension)
        }
    }

    @concurrent static func importWebPage(_ url: URL) async throws -> Document {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, !(200..<300).contains(status) { throw ImportError.http(status) }

        // Links straight to a PDF/EPUB go through the file importers.
        let mime = http?.mimeType ?? ""
        let ext = mime == "application/pdf" ? "pdf" : mime == "application/epub+zip" ? "epub" : url.pathExtension.lowercased()
        if ext == "pdf" || ext == "epub" {
            let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            return try await importFile(at: file)
        }

        let html = String(decoding: data, as: UTF8.self)
        let title = HTMLText.title(fromHTML: html) ?? url.host() ?? "Web Page"
        let (text, headings) = HTMLText.textAndHeadings(fromHTML: HTMLText.mainContent(ofHTML: html), dropPageChrome: true)
        let chapter = Chapter(title: title, text: text, headings: headings.droppingTitle(title))
        let cover = await previewImage(in: html, baseURL: url)
        return try validated(Document(title: title, author: url.host(), chapters: [chapter], cover: cover))
    }

    /// The page's og:image (the picture link previews use), downscaled. Best effort.
    private static func previewImage(in html: String, baseURL: URL) async -> Data? {
        let reference = html.firstCapture(#"(?is)<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)"#)
            ?? html.firstCapture(#"(?is)<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#)
        guard let reference, let imageURL = URL(string: HTMLText.decodeEntities(reference), relativeTo: baseURL),
              let (data, _) = try? await URLSession.shared.data(from: imageURL)
        else { return nil }
        return CoverImage.thumbnail(from: data)
    }

    private static func validated(_ document: Document) throws -> Document {
        var document = document
        document.chapters.removeAll { $0.text.isEmpty }
        guard !document.chapters.isEmpty else { throw ImportError.noText }
        return document
    }
}
