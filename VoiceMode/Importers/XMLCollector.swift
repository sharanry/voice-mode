import Foundation

/// Flattens an XML document into a list of elements (namespace prefixes stripped).
/// Enough for EPUB container/OPF files, which are small and shallow.
nonisolated final class XMLCollector: NSObject, XMLParserDelegate {
    struct Element {
        var name: String
        var attributes: [String: String]
        var text: String
    }

    private var elements: [Element] = []
    private var stack: [Int] = []

    static func parse(_ data: Data) -> [Element] {
        let collector = XMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.elements
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        elements.append(Element(name: localName, attributes: attributeDict, text: ""))
        stack.append(elements.count - 1)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let index = stack.last { elements[index].text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}
