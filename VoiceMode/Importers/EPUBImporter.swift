import Foundation
import ZIPFoundation

nonisolated enum EPUBImporter {
    static func document(fromEPUBAt url: URL) throws -> Document {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "epub-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.unzipItem(at: url, to: root)

        let container = XMLCollector.parse(try Data(contentsOf: root.appending(path: "META-INF/container.xml")))
        guard let opfPath = container.first(where: { $0.name == "rootfile" })?.attributes["full-path"] else {
            throw ImportError.malformed("EPUB has no package file")
        }
        let opfURL = URL(filePath: opfPath, relativeTo: root).standardizedFileURL
        let opf = XMLCollector.parse(try Data(contentsOf: opfURL))
        let base = opfURL.deletingLastPathComponent()

        var manifest: [String: String] = [:]
        for item in opf where item.name == "item" {
            if let id = item.attributes["id"], let href = item.attributes["href"] { manifest[id] = href }
        }

        var chapters: [Chapter] = []
        for idref in opf.filter({ $0.name == "itemref" }).compactMap({ $0.attributes["idref"] }) {
            guard let href = manifest[idref] else { continue }
            let path = href.components(separatedBy: "#")[0]
            let fileURL = URL(filePath: path.removingPercentEncoding ?? path, relativeTo: base).standardizedFileURL
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let html = String(decoding: data, as: UTF8.self)
            let (text, headings) = HTMLText.textAndHeadings(fromHTML: html)
            guard !text.isEmpty else { continue }
            let title = HTMLText.firstHeading(inHTML: html) ?? "Section \(chapters.count + 1)"
            chapters.append(Chapter(title: title, text: text, headings: headings.droppingTitle(title)))
        }

        return Document(
            title: opf.first { $0.name == "title" }?.text.nonEmpty ?? url.deletingPathExtension().lastPathComponent,
            author: opf.first { $0.name == "creator" }?.text.nonEmpty,
            chapters: chapters,
            cover: coverHref(in: opf, manifest: manifest)
                .flatMap { try? Data(contentsOf: URL(filePath: $0.removingPercentEncoding ?? $0, relativeTo: base)) }
                .flatMap(CoverImage.thumbnail)
        )
    }

    /// EPUB 3 marks the cover with properties="cover-image"; EPUB 2 with <meta name="cover" content="item-id">.
    private static func coverHref(in opf: [XMLCollector.Element], manifest: [String: String]) -> String? {
        if let item = opf.first(where: { $0.name == "item" && ($0.attributes["properties"] ?? "").split(separator: " ").contains("cover-image") }) {
            return item.attributes["href"]
        }
        if let id = opf.first(where: { $0.name == "meta" && $0.attributes["name"] == "cover" })?.attributes["content"], let href = manifest[id] {
            return href
        }
        return opf.first { item in
            item.name == "item" && (item.attributes["media-type"] ?? "").hasPrefix("image/")
                && (item.attributes["id"] ?? "").localizedCaseInsensitiveContains("cover")
        }?.attributes["href"]
    }
}
